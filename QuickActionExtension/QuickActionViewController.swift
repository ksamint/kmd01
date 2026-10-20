import AppKit
import UniformTypeIdentifiers

@objc(QuickActionViewController) final class QuickActionViewController: NSViewController {
  private var inputURLs: [URL] = []
  private var context: NSExtensionContext?
  private var pendingRequestID: UUID?
  private var pendingRequestURL: URL?
  private var handoffTimeout: Timer?

  override func loadView() {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    for action in QuickActionKind.allCases {
      let button = NSButton(title: action.title, target: self, action: #selector(runAction(_:)))
      button.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
      button.bezelStyle = .rounded
      stack.addArrangedSubview(button)
    }
    view = stack
  }

  override func beginRequest(with context: NSExtensionContext) {
    self.context = context
    let providers = context.inputItems.compactMap { $0 as? NSExtensionItem }.flatMap {
      $0.attachments ?? []
    }
    let group = DispatchGroup()
    let values = LockedURLs()
    for provider in providers
    where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      group.enter()
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
        let url =
          item as? URL ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
        if let url { values.append(url) }
        group.leave()
      }
    }
    group.notify(queue: .main) { [weak self] in
      self?.inputURLs = values.snapshot()
    }
  }

  @objc private func runAction(_ sender: NSButton) {
    guard let kind = sender.identifier.flatMap({ QuickActionKind(rawValue: $0.rawValue) }),
      !inputURLs.isEmpty
    else {
      NSSound.beep()
      return
    }
    guard pendingRequestID == nil else { return }
    do {
      let request = QuickActionRequestV1(
        version: 1,
        id: UUID(),
        createdAt: Date(),
        action: kind,
        resourceBookmarks: try inputURLs.map {
          try $0.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
          )
        }
      )
      guard
        let container = FileManager.default.containerURL(
          forSecurityApplicationGroupIdentifier: "group.art.apuch.ksamint-markedit"
        )
      else { throw CocoaError(.fileWriteNoPermission) }
      let directory = container.appending(path: "QuickActions/Pending", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try JSONEncoder().encode(request).write(
        to: directory.appending(path: "\(request.id).json"),
        options: [.atomic, .completeFileProtectionUnlessOpen]
      )
      guard
        let callbackURL = URL(
          string: "ksamint-markedit://quick-action?id=\(request.id)"
        )
      else { throw CocoaError(.fileWriteInvalidFileName) }
      pendingRequestID = request.id
      pendingRequestURL = directory.appending(path: "\(request.id).json")
      DistributedNotificationCenter.default().addObserver(
        self,
        selector: #selector(handoffReceived(_:)),
        name: WorkspaceBookmarkNotifications.quickActionReceived,
        object: request.id.uuidString
      )
      handoffTimeout = Timer.scheduledTimer(
        timeInterval: 30,
        target: self,
        selector: #selector(handoffExpired),
        userInfo: nil,
        repeats: false
      )
      guard NSWorkspace.shared.open(callbackURL) else {
        finishHandoff(error: CocoaError(.fileReadNoPermission))
        return
      }
    } catch {
      context?.cancelRequest(withError: error)
    }
  }

  @objc private func handoffReceived(_ notification: Notification) {
    guard notification.object as? String == pendingRequestID?.uuidString else { return }
    finishHandoff(error: nil)
  }

  @objc private func handoffExpired() {
    finishHandoff(error: CocoaError(.fileReadNoPermission))
  }

  private func finishHandoff(error: Error?) {
    handoffTimeout?.invalidate()
    handoffTimeout = nil
    DistributedNotificationCenter.default().removeObserver(self, name: WorkspaceBookmarkNotifications.quickActionReceived, object: nil)
    pendingRequestID = nil
    if let error {
      if let pendingRequestURL { try? FileManager.default.removeItem(at: pendingRequestURL) }
      context?.cancelRequest(withError: error)
    } else {
      context?.completeRequest(returningItems: nil)
    }
    pendingRequestURL = nil
  }
}

private final class LockedURLs: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [URL] = []

  func append(_ url: URL) {
    lock.withLock { values.append(url) }
  }

  func snapshot() -> [URL] {
    lock.withLock { values }
  }
}

private enum QuickActionKind: String, Codable, CaseIterable {
  case preview, openEditor, conversationInbox, saveReference, addWorkspace, analyzeAgent,
    createMarkdown, convertMarkdown, convertDocx

  var title: String {
    switch self {
    case .preview: String(localized: "Quick Preview")
    case .openEditor: String(localized: "Open in kmd")
    case .conversationInbox: String(localized: "Import to Conversation Inbox")
    case .saveReference: String(localized: "Save as Reference")
    case .addWorkspace: String(localized: "Add to Workspace")
    case .analyzeAgent: String(localized: "Analyze with Local Agent")
    case .createMarkdown: String(localized: "New Markdown File")
    case .convertMarkdown: String(localized: "Convert to Markdown")
    case .convertDocx: String(localized: "Convert Markdown to DOCX")
    }
  }
}

private struct QuickActionRequestV1: Codable {
  let version: Int
  let id: UUID
  let createdAt: Date
  let action: QuickActionKind
  let resourceBookmarks: [Data]
}
