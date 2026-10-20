import Foundation

enum WorkspaceAccessIssue: Equatable {
  case permissionRequired
  case notFound
  case storageUnavailable
  case unavailable

  static func classify(_ error: Error) -> Self {
    classify(error as NSError, depth: 0)
  }

  private static func classify(_ error: NSError, depth: Int) -> Self {
    // Underlying POSIX errors often carry the useful reason behind a generic
    // Cocoa bookmark/read error. Limit recursion for malformed error chains.
    if depth < 8, let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
      let issue = classify(underlying, depth: depth + 1)
      if issue != .unavailable { return issue }
    }
    if error.domain == NSPOSIXErrorDomain {
      switch error.code {
      case Int(EACCES), Int(EPERM): return .permissionRequired
      case Int(ENOENT): return .notFound
      case Int(ENODEV), Int(ENXIO), Int(ENOTCONN), Int(ENETDOWN), Int(ENETUNREACH), Int(EHOSTUNREACH):
        return .storageUnavailable
      default: return .unavailable
      }
    }
    if error.domain == NSCocoaErrorDomain {
      switch error.code {
      case CocoaError.fileReadNoPermission.rawValue, CocoaError.fileWriteNoPermission.rawValue:
        return .permissionRequired
      case CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue:
        return .notFound
      default: return .unavailable
      }
    }
    return .unavailable
  }
}

enum WorkspaceBookmarkNotifications {
  static let requested = Notification.Name("art.apuch.ksamint.workspace-grant-requested")
  static let changed = Notification.Name("art.apuch.ksamint.capture-settings-changed")
  static let quickActionReceived = Notification.Name("art.apuch.ksamint.quick-action-received")
}

struct WorkspaceBookmarkOperations {
  enum Scope { case persistent, transfer }

  var resolve: (Data, Scope) throws -> (url: URL, stale: Bool)
  var create: (URL, Scope) throws -> Data
  var start: (URL) -> Bool
  var stop: (URL) -> Void

  static var system: Self {
    Self(
      resolve: { data, scope in
        var stale = false
        var options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutImplicitStartAccessing]
        if scope == .persistent { options.insert(.withSecurityScope) }
        let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
      },
      create: { url, scope in
        try url.bookmarkData(options: scope == .persistent ? [.withSecurityScope] : [], includingResourceValuesForKeys: nil, relativeTo: nil)
      },
      start: { $0.startAccessingSecurityScopedResource() },
      stop: { $0.stopAccessingSecurityScopedResource() }
    )
  }

  // Transfers already-started scopes to an owner that will release them on shutdown.
  func retainForSession(_ acquired: [URL], in retained: inout [URL]) {
    for url in acquired {
      if retained.contains(url) { stop(url) } else { retained.append(url) }
    }
  }

  func acquire(_ data: Data, scope: Scope) throws -> (url: URL, stale: Bool) {
    let resolved = try resolve(data, scope)
    guard start(resolved.url) else { throw CocoaError(.fileReadNoPermission) }
    return resolved
  }
}

final class WorkspaceBookmarkPublisher {
  static let sharedKey = "workspaceGrant.v1"
  private static let sourceKey = "workspaceGrantSource.v1"
  private let shared: UserDefaults
  private let local: UserDefaults
  private let operations: WorkspaceBookmarkOperations
  private var retainedURL: URL?

  init(shared: UserDefaults, local: UserDefaults = .standard, operations: WorkspaceBookmarkOperations = .system) {
    self.shared = shared
    self.local = local
    self.operations = operations
  }

  deinit {
    if let retainedURL { operations.stop(retainedURL) }
  }

  func preserveGeneration(from original: Data, to refreshed: Data) {
    guard var state = local.dictionary(forKey: Self.sourceKey),
          state["source"] as? Data == original else { return }
    state["source"] = refreshed
    local.set(state, forKey: Self.sourceKey)
  }

  @discardableResult
  func publish(_ bookmark: Data?) -> Data? {
    let previous = local.dictionary(forKey: Self.sourceKey)
    let generation: String
    if let existing = previous?["generation"] as? String, UUID(uuidString: existing) != nil,
       previous?["source"] as? Data == bookmark {
      generation = existing
    } else {
      generation = UUID().uuidString
    }
    var state: [String: Any] = ["generation": generation]
    if let bookmark { state["source"] = bookmark }
    var currentBookmark = bookmark
    if let retainedURL { operations.stop(retainedURL) }
    retainedURL = nil

    var envelope: [String: Any] = ["generation": generation, "revoked": bookmark == nil]
    if let bookmark, let resolved = try? operations.acquire(bookmark, scope: .persistent) {
      retainedURL = resolved.url
      if resolved.stale, let refreshed = try? operations.create(resolved.url, .persistent) {
        currentBookmark = refreshed
        state["source"] = refreshed
      }
      // Implicit bookmarks transfer a live grant; app-scoped bookmarks belong to their creator.
      envelope["transfer"] = try? operations.create(resolved.url, .transfer)
    }
    local.set(state, forKey: Self.sourceKey)
    shared.set(envelope, forKey: Self.sharedKey)
    for obsolete in ["workspaceBookmark", "workspaceBookmarks", "workspacePaths"] {
      shared.removeObject(forKey: obsolete)
    }
    return currentBookmark
  }
}

final class WorkspaceBookmarkReceiver {
  private static let localKey = "ownedWorkspaceGrant.v1"
  private let shared: UserDefaults
  private let local: UserDefaults
  private let operations: WorkspaceBookmarkOperations

  init(shared: UserDefaults, local: UserDefaults = .standard, operations: WorkspaceBookmarkOperations = .system) {
    self.shared = shared
    self.local = local
    self.operations = operations
  }

  // Returns one started scope. The caller owns its matching stop.
  func acquire() -> URL? {
    guard let envelope = shared.dictionary(forKey: WorkspaceBookmarkPublisher.sharedKey),
          let generation = envelope["generation"] as? String, UUID(uuidString: generation) != nil,
          let revoked = envelope["revoked"] as? Bool else { return nil }
    if revoked {
      local.removeObject(forKey: Self.localKey)
      return nil
    }
    if let owned = local.dictionary(forKey: Self.localKey),
       owned["generation"] as? String == generation,
       let bookmark = owned["bookmark"] as? Data,
       let resolved = try? operations.acquire(bookmark, scope: .persistent) {
      guard isCurrent(generation) else { operations.stop(resolved.url); return nil }
      if resolved.stale, let refreshed = try? operations.create(resolved.url, .persistent) {
        guard isCurrent(generation) else { operations.stop(resolved.url); return nil }
        local.set(["generation": generation, "bookmark": refreshed], forKey: Self.localKey)
      }
      return resolved.url
    }
    guard let transfer = envelope["transfer"] as? Data,
          let incoming = try? operations.acquire(transfer, scope: .transfer) else { return nil }
    defer { operations.stop(incoming.url) }
    guard let bookmark = try? operations.create(incoming.url, .persistent),
          let owned = try? operations.acquire(bookmark, scope: .persistent) else { return nil }
    guard isCurrent(generation) else { operations.stop(owned.url); return nil }
    local.set(["generation": generation, "bookmark": bookmark], forKey: Self.localKey)
    return owned.url
  }

  private func isCurrent(_ generation: String) -> Bool {
    let current = shared.dictionary(forKey: WorkspaceBookmarkPublisher.sharedKey)
    return current?["generation"] as? String == generation && current?["revoked"] as? Bool == false
  }
}
