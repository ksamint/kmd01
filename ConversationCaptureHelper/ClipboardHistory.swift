import AppKit
import ApplicationServices
import CryptoKit
import Security

struct ClipboardCaptureSnapshot: Sendable {
  let plainText: String?
  let html: Data?
  let rtf: Data?
  let fileURLs: [URL]
}

struct DecodedClipboardCapture: Sendable {
  let content: String
  let fileURLs: [URL]
}

/// Converts pasteboard representations without rendering HTML or following resource URLs.
/// Keeping this pure is important: background clipboard capture must never reach into the
/// source application's sandbox merely to obtain a textual history entry.
enum ClipboardCaptureDecoder {
  static func decode(_ snapshot: ClipboardCaptureSnapshot) -> DecodedClipboardCapture? {
    let content = nonempty(snapshot.plainText)
      ?? snapshot.rtf.flatMap(rtfText)
      ?? snapshot.html.flatMap(htmlText)
    guard let content else { return nil }
    return DecodedClipboardCapture(
      content: content,
      fileURLs: snapshot.fileURLs.filter(isEligibleFileURL)
    )
  }

  static func isEligibleFileURL(_ url: URL) -> Bool {
    guard url.isFileURL else { return false }
    let path = url.standardizedFileURL.path
    guard !path.isEmpty else { return false }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let protectedRoots = [
      home.appending(path: "Library/Containers", directoryHint: .isDirectory).path,
      home.appending(path: "Library/Group Containers", directoryHint: .isDirectory).path,
      home.appending(path: "Library/Application Scripts", directoryHint: .isDirectory).path,
    ]
    return !protectedRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  private static func rtfText(_ data: Data) -> String? {
    guard let value = try? NSAttributedString(
      data: data,
      options: [.documentType: NSAttributedString.DocumentType.rtf],
      documentAttributes: nil
    ).string else { return nil }
    return nonempty(value)
  }

  /// Deliberately uses text transforms rather than AppKit's HTML attributed-string importer.
  /// The attributed-string importer can create WebKit processes and resolve local resources.
  private static func htmlText(_ data: Data) -> String? {
    let source = String(data: data, encoding: .utf8)
      ?? String(data: data, encoding: .utf16)
      ?? String(decoding: data, as: UTF8.self)
    var value = replacing(
      #"<(script|style|noscript|template|iframe|object|embed)\b[^>]*>[\s\S]*?(?:</\1\s*>|$)"#,
      in: source,
      with: ""
    )
    value = replacing(
      #"<\s*(?:br\s*/?|/\s*(?:p|div|li|tr|h[1-6]|blockquote|pre|section|article|header|footer))\s*>"#,
      in: value,
      with: "\n"
    )
    value = replacing(#"<[^>]*>"#, in: value, with: "")
    value = decodeHTMLEntities(value)
    let lines = value
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return nonempty(lines.joined(separator: "\n"))
  }

  private static func replacing(
    _ pattern: String,
    in value: String,
    with replacement: String
  ) -> String {
    guard let expression = try? NSRegularExpression(
      pattern: pattern,
      options: [.caseInsensitive]
    ) else { return value }
    let range = NSRange(value.startIndex ..< value.endIndex, in: value)
    return expression.stringByReplacingMatches(
      in: value,
      options: [],
      range: range,
      withTemplate: replacement
    )
  }

  private static func decodeHTMLEntities(_ value: String) -> String {
    guard let expression = try? NSRegularExpression(
      pattern: #"&(?:#([0-9]+)|#x([0-9a-f]+)|(amp|lt|gt|quot|apos|nbsp));"#,
      options: [.caseInsensitive]
    ) else { return value }
    var result = value
    let range = NSRange(value.startIndex ..< value.endIndex, in: value)
    for match in expression.matches(in: value, options: [], range: range).reversed() {
      guard let matchRange = Range(match.range, in: result) else { continue }
      let replacement: String?
      if let decimalRange = Range(match.range(at: 1), in: value) {
        replacement = UInt32(value[decimalRange]).flatMap(UnicodeScalar.init).map(String.init)
      } else if let hexadecimalRange = Range(match.range(at: 2), in: value) {
        replacement = UInt32(value[hexadecimalRange], radix: 16)
          .flatMap(UnicodeScalar.init)
          .map(String.init)
      } else if let nameRange = Range(match.range(at: 3), in: value) {
        replacement = [
          "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        ][value[nameRange].lowercased()]
      } else {
        replacement = nil
      }
      if let replacement { result.replaceSubrange(matchRange, with: replacement) }
    }
    return result
  }
}

enum ClipboardContentCategory: String, Codable, CaseIterable, Sendable {
  case text, link, code, file

  var localizedTitle: String {
    switch self {
    case .text: String(localized: "Text")
    case .link: String(localized: "Links")
    case .code: String(localized: "Code")
    case .file: String(localized: "Files")
    }
  }

  var systemImage: String {
    switch self {
    case .text: "text.alignleft"
    case .link: "link"
    case .code: "chevron.left.forwardslash.chevron.right"
    case .file: "doc"
    }
  }
}

struct ClipboardHistoryCapture: Sendable {
  let content: String
  let sourceName: String?
  let sourceBundleID: String?
  let sourceURL: String?
  let sessionName: String?
  let hasFiles: Bool
  let hasRichText: Bool
}

struct ClipboardSourceContext: Sendable {
  let applicationName: String?
  let bundleIdentifier: String?
  let sourceURL: String?
  let sessionName: String?
}

@MainActor
enum ClipboardSourceContextReader {
  static func read(pasteboard: NSPasteboard, application: NSRunningApplication?) -> ClipboardSourceContext {
    let metadata = pasteboardMetadata(pasteboard)
    let accessibility = metadata.url == nil || metadata.title == nil
      ? accessibilityMetadata(application)
      : (url: nil, title: nil)
    return ClipboardSourceContext(
      applicationName: application?.localizedName,
      bundleIdentifier: application?.bundleIdentifier,
      sourceURL: ClipboardHistoryStore.sanitizedSourceURL(metadata.url ?? accessibility.url),
      sessionName: ClipboardHistoryStore.normalizedSessionName(metadata.title ?? accessibility.title)
    )
  }
}

enum ClipboardStorageEnvironment {
  static let appGroupIdentifier = "group.art.apuch.ksamint-markedit"

  static var sharedRootURL: URL {
    if hasAppGroupEntitlement,
       let groupURL = FileManager.default.containerURL(
         forSecurityApplicationGroupIdentifier: appGroupIdentifier
       ) {
      return groupURL
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "kmd Development", directoryHint: .isDirectory)
  }

  static var isDevelopmentBundle: Bool {
    Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
  }

  // Entitlements cannot change while the process runs; resolve once.
  static let hasAppGroupEntitlement: Bool = {
    guard let task = SecTaskCreateFromSelf(nil),
          let groups = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.security.application-groups" as CFString,
            nil
          ) as? [String] else { return false }
    return groups.contains(appGroupIdentifier)
  }()

  static func developmentKey(named fileName: String) throws -> SymmetricKey {
    guard isDevelopmentBundle else { throw CocoaError(.fileWriteNoPermission) }
    let directory = sharedRootURL.appending(path: "Keys", directoryHint: .isDirectory)
    let url = directory.appending(path: fileName, directoryHint: .notDirectory)
    if let data = try? Data(contentsOf: url), data.count == 32 { return SymmetricKey(data: data) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = Data(SymmetricKey(size: .bits256).withUnsafeBytes(Array.init))
    try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return SymmetricKey(data: data)
  }
}

struct ClipboardHistoryItem: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let capturedAt: Date
  let sourceName: String?
  let sourceBundleID: String?
  let sourceURL: String?
  let sessionName: String?
  let content: String
  let category: ClipboardContentCategory
  var isPinned: Bool
  var isPermanent: Bool
  var tagIDs: [String]

  init(
    id: String,
    capturedAt: Date,
    sourceName: String?,
    sourceBundleID: String?,
    sourceURL: String? = nil,
    sessionName: String? = nil,
    content: String,
    category: ClipboardContentCategory,
    isPinned: Bool = false,
    isPermanent: Bool = false,
    tagIDs: [String] = []
  ) {
    self.id = id
    self.capturedAt = capturedAt
    self.sourceName = sourceName
    self.sourceBundleID = sourceBundleID
    self.sourceURL = sourceURL
    self.sessionName = sessionName
    self.content = content
    self.category = category
    self.isPinned = isPinned
    self.isPermanent = isPermanent
    self.tagIDs = tagIDs
  }

  private enum CodingKeys: String, CodingKey {
    case id, capturedAt, sourceName, sourceBundleID, sourceURL, sessionName
    case content, category, isPinned, isPermanent, tagIDs
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    capturedAt = try container.decode(Date.self, forKey: .capturedAt)
    sourceName = try container.decodeIfPresent(String.self, forKey: .sourceName)
    sourceBundleID = try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
    sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)
    sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName)
    content = try container.decode(String.self, forKey: .content)
    category = try container.decode(ClipboardContentCategory.self, forKey: .category)
    isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    isPermanent = try container.decodeIfPresent(Bool.self, forKey: .isPermanent) ?? false
    tagIDs = try container.decodeIfPresent([String].self, forKey: .tagIDs) ?? []
  }
}

struct ClipboardUserTag: Codable, Equatable, Identifiable, Sendable {
  let id: String
  var name: String
}

struct ClipboardHistoryArchive: Codable {
  let version: Int
  var items: [ClipboardHistoryItem]
  var tags: [ClipboardUserTag]
}

struct ClipboardItemMetadata: Codable {
  let id: String
  let isPinned: Bool
  let isPermanent: Bool
  let tagIDs: [String]
}

enum ClipboardHistoryJournalEvent: Codable {
  case snapshot(ClipboardHistoryArchive)
  case upsert(ClipboardHistoryItem)
  case removeItems([String])
  case replaceTags([ClipboardUserTag])
  case updateItems([ClipboardItemMetadata])
  case clearItems
}

@MainActor
final class ClipboardHistoryStore {
  static let maximumRecentItems = 10_000
  private static let maximumPinnedItems = 100
  private static let maximumTags = 32
  private static let maximumTagNameLength = 40
  private static let maximumItemBytes = 5 * 1024 * 1024
  private static let maximumJournalRecordBytes = 64 * 1024 * 1024
  private static let compactionJournalBytes = 128 * 1024 * 1024
  private static let compactionRecordCount = 20_000
  private static let keyService = "art.apuch.ksamint-markedit.clipboard-history"
  private static let keyAccount = "clipboard-history-v1"

  private let overrideJournalURL: URL?
  private let overrideLegacyURL: URL?
  private let overrideKey: SymmetricKey?
  private var cachedHistoryKey: SymmetricKey?
  private(set) var items = [ClipboardHistoryItem]()
  private(set) var tags = [ClipboardUserTag]()
  private var itemPositions = [String: Int]()
  private var recentItemCount = 0
  private var journalByteCount = 0
  private var journalRecordCount = 0
  var onKnowledgeChange: (() -> Void)?

  init(fileURL: URL? = nil, legacyFileURL: URL? = nil, key: SymmetricKey? = nil) {
    overrideJournalURL = fileURL
    overrideLegacyURL = legacyFileURL
    overrideKey = key
    load()
    enforceCapacity()
  }

  @discardableResult
  func record(_ capture: ClipboardHistoryCapture) -> Bool {
    let normalized = capture.content
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .precomposedStringWithCompatibilityMapping
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = normalized.data(using: .utf8), !data.isEmpty,
          data.count <= Self.maximumItemBytes else { return false }

    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let existingIndex = itemPositions[digest]
    let existing = existingIndex.map { items[$0] }
    let item = ClipboardHistoryItem(
      id: digest,
      capturedAt: Date(),
      sourceName: capture.sourceName ?? existing?.sourceName,
      sourceBundleID: capture.sourceBundleID ?? existing?.sourceBundleID,
      sourceURL: Self.sanitizedSourceURL(capture.sourceURL) ?? existing?.sourceURL,
      sessionName: Self.normalizedSessionName(capture.sessionName) ?? existing?.sessionName,
      content: normalized,
      category: Self.category(for: normalized, hasFiles: capture.hasFiles),
      isPinned: existing?.isPinned ?? false,
      isPermanent: (existing?.isPermanent ?? false)
        || Self.shouldArchivePermanently(normalized, hasRichText: capture.hasRichText),
      tagIDs: existing?.tagIDs ?? []
    )

    var candidate = items
    if let existingIndex { candidate[existingIndex] = item } else { candidate.append(item) }
    let projectedRecentCount = recentItemCount
      - ((existing.map(Self.isOrdinary) ?? false) ? 1 : 0)
      + (Self.isOrdinary(item) ? 1 : 0)
    let removed = projectedRecentCount > Self.maximumRecentItems
      ? Self.trimmedRecentItems(&candidate)
      : []
    var events: [ClipboardHistoryJournalEvent] = [.upsert(item)]
    if !removed.isEmpty { events.append(.removeItems(removed)) }
    guard append(events) else { return false }
    items = candidate
    rebuildItemIndex()
    finishMutation(syncKnowledge: item.isPermanent || item.isPinned || !item.tagIDs.isEmpty)
    return true
  }

  @discardableResult
  func record(content: String, sourceName: String?, sourceBundleID: String?, hasFiles: Bool) -> Bool {
    record(ClipboardHistoryCapture(
      content: content,
      sourceName: sourceName,
      sourceBundleID: sourceBundleID,
      sourceURL: nil,
      sessionName: nil,
      hasFiles: hasFiles,
      hasRichText: false
    ))
  }

  func createTag(named proposedName: String) -> ClipboardUserTag? {
    guard let name = normalizedTagName(proposedName) else { return nil }
    if let existing = tags.first(where: { equivalentTagNames($0.name, name) }) { return existing }
    guard tags.count < Self.maximumTags else { return nil }
    let tag = ClipboardUserTag(id: UUID().uuidString.lowercased(), name: name)
    let candidate = tags + [tag]
    guard append([.replaceTags(candidate)]) else { return nil }
    tags = candidate
    finishMutation()
    return tag
  }

  @discardableResult
  func renameTag(id: String, to proposedName: String) -> Bool {
    guard let name = normalizedTagName(proposedName),
          !tags.contains(where: { $0.id != id && equivalentTagNames($0.name, name) }),
          let index = tags.firstIndex(where: { $0.id == id }) else { return false }
    var candidate = tags
    candidate[index].name = name
    guard append([.replaceTags(candidate)]) else { return false }
    tags = candidate
    finishMutation()
    return true
  }

  func deleteTag(id: String) {
    guard tags.contains(where: { $0.id == id }) else { return }
    let candidateTags = tags.filter { $0.id != id }
    var candidateItems = items
    for index in candidateItems.indices { candidateItems[index].tagIDs.removeAll { $0 == id } }
    guard append([.replaceTags(candidateTags), .updateItems(candidateItems.map(Self.metadata))]) else { return }
    tags = candidateTags
    items = candidateItems
    rebuildItemIndex()
    finishMutation()
  }

  @discardableResult
  func togglePinned(itemID: String) -> Bool? {
    guard let index = itemPositions[itemID] else { return nil }
    if !items[index].isPinned, items.filter(\.isPinned).count >= Self.maximumPinnedItems { return nil }
    var item = items[index]
    item.isPinned.toggle()
    if item.isPinned { item.isPermanent = true }
    guard append([.updateItems([Self.metadata(item)])]) else { return nil }
    items[index] = item
    rebuildItemIndex()
    finishMutation()
    return item.isPinned
  }

  @discardableResult
  func togglePermanent(itemID: String) -> Bool? {
    guard let index = itemPositions[itemID] else { return nil }
    var item = items[index]
    if item.isPermanent, item.isPinned || !item.tagIDs.isEmpty { return true }
    item.isPermanent.toggle()
    guard append([.updateItems([Self.metadata(item)])]) else { return nil }
    items[index] = item
    rebuildItemIndex()
    finishMutation()
    return item.isPermanent
  }

  @discardableResult
  func toggleTag(_ tagID: String, for itemID: String) -> Bool? {
    guard tags.contains(where: { $0.id == tagID }),
          let index = itemPositions[itemID] else { return nil }
    var item = items[index]
    let result: Bool
    if let tagIndex = item.tagIDs.firstIndex(of: tagID) {
      item.tagIDs.remove(at: tagIndex)
      result = false
    } else {
      item.tagIDs.append(tagID)
      item.isPermanent = true
      result = true
    }
    guard append([.updateItems([Self.metadata(item)])]) else { return nil }
    items[index] = item
    rebuildItemIndex()
    finishMutation()
    return result
  }

  func tagNames(for item: ClipboardHistoryItem) -> [String] {
    let selected = Set(item.tagIDs)
    return tags.filter { selected.contains($0.id) }.map(\.name)
  }

  func clear() {
    // Keep the classification itself as a retention signal. Older journals
    // may contain labels from before labeling also set `isPermanent`.
    let preserved = items.filter { $0.isPinned || $0.isPermanent || !$0.tagIDs.isEmpty }
    do {
      try rewriteJournal(items: preserved, tags: tags)
      items = preserved
      rebuildItemIndex()
      finishMutation(syncKnowledge: false)
    } catch {
      return
    }
  }

  static func category(for content: String, hasFiles: Bool) -> ClipboardContentCategory {
    if hasFiles { return .file }
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
       ["http", "https", "mailto"].contains(scheme), !trimmed.contains(where: \.isWhitespace) { return .link }
    let signals = ["```", "func ", "class ", "struct ", "import ", "const ", "let ", "var ", "=>", "</", "#!/"]
    let punctuation = trimmed.filter { "{}[]();=<>".contains($0) }.count
    if signals.contains(where: trimmed.contains) || (trimmed.contains("\n") && punctuation >= 4) { return .code }
    return .text
  }

  static func shouldArchivePermanently(_ content: String, hasRichText: Bool) -> Bool {
    let count = content.count
    if count >= 4_000 || (hasRichText && count >= 1_500) { return true }
    guard count >= 2_000 else { return false }
    let patterns = [
      #"(?m)^#{1,6}\s+\S"#,
      #"(?m)^(?:[-*+] |\d+[.)] )\S"#,
      #"(?m)^```"#,
      #"(?m)^\|.+\|\s*$"#,
      #"\n\s*\n"#,
    ]
    return patterns.reduce(into: 0) { count, pattern in
      if content.range(of: pattern, options: .regularExpression) != nil { count += 1 }
    } >= 2
  }

  static func sanitizedSourceURL(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), value.count <= 2_048,
          let url = URL(string: value), let scheme = url.scheme?.lowercased(),
          ["http", "https", "file"].contains(scheme) else { return nil }
    return url.absoluteString
  }

  static func normalizedSessionName(_ value: String?) -> String? {
    guard let value = value?.precomposedStringWithCompatibilityMapping
      .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return String(value.prefix(240))
  }
}

private extension ClipboardHistoryStore {
  enum JournalLoadResult {
    case loaded
    case missing
    case corrupt
  }

  func enforceCapacity() {
    trimLoadedItemsIfNeeded()
  }

  func load() {
    do {
      let journalURL = try historyJournalURL()
      switch loadJournal(journalURL) {
      case .loaded:
        sanitizeLoadedState()
        return
      case .corrupt:
        // Never replace a newer, damaged journal with stale legacy data. The original
        // ciphertext remains intact for explicit recovery or future repair tooling.
        return
      case .missing:
        break
      }
      if let archive = loadLegacyArchive() {
        items = archive.items
        tags = archive.tags
        sanitizeLoadedState()
        try rewriteJournal(items: items, tags: tags)
      }
    } catch {
      // Clipboard monitoring must never interrupt copying or the host app.
    }
  }

  func loadJournal(_ url: URL) -> JournalLoadResult {
    guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
    if (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == 0 { return .missing }
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    guard let handle = try? FileHandle(forUpdating: url) else { return .corrupt }
    defer { try? handle.close() }
    var decodedAny = false
    journalByteCount = 0
    journalRecordCount = 0
    // One Keychain round-trip and one decoder for the whole journal, not one
    // per record; a long journal used to pay thousands of securityd calls.
    guard let key = try? historyKey() else { return .corrupt }
    let decoder = JSONDecoder()
    while let header = readExactly(4, from: handle) {
      let length = Int(header[0]) | (Int(header[1]) << 8)
        | (Int(header[2]) << 16) | (Int(header[3]) << 24)
      guard length > 0, length <= Self.maximumJournalRecordBytes,
            let record = readExactly(length, from: handle) else { break }
      guard let sealed = try? AES.GCM.SealedBox(combined: record),
            let plaintext = try? AES.GCM.open(sealed, using: key) else { break }
      let events = (try? decoder.decode([ClipboardHistoryJournalEvent].self, from: plaintext))
        ?? (try? [decoder.decode(ClipboardHistoryJournalEvent.self, from: plaintext)])
      guard let events else { break }
      events.forEach(apply)
      decodedAny = true
      journalRecordCount += 1
      journalByteCount += 4 + length
    }
    if decodedAny,
       let fileSize = try? handle.seekToEnd(),
       fileSize > UInt64(journalByteCount) {
      try? handle.truncate(atOffset: UInt64(journalByteCount))
    }
    return decodedAny ? .loaded : .corrupt
  }

  func readExactly(_ count: Int, from handle: FileHandle) -> Data? {
    var result = Data()
    result.reserveCapacity(count)
    while result.count < count {
      guard let chunk = try? handle.read(upToCount: count - result.count),
            !chunk.isEmpty else { return nil }
      result.append(chunk)
    }
    return result
  }

  func loadLegacyArchive() -> ClipboardHistoryArchive? {
    let candidates: [URL]
    if let overrideLegacyURL { candidates = [overrideLegacyURL] } else if let overrideJournalURL {
      candidates = [overrideJournalURL]
    } else {
      candidates = (try? [legacyHistoryFileURL()]) ?? []
    }
    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
      guard let encrypted = try? Data(contentsOf: url),
            let sealed = try? AES.GCM.SealedBox(combined: encrypted),
            let plaintext = try? AES.GCM.open(sealed, using: historyKey()) else { continue }
      if let archive = try? JSONDecoder().decode(ClipboardHistoryArchive.self, from: plaintext) { return archive }
      if let legacyItems = try? JSONDecoder().decode([ClipboardHistoryItem].self, from: plaintext) {
        return ClipboardHistoryArchive(version: 1, items: legacyItems, tags: [])
      }
    }
    return nil
  }

  func append(_ events: [ClipboardHistoryJournalEvent]) -> Bool {
    guard !events.isEmpty else { return true }
    do {
      let url = try historyJournalURL()
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      if !FileManager.default.fileExists(atPath: url.path) {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return false }
        try FileManager.default.setAttributes([
          .protectionKey: FileProtectionType.completeUnlessOpen,
          .posixPermissions: 0o600,
        ], ofItemAtPath: url.path)
      }
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      let plaintext = try JSONEncoder().encode(events)
      let sealed = try AES.GCM.seal(plaintext, using: historyKey())
      guard let combined = sealed.combined, combined.count <= Self.maximumJournalRecordBytes else { return false }
      var length = UInt32(combined.count).littleEndian
      try withUnsafeBytes(of: &length) { try handle.write(contentsOf: $0) }
      try handle.write(contentsOf: combined)
      journalByteCount += 4 + combined.count
      journalRecordCount += 1
      return true
    } catch { return false }
  }

  func rewriteJournal(items: [ClipboardHistoryItem], tags: [ClipboardUserTag]) throws {
    let url = try historyJournalURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporaryURL = url.deletingLastPathComponent().appending(path: ".history-v2-\(UUID().uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    try FileManager.default.setAttributes([
      .protectionKey: FileProtectionType.completeUnlessOpen,
      .posixPermissions: 0o600,
    ], ofItemAtPath: temporaryURL.path)
    let handle = try FileHandle(forWritingTo: temporaryURL)
    let key = try historyKey()
    var recordCount = 0
    defer { try? handle.close() }
    try writeJournalRecord(
      [.snapshot(ClipboardHistoryArchive(version: 3, items: [], tags: tags))],
      to: handle,
      key: key
    )
    recordCount += 1
    var batch = [ClipboardHistoryJournalEvent]()
    var estimatedBytes = 0
    for item in items {
      let itemBytes = item.content.utf8.count + 2_048
      if !batch.isEmpty, estimatedBytes + itemBytes > 8 * 1024 * 1024 {
        try writeJournalRecord(batch, to: handle, key: key)
        recordCount += 1
        batch.removeAll(keepingCapacity: true)
        estimatedBytes = 0
      }
      batch.append(.upsert(item))
      estimatedBytes += itemBytes
    }
    if !batch.isEmpty {
      try writeJournalRecord(batch, to: handle, key: key)
      recordCount += 1
    }
    try handle.synchronize()
    try handle.close()
    if FileManager.default.fileExists(atPath: url.path) {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
    } else { try FileManager.default.moveItem(at: temporaryURL, to: url) }
    try FileManager.default.setAttributes([
      .protectionKey: FileProtectionType.completeUnlessOpen,
      .posixPermissions: 0o600,
    ], ofItemAtPath: url.path)
    journalByteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    journalRecordCount = recordCount
  }

  func writeJournalRecord(
    _ events: [ClipboardHistoryJournalEvent],
    to handle: FileHandle,
    key: SymmetricKey
  ) throws {
    let plaintext = try JSONEncoder().encode(events)
    let sealed = try AES.GCM.seal(plaintext, using: key)
    guard let combined = sealed.combined, combined.count <= Self.maximumJournalRecordBytes else {
      throw CocoaError(.fileWriteOutOfSpace)
    }
    var length = UInt32(combined.count).littleEndian
    try withUnsafeBytes(of: &length) { try handle.write(contentsOf: $0) }
    try handle.write(contentsOf: combined)
  }

  func finishMutation(syncKnowledge: Bool = true) {
    compactJournalIfNeeded()
    if syncKnowledge { onKnowledgeChange?() }
  }

  func compactJournalIfNeeded() {
    guard journalByteCount >= Self.compactionJournalBytes
      || journalRecordCount >= Self.compactionRecordCount else { return }
    try? rewriteJournal(items: items, tags: tags)
  }

  func apply(_ event: ClipboardHistoryJournalEvent) {
    switch event {
    case let .snapshot(archive): items = archive.items; tags = archive.tags; rebuildItemIndex()
    case let .upsert(item):
      if let index = itemPositions[item.id] {
        items[index] = item
      } else {
        itemPositions[item.id] = items.count
        items.append(item)
      }
    case let .removeItems(ids):
      let selected = Set(ids)
      items.removeAll { selected.contains($0.id) }
      rebuildItemIndex()
    case let .replaceTags(newTags): tags = newTags
    case let .updateItems(metadata):
      let values = Dictionary(uniqueKeysWithValues: metadata.map { ($0.id, $0) })
      for index in items.indices where values[items[index].id] != nil {
        guard let value = values[items[index].id] else { continue }
        items[index].isPinned = value.isPinned
        items[index].isPermanent = value.isPermanent
        items[index].tagIDs = value.tagIDs
      }
    case .clearItems: items.removeAll(); rebuildItemIndex()
    }
  }

  func sanitizeLoadedState() {
    tags = Array(tags.prefix(Self.maximumTags))
    let validTagIDs = Set(tags.map(\.id))
    for index in items.indices {
      items[index].tagIDs = items[index].tagIDs.filter(validTagIDs.contains)
      if items[index].isPinned || !items[index].tagIDs.isEmpty {
        items[index].isPermanent = true
      }
    }
    rebuildItemIndex()
    trimLoadedItemsIfNeeded()
  }

  func trimLoadedItemsIfNeeded() {
    var candidate = items
    let removed = Self.trimmedRecentItems(&candidate)
    if !removed.isEmpty, append([.removeItems(removed)]) {
      items = candidate
      rebuildItemIndex()
    }
  }

  static func trimmedRecentItems(_ values: inout [ClipboardHistoryItem]) -> [String] {
    let ordinary = values.filter(isOrdinary).sorted { $0.capturedAt > $1.capturedAt }
    guard ordinary.count > maximumRecentItems else { return [] }
    let removed = ordinary.dropFirst(maximumRecentItems).map(\.id)
    let selected = Set(removed)
    values.removeAll { selected.contains($0.id) }
    return removed
  }

  static func isOrdinary(_ item: ClipboardHistoryItem) -> Bool {
    !item.isPinned && !item.isPermanent
  }

  func rebuildItemIndex() {
    itemPositions.removeAll(keepingCapacity: true)
    for (index, item) in items.enumerated() { itemPositions[item.id] = index }
    recentItemCount = items.filter(Self.isOrdinary).count
  }

  static func metadata(_ item: ClipboardHistoryItem) -> ClipboardItemMetadata {
    ClipboardItemMetadata(id: item.id, isPinned: item.isPinned, isPermanent: item.isPermanent, tagIDs: item.tagIDs)
  }

  func historyJournalURL() throws -> URL {
    if let overrideJournalURL { return overrideJournalURL }
    return try historyDirectoryURL().appending(path: "history-v2.ksj")
  }

  func legacyHistoryFileURL() throws -> URL {
    if let overrideLegacyURL { return overrideLegacyURL }
    return try historyDirectoryURL().appending(path: "history-v1.ksc")
  }

  func historyDirectoryURL() throws -> URL {
    ClipboardStorageEnvironment.sharedRootURL
      .appending(path: "ClipboardHistory", directoryHint: .isDirectory)
  }

  func historyKey() throws -> SymmetricKey {
    if let overrideKey { return overrideKey }
    if let cachedHistoryKey { return cachedHistoryKey }
    let key = try resolveHistoryKey()
    cachedHistoryKey = key
    return key
  }

  private func resolveHistoryKey() throws -> SymmetricKey {
    if !ClipboardStorageEnvironment.hasAppGroupEntitlement {
      return try ClipboardStorageEnvironment.developmentKey(named: "clipboard-history-v1.key")
    }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keyService,
      kSecAttrAccount as String: Self.keyAccount,
      kSecReturnData as String: true,
    ]
    var item: CFTypeRef?
    if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
       let data = item as? Data, data.count == 32 { return SymmetricKey(data: data) }

    let data = Data(SymmetricKey(size: .bits256).withUnsafeBytes(Array.init))
    var add = query
    add.removeValue(forKey: kSecReturnData as String)
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    add[kSecValueData as String] = data
    let status = SecItemAdd(add as CFDictionary, nil)
    if status == errSecSuccess { return SymmetricKey(data: data) }
    if status == errSecDuplicateItem {
      var existing: CFTypeRef?
      if SecItemCopyMatching(query as CFDictionary, &existing) == errSecSuccess,
         let existingData = existing as? Data, existingData.count == 32 { return SymmetricKey(data: existingData) }
    }
    throw CocoaError(.fileWriteNoPermission)
  }

  func normalizedTagName(_ proposedName: String) -> String? {
    let value = proposedName.precomposedStringWithCompatibilityMapping
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : String(value.prefix(Self.maximumTagNameLength))
  }

  func equivalentTagNames(_ lhs: String, _ rhs: String) -> Bool {
    lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == .orderedSame
  }
}

private extension ClipboardSourceContextReader {
  static func pasteboardMetadata(_ pasteboard: NSPasteboard) -> (url: String?, title: String?) {
    let sourceTypes = [
      NSPasteboard.PasteboardType("org.chromium.source-url"),
      NSPasteboard.PasteboardType("public.url"),
    ]
    let titleTypes = [
      NSPasteboard.PasteboardType("public.url-name"),
      NSPasteboard.PasteboardType("org.chromium.source-title"),
    ]
    let directURL = sourceTypes.compactMap { pasteboard.string(forType: $0) }.first
    let directTitle = titleTypes.compactMap { pasteboard.string(forType: $0) }.first
    let archive = webArchiveMetadata(pasteboard)
    return (directURL ?? archive.url, directTitle ?? archive.title)
  }

  static func webArchiveMetadata(_ pasteboard: NSPasteboard) -> (url: String?, title: String?) {
    let types = [
      NSPasteboard.PasteboardType("Apple Web Archive pasteboard type"),
      NSPasteboard.PasteboardType("com.apple.webarchive"),
    ]
    for type in types {
      guard let data = pasteboard.data(forType: type), data.count <= 2 * 1024 * 1024,
            let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let archive = object as? [String: Any] else { continue }
      let main = archive["WebMainResource"] as? [String: Any]
      let url = main?["WebResourceURL"] as? String
      let title = archive["WebTitle"] as? String ?? main?["WebResourceTitle"] as? String
      if url != nil || title != nil { return (url, title) }
    }
    return (nil, nil)
  }

  static func accessibilityMetadata(_ application: NSRunningApplication?) -> (url: String?, title: String?) {
    guard AXIsProcessTrusted(), let application else { return (nil, nil) }
    let appElement = AXUIElementCreateApplication(application.processIdentifier)
    var focusedValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
          let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return (nil, nil) }
    let window = unsafeDowncast(focusedValue, to: AXUIElement.self)
    return (
      attribute(kAXDocumentAttribute as CFString, from: window),
      attribute(kAXTitleAttribute as CFString, from: window)
    )
  }

  static func attribute(_ name: CFString, from element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value as? String
  }
}

/// Materializes durable clipboard knowledge as ordinary Markdown so the workspace index,
/// global search, encrypted Vault sync, and encrypted GitHub backup all share one source of truth.
enum ClipboardKnowledgeArchive {
  struct Report: Sendable, Equatable {
    let written: Int
    let unchanged: Int
  }

  static func reconcile(
    items: [ClipboardHistoryItem],
    tags: [ClipboardUserTag],
    workspaceRoot: URL
  ) throws -> Report {
    let tagNames = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0.name) })
    var written = 0
    var unchanged = 0
    let labelCatalog = workspaceRoot
      .appending(path: "Clipboard", directoryHint: .isDirectory)
      .appending(path: "Labels.md", directoryHint: .notDirectory)
    let labelMarkdown = labelsMarkdown(tags)
    if let existing = try? String(contentsOf: labelCatalog, encoding: .utf8), existing == labelMarkdown {
      unchanged += 1
    } else {
      try FileManager.default.createDirectory(
        at: labelCatalog.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data(labelMarkdown.utf8).write(
        to: labelCatalog,
        options: [.atomic, .completeFileProtectionUnlessOpen]
      )
      written += 1
    }
    for item in items where item.isPermanent || item.isPinned || !item.tagIDs.isEmpty {
      let calendar = Calendar(identifier: .gregorian)
      let parts = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0) ?? .current, from: item.capturedAt)
      let directory = workspaceRoot
        .appending(path: "Clipboard", directoryHint: .isDirectory)
        .appending(path: String(format: "%04d", parts.year ?? 0), directoryHint: .isDirectory)
        .appending(path: String(format: "%02d", parts.month ?? 0), directoryHint: .isDirectory)
      let destination = directory.appending(path: "Clip--\(item.id).md", directoryHint: .notDirectory)
      let markdown = markdown(item: item, tagNames: item.tagIDs.compactMap { tagNames[$0] })
      if let existing = try? String(contentsOf: destination, encoding: .utf8), existing == markdown {
        unchanged += 1
        continue
      }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(markdown.utf8).write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
      written += 1
    }
    return Report(written: written, unchanged: unchanged)
  }

  private static func labelsMarkdown(_ tags: [ClipboardUserTag]) -> String {
    let rows = tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      .map { "- id: \(jsonString($0.id))\n  name: \(jsonString($0.name))" }
      .joined(separator: "\n")
    return """
    ---
    type: ClipboardLabelCatalog
    category: "Clipboard/Configuration"
    ---

    # Clipboard Labels

    \(rows)
    """ + "\n"
  }

  private static func markdown(item: ClipboardHistoryItem, tagNames: [String]) -> String {
    let displayTags = ["clipboard"] + tagNames.filter { $0.caseInsensitiveCompare("clipboard") != .orderedSame }
    let encodedTags = displayTags.map(jsonString).joined(separator: ", ")
    let primaryCategory = tagNames.first.map { "Clipboard/\($0)" } ?? "Clipboard"
    let title = item.content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
      .first.map(String.init)?
      .trimmingCharacters(in: CharacterSet(charactersIn: "# ")) ?? "Clipboard record"
    var metadata = [
      "type: ClipboardRecord",
      "clipboard_id: \(item.id)",
      "captured_at: \(ISO8601DateFormatter().string(from: item.capturedAt))",
      "category: \(jsonString(primaryCategory))",
      "tags: [\(encodedTags)]",
      "favorite: \(item.isPinned ? "true" : "false")",
      "permanent: true",
    ]
    if let sourceName = item.sourceName { metadata.append("captured_from: \(jsonString(sourceName))") }
    if let sourceBundleID = item.sourceBundleID { metadata.append("source_bundle_id: \(jsonString(sourceBundleID))") }
    if let sourceURL = item.sourceURL { metadata.append("source_url: \(jsonString(sourceURL))") }
    if let sessionName = item.sessionName { metadata.append("source_session: \(jsonString(sessionName))") }
    return "---\n\(metadata.joined(separator: "\n"))\n---\n\n# \(String(title.prefix(120)))\n\n\(item.content)\n"
  }

  private static func jsonString(_ value: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [value]),
          let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
    return String(encoded.dropFirst().dropLast())
  }
}
