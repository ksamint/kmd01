import AppKit
import Foundation

private enum ClipboardCaptureDecoderTestError: Error {
  case failed(String)
}

@main
private enum ClipboardCaptureDecoderTestMain {
  static func main() throws {
    let privateResourceHTML = Data(
      """
      <html><body>
      <p>HTML fallback</p>
      <img src="file:///Users/example/Library/Containers/com.example.private/Data/image.png">
      <script>privateSideEffect()</script>
      </body></html>
      """.utf8
    )
    let preferredPlainText = "原样文本 日本語 français"
    let plain = try unwrap(
      ClipboardCaptureDecoder.decode(
        ClipboardCaptureSnapshot(
          plainText: preferredPlainText,
          html: privateResourceHTML,
          rtf: nil,
          fileURLs: []
        )
      ),
      "decodes a plain-text clipboard snapshot"
    )
    try expect(plain.content == preferredPlainText, "prefers exact plain text over rendering HTML")
    try expect(plain.fileURLs.isEmpty, "does not turn HTML resource references into file captures")

    let htmlOnly = try unwrap(
      ClipboardCaptureDecoder.decode(
        ClipboardCaptureSnapshot(
          plainText: nil,
          html: Data("<p>Bonjour &amp; 你好</p><p>日本語</p><script>secret()</script>".utf8),
          rtf: nil,
          fileURLs: []
        )
      ),
      "decodes HTML without a plain-text representation"
    )
    try expect(htmlOnly.content == "Bonjour & 你好\n日本語", "extracts multilingual HTML text offline")
    try expect(!htmlOnly.content.contains("secret"), "drops script contents")

    let home = FileManager.default.homeDirectoryForCurrentUser
    let privateContainer = home.appending(
      path: "Library/Containers/com.example.private/Data/private.md"
    )
    let sharedContainer = home.appending(
      path: "Library/Group Containers/group.example.private/private.md"
    )
    let userDocument = home.appending(path: "Documents/notes.md")
    let remoteURL = URL(string: "https://example.com/notes.md")!
    try expect(
      !ClipboardCaptureDecoder.isEligibleFileURL(privateContainer),
      "rejects another app's private container"
    )
    try expect(
      !ClipboardCaptureDecoder.isEligibleFileURL(sharedContainer),
      "rejects another app's shared container"
    )
    try expect(
      ClipboardCaptureDecoder.isEligibleFileURL(userDocument),
      "accepts an explicitly copied user file"
    )
    try expect(
      !ClipboardCaptureDecoder.isEligibleFileURL(remoteURL),
      "does not create file bookmarks for web URLs"
    )

    print("Clipboard capture decoder tests passed.")
  }

  private static func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
  ) throws {
    if !condition() { throw ClipboardCaptureDecoderTestError.failed(message) }
  }

  private static func unwrap<Value>(_ value: Value?, _ message: String) throws -> Value {
    guard let value else { throw ClipboardCaptureDecoderTestError.failed(message) }
    return value
  }
}
