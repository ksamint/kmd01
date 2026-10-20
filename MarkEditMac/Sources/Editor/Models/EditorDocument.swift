//
//  EditorDocument.swift
//  MarkEditMac
//
//  Created by cyan on 12/12/22.

import AppKit
import AppKitExtensions
import MarkEditKit
import SharedUI
import FileVersion
import TextBundle
import WebKit

/**
 Main document used to deal with markdown files and text bundles.

 https://developer.apple.com/documentation/appkit/nsdocument
 */
final class EditorDocument: NSDocument {
  var fileData: Data?
  var spellDocTag: Int?
  var stringValue = ""
  var formatCompleted = false // The result of format content is all good
  var isOutdated = false // The content is outdated, needs an update
  var isReadOnlyMode = false
  var isTerminating = false

  // For tab restoration
  var lastTabIndex: Int?
  var lastWasStandalone: Bool = false
  weak var lastSiblingWindow: NSWindow?

  var isContentReady: Bool {
    isDraft || fileURL == nil || fileData != nil
  }

  var hasBeenReverted: Bool {
    Date.now.timeIntervalSince(revertedDate) < 1
  }

  var canUndo: Bool {
    get async {
      if isReadOnlyMode {
        return false
      }

      return (try? await bridge?.history.canUndo()) ?? false
    }
  }

  var canRedo: Bool {
    get async {
      if isReadOnlyMode {
        return false
      }

      return (try? await bridge?.history.canRedo()) ?? false
    }
  }

  var lineEndings: LineEndings? {
    get async {
      try? await bridge?.lineEndings.getLineEndings()
    }
  }

  var baseURL: URL? {
    textBundle != nil ? fileURL : folderURL
  }

  var textFileURL: URL? {
    fileURL?.appending(path: textBundle?.textFileName ?? "", directoryHint: .notDirectory)
  }

  var shouldSaveWhenIdle: Bool {
    // Saving documents without a fileURL would bring up the dialog
    AppRuntimeConfig.autoSaveWhenIdle && fileURL != nil
  }

  private var saveTask: Task<Bool, Never>?
  private var pendingSaveCompletion: DocumentSaveCompletion?
  private var pendingCloseCompletions: [UUID: DocumentSaveCompletion] = [:]
  private var autosaveDelayedTask: Task<Void, Never>?
  private var textBundle: TextBundleWrapper?
  private var revertedDate: Date = .distantPast
  private var suggestedTextEncoding: EditorTextEncoding?
  private weak var hostViewController: EditorViewController?

  /**
   File name from the table of contents.
   */
  private var suggestedFilename: String?

  /**
   File name from external apps, such as Shortcuts or URL schemes.
   */
  private var externalFilename: String?

  override func makeWindowControllers() {
    let storyboard = NSStoryboard(name: NSStoryboard.Name("Main"), bundle: nil)
    let sceneIdentifier = NSStoryboard.SceneIdentifier("EditorWindowController")

    guard let windowController = storyboard.instantiateController(withIdentifier: sceneIdentifier) as? EditorWindowController else {
      return
    }

    // Note hostViewController is a weak reference, it must be strongly retained first
    let contentVC = EditorPreloader.shared.takeViewController()
    windowController.contentViewController = contentVC

    // Restore the autosaved window frame, which relies on windowFrameAutosaveName
    if let autosavedFrame = windowController.autosavedFrame {
      windowController.window?.setFrame(autosavedFrame, display: false)
    }

    isTerminating = false
    hostViewController = contentVC
    hostViewController?.workspaceSession = WorkspaceSessionRegistry.consume(for: fileURL)
    hostViewController?.representedObject = self

    externalFilename = AppDocumentController.suggestedFilename
    AppDocumentController.suggestedFilename = nil

    NSApplication.shared.closeOpenPanels()
    addWindowController(windowController)
    if let fileURL {
      ActivityHistoryStore.shared.record(.opened, url: fileURL)
    }

    #if DEBUG
      if ProcessInfo.processInfo.environment["DEBUG_TAKING_SCREENSHOTS"] == "YES" {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          windowController.window?.setFrameSize(CGSize(width: 720, height: 480))
          windowController.window?.center()
        }
      }
    #endif
  }

  func waitUntilSaveCompleted(userInitiated: Bool = false) async -> Bool {
    await withCheckedContinuation { continuation in
      saveContent(userInitiated: userInitiated) { saved in
        continuation.resume(returning: saved)
      }
    }
  }

  func saveContent(sender: Any? = nil, userInitiated: Bool = false, completion: ((Bool) -> Void)? = nil) {
    enqueueSave(userInitiated: userInitiated, saveAs: false, completion: completion)
  }

  func autosaveDelayed(seconds: Double = 0.25) {
    autosaveDelayedTask?.cancel()
    autosaveDelayedTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      if !Task.isCancelled {
        try? await self?.autosave(withImplicitCancellability: false)
      }
    }
  }

  func updateContent(userInitiated: Bool = false) {
    Task { @MainActor in
      do {
        try await refreshContent(userInitiated: userInitiated)
      } catch {
        // Idle synchronization must retain dirty state without opening an error panel.
        Logger.log(.error, "Failed to synchronize editor content: \(error)")
      }
    }
  }

  func prepareSpellDocTag() {
    guard spellDocTag == nil else {
      return
    }

    spellDocTag = NSSpellChecker.uniqueSpellDocumentTag()
  }

  func applyWorkspaceMetadata(
    _ transform: (WorkspaceDocumentMetadata) -> WorkspaceDocumentMetadata
  ) async throws {
    guard let hostViewController,
          let bridge,
          let currentText = await hostViewController.editorText else {
      throw CocoaError(.fileReadUnknown)
    }

    let metadata = WorkspaceDocumentMetadata.parse(currentText)
    let updatedText = transform(metadata).applying(to: currentText)
    guard updatedText != currentText else {
      return
    }

    try await withCheckedThrowingContinuation { continuation in
      bridge.core.replaceText(text: updatedText, granularity: .wholeDocument) { result in
        continuation.resume(with: result)
      }
    }
    stringValue = updatedText
    isOutdated = true
    updateChangeCount(.changeDone)
  }

  func currentWorkspaceMetadata() async -> WorkspaceDocumentMetadata? {
    guard let text = await hostViewController?.editorText else {
      return nil
    }
    return WorkspaceDocumentMetadata.parse(text)
  }
}

// MARK: - Overridden

extension EditorDocument {
  override class var autosavesInPlace: Bool {
    true
  }

  override class func canConcurrentlyReadDocuments(ofType type: String) -> Bool {
    // Concurrent reads let AppKit construct and read the document on its
    // document-opening queue (window restoration and autosaved drafts take a
    // path AppDocumentController does not hop to main), where the main-actor
    // overrides below trap under Swift 6. Reads must also finish populating the
    // document before returning, so immediate saves cannot write empty content.
    false
  }

  override var fileURL: URL? {
    get {
      super.fileURL
    }
    set {
      let previousURL = super.fileURL
      super.fileURL = newValue

      if let previousURL, let newValue,
         previousURL.standardizedFileURL != newValue.standardizedFileURL {
        Task { @MainActor in
          ActivityHistoryStore.shared.record(.renamed, url: newValue)
        }
      }
    }
  }

  override var displayName: String? {
    get {
      // Default file name for new drafts, pre-filled in the save panel
      if fileURL == nil, let newFileName = suggestedFilename ?? externalFilename {
        return newFileName
      }

      return super.displayName
    }
    set {
      super.displayName = newValue
    }
  }

  override func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) -> Bool {
    // EditorDocument owns AppKit and WebKit state isolated to the main actor.
    // Advertising concurrent writes lets NSDocument call these overrides from a
    // worker queue, which traps under Swift 6 executor checks.
    false
  }

  override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
    // AppKit's close decision must see the latest editor content. In particular,
    // a failed refresh must not turn an edited draft into an empty saved file.
    Task { @MainActor in
      do {
        if isOutdated {
          try await refreshContent()
        }
        if (shouldSaveWhenIdle || !closeAlwaysConfirmsChanges) && fileURL != nil && isDocumentEdited {
          guard await waitUntilSaveCompleted() else {
            cancelTermination()
            notifyDocumentDelegate(delegate, selector: shouldCloseSelector, result: false, contextInfo: contextInfo)
            return
          }
        }
        let identifier = UUID()
        let callback = DocumentSaveCompletion { [self] shouldClose in
          pendingCloseCompletions[identifier] = nil
          if !shouldClose {
            cancelTermination()
          }
          notifyDocumentDelegate(delegate, selector: shouldCloseSelector, result: shouldClose, contextInfo: contextInfo)
        }
        pendingCloseCompletions[identifier] = callback
        super.canClose(
          withDelegate: callback,
          shouldClose: #selector(DocumentSaveCompletion.document(_:didSave:contextInfo:)),
          contextInfo: nil
        )
      } catch {
        cancelTermination()
        presentError(error)
        notifyDocumentDelegate(delegate, selector: shouldCloseSelector, result: false, contextInfo: contextInfo)
      }
    }
  }

  override func close() {
    autosaveDelayedTask?.cancel()
    autosaveDelayedTask = nil
    saveToClosedTabHistory()
    windowControllers.forEach { $0.window?.isReleasedWhenClosed = true }
    super.close()

    if let spellDocTag {
      NSSpellChecker.shared.closeSpellDocument(withTag: spellDocTag)
    }
  }

  override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
    let preferredExtension = MainActor.assumeIsolated {
      AppPreferences.General.newFilenameExtension.rawValue
    }
    // Include all markdown and plaintext types, but prioritize the configured default
    let exportedTypes = NewFilenameExtension.allCases
      .sorted { lhs, _ in
        lhs.rawValue == preferredExtension
      }
      .map { $0.exportedType }

    // Enable *.textbundle only when we have the bundle, typically for a duplicated draft
    let hasTextBundle = MainActor.assumeIsolated { textBundle != nil }
    return hasTextBundle ? ["org.textbundle.package"] + exportedTypes : exportedTypes
  }

  override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
    if typeName.isTextBundle {
      return "textbundle"
    }

    return NewFilenameExtension.preferredExtension(for: typeName).rawValue
  }

  override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
    if let defaultDirectory = AppRuntimeConfig.defaultSaveDirectory {
      // Overriding savePanel.directoryURL does not work as intended
      NSDocumentController.shared.setOpenPanelDirectory(defaultDirectory)
    }

    if textBundle == nil {
      savePanel.accessoryView = EditorSaveOptionsView.wrapper(for: .savePanel) { [weak self, weak savePanel] result in
        switch result {
        case .fileExtension(let value):
          savePanel?.enforceUniformType(value.uniformType)
        case .textEncoding(let value):
          self?.suggestedTextEncoding = value
        default:
          Logger.assertFail("Invalid change: \(result)")
        }
      }
    } else {
      savePanel.accessoryView = nil
    }

    suggestedTextEncoding = nil
    savePanel.allowsOtherFileTypes = true
    return super.prepareSavePanel(savePanel)
  }
}

// MARK: - Reading and Writing

extension EditorDocument {
  override func read(from data: Data, ofType typeName: String) throws {
    // NSDocument may save or restore the document as soon as this returns.
    // Publishing the decoded state later would let those paths write empty or
    // stale text, and a late read callback could overwrite an intervening edit.
    MainActor.assumeIsolated {
      let newValue: String
      if let encoding = AppDocumentController.suggestedTextEncoding {
        newValue = encoding.decode(data: data)
      } else {
        newValue = AppPreferences.General.defaultTextEncoding.decode(data: data, guessEncoding: true)
      }
      fileData = data
      stringValue = newValue
      hostViewController?.representedObject = self
    }
  }

  override func save(_ sender: Any?) {
    saveContent(sender: sender, userInitiated: true)
  }

  override func save(withDelegate delegate: Any?, didSave didSaveSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
    saveContent(userInitiated: true) { saved in
      self.notifyDocumentDelegate(delegate, selector: didSaveSelector, result: saved, contextInfo: contextInfo)
    }
  }

  override func saveAs(_ sender: Any?) {
    enqueueSave(userInitiated: true, saveAs: true)
  }

  override func autosave(withImplicitCancellability implicitlyCancellable: Bool) async throws {
    if isOutdated {
      try await refreshContent()
    }

    // The default autosave doesn't work when the app is about to terminate,
    // it is because we have to do it in an asynchronous way.
    //
    // To work around this, check a flag to save the document manually.
    if !hasBeenReverted && isTerminating && hasUnautosavedChanges, let fileURL, let fileType {
      try writeSafely(to: fileURL, ofType: fileType, for: .autosaveAsOperation)
      fileModificationDate = .now // Prevent immediate presentedItemDidChange calls
    }

    try await super.autosave(withImplicitCancellability: implicitlyCancellable)
  }

  override func data(ofType typeName: String) throws -> Data {
    // Every write entry must fail rather than serialize a stale WebKit snapshot.
    guard !isOutdated else { throw CocoaError(.fileWriteUnknown) }
    let encoding = suggestedTextEncoding ?? AppPreferences.General.defaultTextEncoding
    return encoding.encode(string: stringValue) ?? stringValue.toData() ?? Data()
  }

  override func presentedItemDidChange() {
    guard let fileURL, let fileType else {
      return
    }

    // Only under certain conditions we need this flow,
    // e.g., editing in VS Code won't trigger the regular data(ofType...) reload
    DispatchQueue.main.async {
      do {
        // For text bundles, use the text.markdown file inside it
        let filePath = self.textBundle?.textFilePath(baseURL: fileURL) ?? fileURL.path
        let modificationDate = try FileManager.default.attributesOfItem(atPath: filePath)[.modificationDate] as? Date

        if let modificationDate, modificationDate > (self.fileModificationDate ?? .distantPast) {
          self.fileModificationDate = modificationDate
          try self.revert(toContentsOf: fileURL, ofType: fileType)
        }
      } catch {
        Logger.log(.error, error.localizedDescription)
      }
    }
  }

  override func revert(toContentsOf url: URL, ofType typeName: String) throws {
    revertedDate = .now
    try super.revert(toContentsOf: url, ofType: typeName)
  }
}

// MARK: - Scripting

extension EditorDocument {
  /// Handle save operations from AppleScript.
  ///
  /// Override to catch invalid output paths early so we can present more informative errors.
  override func handleSave(_ command: NSScriptCommand) -> Any? {
    guard let fileURL = command.evaluatedArguments?["File"] as? URL else {
      // Save without predefined destination (will open save panel if needed).
      return saveScriptCommand(command)
    }

    let inputExtension = fileURL.pathExtension.lowercased()

    // Support extension-less paths by bypassing file type validation
    if inputExtension.isEmpty {
      return saveScriptCommand(command, destination: (fileURL.deletingPathExtension(), ""))
    }

    // Provided limited support for the 'as' parameter
    if let desiredType = command.evaluatedArguments?["FileType"] as? String {
      let desiredExtension = NewFilenameExtension.preferredExtension(for: desiredType).rawValue
      if inputExtension == desiredExtension {
        return saveScriptCommand(command, destination: (fileURL, desiredType))
      }

      // Raise error because we cannot adjust the extension due to sandbox restrictions
      let scriptError = ScriptingError.extensionMismatch(
        expectedExtension: desiredExtension,
        outputType: desiredType
      )

      scriptError.applyToCommand(command)
      return nil
    }

    let isValidExtension = NewFilenameExtension.allCases.contains {
      $0.rawValue == inputExtension
    } || (textBundle != nil && inputExtension == "textbundle")

    guard isValidExtension else {
      let scriptError = ScriptingError.invalidDestination(fileURL, document: self)
      scriptError.applyToCommand(command)
      return nil
    }

    let typeName = NewFilenameExtension.allCases.first { $0.rawValue == inputExtension }?.exportedType ?? "org.textbundle.package"
    return saveScriptCommand(command, destination: (fileURL, typeName))
  }
}

// MARK: - Version Browsing

extension EditorDocument: FileVersionPickerDelegate {
  override func browseVersions(_ sender: Any?) {
    guard let fileURL else {
      return Logger.assertFail("Missing fileURL for document: \(self)")
    }

    let localVersions = {
      let otherVersions = NSFileVersion.otherVersionsOfItem(at: fileURL) ?? []
      Logger.log(.debug, "Found \(otherVersions.count) local versions")

      if otherVersions.isEmpty, let currentVersion = NSFileVersion.currentVersionOfItem(at: fileURL) {
        return [currentVersion]
      }

      let sortedVersions = otherVersions.newestToOldest()
      let differentIndex = sortedVersions.firstIndex {
        // Find the first version that differs from the current one
        (try? Data(contentsOf: $0.url))?.toString() != stringValue
      }

      return Array(sortedVersions.suffix(from: differentIndex ?? 0))
    }()

    guard !localVersions.isEmpty else {
      return Logger.assertFail("File \(fileURL) has no local versions")
    }

    let picker = FileVersionPicker(
      modernStyle: AppDesign.modernStyle,
      fileURL: fileURL,
      currentText: stringValue,
      localVersions: localVersions,
      localizable: FileVersionLocalizable(
        previous: Localized.General.previous,
        next: Localized.General.next,
        cancel: Localized.General.cancel,
        revertTitle: Localized.FileVersion.revertTitle,
        modeTitles: Localized.FileVersion.modeTitles
      ),
      delegate: self
    )

    hostViewController?.presentAsSheet(picker)
  }

  func fileVersionPicker(_ picker: FileVersionPicker, didPickVersion version: NSFileVersion) {
    guard let contents = try? Data(contentsOf: version.url).toString() else {
      return Logger.assertFail("Failed to get file contents of version: \(version)")
    }

    stringValue = contents
    hostViewController?.resetEditor()
    saveContent()
  }

  func fileVersionPicker(_ picker: FileVersionPicker, didBecomeSheet: Bool) {
    hostViewController?.setHasModalSheet(value: didBecomeSheet)
  }
}

// MARK: - Text Bundle

extension EditorDocument {
  override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
    guard typeName.isTextBundle else {
      return try super.read(from: fileWrapper, ofType: typeName)
    }

    let bundle = try TextBundleWrapper(fileWrapper: fileWrapper)
    MainActor.assumeIsolated {
      textBundle = bundle
    }
    try read(from: bundle.data, ofType: typeName)
  }

  override func write(to url: URL, ofType typeName: String) throws {
    guard typeName.isTextBundle else {
      return try super.write(to: url, ofType: typeName)
    }

    try MainActor.assumeIsolated {
      let fileWrapper = try textBundle?.fileWrapper(with: data(ofType: typeName))
      try fileWrapper?.write(to: url, originalContentsURL: nil)
    }
  }

  override func duplicate() throws -> NSDocument {
    guard textBundle != nil, let fileURL else {
      return try super.duplicate()
    }

    return try NSDocumentController.shared.duplicateDocument(
      withContentsOf: fileURL,
      copying: true,
      displayName: fileURL.deletingPathExtension().lastPathComponent
    )
  }
}

// MARK: - Printing

extension EditorDocument {
  @IBAction override func printDocument(_ sender: Any?) {
    guard let window = hostViewController?.view.window else {
      return
    }

    // Ideally we should be able to print WKWebView,
    // but it doesn't work well because of the lazily rendering strategy used in CodeMirror.
    //
    // For now let's just print plain text,
    // we don't expect printing to be used a lot.

    Task { @MainActor in
      // Alignment
      printInfo.isHorizontallyCentered = true
      printInfo.isVerticallyCentered = false

      // Sizing
      let width = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
      let height = printInfo.paperSize.height - printInfo.topMargin - printInfo.bottomMargin
      let frame = CGRect(x: 0, y: 0, width: width, height: height)

      // Rendering
      let textView = NSTextView(frame: frame)
      textView.string = await hostViewController?.editorText ?? stringValue
      textView.sizeToFit()

      let operation = NSPrintOperation(view: textView)
      operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
  }
}

// MARK: - Private

private extension EditorDocument {
  var bridge: WebModuleBridge? {
    hostViewController?.bridge
  }

  var closeAlwaysConfirmsChanges: Bool {
    UserDefaults.standard.bool(forKey: NSCloseAlwaysConfirmsChanges)
  }

  var needsFormatting: Bool {
    guard !formatCompleted else {
      return false
    }

    return AppPreferences.Assistant.insertFinalNewline || AppPreferences.Assistant.trimTrailingWhitespace
  }

  func saveScriptCommand(_ command: NSScriptCommand, destination: (URL, String)? = nil) -> Any? {
    command.suspendExecution()
    enqueueSave(userInitiated: true, saveAs: false, destination: destination) { saved in
      if !saved {
        command.scriptErrorNumber = NSInternalScriptError
        command.scriptErrorString = CocoaError(.fileWriteUnknown).localizedDescription
      }
      command.resumeExecution(withResult: nil)
    }
    return nil
  }

  func enqueueSave(userInitiated: Bool, saveAs: Bool, destination: (URL, String)? = nil, completion: ((Bool) -> Void)? = nil) {
    // Serialize editor synchronization and save panels as well as the write itself.
    let previousSave = saveTask
    saveTask = Task { @MainActor in
      _ = await previousSave?.value
      let saved = await performSave(userInitiated: userInitiated, saveAs: saveAs, destination: destination)
      completion?(saved)
      return saved
    }
  }

  func performSave(userInitiated: Bool, saveAs: Bool, destination: (URL, String)? = nil) async -> Bool {
    let wasEdited = isOutdated || isDocumentEdited || hasUnautosavedChanges
    do {
      if isOutdated || (userInitiated && needsFormatting && hostViewController?.hasFinishedLoading == true) {
        try await refreshContent(userInitiated: userInitiated)
      }
      let savedText = stringValue
      let savedRevision = hostViewController?.editorTextRevision
      let didSave: Bool
      if let (url, typeName) = destination {
        try await super.save(to: url, ofType: typeName, for: .saveOperation)
        didSave = true
      } else {
        didSave = await withCheckedContinuation { continuation in
          let callback = DocumentSaveCompletion { continuation.resume(returning: $0) }
          pendingSaveCompletion = callback
          if saveAs {
            super.runModalSavePanel(
              for: .saveAsOperation,
              delegate: callback,
              didSave: #selector(DocumentSaveCompletion.document(_:didSave:contextInfo:)),
              contextInfo: nil
            )
          } else {
            super.save(withDelegate: callback, didSave: #selector(DocumentSaveCompletion.document(_:didSave:contextInfo:)), contextInfo: nil)
          }
        }
      }
      pendingSaveCompletion = nil
      guard didSave else {
        if wasEdited || isOutdated || hostViewController?.editorTextRevision != savedRevision {
          markContentDirty(true)
        }
        return false
      }
      if let fileURL {
        ActivityHistoryStore.shared.record(.saved, url: fileURL)
      }
      return await finishSaving(text: savedText, revision: savedRevision)
    } catch {
      if wasEdited || isOutdated {
        markContentDirty(true)
      }
      presentError(error)
      return false
    }
  }

  func refreshContent(userInitiated: Bool = false) async throws {
    guard let hostViewController, hostViewController.hasFinishedLoading else {
      if isOutdated {
        markContentDirty(true)
        throw CocoaError(.fileReadUnknown)
      }
      return // A model-only document already has its synchronously decoded text.
    }
    defer { unblockUserInteraction() }
    do {
      let insertFinalNewline = AppPreferences.Assistant.insertFinalNewline
      let trimTrailingWhitespace = AppPreferences.Assistant.trimTrailingWhitespace
      if insertFinalNewline || trimTrailingWhitespace {
        let formatted = try await editorScript("""
          return String(webModules.format.formatContent({insertFinalNewline, trimTrailingWhitespace, userInitiated}));
          """, arguments: [
            "insertFinalNewline": insertFinalNewline,
            "trimTrailingWhitespace": trimTrailingWhitespace,
            "userInitiated": userInitiated,
          ])
        formatCompleted = formatted == "true"
      }
      let revision = hostViewController.editorTextRevision
      let snapshot = try await editorScript("""
        return JSON.stringify({text: webModules.core.getEditorText(), title: needsTitle ? webModules.toc.getTableOfContents()[0]?.title : undefined});
        """, arguments: ["needsTitle": fileURL == nil])
      let content = try JSONDecoder().decode(DocumentEditorSnapshot.self, from: Data(snapshot.utf8))
      guard hostViewController.editorTextRevision == revision else {
        throw CocoaError(.fileReadUnknown)
      }
      stringValue = content.text
      let editorText = content.text
      DispatchQueue.global(qos: .utility).async {
        let fileData = editorText.toData() ?? Data()
        let directory = AppCustomization.debugDirectory.fileURL
        try? fileData.write(to: directory.appending(path: "last-edited.md"))
      }
      suggestedFilename = fileURL == nil ? content.title : nil
      isOutdated = false
    } catch {
      isOutdated = true
      markContentDirty(true)
      throw error
    }
  }

  func finishSaving(text: String, revision: UInt64?) async -> Bool {
    guard !isOutdated, hostViewController?.editorTextRevision == revision else {
      markContentDirty(true)
      return false
    }
    guard hostViewController?.hasFinishedLoading == true else {
      return true
    }
    // Compare and mark in one JavaScript task. A native revision check alone can
    // miss an edit whose WebKit message is still queued on the main thread.
    let result = try? await editorScript("""
      if (webModules.core.getEditorText() !== savedText) return "changed";
      webModules.history.markContentClean();
      return "clean";
      """, arguments: ["savedText": text])
    guard result == "clean", hostViewController?.editorTextRevision == revision, !isOutdated else {
      isOutdated = true
      markContentDirty(true)
      return false
    }
    return true
  }

  func editorScript(_ script: String, arguments: [String: Any] = [:]) async throws -> String {
    guard let hostViewController, hostViewController.hasFinishedLoading else {
      throw CocoaError(.fileReadUnknown)
    }
    return try await withCheckedThrowingContinuation { continuation in
      let result = DocumentEditorResult(continuation)
      // Do not race a non-cancellable WebKit task in a task group: the group
      // would still wait for the hung renderer. The gate ignores late callbacks.
      DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        result.finish(.failure(CocoaError(.fileReadUnknown)))
      }
      hostViewController.webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { value in
        result.finish(value.flatMap { value in
          guard let text = value as? String else {
            return .failure(CocoaError(.fileReadUnknown))
          }
          return .success(text)
        })
      }
    }
  }

  func cancelTermination() {
    isTerminating = false
    NSDocumentController.shared.editorDocuments.forEach { $0.isTerminating = false }
  }

  func notifyDocumentDelegate(_ delegate: Any?, selector: Selector?, result: Bool, contextInfo: UnsafeMutableRawPointer?) {
    guard let delegate = delegate as? NSObject, let selector, delegate.responds(to: selector),
          let implementation = delegate.method(for: selector) else {
      return
    }
    typealias Callback = @convention(c) (AnyObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
    let callback = unsafeBitCast(implementation, to: Callback.self)
    callback(delegate, selector, self, result, contextInfo)
  }
}

private struct DocumentEditorSnapshot: Decodable {
  let text: String
  let title: String?
}

@MainActor
private final class DocumentSaveCompletion: NSObject {
  private var completion: ((Bool) -> Void)?

  init(_ completion: @escaping (Bool) -> Void) {
    self.completion = completion
  }

  @objc func document(_ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
    let callback = completion
    completion = nil
    callback?(didSave)
  }
}

@MainActor
private final class DocumentEditorResult {
  private var continuation: CheckedContinuation<String, Error>?

  init(_ continuation: CheckedContinuation<String, Error>) {
    self.continuation = continuation
  }

  func finish(_ result: Result<String, Error>) {
    let pending = continuation
    continuation = nil
    pending?.resume(with: result)
  }
}
