//
//  FinderTools.swift
//  FinderExtension
//
//  Created by cyan on 11/13/25.
//

import AppKit
import FinderSync
import os.log

final class FinderTools: FIFinderSync {
  private var securityScopedWorkspaceURL: URL?
  private let workspace = UserDefaults(suiteName: "group.art.apuch.ksamint-markedit")
    .map { WorkspaceBookmarkReceiver(shared: $0) }

  override init() {
    super.init()
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(refreshWorkspaceGrant),
      name: WorkspaceBookmarkNotifications.changed,
      object: nil
    )
    refreshWorkspaceGrant()
    DistributedNotificationCenter.default().post(name: WorkspaceBookmarkNotifications.requested, object: nil)
  }

  @objc private func refreshWorkspaceGrant() {
    if let securityScopedWorkspaceURL { securityScopedWorkspaceURL.stopAccessingSecurityScopedResource() }
    securityScopedWorkspaceURL = workspace?.acquire()
    FIFinderSyncController.default().directoryURLs = Set([securityScopedWorkspaceURL].compactMap { $0 })
  }

  deinit {
    DistributedNotificationCenter.default().removeObserver(self)
    securityScopedWorkspaceURL?.stopAccessingSecurityScopedResource()
  }

  override var toolbarItemName: String {
    String(format: String(localized: "New %@ File"), fileBaseName)
  }

  override var toolbarItemToolTip: String {
    toolbarItemName
  }

  override var toolbarItemImage: NSImage {
    let symbols = [
      "text.pad.header.badge.plus",
      "document.badge.plus",
      "plus.square.on.square",
    ]

    for symbol in symbols {
      if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
        return image
      }
    }

    return super.toolbarItemImage
  }

  override func menu(for menuKind: FIMenuKind) -> NSMenu {
    let menu = NSMenu()
    if menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer {
      let quickActions = NSMenu(title: String(localized: "kmd Quick Actions"))
      for (index, action) in WorkspaceQuickAction.allCases.enumerated() {
        let item = NSMenuItem(
          title: action.title,
          action: #selector(runQuickAction(_:)),
          keyEquivalent: ""
        )
        item.tag = index
        item.target = self
        quickActions.addItem(item)
      }
      let wrapper = NSMenuItem(
        title: String(localized: "kmd Quick Actions"),
        action: nil,
        keyEquivalent: ""
      )
      wrapper.submenu = quickActions
      menu.addItem(wrapper)
      menu.addItem(.separator())
    }
    let specs = fileTypes.map {
      String(format: String(localized: "New “%@%@”"), fileBaseName, $0)
    }

    for (index, title) in specs.enumerated() {
      let item = NSMenuItem(
        title: title,
        action: #selector(newTextFile(_:)),
        keyEquivalent: ""
      )

      item.tag = index
      menu.addItem(item)
    }

    if menuKind == .toolbarItemMenu {
      return menu
    }

    let itemWrapper = NSMenuItem(title: toolbarItemName, action: nil, keyEquivalent: "")
    itemWrapper.submenu = menu

    let menuWrapper = NSMenu()
    menuWrapper.addItem(itemWrapper)

    return menuWrapper
  }
}

// MARK: - Private

private let logger = os.Logger()
private let fileTypes = [".md", ".markdown", ".txt", ""]
private let fileBaseName = String(localized: "Untitled")

extension FinderTools {
  @objc fileprivate func runQuickAction(_ sender: NSMenuItem) {
    guard WorkspaceQuickAction.allCases.indices.contains(sender.tag) else { return }
    let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
    guard !urls.isEmpty else { return logger.log(level: .error, "Missing selectedItemURLs") }
    do {
      let request = WorkspaceQuickActionRequest(
        version: 1,
        id: UUID(),
        createdAt: Date(),
        action: WorkspaceQuickAction.allCases[sender.tag],
        resourceBookmarks: try urls.map {
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
        options: .atomic
      )
      guard
        let callbackURL = URL(
          string: "ksamint-markedit://quick-action?id=\(request.id)"
        )
      else { throw CocoaError(.fileWriteInvalidFileName) }
      NSWorkspace.shared.open(callbackURL)
    } catch {
      logger.log(level: .error, "Quick Action failed: \(error.localizedDescription)")
    }
  }

  @objc fileprivate func newTextFile(_ sender: NSMenuItem) {
    guard let directory = FIFinderSyncController.default().targetedURL() else {
      return logger.log(level: .error, "Missing targetedURL")
    }

    let uniqueFileURL = FileManager.default.uniqueFileURL(
      in: directory,
      baseName: fileBaseName,
      pathExtension: fileTypes[sender.tag]
    )

    do {
      try Data().write(to: uniqueFileURL)
      NSWorkspace.shared.activateFileViewerSelecting([uniqueFileURL])
    } catch {
      logger.log(level: .error, "\(error)")
    }
  }
}

private enum WorkspaceQuickAction: String, Codable, CaseIterable {
  case preview, openEditor, conversationInbox, saveReference, addWorkspace, analyzeAgent,
    createMarkdown, convertMarkdown, convertDocx

  var title: String {
    switch self {
    case .preview: String(localized: "Quick Preview")
    case .openEditor: String(localized: "Open in Editor")
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

private struct WorkspaceQuickActionRequest: Codable {
  let version: Int
  let id: UUID
  let createdAt: Date
  let action: WorkspaceQuickAction
  let resourceBookmarks: [Data]
}

extension FileManager {
  fileprivate func uniqueFileURL(
    in directory: URL,
    baseName: String,
    pathExtension: String
  ) -> URL {
    var index = 1
    var fileName = "\(baseName)\(pathExtension)"

    while fileExists(atPath: directory.appending(path: fileName).path) {
      index += 1
      fileName = "\(baseName) \(index)\(pathExtension)"
    }

    return directory.appending(path: fileName)
  }
}
