//
//  WorkspaceSession.swift
//  MarkEditMac
//
//  Created by ksamint on 7/27/26.
//

import AppKit
import SharedUI

enum WorkspaceSidebarMode: Int {
  case files = 0
  case search = 1
  case tags = 2
  case preview = 3 // Legacy persisted value; preview now has its own right pane.
  case outline = 4
}

enum WorkspaceTaxonomyItem: Equatable {
  case tag(WorkspaceTagSummary)
  case category(WorkspaceCategorySummary)

  var displayName: String {
    switch self {
    case let .tag(tag):
      return tag.displayName
    case let .category(category):
      return category.path
    }
  }

  var fileCount: Int {
    switch self {
    case let .tag(tag):
      return tag.fileCount
    case let .category(category):
      return category.fileCount
    }
  }
}

enum WorkspaceTaxonomyAction: Equatable {
  case rename
  case merge
  case delete
}

struct WorkspaceHubSnapshot: Codable {
  let version: Int
  let hasWorkspace: Bool
  let workspaceName: String
  let rootPath: String
  let recentFiles: [WorkspaceFileSummary]
  let recentDocuments: [WorkspaceRecentDocument]
  let activities: [WorkspaceActivitySummary]
  let tags: [WorkspaceTagSummary]
  let categories: [WorkspaceCategorySummary]
  let graph: WorkspaceGraph
  let accountEnabled: Bool
  let syncEnabled: Bool
  let backupEnabled: Bool
  let accountServiceStatus: String
  let conversationPendingCount: Int

  @MainActor
  static func local() async -> Self {
    let history = ActivityHistoryStore.shared
    return Self(
      version: 2,
      hasWorkspace: false,
      workspaceName: "kmd",
      rootPath: Localized.Workspace.noFolder,
      recentFiles: [],
      recentDocuments: history.recentDocuments().map(WorkspaceRecentDocument.init),
      activities: history.entries().map(WorkspaceActivitySummary.init),
      tags: [],
      categories: [],
      graph: WorkspaceGraph(nodes: [], edges: []),
      accountEnabled: false,
      syncEnabled: false,
      backupEnabled: false,
      accountServiceStatus: await AccountServiceMonitor.shared.currentStatus,
      conversationPendingCount: ConversationCaptureCoordinator.shared.pendingCount
    )
  }
}

struct WorkspaceRecentDocument: Codable {
  let path: String
  let title: String
  let lastOpenedAt: Double

  init(_ activity: EditorHistory.Activity) {
    path = activity.path
    title = activity.title
    lastOpenedAt = activity.timestamp.timeIntervalSince1970 * 1_000
  }
}

struct WorkspaceActivitySummary: Codable {
  let id: String
  let path: String
  let title: String
  let kind: String
  let timestamp: Double
  let count: Int

  init(_ activity: EditorHistory.Activity) {
    id = activity.id.uuidString
    path = activity.path
    title = activity.title
    kind = activity.kind.rawValue
    timestamp = activity.timestamp.timeIntervalSince1970 * 1_000
    count = activity.count
  }
}

actor AccountServiceMonitor {
  static let shared = AccountServiceMonitor()
  private(set) var currentStatus = "checking"

  func refresh() async {
    guard let url = URL(string: "https://api.notes.apuch.cn/healthz") else {
      currentStatus = "offline"
      return
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 3
    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      currentStatus = (200..<300).contains(status) ? "online" : "offline"
    } catch {
      currentStatus = "offline"
    }
  }
}

@MainActor
final class WorkspaceSession {
  let rootURL: URL
  let index: WorkspaceIndex
  let deepSearchIndex: WorkspaceDeepSearch

  private(set) var isAuthorized: Bool
  private(set) var accessIssue: WorkspaceAccessIssue?
  var onFileSystemChange: (() -> Void)?
  var onIndexStateChange: ((WorkspaceIndexState) -> Void)?

  private let bookmark: Data
  private let hasSecurityScope: Bool
  private let filePresenter: WorkspaceFilePresenter
  private var refreshTask: Task<Void, Never>?
  private var rebuildTask: Task<Void, Never>?
  private var rebuildRequestedWhileRunning = false

  init(rootURL: URL, bookmark: Data, isAuthorized: Bool) {
    let standardizedRoot = rootURL.standardizedFileURL
    self.rootURL = standardizedRoot
    self.bookmark = bookmark
    self.hasSecurityScope = isAuthorized
    self.isAuthorized = isAuthorized
    self.accessIssue = isAuthorized ? nil : .unavailable
    self.index = WorkspaceIndex(rootURL: standardizedRoot)
    self.deepSearchIndex = WorkspaceDeepSearch(rootURL: standardizedRoot)
    self.filePresenter = WorkspaceFilePresenter(rootURL: standardizedRoot)

    filePresenter.onChange = { [weak self] changedURL in
      self?.scheduleRefresh(changedURL: changedURL)
    }
    NSFileCoordinator.addFilePresenter(filePresenter)
  }

  deinit {
    refreshTask?.cancel()
    NSFileCoordinator.removeFilePresenter(filePresenter)
    if hasSecurityScope {
      rootURL.stopAccessingSecurityScopedResource()
    }
  }

  static func create(for rootURL: URL) throws -> WorkspaceSession {
    let bookmark = try rootURL.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    let isAuthorized = rootURL.startAccessingSecurityScopedResource()
    return WorkspaceSession(rootURL: rootURL, bookmark: bookmark, isAuthorized: isAuthorized)
  }

  static func restore(from bookmark: Data) throws -> WorkspaceSession {
    var isStale = false
    let url = try URL(
      resolvingBookmarkData: bookmark,
      options: [.withSecurityScope, .withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )
    let isAuthorized = url.startAccessingSecurityScopedResource()
    // Keep the original bookmark when a removable volume or grant is unavailable.
    let resolvedBookmark = isStale && isAuthorized
      ? (try? url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )) ?? bookmark
      : bookmark
    if resolvedBookmark != bookmark {
      ConversationCaptureCoordinator.shared.workspaceBookmarkDidRefresh(from: bookmark, to: resolvedBookmark)
      if AppPreferences.General.workspaceFolderBookmark == bookmark {
        AppPreferences.General.workspaceFolderBookmark = resolvedBookmark
      }
      AppPreferences.General.workspaceFolderBookmarks =
        AppPreferences.General.workspaceFolderBookmarks.mapValues { $0 == bookmark ? resolvedBookmark : $0 }
      ConversationCaptureCoordinator.shared.synchronizeHelperConfiguration()
    }
    return WorkspaceSession(rootURL: url, bookmark: resolvedBookmark, isAuthorized: isAuthorized)
  }

  func persist(for fileURLs: [URL] = []) {
    AppPreferences.General.workspaceFolderBookmark = bookmark
    ConversationCaptureCoordinator.shared.synchronizeHelperConfiguration()

    guard !fileURLs.isEmpty else {
      return
    }

    var bookmarks = AppPreferences.General.workspaceFolderBookmarks
    for fileURL in fileURLs where contains(fileURL) {
      bookmarks[fileURL.standardizedFileURL.path] = bookmark
    }
    AppPreferences.General.workspaceFolderBookmarks = bookmarks
    ConversationCaptureCoordinator.shared.synchronizeHelperConfiguration()
  }

  func contains(_ url: URL) -> Bool {
    let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
    let candidate = url.resolvingSymlinksInPath().standardizedFileURL
    let rootComponents = root.pathComponents
    let candidateComponents = candidate.pathComponents

    return candidateComponents.count >= rootComponents.count
      && candidateComponents.prefix(rootComponents.count) == rootComponents[...]
  }

  func rebuildIndex() {
    guard isAuthorized else {
      onIndexStateChange?(.failed)
      return
    }

    onIndexStateChange?(.indexing)
    guard rebuildTask == nil else {
      // A rebuild is already walking the tree; run one more afterwards so a
      // change made meanwhile is still picked up, without stacking rebuilds.
      rebuildRequestedWhileRunning = true
      return
    }

    rebuildTask = Task { [weak self] in
      guard let self else {
        return
      }

      do {
        let fileCount = try await index.rebuild()
        if !Task.isCancelled, isAuthorized {
          accessIssue = nil
          onIndexStateChange?(.ready(fileCount: fileCount))
        }
      } catch {
        recordIndexAccessFailure(error)
        onIndexStateChange?(.failed)
      }

      rebuildTask = nil
      if rebuildRequestedWhileRunning {
        rebuildRequestedWhileRunning = false
        rebuildIndex()
      }
    }
  }

  func search(_ query: String) async -> [WorkspaceSearchResult] {
    guard isAuthorized else {
      return []
    }

    return await index.search(query)
  }

  func deepSearch(_ query: String) async throws -> [WorkspaceSearchResult] {
    guard isAuthorized else {
      return []
    }
    return try await deepSearchIndex.search(query).map(\.result)
  }

  func deepSearchState() async -> WorkspaceDeepSearchState {
    await deepSearchIndex.state
  }

  func installAndIndexDeepSearch() async throws {
    guard isAuthorized else {
      return
    }
    try await deepSearchIndex.installModel()
    _ = try await deepSearchIndex.rebuild()
  }

  func taxonomy() async -> ([WorkspaceTagSummary], [WorkspaceCategorySummary]) {
    guard isAuthorized else {
      return ([], [])
    }
    let tags = await index.tags()
    let categories = await index.categories()
    return (tags, categories)
  }

  func files(for item: WorkspaceTaxonomyItem) async -> [URL] {
    guard isAuthorized else {
      return []
    }

    switch item {
    case let .tag(tag):
      return await index.files(tagIdentity: tag.identity)
    case let .category(category):
      return await index.files(categoryPath: category.path)
    }
  }

  func graph(limit: Int = WorkspaceIndex.defaultGraphNodeLimit) async -> WorkspaceGraph {
    guard isAuthorized else {
      return WorkspaceGraph(nodes: [], edges: [])
    }
    return await index.graph(limit: limit)
  }

  func hubSnapshot() async -> WorkspaceHubSnapshot {
    let recentFiles = await index.recentFiles()
    let tags = await index.tags()
    let categories = await index.categories()
    let graph = await index.graph()
    let configuration = try? await WorkspaceConfigurationStore(rootURL: rootURL).load()
    let sync = configuration?.sync
    let history = ActivityHistoryStore.shared
    return WorkspaceHubSnapshot(
      version: 2,
      hasWorkspace: true,
      workspaceName: rootURL.lastPathComponent,
      rootPath: rootURL.path,
      recentFiles: recentFiles,
      recentDocuments: history.recentDocuments().map(WorkspaceRecentDocument.init),
      activities: history.entries().map(WorkspaceActivitySummary.init),
      tags: tags,
      categories: categories,
      graph: graph,
      accountEnabled: sync?.accountEnabled == true,
      syncEnabled: sync?.syncEnabled == true,
      backupEnabled: sync?.cosBackupEnabled == true || sync?.githubBackupEnabled == true,
      accountServiceStatus: await AccountServiceMonitor.shared.currentStatus,
      conversationPendingCount: ConversationCaptureCoordinator.shared.pendingCount
    )
  }

  private func scheduleRefresh(changedURL: URL?) {
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard let self, !Task.isCancelled else {
        return
      }

      onFileSystemChange?()
      guard isAuthorized else { return }

      do {
        if let changedURL, contains(changedURL) {
          try await index.refresh(url: changedURL)
        } else {
          _ = try await index.rebuild()
        }

        guard !Task.isCancelled, isAuthorized else {
          return
        }
        accessIssue = nil
        onIndexStateChange?(await index.state)
      } catch {
        recordIndexAccessFailure(error)
        onIndexStateChange?(.failed)
      }
    }
  }

  func recordAccessFailure(_ error: Error) {
    accessIssue = WorkspaceAccessIssue.classify(error)
    isAuthorized = false
    onIndexStateChange?(.failed)
  }

  private func recordIndexAccessFailure(_ error: Error) {
    // Index-cache and SQLite failures are not evidence of a workspace access
    // problem. Only classify errors explicitly associated with this root.
    let nsError = error as NSError
    let path = nsError.userInfo[NSFilePathErrorKey] as? String
      ?? (nsError.userInfo[NSURLErrorKey] as? URL)?.path
    guard let path else { return }
    let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    let rootComponents = rootURL.pathComponents
    guard components.starts(with: rootComponents) else { return }
    if WorkspaceAccessIssue.classify(error) != .unavailable {
      recordAccessFailure(error)
    }
  }
}

@MainActor
enum WorkspaceSessionRegistry {
  private static var sessions = [String: WorkspaceSession]()

  static func register(_ session: WorkspaceSession, for fileURL: URL) {
    sessions[fileURL.standardizedFileURL.path] = session
  }

  static func consume(for fileURL: URL?) -> WorkspaceSession? {
    guard let fileURL else {
      return nil
    }

    return sessions.removeValue(forKey: fileURL.standardizedFileURL.path)
  }
}

final class WorkspaceTreeNode: NSObject {
  let url: URL
  let isDirectory: Bool
  let isSymbolicLink: Bool
  weak var parent: WorkspaceTreeNode?

  private var loadedChildren: [WorkspaceTreeNode]?
  private(set) var accessError: Error?

  init(url: URL, parent: WorkspaceTreeNode? = nil) {
    let values: URLResourceValues?
    do {
      values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    } catch {
      values = nil
      accessError = error
    }

    self.url = url.standardizedFileURL
    self.isDirectory = values?.isDirectory == true
    self.isSymbolicLink = values?.isSymbolicLink == true
    self.parent = parent
  }

  func children(showHiddenFiles: Bool) -> [WorkspaceTreeNode] {
    if let loadedChildren {
      return loadedChildren
    }

    guard isDirectory, !isSymbolicLink else {
      return []
    }

    let properties: [URLResourceKey] = [
      .isDirectoryKey,
      .isSymbolicLinkKey,
      .isHiddenKey,
    ]
    let urls: [URL]
    do {
      urls = try FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: properties,
        options: showHiddenFiles ? [] : [.skipsHiddenFiles]
      )
      accessError = nil
    } catch {
      accessError = error
      return []
    }

    let children = urls
      .map { WorkspaceTreeNode(url: $0, parent: self) }
      .sorted {
        if $0.isDirectory != $1.isDirectory {
          return $0.isDirectory
        }
        return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
      }

    loadedChildren = children
    return children
  }

  func invalidate(recursive: Bool = false) {
    if recursive {
      loadedChildren?.forEach { $0.invalidate(recursive: true) }
    }
    loadedChildren = nil
  }
}

private final class WorkspaceFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
  let presentedItemURL: URL?
  let presentedItemOperationQueue: OperationQueue
  var onChange: (@MainActor (URL?) -> Void)?

  init(rootURL: URL) {
    self.presentedItemURL = rootURL
    self.presentedItemOperationQueue = OperationQueue()
    presentedItemOperationQueue.maxConcurrentOperationCount = 1
    presentedItemOperationQueue.qualityOfService = .utility
  }

  func presentedItemDidChange() {
    notify(nil)
  }

  func presentedSubitemDidAppear(at url: URL) {
    notify(url)
  }

  func presentedSubitemDidChange(at url: URL) {
    notify(url)
  }

  func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
    notify(oldURL.deletingLastPathComponent())
  }

  func accommodatePresentedSubitemDeletion(
    at url: URL,
    completionHandler: @escaping @Sendable (Error?) -> Void
  ) {
    notify(url)
    completionHandler(nil)
  }

  private func notify(_ url: URL?) {
    Task { @MainActor [weak self] in
      self?.onChange?(url)
    }
  }
}
