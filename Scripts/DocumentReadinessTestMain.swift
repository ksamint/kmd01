import Foundation

// The driver inserts the production read, serialization and Save All methods.
// Framework doubles keep this regression independent of windows and Automation.
private struct TestEncoding: Sendable {
  let delay: TimeInterval

  func decode(data: Data, guessEncoding: Bool = false) -> String {
    Thread.sleep(forTimeInterval: delay)
    return String(data: data, encoding: .utf8) ?? ""
  }

  func encode(string: String) -> Data? { Data(string.utf8) }
}

@MainActor
private enum AppPreferences {
  enum General {
    static let defaultTextEncoding = TestEncoding(delay: 0.08)
  }
}

@MainActor
private class DocumentDouble {
  var lastSavedData: Data?

  func read(from data: Data, ofType typeName: String) throws {}
  func data(ofType typeName: String) throws -> Data { Data() }
  func save(_ sender: Any?) {
    do {
      lastSavedData = try data(ofType: "public.plain-text")
    } catch {
      preconditionFailure("Unexpected serialization failure: \(error)")
    }
  }
}

@MainActor
private final class EditorDouble {
  var representedObject: Any?
}

@MainActor
private final class EditorDocument: DocumentDouble {
  var fileData: Data?
  var stringValue = ""
  var suggestedTextEncoding: TestEncoding?
  var hostViewController: EditorDouble?
  // DOCUMENT_READ
  // DOCUMENT_DATA
}

@MainActor
private class ControllerDouble {
  var documents = [DocumentDouble]()

  func saveAllDocuments(_ sender: Any?) {}
}

@MainActor
private final class AppDocumentController: ControllerDouble {
  static var suggestedTextEncoding: TestEncoding?
  // SAVE_ALL
}

private extension String {
  func toData() -> Data? { Data(utf8) }
}

@main
private enum DocumentReadinessTestMain {
  @MainActor
  static func main() throws {
    let controller = AppDocumentController()
    let document = EditorDocument()
    let editor = EditorDouble()
    document.hostViewController = editor
    controller.documents = [document]

    // The delayed decoder must finish before AppKit receives a loaded document.
    // There is deliberately no run-loop turn or sleep between read and Save All.
    let first = Data("Original note: 中文 café\n".utf8)
    try document.read(from: first, ofType: "public.plain-text")
    controller.saveAllDocuments(nil)
    precondition(document.lastSavedData == first, "Immediate Save All lost the initial read")
    precondition(document.fileData == first)
    precondition(editor.representedObject as? EditorDocument === document)

    // A later read (such as Revert) must replace old text before it can be saved.
    AppDocumentController.suggestedTextEncoding = TestEncoding(delay: 0.08)
    let replacement = Data("Replacement note\n".utf8)
    try document.read(from: replacement, ofType: "public.plain-text")
    controller.saveAllDocuments(nil)
    precondition(document.lastSavedData == replacement, "Save All serialized the previous read")
    precondition(document.fileData == replacement)

    let large = Data(String(repeating: "Large note: 中文 café\n", count: 12_000).utf8)
    precondition(large.count > 200_000)
    try document.read(from: large, ofType: "public.plain-text")
    controller.saveAllDocuments(nil)
    precondition(document.lastSavedData == large, "Save All truncated a large document")

    // Empty files are legitimate loaded documents, not failed/pending reads.
    try document.read(from: Data(), ofType: "public.plain-text")
    controller.saveAllDocuments(nil)
    precondition(document.fileData != nil && document.lastSavedData == Data())
    print("Document read completion and immediate Save All regression passed.")
  }
}
