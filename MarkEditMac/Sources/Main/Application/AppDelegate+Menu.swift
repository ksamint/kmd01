//
//  AppDelegate+Menu.swift
//  MarkEditMac
//
//  Created by cyan on 1/15/23.
//

import AppKit
import MarkEditKit

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
  @available(macOS 15.1, *)
  var activeWritingToolsItem: NSMenuItem? {
    mainEditMenu?.items.first {
      $0.identifier?.rawValue == "__NSTextViewContextSubmenuIdentifierWritingTools"
    }
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    switch menu {
    case mainFileMenu:
      reconfigureMainFileMenu(document: currentDocument)
    case mainEditMenu:
      reconfigureMainEditMenu(document: currentDocument)
    case mainExtensionsMenu:
      reconfigureMainExtensionsMenu(document: currentDocument)
    case mainWindowMenu:
      reconfigureMainWindowMenu(document: currentDocument)
    case openFileInMenu:
      reconfigureOpenFileInMenu(document: currentDocument)
    case reopenFileMenu:
      reconfigureReopenFileMenu(document: currentDocument)
    case lineEndingsMenu:
      reconfigureLineEndingsMenu(document: currentDocument)
    default:
      break
    }
  }
}

// MARK: - NSMenuItemValidation

extension AppDelegate: NSMenuItemValidation {
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(newFileFromClipboard(_:)):
      return NSPasteboard.general.hasText
    case #selector(reopenClosedTab(_:)):
      return EditorClosedTabHistory.shared.hasEntries
    case #selector(toggleDocumentOutline(_:)):
      menuItem.setOn(currentEditor?.workspaceSidebarVisible == true
        && currentEditor?.workspaceSidebarMode == .outline)
      return currentEditor != nil
    case #selector(toggleWorkspaceFiles(_:)):
      menuItem.setOn(currentEditor?.workspaceSidebarVisible == true
        && currentEditor?.workspaceSidebarMode == .files)
      return currentEditor != nil
    case #selector(toggleWorkspaceSearch(_:)):
      menuItem.setOn(currentEditor?.workspaceSidebarVisible == true
        && currentEditor?.workspaceSidebarMode == .search)
      return currentEditor != nil
    case #selector(toggleWorkspaceTags(_:)):
      menuItem.setOn(currentEditor?.workspaceSidebarVisible == true
        && currentEditor?.workspaceSidebarMode == .tags)
      return currentEditor != nil
    case #selector(toggleRenderedPreview(_:)):
      menuItem.setOn(currentEditor?.workspacePreviewVisible == true)
      return currentEditor != nil
    case #selector(showWorkspaceHub(_:)):
      return currentEditor != nil
    default:
      return true
    }
  }
}

// MARK: - Workspace View Menu

extension AppDelegate {
  func configureWorkspaceViewMenu() {
    let customizeToolbarAction = NSSelectorFromString("runToolbarCustomizationPalette:")
    guard let viewMenu = NSApp.mainMenu?.items
      .compactMap(\.submenu)
      .first(where: { menu in
        menu.items.contains { $0.action == customizeToolbarAction }
      }),
      !viewMenu.items.contains(where: { $0.action == #selector(toggleDocumentOutline(_:)) }) else {
      return
    }

    let items = [
      workspaceViewMenuItem(
        title: String(localized: "Document Outline"),
        action: #selector(toggleDocumentOutline(_:)),
        key: "o",
        modifiers: [.command, .shift]
      ),
      workspaceViewMenuItem(
        title: Localized.Workspace.files,
        action: #selector(toggleWorkspaceFiles(_:)),
        key: "e",
        modifiers: [.command, .shift]
      ),
      workspaceViewMenuItem(
        title: Localized.Workspace.search,
        action: #selector(toggleWorkspaceSearch(_:)),
        key: "f",
        modifiers: [.command, .shift]
      ),
      workspaceViewMenuItem(
        title: Localized.Workspace.tags,
        action: #selector(toggleWorkspaceTags(_:)),
        key: "t",
        modifiers: [.command, .shift]
      ),
      workspaceViewMenuItem(
        title: Localized.Editor.previewButtonTitle,
        action: #selector(toggleRenderedPreview(_:)),
        key: "p",
        modifiers: [.command, .option]
      ),
      workspaceViewMenuItem(
        title: Localized.Workspace.hub,
        action: #selector(showWorkspaceHub(_:)),
        key: "h",
        modifiers: [.command, .shift]
      ),
      NSMenuItem.separator(),
    ]

    for item in items.reversed() {
      viewMenu.insertItem(item, at: 0)
    }
  }

  @IBAction func toggleDocumentOutline(_ sender: Any?) {
    currentEditor?.toggleWorkspaceSidebar(.outline)
  }

  @IBAction func toggleWorkspaceFiles(_ sender: Any?) {
    currentEditor?.toggleWorkspaceSidebar(.files)
  }

  @IBAction func toggleWorkspaceSearch(_ sender: Any?) {
    currentEditor?.toggleWorkspaceSidebar(.search)
  }

  @IBAction func toggleWorkspaceTags(_ sender: Any?) {
    currentEditor?.toggleWorkspaceSidebar(.tags)
  }

  @IBAction func toggleRenderedPreview(_ sender: Any?) {
    currentEditor?.toggleRenderedPreview()
  }

  @IBAction func showWorkspaceHub(_ sender: Any?) {
    currentEditor?.showWorkspaceHub()
  }

  private func workspaceViewMenuItem(
    title: String,
    action: Selector,
    key: String,
    modifiers: NSEvent.ModifierFlags
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    item.target = self
    return item
  }
}

// MARK: - Private

private extension AppDelegate {
  func reconfigureMainFileMenu(document: EditorDocument?) {
    [openFileInMenu, reopenFileMenu, lineEndingsMenu].forEach {
      $0?.superMenuItem?.isEnabled = document?.fileURL != nil
    }
  }

  func reconfigureMainEditMenu(document: EditorDocument?) {
    Task { @MainActor in
      guard let document else {
        return
      }

      editUndoItem?.isEnabled = await document.canUndo
      editRedoItem?.isEnabled = await document.canRedo
      editPasteItem?.isEnabled = NSPasteboard.general.hasText
    }

    // [macOS 27] Always enable "Writing Tools"
    if #available(macOS 27.0, *), AppDesign.forceWritingTools {
      // Prevent duplicate items
      editWritingToolsItem?.isHidden = !(activeWritingToolsItem?.isHidden ?? true)

      // Copy properties from `standardWritingToolsMenuItem`
      let systemItem = NSMenuItem.systemWritingToolsItem
      editWritingToolsItem?.submenu = systemItem?.submenu?.copiedMenu
      editWritingToolsItem?.title = systemItem?.title ?? Localized.WritingTools.featureName
      editWritingToolsItem?.image = AppWritingTools.affordanceIcon
    }

    editTypewriterItem?.setOn(AppPreferences.Editor.typewriterMode)
  }

  func reconfigureMainExtensionsMenu(document: EditorDocument?) {
    mainExtensionsMenu?.items.forEach {
      let isEnabled = $0.target === NSApp.appDelegate || document != nil
      $0.setEnabledRecursively(isEnabled: isEnabled)
    }
  }

  func reconfigureMainWindowMenu(document: EditorDocument?) {
    windowFloatingItem?.isEnabled = NSApp.keyWindow is EditorWindow
    windowFloatingItem?.setOn(NSApp.keyWindow?.level == .floating)
  }

  @MainActor
  func reconfigureOpenFileInMenu(document: EditorDocument?) {
    openFileInMenu?.removeAllItems()

    // Disabled or not able to find the document, just leave the menu empty
    guard let fileURL = document?.fileURL else {
      return
    }

    // Basically, we wouldn't expect to see "MarkEdit.app"
    let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: fileURL).filter {
      $0.lastPathComponent != Bundle.main.bundleURL.lastPathComponent
    }

    appURLs.forEach { appURL in
      let item = openFileInMenu?.addItem(withTitle: appURL.localizedName) {
        NSWorkspace.shared.open(
          [fileURL],
          withApplicationAt: appURL,
          configuration: NSWorkspace.OpenConfiguration(),
          completionHandler: nil
        )
      }

      let icon = NSWorkspace.shared.icon(forFile: appURL.path)
      item?.image = icon.resized(with: CGSize(width: 16, height: 16))
      item?.ensureImageVisibility()
    }
  }

  func reconfigureReopenFileMenu(document: EditorDocument?) {
    reopenFileMenu?.removeAllItems()

    // Disabled or not able to find the document, just leave the menu empty
    guard document?.fileURL != nil else {
      return
    }

    for encoding in EditorTextEncoding.allCases {
      let item = reopenFileMenu?.addItem(withTitle: encoding.localizedDescription, action: #selector(EditorViewController.reopenWithEncoding(_:)))
      item?.representedObject = encoding

      if EditorTextEncoding.groupingCases.contains(encoding) {
        reopenFileMenu?.addItem(.separator())
      }
    }
  }

  func reconfigureLineEndingsMenu(document: EditorDocument?) {
    Task { @MainActor in
      guard let lineEndings = await document?.lineEndings else {
        return
      }

      lineEndingsLFItem?.setOn(lineEndings == .lf)
      lineEndingsCRLFItem?.setOn(lineEndings == .crlf)
      lineEndingsCRItem?.setOn(lineEndings == .cr)
      lineEndingsMenu?.reloadItems()
    }
  }
}

// MARK: - Private

private extension AppDelegate {
  @IBAction func checkForUpdates(_ sender: Any?) {
    Task {
      await AppUpdater.checkForUpdates(explicitly: true)
    }
  }

  @IBAction func openDocumentsFolder(_ sender: Any?) {
    NSWorkspace.shared.open(.documentsDirectory)
  }

  @IBAction func grantFolderAccess(_ sender: Any?) {
    NSApp.closeOpenPanels()
    Task {
      await saveGrantedFolderAsBookmark()
    }
  }

  @IBAction func newFileFromClipboard(_ sender: Any?) {
    createNewFile(initialContent: NSPasteboard.general.string)
  }

  @IBAction func saveAllDocuments(_ sender: Any?) {
    NSDocumentController.shared.saveAllDocuments(nil)
  }

  @IBAction func openDevelopmentGuide(_ sender: Any?) {
    NSWorkspace.shared.safelyOpenURL(string: "https://github.com/MarkEdit-app/MarkEdit/wiki/Development")
  }

  @IBAction func manageExtensions(_ sender: Any?) {
    ExtensionsWindowController.shared.present()
  }

  @IBAction func openCustomizationGuide(_ sender: Any?) {
    NSWorkspace.shared.safelyOpenURL(string: "https://github.com/MarkEdit-app/MarkEdit/wiki/Customization")
  }

  @IBAction func showHelp(_ sender: Any?) {
    NSWorkspace.shared.safelyOpenURL(string: "https://github.com/MarkEdit-app/MarkEdit/wiki")
  }

  @IBAction func openIssueTracker(_ sender: Any?) {
    NSWorkspace.shared.safelyOpenURL(string: "https://github.com/ksamint/kmd01/issues")
  }

  @IBAction func openVersionHistory(_ sender: Any?) {
    NSWorkspace.shared.safelyOpenURL(string: "https://github.com/ksamint/kmd01/releases")
  }
}
