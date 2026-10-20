import AppKit
import Security
import SharedUI
import UniformTypeIdentifiers

enum QuickActionKind: String, Codable {
  case preview
  case openEditor
  case conversationInbox
  case saveReference
  case addWorkspace
  case analyzeAgent
  case createMarkdown
  case convertMarkdown
  case convertDocx
}

struct QuickActionRequestV1: Codable {
  let version: Int
  let id: UUID
  let createdAt: Date
  let action: QuickActionKind
  let resourceBookmarks: [Data]
}

@MainActor
final class QuickActionCoordinator {
  static let shared = QuickActionCoordinator()
  private let conversion = FormatConversionService()
  private let documentExport = DatamergeDocumentExportService()

  func handle(id: UUID, appDelegate: AppDelegate) async {
    do {
      let requestURL = try pendingDirectory().appending(path: "\(id).json")
      let request = try JSONDecoder().decode(
        QuickActionRequestV1.self,
        from: Data(contentsOf: requestURL)
      )
      guard request.version == 1, request.id == id,
        (0 ..< 10 * 60).contains(Date().timeIntervalSince(request.createdAt))
      else {
        throw QuickActionError.invalidRequest
      }
      var urls: [URL] = []
      var releaseScopesOnReturn = true
      defer {
        if releaseScopesOnReturn {
          for url in urls { url.stopAccessingSecurityScopedResource() }
        }
        try? FileManager.default.removeItem(at: requestURL)
      }
      for bookmark in request.resourceBookmarks {
        urls.append(try WorkspaceBookmarkOperations.system.acquire(bookmark, scope: .transfer).url)
      }
      switch request.action {
      case .preview, .openEditor, .analyzeAgent:
        WorkspaceBookmarkOperations.system.retainForSession(urls, in: &appDelegate.activeResourceSecurityScopes)
        releaseScopesOnReturn = false
      default:
        break
      }
      DistributedNotificationCenter.default().post(
        name: WorkspaceBookmarkNotifications.quickActionReceived, object: id.uuidString
      )
      try await execute(request.action, urls: urls, appDelegate: appDelegate)
    } catch {
      let alert = NSAlert(error: error)
      alert.messageText = String(localized: "Quick Action Failed")
      alert.runModal()
    }
  }

  private func execute(_ action: QuickActionKind, urls: [URL], appDelegate: AppDelegate)
    async throws {
    switch action {
    case .preview:
      guard let first = urls.first else { throw QuickActionError.emptySelection }
      await appDelegate.openResourceURL(first, tabbingWindow: NSApp.keyWindow)
    case .openEditor:
      for url in urls where !url.hasDirectoryPath {
        _ = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: true)
      }
    case .conversationInbox:
      try ConversationCaptureCoordinator.shared.importConversationResources(urls)
    case .saveReference:
      try writeReference(for: urls)
    case .addWorkspace:
      try copyIntoWorkspace(urls)
    case .analyzeAgent:
      guard let first = urls.first else { throw QuickActionError.emptySelection }
      await appDelegate.openResourceURL(first, tabbingWindow: NSApp.keyWindow)
      if let editor = appDelegate.currentEditor {
        if !editor.agentPanelVisible { editor.toggleAgentPanel() }
      } else {
        throw QuickActionError.noEditorForAgent
      }
    case .createMarkdown:
      guard let selected = urls.first else { throw QuickActionError.emptySelection }
      var workspaceRootURL: URL?
      if !selected.hasDirectoryPath {
        workspaceRootURL = try? workspaceRoot()
      }
      defer { workspaceRootURL?.stopAccessingSecurityScopedResource() }
      let directory = selected.hasDirectoryPath ? selected : selected.deletingLastPathComponent()
      if !selected.hasDirectoryPath,
        workspaceRootURL.map({ !contains(directory, root: $0) }) != false {
        throw QuickActionError.selectFolderForCreation
      }
      let destination = uniqueURL(in: directory, name: "\(Localized.Workspace.untitledFile).md")
      try Data().write(to: destination, options: .atomic)
      NSWorkspace.shared.activateFileViewerSelecting([destination])
    case .convertMarkdown:
      let plan = try await conversion.plan(ConversionRequestV1(resources: urls))
      guard confirm(plan) else { return }
      _ = try await conversion.execute(plan) { progress in
        NotificationCenter.default.post(name: .conversionProgress, object: progress)
      }
    case .convertDocx:
      let markdownFiles = urls.filter {
        !$0.hasDirectoryPath && ["md", "markdown"].contains($0.pathExtension.lowercased())
      }
      guard !markdownFiles.isEmpty else { throw QuickActionError.unsupported }
      guard confirmDocumentExport() else { return }
      let workspaceRootURL = try? workspaceRoot()
      defer { workspaceRootURL?.stopAccessingSecurityScopedResource() }
      let allInsideWorkspace =
        workspaceRootURL.map { root in
          markdownFiles.allSatisfy { contains($0, root: root) }
        } ?? false
      let outputDirectory = allInsideWorkspace ? nil : chooseDocumentExportDirectory(markdownFiles)
      guard allInsideWorkspace || outputDirectory != nil else { return }
      let outputs = try await documentExport.convert(
        markdownFiles,
        outputDirectory: outputDirectory
      )
      NSWorkspace.shared.activateFileViewerSelecting(outputs)
    }
  }

  private func writeReference(for urls: [URL]) throws {
    let root = try workspaceRoot()
    defer { root.stopAccessingSecurityScopedResource() }
    let directory = root.appending(path: "References", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let title = urls.count == 1 ? urls[0].lastPathComponent : "Imported resources"
    let links = urls.map { "- [\($0.lastPathComponent)](\($0.path(percentEncoded: false)))" }
      .joined(separator: "\n")
    let content = """
      ---
      type: Reference
      generated: \(ISO8601DateFormatter().string(from: Date()))
      sources: \(urls.count)
      tags: [reference]
      ---

      # \(title)

      \(links)
      """
    try Data(content.utf8).write(
      to: uniqueURL(in: directory, name: "\(title).md"),
      options: .atomic
    )
  }

  private func copyIntoWorkspace(_ urls: [URL]) throws {
    let root = try workspaceRoot()
    defer { root.stopAccessingSecurityScopedResource() }
    for url in urls {
      let destination = uniqueURL(in: root, name: url.lastPathComponent)
      try FileManager.default.copyItem(at: url, to: destination)
    }
  }

  private func confirm(_ plan: ConversionPlanV1) -> Bool {
    let alert = NSAlert()
    alert.messageText = String(localized: "Convert to Markdown")
    alert.informativeText =
      plan.usesRemoteService
      ? String(
        localized:
          "The selected PDF or document image will be uploaded over TLS to the configured Tencent MinerU Precision VLM service. The source is deleted after submission and results expire after one hour."
      )
      : String(localized: "A new Markdown result will be created. Source files are not modified.")
    alert.addButton(withTitle: String(localized: "Convert"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    return alert.runModal() == .alertFirstButtonReturn
  }

  private func confirmDocumentExport() -> Bool {
    let alert = NSAlert()
    alert.messageText = String(localized: "Convert Markdown to DOCX")
    alert.informativeText = String(
      localized:
        "The selected Markdown will be sent over TLS to the Datamerge conversion service. DOCX files are saved next to the sources; the Markdown files are not modified."
    )
    alert.addButton(withTitle: String(localized: "Convert"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    return alert.runModal() == .alertFirstButtonReturn
  }

  private func chooseDocumentExportDirectory(_ sources: [URL]) -> URL? {
    let panel = NSOpenPanel()
    panel.title = String(localized: "Choose DOCX Output Folder")
    panel.prompt = String(localized: "Choose")
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = sources.first?.deletingLastPathComponent()
    return panel.runModal() == .OK ? panel.url : nil
  }

  private func contains(_ url: URL, root: URL) -> Bool {
    let path = url.standardizedFileURL.pathComponents
    let rootPath = root.standardizedFileURL.pathComponents
    return path.count >= rootPath.count && Array(path.prefix(rootPath.count)) == rootPath
  }

  private func workspaceRoot() throws -> URL {
    guard let bookmark = AppPreferences.General.workspaceFolderBookmark else {
      throw QuickActionError.noWorkspace
    }
    return try WorkspaceBookmarkOperations.system.acquire(bookmark, scope: .persistent).url
  }

  private func pendingDirectory() throws -> URL {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.art.apuch.ksamint-markedit"
      )
    else {
      throw CocoaError(.fileReadNoPermission)
    }
    return container.appending(path: "QuickActions/Pending", directoryHint: .isDirectory)
  }

  private func uniqueURL(in directory: URL, name: String) -> URL {
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var index = 1
    var candidate = directory.appending(path: name)
    while FileManager.default.fileExists(atPath: candidate.path) {
      index += 1
      candidate = directory.appending(
        path: ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
      )
    }
    return candidate
  }
}

/// Uses a least-privilege Datamerge standard key stored in this Mac's
/// Keychain. The administrator credential is used only once to provision that
/// key and is never embedded in, logged by, or returned to the application.
private actor DatamergeDocumentExportService {
  private static let endpoint = URL(string: "https://datame.opcglobal.cn/api/conversion/convert")!
  private static let maximumSourceBytes = 10 * 1024 * 1024

  func convert(_ sources: [URL], outputDirectory: URL?) async throws -> [URL] {
    var outputs: [URL] = []
    for source in sources {
      let data = try Data(contentsOf: source, options: .mappedIfSafe)
      guard !data.isEmpty, data.count <= Self.maximumSourceBytes,
        let markdown = String(data: data, encoding: .utf8)
      else {
        throw QuickActionError.fileLimit
      }
      let stem = (source.lastPathComponent as NSString).deletingPathExtension
      guard let apiKey = DatamergeConversionCredential.apiKey() else {
        throw QuickActionError.documentExportNotConfigured
      }
      var request = URLRequest(url: Self.endpoint)
      request.httpMethod = "POST"
      request.timeoutInterval = 60
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue(apiKey, forHTTPHeaderField: "x-datamerge-key")
      request.httpBody = try JSONEncoder().encode(
        DocumentExportRequest(
          content: markdown,
          output: "docx",
          mode: "quick",
          filename: stem,
          title: stem
        )
      )
      let (responseData, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse,
        http.statusCode == 200,
        responseData.count >= 4,
        responseData.starts(with: [0x50, 0x4B, 0x03, 0x04])
      else {
        throw QuickActionError.documentExportFailed
      }
      let destination = uniqueDestination(
        in: outputDirectory ?? source.deletingLastPathComponent(),
        name: stem
      )
      try responseData.write(
        to: destination,
        options: [.atomic, .completeFileProtectionUnlessOpen]
      )
      outputs.append(destination)
    }
    return outputs
  }

  private func uniqueDestination(in directory: URL, name: String) -> URL {
    var index = 1
    var candidate = directory.appending(path: "\(name).docx")
    while FileManager.default.fileExists(atPath: candidate.path) {
      index += 1
      candidate = directory.appending(path: "\(name) \(index).docx")
    }
    return candidate
  }
}

private struct DocumentExportRequest: Encodable {
  let content: String
  let output: String
  let mode: String
  let filename: String
  let title: String
}

enum DatamergeConversionCredential {
  private static let service = "art.apuch.kmd.datamerge-conversion"
  private static let account = "standard-api-key"

  static var isConfigured: Bool { apiKey() != nil }

  static func apiKey() -> String? {
    guard Bundle.main.bundleIdentifier?.hasSuffix(".dev") != true else { return nil }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data,
      let value = String(data: data, encoding: .utf8),
      !value.isEmpty
    else { return nil }
    return value
  }

  static func save(_ value: String) throws {
    guard Bundle.main.bundleIdentifier?.hasSuffix(".dev") != true else {
      throw QuickActionError.documentExportNotConfigured
    }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw QuickActionError.documentExportNotConfigured }
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let attributes: [String: Any] = [
      kSecValueData as String: Data(normalized.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var item = base
      for (key, value) in attributes {
        item[key] = value
      }
      let addStatus = SecItemAdd(item as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw CocoaError(.fileWriteNoPermission) }
    } else if status != errSecSuccess {
      throw CocoaError(.fileWriteNoPermission)
    }
  }

  static func remove() {
    guard Bundle.main.bundleIdentifier?.hasSuffix(".dev") != true else { return }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}

struct ConversionRequestV1 {
  let id = UUID()
  let resources: [URL]
}

struct ConversionPlanV1 {
  let request: ConversionRequestV1
  let supported: [URL]
  let usesRemoteService: Bool
  let outputDirectory: URL
}

struct ConversionResultV1 {
  let jobID: UUID
  let outputs: [URL]
}

protocol ConversionProvider {
  func probe(_ resources: [URL]) async -> [URL]
  func plan(_ request: ConversionRequestV1) async throws -> ConversionPlanV1
  func execute(
    _ plan: ConversionPlanV1,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ConversionResultV1
  func cancel(jobID: UUID) async
}

actor FormatConversionService: ConversionProvider {
  private var cancelled = Set<UUID>()

  func probe(_ resources: [URL]) async -> [URL] {
    resources.filter { url in
      if url.hasDirectoryPath { return true }
      let ext = url.pathExtension.lowercased()
      return [
        "txt", "md", "markdown", "html", "htm", "json", "yaml", "yml", "csv", "zip", "tar", "tgz",
        "pdf", "png", "jpg", "jpeg", "tiff", "heic",
      ].contains(ext)
    }
  }

  func plan(_ request: ConversionRequestV1) async throws -> ConversionPlanV1 {
    guard request.resources.count <= 50 else { throw QuickActionError.batchLimit }
    let supported = await probe(request.resources)
    guard !supported.isEmpty else { throw QuickActionError.unsupported }
    for url in supported {
      let values = try url.resourceValues(forKeys: [.fileSizeKey])
      if (values.fileSize ?? 0) > 200 * 1024 * 1024 { throw QuickActionError.fileLimit }
    }
    let remote = supported.contains {
      ["pdf", "png", "jpg", "jpeg", "tiff", "heic"].contains($0.pathExtension.lowercased())
    }
    let root = supported[0].deletingLastPathComponent()
    return ConversionPlanV1(
      request: request,
      supported: supported,
      usesRemoteService: remote,
      outputDirectory: root.appending(
        path: "ksamint-converted-\(request.id.uuidString.prefix(8))",
        directoryHint: .isDirectory
      )
    )
  }

  func execute(_ plan: ConversionPlanV1, progress: @escaping @Sendable (Double) -> Void)
    async throws -> ConversionResultV1 {
    if plan.usesRemoteService {
      throw QuickActionError.remoteProviderNotConfigured
    }
    try FileManager.default.createDirectory(
      at: plan.outputDirectory,
      withIntermediateDirectories: true
    )
    var outputs: [URL] = []
    for (index, url) in plan.supported.enumerated() {
      if cancelled.contains(plan.request.id) { throw CancellationError() }
      let output = plan.outputDirectory.appending(
        path: "\((url.lastPathComponent as NSString).deletingPathExtension).md"
      )
      let content = try await localMarkdown(url)
      if cancelled.contains(plan.request.id) { throw CancellationError() }
      try Data(content.utf8).write(to: output, options: .atomic)
      outputs.append(output)
      progress(Double(index + 1) / Double(plan.supported.count))
    }
    return ConversionResultV1(jobID: plan.request.id, outputs: outputs)
  }

  func cancel(jobID: UUID) async { cancelled.insert(jobID) }

  private func localMarkdown(_ url: URL) async throws -> String {
    if url.hasDirectoryPath {
      let children = try FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: nil
      )
      let entries = children
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map { "- \($0.lastPathComponent)" }
      return "# \(url.lastPathComponent)\n\n" + entries.joined(separator: "\n")
    }
    let ext = url.pathExtension.lowercased()
    if ext == "zip" {
      return try await archiveManifest(url, executable: "/usr/bin/zipinfo", arguments: ["-1"])
    }
    if ["tar", "tgz"].contains(ext) {
      return try await archiveManifest(url, executable: "/usr/bin/tar", arguments: ["-tf"])
    }
    let text = try String(contentsOf: url, encoding: .utf8)
    if ["md", "markdown", "txt"].contains(ext) { return text }
    if ["html", "htm"].contains(ext) {
      return ClipboardCaptureDecoder.decode(ClipboardCaptureSnapshot(
        plainText: nil, html: Data(text.utf8), rtf: nil, fileURLs: []
      ))?.content ?? text
    }
    return "# \(url.lastPathComponent)\n\n```\(ext)\n\(text)\n```\n"
  }

  private func archiveManifest(_ url: URL, executable: String, arguments: [String]) async throws -> String {
    let output = try await ProcessOutput.run(
      executableURL: URL(fileURLWithPath: executable), arguments: arguments + [url.path]
    )
    guard output.status == 0 else {
      let detail = String(data: output.standardError, encoding: .utf8)
      throw QuickActionError.archiveListing(detail.flatMap { $0.isEmpty ? nil : $0 } ?? "Archive listing failed")
    }
    let listingData = output.standardOutput
    let listing = String(data: listingData, encoding: .utf8) ?? ""
    let entries = listing.split(whereSeparator: \.isNewline).prefix(200_000)
    return "# \(url.lastPathComponent)\n\n" + entries.map { "- `\($0)`" }.joined(separator: "\n")
      + "\n"
  }
}

private enum QuickActionError: LocalizedError {
  case invalidRequest, emptySelection, noWorkspace, noEditorForAgent, unsupported, batchLimit,
    fileLimit, remoteProviderNotConfigured, documentExportNotConfigured, documentExportFailed,
    selectFolderForCreation
  case archiveListing(String)

  var errorDescription: String? {
    switch self {
    case .invalidRequest: "The Quick Action request is invalid or expired."
    case .emptySelection: "No resources were selected."
    case .noWorkspace: "Authorize a workspace in kmd first."
    case .noEditorForAgent: "Open a Markdown document before starting the local Agent panel."
    case .unsupported: "None of the selected resources has a configured conversion provider."
    case .batchLimit: "A conversion batch can contain at most 50 files."
    case .fileLimit: "Each conversion source must be 200 MB or smaller."
    case .remoteProviderNotConfigured:
      "The Tencent MinerU Precision VLM provider is not configured on this server yet."
    case .documentExportNotConfigured: "Add a Datamerge conversion key in kmd Settings first."
    case .documentExportFailed:
      "The Datamerge DOCX conversion service did not return a valid document."
    case .selectFolderForCreation:
      "Select a folder, or authorize its parent as the kmd workspace, before creating a Markdown file."
    case .archiveListing(let detail): detail
    }
  }
}

extension Notification.Name {
  static let conversionProgress = Notification.Name("art.apuch.ksamint.conversion-progress")
}
