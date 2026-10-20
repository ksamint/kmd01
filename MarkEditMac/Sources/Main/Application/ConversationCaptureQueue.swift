import CryptoKit
import Foundation
import Security

/// Encrypted, device-local holding queue for captures that still need review.
/// The helper and main app deliberately share this small storage contract.
@MainActor
struct ConversationCaptureQueue {
  var onSharedContainerAvailability: ((Bool) -> Void)?

  private static let retention: TimeInterval = 30 * 24 * 60 * 60
  private static let service = "art.apuch.ksamint-markedit.conversation-capture"
  private static let account = "pending-queue-v1"

  var count: Int {
    urls.count
  }

  var urls: [URL] {
    ((try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )) ?? [])
      .filter { $0.pathExtension == "ksc" }
      .sorted {
        let left = try? $0.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate
        let right = try? $1.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate
        return (left ?? .distantPast) < (right ?? .distantPast)
      }
  }

  func save(_ capture: PendingConversationCapture) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(capture)
    let sealed = try AES.GCM.seal(data, using: key())
    guard let combined = sealed.combined else { throw ConversationCaptureQueueError.encryption }
    try combined.write(
      to: directory.appending(path: "\(UUID().uuidString).ksc"),
      options: [.atomic, .completeFileProtectionUnlessOpen]
    )
  }

  func capture(at url: URL) -> PendingConversationCapture? {
    guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
          let data = try? Data(contentsOf: url),
          let box = try? AES.GCM.SealedBox(combined: data),
          let key = try? key(),
          let plaintext = try? AES.GCM.open(box, using: key),
          let capture = try? JSONDecoder().decode(PendingConversationCapture.self, from: plaintext)
    else { return nil }
    return capture
  }

  func remove(_ url: URL) {
    guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
    try? FileManager.default.removeItem(at: url)
  }

  func purgeExpired() {
    let cutoff = Date().addingTimeInterval(-Self.retention)
    for url in urls {
      let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
      if modified.map({ $0 < cutoff }) == true { remove(url) }
    }
  }

  private var directory: URL {
    let sharedContainer = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.art.apuch.ksamint-markedit"
    )
    onSharedContainerAvailability?(sharedContainer != nil)
    return (sharedContainer ?? URL.applicationSupportDirectory)
      .appending(path: "ConversationInbox/Pending", directoryHint: .isDirectory)
  }

  private func key() throws -> SymmetricKey {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccessGroup as String: keychainAccessGroup(),
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: Self.account,
      kSecReturnData as String: true,
    ]
    if let data = keyData(matching: query) { return SymmetricKey(data: data) }

    let data = Data(SymmetricKey(size: .bits256).withUnsafeBytes(Array.init))
    var add = query
    add.removeValue(forKey: kSecReturnData as String)
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    add[kSecValueData as String] = data
    let status = SecItemAdd(add as CFDictionary, nil)
    if status == errSecSuccess { return SymmetricKey(data: data) }
    if status == errSecDuplicateItem, let existing = keyData(matching: query) {
      return SymmetricKey(data: existing)
    }
    throw ConversationCaptureQueueError.keychain
  }

  private func keyData(matching query: [String: Any]) -> Data? {
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data,
          data.count == 32 else { return nil }
    return data
  }

  private func keychainAccessGroup() -> String {
    guard let task = SecTaskCreateFromSelf(nil),
          let groups = SecTaskCopyValueForEntitlement(
            task,
            "keychain-access-groups" as CFString,
            nil
          ) as? [String],
          let group = groups.first(where: {
            $0.hasSuffix("group.art.apuch.ksamint-markedit")
          })
    else { return "group.art.apuch.ksamint-markedit" }
    return group
  }
}

struct PendingConversationCapture: Codable {
  let capturedAt: Date
  let sourceName: String?
  let sourceBundleID: String?
  let content: String
}

private enum ConversationCaptureQueueError: Error {
  case encryption
  case keychain
}
