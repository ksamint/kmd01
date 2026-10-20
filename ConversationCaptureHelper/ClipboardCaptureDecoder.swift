import AppKit

struct ClipboardCaptureSnapshot: Sendable {
  let plainText: String?
  let html: Data?
  let rtf: Data?
  let fileURLs: [URL]
}

struct DecodedClipboardCapture: Sendable {
  let content: String
  let fileURLs: [URL]
}

/// Converts pasteboard representations without rendering HTML or following resource URLs.
/// Keeping this pure is important: background clipboard capture must never reach into the
/// source application's sandbox merely to obtain a textual history entry.
enum ClipboardCaptureDecoder {
  static func decode(_ snapshot: ClipboardCaptureSnapshot) -> DecodedClipboardCapture? {
    let content = nonempty(snapshot.plainText)
      ?? snapshot.rtf.flatMap(rtfText)
      ?? snapshot.html.flatMap(htmlText)
    guard let content else { return nil }
    return DecodedClipboardCapture(
      content: content,
      fileURLs: snapshot.fileURLs.filter(isEligibleFileURL)
    )
  }

  static func isEligibleFileURL(_ url: URL) -> Bool {
    guard url.isFileURL else { return false }
    let path = url.standardizedFileURL.path
    guard !path.isEmpty else { return false }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let protectedRoots = [
      home.appending(path: "Library/Containers", directoryHint: .isDirectory).path,
      home.appending(path: "Library/Group Containers", directoryHint: .isDirectory).path,
      home.appending(path: "Library/Application Scripts", directoryHint: .isDirectory).path,
    ]
    return !protectedRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  private static func rtfText(_ data: Data) -> String? {
    guard let value = try? NSAttributedString(
      data: data,
      options: [.documentType: NSAttributedString.DocumentType.rtf],
      documentAttributes: nil
    ).string else { return nil }
    return nonempty(value)
  }

  /// Deliberately uses text transforms rather than AppKit's HTML attributed-string importer.
  /// The attributed-string importer can create WebKit processes and resolve local resources.
  private static func htmlText(_ data: Data) -> String? {
    guard let source = String(bytes: data, encoding: .utf8)
      ?? String(bytes: data, encoding: .utf16) else { return nil }
    var value = replacing(
      #"<(script|style|noscript|template|iframe|object|embed)\b[^>]*>[\s\S]*?(?:</\1\s*>|$)"#,
      in: source,
      with: ""
    )
    value = replacing(
      #"<\s*(?:br\s*/?|/\s*(?:p|div|li|tr|h[1-6]|blockquote|pre|section|article|header|footer))\s*>"#,
      in: value,
      with: "\n"
    )
    value = replacing(#"<[^>]*>"#, in: value, with: "")
    value = decodeHTMLEntities(value)
    let lines = value
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return nonempty(lines.joined(separator: "\n"))
  }

  private static func replacing(
    _ pattern: String,
    in value: String,
    with replacement: String
  ) -> String {
    guard let expression = try? NSRegularExpression(
      pattern: pattern,
      options: [.caseInsensitive]
    ) else { return value }
    let range = NSRange(value.startIndex ..< value.endIndex, in: value)
    return expression.stringByReplacingMatches(
      in: value,
      options: [],
      range: range,
      withTemplate: replacement
    )
  }

  private static func decodeHTMLEntities(_ value: String) -> String {
    guard let expression = try? NSRegularExpression(
      pattern: #"&(?:#([0-9]+)|#x([0-9a-f]+)|(amp|lt|gt|quot|apos|nbsp));"#,
      options: [.caseInsensitive]
    ) else { return value }
    var result = value
    let range = NSRange(value.startIndex ..< value.endIndex, in: value)
    for match in expression.matches(in: value, options: [], range: range).reversed() {
      guard let matchRange = Range(match.range, in: result) else { continue }
      let replacement: String?
      if let decimalRange = Range(match.range(at: 1), in: value) {
        replacement = UInt32(value[decimalRange]).flatMap(UnicodeScalar.init).map(String.init)
      } else if let hexadecimalRange = Range(match.range(at: 2), in: value) {
        replacement = UInt32(value[hexadecimalRange], radix: 16)
          .flatMap(UnicodeScalar.init)
          .map(String.init)
      } else if let nameRange = Range(match.range(at: 3), in: value) {
        replacement = [
          "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        ][value[nameRange].lowercased()]
      } else {
        replacement = nil
      }
      if let replacement { result.replaceSubrange(matchRange, with: replacement) }
    }
    return result
  }
}
