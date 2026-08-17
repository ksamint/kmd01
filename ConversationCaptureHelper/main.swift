import AppKit
import ApplicationServices
import CryptoKit
import Security

private let appGroup = "group.art.apuch.ksamint-markedit"

@MainActor
final class CaptureHelperDelegate: NSObject, NSApplicationDelegate {
  private let capture = ClipboardCaptureService()

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard SharedCaptureSettings.enabled else {
      NSApp.terminate(nil)
      return
    }
    capture.start()
  }
}

MainActor.assumeIsolated {
  let helperDelegate = CaptureHelperDelegate()
  let helperApplication = NSApplication.shared
  helperApplication.setActivationPolicy(.accessory)
  helperApplication.delegate = helperDelegate
  helperApplication.run()
  _ = helperDelegate
}

@MainActor
private final class ClipboardCaptureService: NSObject {
  private static let maximumBytes = 5 * 1024 * 1024
  private static let retention: TimeInterval = 30 * 24 * 60 * 60
  private static let passwordManagers: Set<String> = [
    "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
    "com.apple.Passwords", "com.lastpass.LastPass",
  ]

  private var timer: Timer?
  private var statusItem: NSStatusItem?
  private var lastChangeCount = NSPasteboard.general.changeCount
  private var idlePolls = 0
  private var captureNext = false
  private var paused = false
  private var lastSavedURL: URL?
  private let clipboardHistory = ClipboardHistoryStore()
  private var clipboardPalette: ClipboardPaletteController?
  private var paletteHotKey: ClipboardPaletteHotKey?
  private var paletteShortcutAvailable = false
  private var knowledgeExportTask: Task<Void, Never>?

  func start() {
    clipboardHistory.onKnowledgeChange = { [weak self] in
      self?.scheduleKnowledgeExport()
    }
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(settingsChanged),
      name: .captureSettingsChanged,
      object: nil
    )
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(showClipboardPalette),
      name: .showClipboardPalette,
      object: nil
    )
    let hotKey = ClipboardPaletteHotKey { [weak self] in self?.toggleClipboardPalette() }
    paletteShortcutAvailable = hotKey.register()
    paletteHotKey = hotKey
    if !paletteShortcutAvailable {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        guard let self, let paletteHotKey else { return }
        paletteShortcutAvailable = paletteHotKey.register()
        rebuildMenu()
      }
    }
    installStatusItem()
    purgeExpired()
    scheduleKnowledgeExport()
    schedule(after: 0.75)
  }

  private func schedule(after interval: TimeInterval) {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
      Task { @MainActor in self?.poll() }
    }
  }

  private func poll() {
    guard SharedCaptureSettings.enabled else {
      NSApp.terminate(nil)
      return
    }
    guard !paused else {
      schedule(after: 2)
      return
    }
    let pasteboard = NSPasteboard.general
    guard pasteboard.changeCount != lastChangeCount else {
      idlePolls += 1
      schedule(after: idlePolls > 20 ? 2 : 0.75)
      return
    }
    lastChangeCount = pasteboard.changeCount
    idlePolls = 0
    defer { schedule(after: 0.75) }
    guard let envelope = captureEnvelope(pasteboard) else { return }
    let app = NSWorkspace.shared.frontmostApplication
    if !captureNext, Self.passwordManagers.contains(app?.bundleIdentifier ?? "") { return }
    let source = ClipboardSourceContextReader.read(pasteboard: pasteboard, application: app)
    let forced = captureNext
    captureNext = false
    rebuildMenu()
    if !forced, isSensitive(envelope.content) { return }
    let enriched = CaptureEnvelopeV1(
      version: 1,
      id: envelope.id,
      capturedAt: envelope.capturedAt,
      sourceName: source.applicationName,
      sourceBundleID: source.bundleIdentifier,
      content: envelope.content,
      html: envelope.html,
      rtf: envelope.rtf,
      fileBookmarks: envelope.fileBookmarks
    )
    if clipboardHistory.record(ClipboardHistoryCapture(
      content: enriched.content,
      sourceName: enriched.sourceName,
      sourceBundleID: enriched.sourceBundleID,
      sourceURL: source.sourceURL,
      sessionName: source.sessionName,
      hasFiles: !enriched.fileBookmarks.isEmpty,
      hasRichText: enriched.html != nil || enriched.rtf != nil
    )) {
      clipboardPalette?.reload()
    }
    guard shouldCapture(enriched.content) else { return }
    if forced || highConfidence(enriched.content) {
      if !saveConversation(enriched) { savePending(enriched) }
    } else {
      savePending(enriched)
    }
  }

  private func shouldCapture(_ text: String) -> Bool {
    captureNext || text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 80
  }

  private func isSensitive(_ text: String) -> Bool {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.range(of: #"^\d{4,8}$"#, options: .regularExpression) != nil { return true }
    if !value.contains("\n"), value.count >= 20 {
      return value.allSatisfy { $0.isLetter || $0.isNumber } && Set(value).count > 14
    }
    return false
  }

  private func highConfidence(_ text: String) -> Bool {
    guard text.precomposedStringWithCompatibilityMapping.count >= 200 else { return false }
    let lower = text.lowercased()
    let user = lower.range(of: #"(?m)^(?:#{1,4}\s*)?(user|human|you)\b"#, options: .regularExpression) != nil
    let assistant = lower.range(of: #"(?m)^(?:#{1,4}\s*)?(assistant|claude|chatgpt)\b"#, options: .regularExpression) != nil
    return user && assistant
  }

  private func saveConversation(_ capture: CaptureEnvelopeV1) -> Bool {
    guard let root = SharedCaptureSettings.workspaceURL else { return false }
    defer { root.stopAccessingSecurityScopedResource() }
    let normalized = capture.content.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .precomposedStringWithCompatibilityMapping
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let digest = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    let timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    let parts = Calendar(identifier: .gregorian).dateComponents(in: timeZone, from: Date())
    let directory = root.appending(path: "Conversations/\(String(format: "%04d", parts.year ?? 0))/\(String(format: "%02d", parts.month ?? 0))", directoryHint: .isDirectory)
    let url = directory.appending(path: "Captured--\(digest.prefix(12)).md")
    if FileManager.default.fileExists(atPath: url.path) { return true }
    let source = capture.sourceName ?? "Clipboard"
    let markdown = """
    ---
    type: Conversation
    source: "clipboard"
    imported_at: \(ISO8601DateFormatter().string(from: capture.capturedAt))
    content_digest: \(digest)
    category: "Conversations/Clipboard"
    tags: ["conversation", "clipboard"]
    captured_from: \(jsonString(source))
    ---

    # \(source) conversation

    \(normalized)

    """
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(markdown.utf8).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
      lastSavedURL = url
      rebuildMenu()
      return true
    } catch {
      return false
    }
  }

  private func savePending(_ capture: CaptureEnvelopeV1) {
    do {
      guard let pendingDirectory = SharedCaptureSettings.pendingDirectory else {
        throw CocoaError(.fileWriteNoPermission)
      }
      try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
      // JSON keeps the core PendingCapture fields forward-compatible with the
      // main app while preserving richer envelope fields for future imports.
      let plaintext = try JSONEncoder().encode(capture)
      let key = try pendingKey()
      let identifier = HMAC<SHA256>.authenticationCode(
        for: Data(capture.content.precomposedStringWithCompatibilityMapping.utf8),
        using: key
      )
        .map { String(format: "%02x", $0) }
        .joined()
      let destination = pendingDirectory.appending(path: "\(identifier).ksc")
      if FileManager.default.fileExists(atPath: destination.path) { return }
      let sealed = try AES.GCM.seal(plaintext, using: key)
      guard let combined = sealed.combined else { return }
      try combined.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
      rebuildMenu()
    } catch {
      NSSound.beep()
    }
  }

  private func pendingKey() throws -> SymmetricKey {
    if !ClipboardStorageEnvironment.hasAppGroupEntitlement { return try ClipboardStorageEnvironment.developmentKey(named: "conversation-pending-v1.key") }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccessGroup as String: keychainAccessGroup(),
      kSecAttrService as String: "art.apuch.ksamint-markedit.conversation-capture",
      kSecAttrAccount as String: "pending-queue-v1",
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
         let existingData = existing as? Data,
         existingData.count == 32 {
        return SymmetricKey(data: existingData)
      }
    }
    throw CocoaError(.fileWriteNoPermission)
  }

  private func purgeExpired() {
    guard let pendingDirectory = SharedCaptureSettings.pendingDirectory else { return }
    let cutoff = Date().addingTimeInterval(-Self.retention)
    let urls = (try? FileManager.default.contentsOfDirectory(
      at: pendingDirectory,
      includingPropertiesForKeys: [.contentModificationDateKey]
    )) ?? []
    for url in urls where (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map({ $0 < cutoff }) == true {
      try? FileManager.default.removeItem(at: url)
    }
  }
}

private extension ClipboardCaptureService {
  func captureEnvelope(_ pasteboard: NSPasteboard) -> CaptureEnvelopeV1? {
    let html = pasteboard.data(forType: .html).flatMap { $0.count <= Self.maximumBytes ? $0 : nil }
    let rtf = pasteboard.data(forType: .rtf).flatMap { $0.count <= Self.maximumBytes ? $0 : nil }
    let fileURLs = pasteboard.pasteboardItems?.prefix(256).compactMap { item -> URL? in
      guard let value = item.string(forType: .fileURL), let url = URL(string: value) else { return nil }
      return url
    } ?? []
    guard let decoded = ClipboardCaptureDecoder.decode(ClipboardCaptureSnapshot(
      plainText: pasteboard.string(forType: .string),
      html: html,
      rtf: rtf,
      fileURLs: fileURLs
    )), let bytes = decoded.content.data(using: .utf8), bytes.count <= Self.maximumBytes else { return nil }
    // A background clipboard monitor must not open another application's files. Only the
    // explicit "capture next copy" gesture is allowed to persist access to copied files.
    let bookmarks = captureNext ? decoded.fileURLs.compactMap { url in
      try? url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    } : []
    return CaptureEnvelopeV1(
      version: 1,
      id: UUID(),
      capturedAt: Date(),
      sourceName: nil,
      sourceBundleID: nil,
      content: decoded.content,
      html: html,
      rtf: rtf,
      fileBookmarks: bookmarks
    )
  }

  func scheduleKnowledgeExport() {
    knowledgeExportTask?.cancel()
    let items = clipboardHistory.items
    let tags = clipboardHistory.tags
    knowledgeExportTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled, let root = SharedCaptureSettings.workspaceURL else { return }
      defer { root.stopAccessingSecurityScopedResource() }
      _ = try? await Task.detached(priority: .utility) {
        try ClipboardKnowledgeArchive.reconcile(items: items, tags: tags, workspaceRoot: root)
      }.value
      if !Task.isCancelled { self?.knowledgeExportTask = nil }
    }
  }

  func commitClipboardItem(
    _ item: ClipboardHistoryItem,
    to application: NSRunningApplication?
  ) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(item.content, forType: .string)
    lastChangeCount = pasteboard.changeCount

    guard let application else { return }
    application.activate(options: [.activateAllWindows])
    guard AXIsProcessTrusted() else {
      NSSound.beep()
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
      let source = CGEventSource(stateID: .hidSystemState)
      let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
      keyDown?.flags = .maskCommand
      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
      keyUp?.flags = .maskCommand
      keyDown?.post(tap: .cghidEventTap)
      keyUp?.post(tap: .cghidEventTap)
    }
  }

  func toggleClipboardPalette() {
    if clipboardPalette == nil {
      clipboardPalette = ClipboardPaletteController(
        store: clipboardHistory,
        onCommit: { [weak self] item, application in
          self?.commitClipboardItem(item, to: application)
        },
        onDismiss: { [weak self] in
          DispatchQueue.main.async { self?.clipboardPalette = nil }
        }
      )
    }
    clipboardPalette?.toggle()
  }

  private func installStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: String(localized: "Conversation Inbox"))
    statusItem = item
    rebuildMenu()
  }

  private func rebuildMenu() {
    let menu = NSMenu()
    let status = NSMenuItem(
      title: paused ? String(localized: "Conversation capture is paused") : String(localized: "Conversation capture is on"),
      action: nil,
      keyEquivalent: ""
    )
    status.isEnabled = false
    menu.addItem(status)
    let paletteItem = menu.addItem(
      withTitle: String(localized: "Show Clipboard History"),
      action: #selector(showClipboardPalette),
      keyEquivalent: ""
    )
    paletteItem.target = self
    paletteItem.keyEquivalentModifierMask = [.control, .shift]
    paletteItem.keyEquivalent = "v"
    if !paletteShortcutAvailable {
      paletteItem.toolTip = String(localized: "The global shortcut is already used by another app")
    }
    menu.addItem(withTitle: paused ? String(localized: "Resume Capture") : String(localized: "Pause Capture"), action: #selector(togglePause), keyEquivalent: "").target = self
    menu.addItem(withTitle: String(localized: "Capture Next Copy"), action: #selector(captureNextCopy), keyEquivalent: "").target = self
    menu.addItem(withTitle: String(localized: "Open Conversation Inbox"), action: #selector(openInbox), keyEquivalent: "").target = self
    menu.addItem(withTitle: String(localized: "Open Capture History"), action: #selector(openHistory), keyEquivalent: "").target = self
    menu.addItem(withTitle: String(localized: "Search Captures"), action: #selector(searchHistory), keyEquivalent: "").target = self
    if lastSavedURL != nil { menu.addItem(withTitle: String(localized: "Undo Last Capture"), action: #selector(undoLast), keyEquivalent: "").target = self }
    menu.addItem(withTitle: String(localized: "Clear Clipboard History…"), action: #selector(clearClipboardHistory), keyEquivalent: "").target = self
    menu.addItem(.separator())
    if !AXIsProcessTrusted() {
      menu.addItem(withTitle: String(localized: "Enable Direct Paste…"), action: #selector(requestAccessibilityPermission), keyEquivalent: "").target = self
    }
    menu.addItem(withTitle: String(localized: "Permission Settings…"), action: #selector(openSettings), keyEquivalent: "").target = self
    menu.addItem(withTitle: String(localized: "Turn Off Conversation Capture"), action: #selector(turnOff), keyEquivalent: "").target = self
    statusItem?.menu = menu
  }

  @objc private func togglePause() { paused.toggle(); rebuildMenu() }
  @objc private func captureNextCopy() { captureNext = true; rebuildMenu() }
  @objc private func showClipboardPalette() { toggleClipboardPalette() }
  @objc private func openInbox() {
    openMainApp(route: "conversation-inbox")
  }
  @objc private func openHistory() { openMainApp(route: "capture-history") }
  @objc private func searchHistory() { openMainApp(route: "capture-search") }
  @objc private func openSettings() {
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    ) {
      NSWorkspace.shared.open(url)
    }
  }
  @objc private func undoLast() {
    guard let lastSavedURL else { return }
    _ = try? FileManager.default.trashItem(at: lastSavedURL, resultingItemURL: nil)
    self.lastSavedURL = nil
    rebuildMenu()
  }
  @objc private func clearClipboardHistory() {
    let alert = NSAlert()
    alert.messageText = String(localized: "Clear clipboard history?")
    alert.informativeText = String(
      localized: "This removes recent items but keeps favorite, labeled, and permanent records."
    )
    alert.addButton(withTitle: String(localized: "Clear"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    clipboardHistory.clear()
    clipboardPalette?.reload()
  }
  @objc private func requestAccessibilityPermission() {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
      NSWorkspace.shared.open(url)
    }
  }
  @objc private func turnOff() {
    SharedCaptureSettings.enabled = false
    DistributedNotificationCenter.default().post(name: .captureSettingsChanged, object: nil)
    NSApp.terminate(nil)
  }
  @objc private func settingsChanged() { if !SharedCaptureSettings.enabled { NSApp.terminate(nil) } }

  private func openMainApp(route: String) {
    guard let url = URL(string: "ksamint-markedit://\(route)") else { return }
    NSWorkspace.shared.open(url)
  }

  private func jsonString(_ value: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [value]), let text = String(data: data, encoding: .utf8) else { return "\"\"" }
    return String(text.dropFirst().dropLast())
  }

  private func keychainAccessGroup() -> String {
    guard let task = SecTaskCreateFromSelf(nil),
          let groups = SecTaskCopyValueForEntitlement(
            task,
            "keychain-access-groups" as CFString,
            nil
          ) as? [String],
          let group = groups.first(where: { $0.hasSuffix("group.art.apuch.ksamint-markedit") })
    else { return "group.art.apuch.ksamint-markedit" }
    return group
  }
}

private enum SharedCaptureSettings {
  private static var defaults: UserDefaults {
    UserDefaults(suiteName: appGroup) ?? .standard
  }
  static var enabled: Bool {
    get { defaults.bool(forKey: "conversationCaptureEnabled") }
    set { defaults.set(newValue, forKey: "conversationCaptureEnabled") }
  }
  static var workspaceURL: URL? {
    guard let bookmark = defaults.data(forKey: "workspaceBookmark") else { return nil }
    var stale = false
    guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
          url.startAccessingSecurityScopedResource() else { return nil }
    return url.standardizedFileURL
  }
  static var pendingDirectory: URL? {
    ClipboardStorageEnvironment.sharedRootURL
      .appending(path: "ConversationInbox/Pending", directoryHint: .isDirectory)
  }
}

private struct CaptureEnvelopeV1: Codable {
  let version: Int
  let id: UUID
  let capturedAt: Date
  let sourceName: String?
  let sourceBundleID: String?
  let content: String
  let html: Data?
  let rtf: Data?
  let fileBookmarks: [Data]
}

private extension Notification.Name {
  static let captureSettingsChanged = Notification.Name("art.apuch.ksamint.capture-settings-changed")
  static let showClipboardPalette = Notification.Name("art.apuch.ksamint.show-clipboard-palette")
}
