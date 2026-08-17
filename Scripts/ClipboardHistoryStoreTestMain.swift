import AppKit
import CryptoKit
import Foundation

private struct LegacyClipboardItem: Encodable {
  let id: String
  let capturedAt: Date
  let sourceName: String?
  let sourceBundleID: String?
  let content: String
  let category: ClipboardContentCategory
}

private enum ClipboardHistoryTestError: Error {
  case failed(String)
}

// swiftlint:disable convenience_type
@main
@MainActor
private struct ClipboardHistoryStoreTestMain {
  static func main() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "kmd-clipboard-history-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let key = SymmetricKey(size: .bits256)
    let archiveURL = root.appending(path: "history.ksc")
    var store = ClipboardHistoryStore(fileURL: archiveURL, key: key)
    try expect(store.record(content: "ACME invoice 1001", sourceName: "Tests", sourceBundleID: nil, hasFiles: false), "records content")
    let journalPermissions = try FileManager.default.attributesOfItem(atPath: archiveURL.path)[.posixPermissions] as? NSNumber
    try expect(journalPermissions?.intValue == 0o600, "protects the encrypted journal from other local users")
    let invoice = try unwrap(store.createTag(named: " 发票信息 "), "creates a label")
    let duplicate = try unwrap(store.createTag(named: "发票信息"), "returns an existing normalized label")
    try expect(invoice.id == duplicate.id, "deduplicates equivalent labels")
    let itemID = try unwrap(store.items.first?.id, "creates a history item")
    try expect(store.toggleTag(invoice.id, for: itemID) == true, "assigns a label")
    try expect(store.togglePinned(itemID: itemID) == true, "pins an item")

    store = ClipboardHistoryStore(fileURL: archiveURL, key: key)
    var restored = try unwrap(store.items.first, "restores an encrypted item")
    try expect(restored.isPinned, "persists pin state")
    try expect(restored.tagIDs == [invoice.id], "persists label assignment")
    try expect(store.record(content: "ACME invoice 1001", sourceName: "Tests Again", sourceBundleID: nil, hasFiles: false), "re-records duplicate content")
    restored = try unwrap(store.items.first, "keeps the re-recorded item")
    try expect(restored.isPinned && restored.tagIDs == [invoice.id], "preserves metadata when content is copied again")

    let structured = "# 关键方案\n\n" + String(repeating: "- 中文 日本語 français documentation\n", count: 200)
    try expect(store.record(ClipboardHistoryCapture(
      content: structured,
      sourceName: "Safari",
      sourceBundleID: "com.apple.Safari",
      sourceURL: "https://example.com/session/42",
      sessionName: "Architecture discussion",
      hasFiles: false,
      hasRichText: true
    )), "records rich source metadata")
    let permanent = try unwrap(store.items.last, "stores structured content")
    try expect(permanent.isPermanent, "archives long formatted content permanently")
    try expect(permanent.sourceURL == "https://example.com/session/42", "persists a safe source URL")
    try expect(permanent.sessionName == "Architecture discussion", "persists the session name")

    store = ClipboardHistoryStore(fileURL: archiveURL, key: key)
    let restoredPermanent = try unwrap(store.items.first { $0.id == permanent.id }, "restores permanent content")
    try expect(restoredPermanent.isPermanent, "restores permanent status from the journal")
    try expect(restoredPermanent.sourceURL == permanent.sourceURL, "restores source context from the journal")

    try expect(store.renameTag(id: invoice.id, to: "公司信息"), "renames a label")
    try expect(store.tags.first?.name == "公司信息", "stores the renamed label")
    store.deleteTag(id: invoice.id)
    try expect(store.items.first?.tagIDs.isEmpty == true, "removes deleted label references")
    _ = store.createTag(named: "常用 Command")
    let journalSizeBeforeClear = try Data(contentsOf: archiveURL).count
    store.clear()
    try expect(store.items.count == 2, "keeps permanent clipboard knowledge when recent history is cleared")
    try expect(store.items.contains { $0.id == permanent.id }, "keeps the automatic permanent record")
    try expect(store.items.contains { $0.id == itemID }, "keeps the favorited record")
    try expect(store.tags.map(\.name) == ["常用 Command"], "keeps user labels when history is cleared")
    let journalSizeAfterClear = try Data(contentsOf: archiveURL).count
    try expect(journalSizeAfterClear < journalSizeBeforeClear, "physically compacts cleared recent history")

    let classified = "Company introduction with a reusable address and invoice profile."
    try expect(store.record(
      content: classified,
      sourceName: "Tests",
      sourceBundleID: nil,
      hasFiles: false
    ), "records a classifiable item")
    let classifiedID = try unwrap(store.items.last?.id, "stores classifiable content")
    let companyTag = try unwrap(store.createTag(named: "公司信息"), "creates a global classification")
    try expect(store.toggleTag(companyTag.id, for: classifiedID) == true, "classifies the item")
    try expect(
      store.items.first { $0.id == classifiedID }?.isPermanent == true,
      "classifying a record makes it permanent"
    )
    try expect(store.togglePermanent(itemID: classifiedID) == true, "does not disable retention for labeled records")
    try expect(store.togglePinned(itemID: classifiedID) == true, "favorites the item")
    try expect(
      store.items.first { $0.id == classifiedID }?.isPermanent == true,
      "favoriting a record makes it permanent"
    )

    let knowledgeRoot = root.appending(path: "Workspace", directoryHint: .isDirectory)
    let export = try ClipboardKnowledgeArchive.reconcile(
      items: store.items,
      tags: store.tags,
      workspaceRoot: knowledgeRoot
    )
    try expect(export.written >= 2, "exports permanent clipboard knowledge as Markdown")
    let clipboardRoot = knowledgeRoot.appending(path: "Clipboard", directoryHint: .isDirectory)
    let clipboardRootEntries = try FileManager.default.contentsOfDirectory(
      at: clipboardRoot,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
    let exportedAtRoot = clipboardRootEntries.filter { $0.pathExtension == "md" }
    try expect(
      exportedAtRoot.map(\.lastPathComponent) == ["Labels.md"],
      "stores only the global label catalog at the Clipboard root"
    )
    let exportedMarkdown = recursiveMarkdownFiles(at: knowledgeRoot)
      .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
    let classifiedMarkdown = try unwrap(
      exportedMarkdown.first { $0.contains("clipboard_id: \(classifiedID)") },
      "exports the classified record"
    )
    try expect(classifiedMarkdown.contains("tags: [\"clipboard\", \"公司信息\"]"), "exports global labels")
    try expect(classifiedMarkdown.contains("favorite: true"), "exports favorite metadata")
    try expect(classifiedMarkdown.contains(classified), "exports original content without conversion")

    let legacyURL = root.appending(path: "legacy.ksc")
    let legacy = LegacyClipboardItem(
      id: "legacy",
      capturedAt: Date(timeIntervalSince1970: 1_600_000_000),
      sourceName: "Legacy",
      sourceBundleID: nil,
      content: "legacy clipboard value",
      category: .text
    )
    let legacyPlaintext = try JSONEncoder().encode([legacy])
    let legacySealed = try AES.GCM.seal(legacyPlaintext, using: key)
    try unwrap(legacySealed.combined, "creates a legacy encrypted archive").write(to: legacyURL)
    let migratedJournalURL = root.appending(path: "migrated.ksj")
    let migrated = ClipboardHistoryStore(fileURL: migratedJournalURL, legacyFileURL: legacyURL, key: key)
    try expect(migrated.items.first?.content == legacy.content, "migrates v1 item arrays")
    try expect(migrated.items.first?.isPinned == false, "defaults migrated pin state")
    try expect(migrated.items.first?.tagIDs.isEmpty == true, "defaults migrated labels")
    try expect(migrated.items.first?.capturedAt == legacy.capturedAt, "keeps ordinary history by count instead of age")
    try expect(FileManager.default.fileExists(atPath: legacyURL.path), "keeps the legacy encrypted backup")
    try expect(FileManager.default.fileExists(atPath: migratedJournalURL.path), "creates the append-only journal")

    let staleTaggedURL = root.appending(path: "stale-tagged.ksj")
    let staleTag = ClipboardUserTag(id: "legacy-tag", name: "Legacy label")
    let staleTaggedItem = ClipboardHistoryItem(
      id: "stale-tagged",
      capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
      sourceName: "Legacy",
      sourceBundleID: nil,
      content: "labeled before labels implied permanent retention",
      category: .text,
      isPinned: false,
      isPermanent: false,
      tagIDs: [staleTag.id]
    )
    try writeJournal(
      [.snapshot(ClipboardHistoryArchive(version: 2, items: [staleTaggedItem], tags: [staleTag]))],
      to: staleTaggedURL,
      key: key
    )
    let normalizedStaleTagged = ClipboardHistoryStore(fileURL: staleTaggedURL, key: key)
    try expect(
      normalizedStaleTagged.items.first?.isPermanent == true,
      "upgrades previously labeled records to permanent retention"
    )
    normalizedStaleTagged.clear()
    let restoredStaleTagged = ClipboardHistoryStore(fileURL: staleTaggedURL, key: key)
    try expect(
      restoredStaleTagged.items.map(\.id) == [staleTaggedItem.id],
      "keeps previously labeled records when clearing ordinary history"
    )

    var truncated = try Data(contentsOf: migratedJournalURL)
    truncated.append(contentsOf: [0x12, 0x34])
    try truncated.write(to: migratedJournalURL)
    let recovered = ClipboardHistoryStore(fileURL: migratedJournalURL, key: key)
    try expect(recovered.items.first?.content == legacy.content, "ignores a truncated final journal record")
    try expect(recovered.record(
      content: "recorded after truncated tail recovery",
      sourceName: "Tests",
      sourceBundleID: nil,
      hasFiles: false
    ), "appends after trimming a truncated tail")
    let recoveredAgain = ClipboardHistoryStore(fileURL: migratedJournalURL, key: key)
    try expect(
      recoveredAgain.items.contains { $0.content == "recorded after truncated tail recovery" },
      "replays records appended after truncated-tail recovery"
    )

    let corruptURL = root.appending(path: "corrupt.ksj")
    let corruptBytes = Data([0x20, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03])
    try corruptBytes.write(to: corruptURL)
    let corrupt = ClipboardHistoryStore(fileURL: corruptURL, legacyFileURL: legacyURL, key: key)
    try expect(corrupt.items.isEmpty, "does not replace a corrupt v2 journal with stale legacy data")
    let preservedCorruptBytes = try Data(contentsOf: corruptURL)
    try expect(preservedCorruptBytes == corruptBytes, "preserves a corrupt journal for recovery")

    let capacityURL = root.appending(path: "capacity.ksj")
    let capacityStore = ClipboardHistoryStore(fileURL: capacityURL, key: key)
    for index in 0 ... ClipboardHistoryStore.maximumRecentItems {
      try expect(capacityStore.record(
        content: "ordinary clipboard item \(index)",
        sourceName: "Tests",
        sourceBundleID: nil,
        hasFiles: false
      ), "appends capacity item \(index)")
    }
    try expect(
      capacityStore.items.filter { !$0.isPinned && !$0.isPermanent }.count == ClipboardHistoryStore.maximumRecentItems,
      "retains exactly 10,000 ordinary entries"
    )

    let reloadedCapacity = ClipboardHistoryStore(fileURL: capacityURL, key: key)
    try expect(reloadedCapacity.items.count == ClipboardHistoryStore.maximumRecentItems, "replays the 10,000-item journal")

    let pasteboard = NSPasteboard(name: NSPasteboard.Name("kmd-source-context-tests"))
    let sourceType = NSPasteboard.PasteboardType("org.chromium.source-url")
    let titleType = NSPasteboard.PasteboardType("org.chromium.source-title")
    pasteboard.declareTypes([sourceType, titleType], owner: nil)
    pasteboard.setString("https://example.com/chat/7", forType: sourceType)
    pasteboard.setString("Claude planning session", forType: titleType)
    let context = ClipboardSourceContextReader.read(pasteboard: pasteboard, application: nil)
    try expect(context.sourceURL == "https://example.com/chat/7", "reads the clipboard source URL")
    try expect(context.sessionName == "Claude planning session", "reads the clipboard session name")
    try expect(ClipboardHistoryStore.sanitizedSourceURL("javascript:alert(1)") == nil, "rejects unsafe source URLs")

    print("Clipboard history store tests passed.")
  }

  private static func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
  ) throws {
    if !condition() { throw ClipboardHistoryTestError.failed(message) }
  }

  private static func unwrap<Value>(_ value: Value?, _ message: String) throws -> Value {
    guard let value else { throw ClipboardHistoryTestError.failed(message) }
    return value
  }

  private static func recursiveMarkdownFiles(at root: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }
  }

  private static func writeJournal(
    _ events: [ClipboardHistoryJournalEvent],
    to url: URL,
    key: SymmetricKey
  ) throws {
    let plaintext = try JSONEncoder().encode(events)
    let sealed = try AES.GCM.seal(plaintext, using: key)
    let combined = try unwrap(sealed.combined, "creates an encrypted journal record")
    var length = UInt32(combined.count).littleEndian
    var data = withUnsafeBytes(of: &length) { Data($0) }
    data.append(combined)
    try data.write(to: url)
  }
}
// swiftlint:enable convenience_type
