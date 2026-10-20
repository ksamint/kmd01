import AppKit
import ServiceManagement

enum ConversationCaptureServiceState: Equatable {
  case disabled
  case enabled
  case registered
  case approvalRequired
  case notRegistered
  case unavailable
  case sharingUnavailable

  var localizedDescription: String {
    switch self {
    case .disabled:
      String(localized: "Clipboard capture is off")
    case .enabled:
      String(localized: "Clipboard capture is running in the background")
    case .registered:
      String(localized: "Clipboard capture is registered and will start at the next login")
    case .approvalRequired:
      String(localized: "Approval is required in System Settings › Login Items")
    case .notRegistered:
      String(localized: "The background helper is not registered")
    case .unavailable:
      String(localized: "Background capture is unavailable on this Mac")
    case .sharingUnavailable:
      String(localized: "Capture sharing is unavailable. Check the app installation or access.")
    }
  }

  var systemImage: String {
    switch self {
    case .enabled:
      "checkmark.circle.fill"
    case .registered:
      "clock.badge.checkmark"
    case .approvalRequired:
      "exclamationmark.triangle.fill"
    case .disabled:
      "pause.circle"
    case .notRegistered, .unavailable, .sharingUnavailable:
      "xmark.circle"
    }
  }

  var color: NSColor {
    switch self {
    case .enabled:
      .systemGreen
    case .approvalRequired:
      .systemOrange
    case .disabled, .registered, .notRegistered, .unavailable, .sharingUnavailable:
      .secondaryLabelColor
    }
  }
}

@MainActor
final class ConversationCaptureCoordinator: NSObject {
  static let shared = ConversationCaptureCoordinator()
  static let agentArgument = "--conversation-capture-agent"
  static let historyDirectoryName = "Conversations"
  static let historySearchQuery = #"path:"Conversations/""#

  private static let maximumClipboardBytes = 5 * 1024 * 1024
  private static let passwordManagerBundleIDs = [
    "com.1password.1password",
    "com.agilebits.onepassword7",
    "com.bitwarden.desktop",
    "com.apple.Passwords",
    "com.lastpass.LastPass",
  ]

  private var timer: Timer?
  private var statusItem: NSStatusItem?
  private var lastChangeCount = NSPasteboard.general.changeCount
  private var idlePolls = 0
  private var captureNextCopy = false
  private var lastSavedURL: URL?
  private var isAgentProcess = false
  private var sharedConfigurationUnavailable = false
  private var sharedContainerUnavailable = false
  private let documentCodec = ConversationCaptureDocument()
  private lazy var pendingQueue = ConversationCaptureQueue { [weak self] available in
    self?.sharedContainerUnavailable = !available
  }
  private lazy var workspaceGrantPublisher = UserDefaults(suiteName: "group.art.apuch.ksamint-markedit")
    .map { WorkspaceBookmarkPublisher(shared: $0) }

  override private init() {
    super.init()
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(workspaceGrantRequested),
      name: WorkspaceBookmarkNotifications.requested,
      object: nil
    )
  }

  @objc private func workspaceGrantRequested() {
    synchronizeHelperConfiguration()
  }

  func configureFromPreferences() {
    synchronizeHelperConfiguration()
    guard AppPreferences.General.conversationCaptureEnabled else { return }
    _ = registerLoginAgent()
  }

  func startAgentProcess() {
    isAgentProcess = true
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(stopAgentProcess),
      name: .conversationCaptureDisabled,
      object: nil
    )
    start()
  }

  func setEnabled(_ enabled: Bool, updatePreference: Bool = true) {
    if updatePreference {
      AppPreferences.General.conversationCaptureEnabled = enabled
    }
    // Keep the helper's shared preference in sync in both directions. Without
    // this, disabling capture leaves an already-running helper polling the
    // pasteboard with a stale `true` value.
    synchronizeHelperConfiguration()
    if enabled {
      _ = registerLoginAgent()
    } else {
      timer?.invalidate()
      timer = nil
      if let statusItem {
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
      }
      unregisterLoginAgent()
      DistributedNotificationCenter.default().post(name: .conversationCaptureDisabled, object: nil)
      if isAgentProcess { NSApp.terminate(nil) }
    }
  }

  var pendingCount: Int {
    pendingQueue.count
  }

  func importConversationResources(_ urls: [URL]) throws {
    var imported = false
    for url in urls where !url.hasDirectoryPath {
      let values = try url.resourceValues(forKeys: [.fileSizeKey])
      guard (values.fileSize ?? 0) <= Self.maximumClipboardBytes else { continue }
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
      imported = saveConversation(text, sourceName: url.lastPathComponent, sourceBundleID: nil) || imported
    }
    if !imported { throw CocoaError(.fileReadUnsupportedScheme) }
  }

  private func start() {
    guard timer == nil else { return }
    lastChangeCount = NSPasteboard.general.changeCount
    installStatusItem()
    pendingQueue.purgeExpired()
    schedulePoll(after: 0.75)
  }

  private func schedulePoll(after interval: TimeInterval) {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
      Task { @MainActor in self?.pollPasteboard() }
    }
  }

  private func pollPasteboard() {
    let pasteboard = NSPasteboard.general
    guard pasteboard.changeCount != lastChangeCount else {
      idlePolls += 1
      schedulePoll(after: idlePolls > 20 ? 2 : 0.75)
      return
    }
    lastChangeCount = pasteboard.changeCount
    idlePolls = 0
    defer { schedulePoll(after: 0.75) }

    guard let text = preferredText(from: pasteboard), shouldCapture(text) else { return }
    let application = NSWorkspace.shared.frontmostApplication
    let bundleID = application?.bundleIdentifier
    if !captureNextCopy, Self.passwordManagerBundleIDs.contains(bundleID ?? "") { return }

    let forced = captureNextCopy
    captureNextCopy = false
    updateStatusMenu()
    if !forced, isSensitive(text) { return }
    if forced || isHighConfidenceConversation(text) {
      _ = saveConversation(text, sourceName: application?.localizedName, sourceBundleID: bundleID)
    } else {
      savePending(text, sourceName: application?.localizedName, sourceBundleID: bundleID)
    }
  }

  private func preferredText(from pasteboard: NSPasteboard) -> String? {
    // Plain text first: importing HTML through WebKit on the main thread is
    // expensive and happens on every clipboard change while capture is on.
    let value = pasteboard.string(forType: .string).flatMap { $0.isEmpty ? nil : $0 }
      ?? attributedClipboardText(from: pasteboard, type: .html, documentType: .html)
      ?? attributedClipboardText(from: pasteboard, type: .rtf, documentType: .rtf)
    guard let value, let size = value.data(using: .utf8)?.count,
          size > 0, size <= Self.maximumClipboardBytes else { return nil }
    return value
  }

  private func attributedClipboardText(
    from pasteboard: NSPasteboard,
    type: NSPasteboard.PasteboardType,
    documentType: NSAttributedString.DocumentType
  ) -> String? {
    guard let data = pasteboard.data(forType: type),
          let value = try? NSAttributedString(
            data: data,
            options: [.documentType: documentType],
            documentAttributes: nil
          ).string,
          !value.isEmpty else { return nil }
    return value
  }

  private func shouldCapture(_ text: String) -> Bool {
    captureNextCopy || text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 80
  }

  private func isSensitive(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.range(of: #"^\d{4,8}$"#, options: .regularExpression) != nil { return true }
    if !trimmed.contains("\n"), trimmed.count >= 20 {
      let alphaNumeric = trimmed.filter { $0.isLetter || $0.isNumber }.count
      let unique = Set(trimmed).count
      if alphaNumeric == trimmed.count, unique > 14 { return true }
    }
    return false
  }

  private func isHighConfidenceConversation(_ text: String) -> Bool {
    documentCodec.isHighConfidenceConversation(text)
  }

  @discardableResult
  private func saveConversation(_ text: String, sourceName: String?, sourceBundleID: String?) -> Bool {
    guard let rootURL = authorizedWorkspaceRoot() else {
      savePending(text, sourceName: sourceName, sourceBundleID: sourceBundleID)
      return false
    }
    defer { rootURL.stopAccessingSecurityScopedResource() }
    let normalized = documentCodec.normalize(text)
    let digest = documentCodec.digest(normalized)
    let calendar = Calendar(identifier: .gregorian)
    let timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    let parts = calendar.dateComponents(in: timeZone, from: Date())
    let directory = rootURL
      .appending(path: Self.historyDirectoryName, directoryHint: .isDirectory)
      .appending(path: String(format: "%04d", parts.year ?? 0), directoryHint: .isDirectory)
      .appending(path: String(format: "%02d", parts.month ?? 0), directoryHint: .isDirectory)
    let filename = "Captured--\(digest.prefix(12)).md"
    let fileURL = directory.appending(path: filename)
    guard !FileManager.default.fileExists(atPath: fileURL.path) else { return true }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let markdown = documentCodec.markdown(
        for: normalized,
        digest: digest,
        sourceName: sourceName,
        sourceBundleID: sourceBundleID
      )
      try Data(markdown.utf8).write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
      lastSavedURL = fileURL
      updateStatusMenu()
      return true
    } catch {
      NSSound.beep()
      savePending(text, sourceName: sourceName, sourceBundleID: sourceBundleID)
      return false
    }
  }

  private func savePending(_ text: String, sourceName: String?, sourceBundleID: String?) {
    do {
      let capture = PendingConversationCapture(
        capturedAt: Date(),
        sourceName: sourceName,
        sourceBundleID: sourceBundleID,
        content: text
      )
      try pendingQueue.save(capture)
      updateStatusMenu()
    } catch {
      NSSound.beep()
    }
  }

  private func authorizedWorkspaceRoot() -> URL? {
    guard let bookmark = AppPreferences.General.workspaceFolderBookmark else { return nil }
    var stale = false
    guard let url = try? URL(
      resolvingBookmarkData: bookmark,
      options: [.withSecurityScope, .withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &stale
    ), url.startAccessingSecurityScopedResource() else { return nil }
    if stale, let refreshed = try? url.bookmarkData(
      options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
    ) {
      workspaceBookmarkDidRefresh(from: bookmark, to: refreshed)
      AppPreferences.General.workspaceFolderBookmark = refreshed
      AppPreferences.General.workspaceFolderBookmarks =
        AppPreferences.General.workspaceFolderBookmarks.mapValues { $0 == bookmark ? refreshed : $0 }
      synchronizeHelperConfiguration()
    }
    return url.standardizedFileURL
  }
}

extension ConversationCaptureCoordinator {
  var serviceState: ConversationCaptureServiceState {
    guard AppPreferences.General.conversationCaptureEnabled else { return .disabled }
    if sharedConfigurationUnavailable || sharedContainerUnavailable { return .sharingUnavailable }
    // Distinguish a running helper from a login item that is only registered
    // for the next login session.
    if isCaptureHelperRunning { return .enabled }
    // Developer ID/App Store builds use SMAppService. Local ad-hoc `.dev`
    // builds cannot register a login item, but can safely run the embedded
    // helper for the lifetime of the development session.
    if isDevelopmentBuild {
      return .notRegistered
    }
    guard #available(macOS 13, *) else { return .unavailable }
    switch SMAppService.loginItem(identifier: captureHelperIdentifier).status {
    case .enabled:
      return .registered
    case .requiresApproval:
      return .approvalRequired
    case .notRegistered:
      return .notRegistered
    case .notFound:
      // The helper is embedded, but macOS has not indexed it for
      // SMAppService yet. Enabling capture will retry registration and use a
      // signed session fallback if indexing still has not completed.
      return .notRegistered
    @unknown default:
      return .unavailable
    }
  }

  func showInbox() {
    reviewNextPendingCapture()
  }

  func openCaptureHistory() {
    guard let root = authorizedWorkspaceRoot() else {
      showWorkspaceRequired()
      return
    }
    defer { root.stopAccessingSecurityScopedResource() }
    let folder = root.appending(path: Self.historyDirectoryName, directoryHint: .isDirectory)
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      NSWorkspace.shared.open(folder)
    } catch {
      showCaptureError(error.localizedDescription)
    }
  }

  func searchCaptureHistory() {
    NSApp.activate(ignoringOtherApps: true)
    if let editor = NSApp.currentEditor {
      editor.showCaptureHistorySearch()
      return
    }
    NSDocumentController.shared.newDocument(nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
      NSApp.currentEditor?.showCaptureHistorySearch()
    }
  }

  func showClipboardPalette() {
    if serviceState == .enabled {
      DistributedNotificationCenter.default().post(name: .showClipboardPalette, object: nil)
      return
    }
    guard isDevelopmentBuild, launchDevelopmentHelper() else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      DistributedNotificationCenter.default().post(name: .showClipboardPalette, object: nil)
    }
  }

  func openAccessibilitySettings() {
    guard let settings = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    ) else { return }
    NSWorkspace.shared.open(settings)
  }

  func openPermissionSettings() {
    guard let settings = URL(
      string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    ) else { return }
    NSWorkspace.shared.open(settings)
  }
}

extension ConversationCaptureCoordinator {
  private func installStatusItem() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(
      systemSymbolName: "text.bubble",
      accessibilityDescription: String(localized: "Conversation Inbox")
    )
    statusItem = item
    updateStatusMenu()
  }

  private func updateStatusMenu() {
    guard let statusItem else { return }
    let menu = NSMenu()
    let state = NSMenuItem(
      title: captureNextCopy
        ? String(localized: "Waiting for next copy…")
        : String(localized: "Conversation capture is on"),
      action: nil,
      keyEquivalent: ""
    )
    state.isEnabled = false
    menu.addItem(state)
    menu.addItem(
      withTitle: String(localized: "Capture Next Copy"),
      action: #selector(captureNext),
      keyEquivalent: ""
    )
      .target = self
    menu.addItem(
      withTitle: String(localized: "Open Conversation Inbox"),
      action: #selector(openInbox),
      keyEquivalent: ""
    )
      .target = self
    menu.addItem(
      withTitle: String(localized: "Open Capture History"),
      action: #selector(openCaptureHistoryFromMenu),
      keyEquivalent: ""
    )
      .target = self
    menu.addItem(
      withTitle: String(localized: "Search Captures"),
      action: #selector(searchCaptureHistoryFromMenu),
      keyEquivalent: ""
    )
      .target = self
    if lastSavedURL != nil {
      menu.addItem(
        withTitle: String(localized: "Undo Last Capture"),
        action: #selector(undoLastCapture),
        keyEquivalent: ""
      )
        .target = self
    }
    menu.addItem(.separator())
    menu.addItem(
      withTitle: String(localized: "Turn Off Conversation Capture"),
      action: #selector(turnOff),
      keyEquivalent: ""
    )
      .target = self
    statusItem.menu = menu
  }

  @objc private func captureNext() {
    captureNextCopy = true
    updateStatusMenu()
  }

  @objc private func openInbox() {
    reviewNextPendingCapture()
  }

  @objc private func openCaptureHistoryFromMenu() {
    openCaptureHistory()
  }

  @objc private func searchCaptureHistoryFromMenu() {
    searchCaptureHistory()
  }

  private func reviewNextPendingCapture() {
    pendingQueue.purgeExpired()
    guard let url = pendingQueue.urls.first else {
      if let root = authorizedWorkspaceRoot() {
        let folder = root.appending(path: Self.historyDirectoryName, directoryHint: .isDirectory)
        root.stopAccessingSecurityScopedResource()
        NSWorkspace.shared.open(folder)
      }
      return
    }
    guard let capture = pendingQueue.capture(at: url) else {
      pendingQueue.remove(url)
      reviewNextPendingCapture()
      return
    }

    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = String(localized: "Review clipboard capture")
    let source = capture.sourceName ?? String(localized: "Unknown application")
    let preview = String(capture.content.prefix(1_500))
    alert.informativeText = "\(source) · \(capture.capturedAt.formatted())\n\n\(preview)"
    alert.addButton(withTitle: String(localized: "Save to Conversations"))
    alert.addButton(withTitle: String(localized: "Keep for Later"))
    alert.addButton(withTitle: String(localized: "Discard"))

    switch alert.runModal() {
    case .alertFirstButtonReturn:
      if saveConversation(
        capture.content,
        sourceName: capture.sourceName,
        sourceBundleID: capture.sourceBundleID
      ) {
        pendingQueue.remove(url)
        reviewNextPendingCapture()
      }
    case .alertThirdButtonReturn:
      pendingQueue.remove(url)
      reviewNextPendingCapture()
    default:
      break
    }
  }

  @objc private func undoLastCapture() {
    guard let url = lastSavedURL else { return }
    _ = try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    lastSavedURL = nil
    updateStatusMenu()
  }

  @objc private func turnOff() {
    setEnabled(false)
  }

  @objc private func stopAgentProcess() {
    guard isAgentProcess else { return }
    NSApp.terminate(nil)
  }

  @discardableResult
  private func registerLoginAgent() -> Bool {
    if isDevelopmentBuild {
      return launchDevelopmentHelper()
    }
    guard #available(macOS 13, *) else { return false }
    let service = SMAppService.loginItem(identifier: captureHelperIdentifier)
    let initialStatus = service.status
    do {
      switch initialStatus {
      case .notRegistered, .notFound:
        try service.register()
      default:
        break
      }
      switch service.status {
      case .enabled:
        return true
      case .requiresApproval:
        showLoginItemApprovalRequired()
        return false
      case .notFound:
        return false
      default:
        return false
      }
    } catch {
      return false
    }
  }

  private func unregisterLoginAgent() {
    // Stop both an SMAppService-managed instance and the explicit session
    // fallback. This keeps the opt-out immediate and privacy preserving.
    for application in NSRunningApplication.runningApplications(
      withBundleIdentifier: captureHelperIdentifier
    ) {
      application.terminate()
    }
    if isDevelopmentBuild { return }
    guard #available(macOS 13, *) else { return }
    let service = SMAppService.loginItem(identifier: captureHelperIdentifier)
    try? service.unregister()
  }

  /// Mirrors the containing app's identifier so both Debug (`.dev`) and
  /// Release builds address the login item actually embedded in that app.
  private var captureHelperIdentifier: String {
    let appIdentifier = Bundle.main.bundleIdentifier ?? "art.apuch.ksamint.markedit"
    return "\(appIdentifier).conversation-capture-helper"
  }

  private var isDevelopmentBuild: Bool {
    Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
  }

  private var isCaptureHelperRunning: Bool {
    !NSRunningApplication.runningApplications(
      withBundleIdentifier: captureHelperIdentifier
    ).isEmpty
  }

  @discardableResult
  private func launchDevelopmentHelper() -> Bool {
    if isCaptureHelperRunning { return true }
    let helperURL = Bundle.main.bundleURL
      .appending(
        path: "Contents/Library/LoginItems/ConversationCaptureHelper.app",
        directoryHint: .isDirectory
      )
    guard FileManager.default.fileExists(atPath: helperURL.path) else { return false }
    return NSWorkspace.shared.open(helperURL)
  }

  func workspaceBookmarkDidRefresh(from original: Data, to refreshed: Data) {
    workspaceGrantPublisher?.preserveGeneration(from: original, to: refreshed)
  }

  func synchronizeHelperConfiguration() {
    let groupIdentifier = "group.art.apuch.ksamint-markedit"
    guard let defaults = UserDefaults(suiteName: groupIdentifier) else {
      sharedConfigurationUnavailable = true
      return
    }
    sharedConfigurationUnavailable = false
    defaults.set(AppPreferences.General.conversationCaptureEnabled, forKey: "conversationCaptureEnabled")
    defaults.set(
      AppPreferences.General.conversationCaptureSyncInterval.rawValue,
      forKey: "conversationCaptureSyncInterval"
    )
    let bookmark = AppPreferences.General.workspaceFolderBookmark
    if let refreshed = workspaceGrantPublisher?.publish(bookmark), refreshed != bookmark {
      AppPreferences.General.workspaceFolderBookmark = refreshed
      AppPreferences.General.workspaceFolderBookmarks =
        AppPreferences.General.workspaceFolderBookmarks.mapValues { $0 == bookmark ? refreshed : $0 }
    }
    DistributedNotificationCenter.default().post(name: .captureSettingsChanged, object: nil)
  }

  private func showLoginItemApprovalRequired() {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = String(localized: "Enable Conversation Capture")
    alert.informativeText = String(
      localized: "Allow kmd Conversation Capture in System Settings › General › Login Items."
    )
    alert.addButton(withTitle: String(localized: "Open System Settings"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    if let settings = URL(
      string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    ) {
      NSWorkspace.shared.open(settings)
    }
  }

  private func showWorkspaceRequired() {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = String(localized: "Choose a workspace first")
    alert.informativeText = String(
      localized: "Captured conversations are saved inside the authorized workspace’s Conversations folder."
    )
    alert.addButton(withTitle: String(localized: "OK"))
    alert.runModal()
  }

  private func showCaptureError(_ description: String) {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = String(localized: "Could not open capture history")
    alert.informativeText = description
    alert.addButton(withTitle: String(localized: "OK"))
    alert.runModal()
  }
}

private extension Notification.Name {
  static let conversationCaptureDisabled = Notification.Name(
    "art.apuch.ksamint-markedit.conversation-capture-disabled"
  )
  static let captureSettingsChanged = Notification.Name(
    "art.apuch.ksamint.capture-settings-changed"
  )
  static let showClipboardPalette = Notification.Name(
    "art.apuch.ksamint.show-clipboard-palette"
  )
}
