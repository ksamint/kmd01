import AppKit
import WebKit

// Only framework/bridge doubles live here. The driver inserts the production
// transaction, refresh, callbacks, serialization and Save All/quit aggregation.
#if !SDK_CHECK
@MainActor
private class NSDocument: NSObject {
  enum SaveOperationType { case saveOperation, saveAsOperation, autosaveAsOperation }
  enum ChangeType { case changeDone, changeCleared }

  var fileURL: URL? = URL(fileURLWithPath: "/not-written/test.md")
  var fileType: String? = "public.plain-text"
  var fileModificationDate: Date?
  var isDocumentEdited = true
  var hasUnautosavedChanges = true
  var saveDelay = 0.02
  var saveSucceeds = true
  var written: String?
  var saveRequests = 0
  var activeDestinationWrites = 0
  var maximumDestinationWrites = 0
  var destinations: [URL] = []
  var beforeWrite: (() -> Void)?
  var afterWrite: (() -> Void)?
  var closeRequests = 0
  var nativeCloseResult = true
  var errors = 0

  func save(_ sender: Any?) {}
  func saveAs(_ sender: Any?) {}
  func save(withDelegate delegate: Any?, didSave selector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
    completeSave(delegate: delegate, contextInfo: contextInfo)
  }
  private func completeSave(delegate: Any?, contextInfo: UnsafeMutableRawPointer?) {
    saveRequests += 1
    DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay) {
      self.beforeWrite?()
      var saved = self.saveSucceeds
      if saved {
        do {
          self.written = String(data: try self.data(ofType: "public.plain-text"), encoding: .utf8)
          self.isDocumentEdited = false
          self.hasUnautosavedChanges = false
          self.fileURL = self.fileURL ?? URL(fileURLWithPath: "/not-written/draft.md")
          self.afterWrite?()
        } catch {
          saved = false
        }
      }
      (delegate as? DocumentSaveCompletion)?.document(self, didSave: saved, contextInfo: contextInfo)
    }
  }
  func runModalSavePanel(for operation: SaveOperationType, delegate: Any?, didSave selector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
    // Call the base implementation, as AppKit's panel eventually performs a write.
    completeSave(delegate: delegate, contextInfo: contextInfo)
  }
  func save(to url: URL, ofType: String, for operation: SaveOperationType) async throws {
    activeDestinationWrites += 1
    maximumDestinationWrites = max(maximumDestinationWrites, activeDestinationWrites)
    defer { activeDestinationWrites -= 1 }
    try await Task.sleep(for: .milliseconds(30))
    if !saveSucceeds { throw CocoaError(.fileWriteUnknown) }
    written = String(data: try data(ofType: ofType), encoding: .utf8)
    destinations.append(url)
    isDocumentEdited = false
    hasUnautosavedChanges = false
    fileURL = url
  }
  func canClose(withDelegate delegate: Any, shouldClose selector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
    closeRequests += 1
    (delegate as? DocumentSaveCompletion)?.document(self, didSave: nativeCloseResult, contextInfo: contextInfo)
  }
  func autosave(withImplicitCancellability: Bool) async throws {
    if !saveSucceeds { throw CocoaError(.fileWriteUnknown) }
    written = String(data: try data(ofType: "public.plain-text"), encoding: .utf8)
  }
  func writeSafely(to: URL, ofType: String, for operation: SaveOperationType) throws {
    if !saveSucceeds { throw CocoaError(.fileWriteUnknown) }
    written = String(data: try data(ofType: ofType), encoding: .utf8)
  }
  func data(ofType: String) throws -> Data { Data() }
  @discardableResult
  func presentError(_ error: Error) -> Bool { errors += 1; return false }
  func updateChangeCount(_ change: ChangeType) {
    isDocumentEdited = change == .changeDone
    hasUnautosavedChanges = isDocumentEdited
  }
  func unblockUserInteraction() {}
}

@MainActor
private final class NSScriptCommand {
  var scriptErrorNumber = 0
  var scriptErrorString: String?
  var didSuspend = false
  var resumeCount = 0

  func suspendExecution() { didSuspend = true }
  func resumeExecution(withResult: Any?) { resumeCount += 1 }
}
#endif

@MainActor
private final class EditorDouble {
  var editorTextRevision: UInt64 = 1
  var hasFinishedLoading = true

  #if SDK_CHECK
  let webView: WKWebView = WKWebView()
  #else
  let webView = WebViewDouble()
  #endif
}

#if !SDK_CHECK
@MainActor
private final class WebViewDouble {
  var text = "latest editor text\n"
  var missingSnapshot = false
  var neverReplies = false
  var cleanCount = 0
  var callbackDelay = 0.001
  var afterSnapshot: (() -> Void)?
  var beforeClean: (() -> Void)?
  var lateReply: (() -> Void)?

  func callAsyncJavaScript(
    _ script: String,
    arguments: [String: Any],
    in frame: WKFrameInfo?,
    in world: WKContentWorld,
    completionHandler: @escaping @MainActor (Result<Any, Error>) -> Void
  ) {
    let result: String
    if script.contains("formatContent") {
      result = "true"
    } else if script.contains("JSON.stringify") {
      guard let data = try? JSONSerialization.data(withJSONObject: ["text": text]),
            let snapshot = String(data: data, encoding: .utf8) else {
        preconditionFailure("Invalid test text")
      }
      result = missingSnapshot ? "{}" : snapshot
      afterSnapshot?()
    } else {
      beforeClean?()
      if text == arguments["savedText"] as? String {
        cleanCount += 1
        result = "clean"
      } else {
        result = "changed"
      }
    }
    let reply = { completionHandler(.success(result)) }
    if neverReplies {
      lateReply = reply
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + callbackDelay) { completionHandler(.success(result)) }
    }
  }
}
#endif

private enum AppCustomization {
  struct DebugDirectory: Sendable {
    var fileURL: URL { URL(fileURLWithPath: "/dev/null") }
  }

  static let debugDirectory = DebugDirectory()
}

private struct TestEncoding {
  func encode(string: String) -> Data? { Data(string.utf8) }
}
@MainActor
private enum AppPreferences {
  enum General { static let defaultTextEncoding = TestEncoding() }
  @MainActor
  enum Assistant {
    static var insertFinalNewline = false
    static var trimTrailingWhitespace = false
  }
}
@MainActor
private final class ActivityHistoryStore {
  enum Kind { case saved }

  static let shared = ActivityHistoryStore()
  var saves = 0

  func record(_ kind: Kind, url: URL) { saves += 1 }
}
private enum Logger {
  enum Level { case error }
  static func log(_ level: Level, _ message: String) {}
}
private extension String { func toData() -> Data? { Data(utf8) } }

@MainActor
private final class EditorDocument: NSDocument {
  var stringValue = "stale model text"
  var isOutdated = true
  var formatCompleted = false
  var shouldSaveWhenIdle = true
  var closeAlwaysConfirmsChanges = false
  var isTerminating = false
  var hasBeenReverted = false
  var needsFormatting = false
  var hostViewController: EditorDouble? = EditorDouble()
  var editor: EditorDouble {
    guard let hostViewController else { preconditionFailure("Missing test editor") }
    return hostViewController
  }

  var suggestedFilename: String?
  var suggestedTextEncoding: TestEncoding?
  private var saveTask: Task<Bool, Never>?
  private var pendingSaveCompletion: DocumentSaveCompletion?
  private var pendingCloseCompletions: [UUID: DocumentSaveCompletion] = [:]

  func markContentDirty(_ dirty: Bool) { updateChangeCount(dirty ? .changeDone : .changeCleared) }
  // DOCUMENT_METHODS
}

// RESULT_HELPERS

@MainActor
private final class NSDocumentController {
  static let shared = NSDocumentController()

  var editorDocuments: [EditorDocument] = []
  var outdatedDocuments: [EditorDocument] {
    editorDocuments.filter { $0.isOutdated || $0.isDocumentEdited || $0.hasUnautosavedChanges }
  }
  var hasOutdatedDocuments: Bool { !outdatedDocuments.isEmpty }
  // CONTROLLER_SAVE
}

@MainActor
private enum AppRuntimeConfig {
  static let autoSaveWhenIdle = true
}

@MainActor
private final class AppDelegate {
  // TERMINATION_METHOD
}

#if !SDK_CHECK
@MainActor
private final class NSApplication {
  enum TerminateReply { case terminateLater, terminateNow }

  var shouldTerminate: Bool?

  func reply(toApplicationShouldTerminate value: Bool) {
    shouldTerminate = value
  }
}

@MainActor
private final class CloseRecorder: NSObject {
  var result: Bool?
  var context: UnsafeMutableRawPointer?

  @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
    result = shouldClose
    context = contextInfo
  }
}

@main
private enum DocumentSavingTestMain {
  @MainActor
  static func main() async throws {
    // A write taking longer than the former 600 ms delay must still be awaited.
    let slow = EditorDocument()
    slow.saveDelay = 0.85
    let start = Date()
    let saved = await slow.waitUntilSaveCompleted(userInitiated: true)
    precondition(saved && Date().timeIntervalSince(start) >= 0.8)
    precondition(slow.written == "latest editor text\n")
    precondition(slow.editor.webView.cleanCount == 1)

    let failed = EditorDocument()
    failed.saveSucceeds = false
    let didFail = await failed.waitUntilSaveCompleted()
    precondition(!didFail && failed.isDocumentEdited)
    precondition(failed.editor.webView.cleanCount == 0)

    let draft = EditorDocument()
    draft.fileURL = nil
    let draftSaved = await draft.waitUntilSaveCompleted(userInitiated: true)
    precondition(draftSaved && draft.written == "latest editor text\n" && draft.fileURL != nil)

    let saveAs = EditorDocument()
    let saveAsSucceeded = await withCheckedContinuation { continuation in
      saveAs.enqueueSave(userInitiated: true, saveAs: true) { continuation.resume(returning: $0) }
    }
    precondition(saveAsSucceeded && saveAs.written == "latest editor text\n")
    let cancelledPanel = EditorDocument()
    cancelledPanel.saveSucceeds = false
    let panelSaved = await withCheckedContinuation { continuation in
      cancelledPanel.enqueueSave(userInitiated: true, saveAs: true) { continuation.resume(returning: $0) }
    }
    precondition(!panelSaved && cancelledPanel.isDocumentEdited && cancelledPanel.written == nil)

    let cleanCancel = EditorDocument()
    cleanCancel.isOutdated = false
    cleanCancel.isDocumentEdited = false
    cleanCancel.hasUnautosavedChanges = false
    cleanCancel.saveSucceeds = false
    let cleanPanelSaved = await withCheckedContinuation { continuation in
      cleanCancel.enqueueSave(userInitiated: true, saveAs: true) { continuation.resume(returning: $0) }
    }
    precondition(!cleanPanelSaved && !cleanCancel.isDocumentEdited && !cleanCancel.hasUnautosavedChanges)

    let delegateSave = EditorDocument()
    let saveRecorder = CloseRecorder()
    delegateSave.save(withDelegate: saveRecorder, didSave: #selector(CloseRecorder.document(_:shouldClose:contextInfo:)), contextInfo: nil)
    try await Task.sleep(for: .milliseconds(80))
    precondition(saveRecorder.result == true && delegateSave.written == "latest editor text\n")

    let missing = EditorDocument()
    missing.editor.webView.missingSnapshot = true
    let missingSaved = await missing.waitUntilSaveCompleted()
    precondition(!missingSaved && missing.isOutdated && missing.isDocumentEdited)
    precondition(missing.saveRequests == 0 && missing.written == nil)

    let editedWhileWriting = EditorDocument()
    editedWhileWriting.afterWrite = {
      editedWhileWriting.editor.webView.text = "newer edit"
      editedWhileWriting.editor.editorTextRevision += 1
      editedWhileWriting.isOutdated = true
    }
    let editedSaved = await editedWhileWriting.waitUntilSaveCompleted()
    precondition(!editedSaved && editedWhileWriting.isDocumentEdited)
    precondition(editedWhileWriting.editor.webView.cleanCount == 0)

    let queuedEdit = EditorDocument()
    queuedEdit.editor.webView.beforeClean = {
      queuedEdit.editor.webView.text = "queued native notification edit"
    }
    let queuedSaved = await queuedEdit.waitUntilSaveCompleted()
    precondition(!queuedSaved && queuedEdit.isOutdated && queuedEdit.isDocumentEdited)
    precondition(queuedEdit.editor.webView.cleanCount == 0)

    let racedRead = EditorDocument()
    racedRead.editor.webView.afterSnapshot = {
      racedRead.editor.editorTextRevision += 1
    }
    let racedSaved = await racedRead.waitUntilSaveCompleted()
    precondition(!racedSaved && racedRead.isOutdated && racedRead.saveRequests == 0)

    let close = CloseRecorder()
    let context = UnsafeMutableRawPointer(bitPattern: 1234)
    missing.canClose(withDelegate: close, shouldClose: #selector(CloseRecorder.document(_:shouldClose:contextInfo:)), contextInfo: context)
    try await Task.sleep(for: .milliseconds(30))
    precondition(close.result == false && close.context == context && missing.closeRequests == 0)

    let failedClose = EditorDocument()
    failedClose.saveSucceeds = false
    let failedCloseRecorder = CloseRecorder()
    failedClose.canClose(withDelegate: failedCloseRecorder, shouldClose: #selector(CloseRecorder.document(_:shouldClose:contextInfo:)), contextInfo: context)
    try await Task.sleep(for: .milliseconds(80))
    precondition(failedCloseRecorder.result == false && failedClose.closeRequests == 0 && failedClose.isDocumentEdited)

    let nativeCancel = EditorDocument()
    nativeCancel.isOutdated = false
    nativeCancel.closeAlwaysConfirmsChanges = true
    nativeCancel.shouldSaveWhenIdle = false
    nativeCancel.nativeCloseResult = false
    nativeCancel.isTerminating = true
    let nativeClose = CloseRecorder()
    nativeCancel.canClose(withDelegate: nativeClose, shouldClose: #selector(CloseRecorder.document(_:shouldClose:contextInfo:)), contextInfo: context)
    try await Task.sleep(for: .milliseconds(30))
    precondition(nativeClose.result == false && nativeClose.context == context && !nativeCancel.isTerminating)

    let nativeDiscard = EditorDocument()
    nativeDiscard.fileURL = nil
    nativeDiscard.isOutdated = false
    let discard = CloseRecorder()
    nativeDiscard.canClose(withDelegate: discard, shouldClose: #selector(CloseRecorder.document(_:shouldClose:contextInfo:)), contextInfo: context)
    try await Task.sleep(for: .milliseconds(30))
    precondition(discard.result == true && discard.context == context && nativeDiscard.saveRequests == 0)

    let script = NSScriptCommand()
    let scripted = EditorDocument()
    let destination = URL(fileURLWithPath: "/not-written/script.txt")
    _ = scripted.saveScriptCommand(script, destination: (destination, "public.plain-text"))
    precondition(script.didSuspend && script.resumeCount == 0)
    try await Task.sleep(for: .milliseconds(100))
    precondition(script.resumeCount == 1 && script.scriptErrorNumber == 0)
    precondition(scripted.written == "latest editor text\n" && scripted.fileURL == destination)

    let failedScript = NSScriptCommand()
    let scriptFailure = EditorDocument()
    scriptFailure.saveSucceeds = false
    _ = scriptFailure.saveScriptCommand(failedScript, destination: (destination, "public.plain-text"))
    try await Task.sleep(for: .milliseconds(100))
    precondition(failedScript.didSuspend && failedScript.resumeCount == 1 && failedScript.scriptErrorNumber != 0)
    precondition(scriptFailure.written == nil && scriptFailure.isDocumentEdited)

    let serial = EditorDocument()
    let firstDestination = destination.appendingPathExtension("first")
    var firstResult: Bool?
    serial.enqueueSave(userInitiated: true, saveAs: false, destination: (firstDestination, "public.plain-text")) { firstResult = $0 }
    let secondResult = await withCheckedContinuation { continuation in
      serial.enqueueSave(userInitiated: true, saveAs: false, destination: (destination, "public.plain-text")) {
        continuation.resume(returning: $0)
      }
    }
    precondition(firstResult == true && secondResult && serial.maximumDestinationWrites == 1)
    precondition(serial.destinations == [firstDestination, destination])

    let controller = NSDocumentController()
    controller.editorDocuments = [failed]
    let quit = await controller.saveOutdatedDocuments()
    precondition(!quit && failed.isDocumentEdited)
    NSDocumentController.shared.editorDocuments = [failed]
    failed.isTerminating = true
    let application = NSApplication()
    let appDelegate = AppDelegate()
    precondition(appDelegate.applicationShouldTerminate(application) == .terminateLater)
    try await Task.sleep(for: .milliseconds(80))
    precondition(application.shouldTerminate == false && !failed.isTerminating)

    failed.saveSucceeds = true
    let retried = await controller.saveOutdatedDocuments()
    precondition(retried && !failed.isDocumentEdited)

    let autosave = EditorDocument()
    autosave.editor.webView.missingSnapshot = true
    do {
      try await autosave.autosave(withImplicitCancellability: false)
      preconditionFailure("Failed refresh must fail autosave")
    } catch { precondition(autosave.written == nil && autosave.isOutdated) }

    let bypass = EditorDocument()
    do {
      _ = try bypass.data(ofType: "public.plain-text")
      preconditionFailure("A direct write must reject stale data")
    } catch { precondition(bypass.isOutdated) }

    let hung = EditorDocument()
    hung.editor.webView.neverReplies = true
    let timeoutStart = Date()
    let hungSaved = await hung.waitUntilSaveCompleted()
    precondition(!hungSaved && Date().timeIntervalSince(timeoutStart) < 6)
    precondition(hung.isOutdated && hung.written == nil)
    hung.editor.webView.lateReply?()
    precondition(hung.isOutdated && hung.written == nil, "Late callbacks must not commit an expired snapshot")
    print("Document saving: delayed completion, failed/cancelled writes, missing/stale snapshots, revision races, close/quit refusal, autosave and timeout regressions passed.")
  }
}
#endif
