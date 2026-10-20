//
//  AppDelegate+FileSystem.swift
//  MarkEditMac
//
//  Created by cyan on 4/30/24.
//

import AppKit
import MarkEditKit
import ResourceCore

extension AppDelegate {
  func configureResourceMenu() {
    guard let mainFileMenu,
          !mainFileMenu.items.contains(where: { $0.action == #selector(openResource(_:)) }) else {
      return
    }
    let item = NSMenuItem(
      title: Localized.Resource.openResource,
      action: #selector(openResource(_:)),
      keyEquivalent: "o"
    )
    item.keyEquivalentModifierMask = [.command, .option]
    item.target = self
    let openIndex = mainFileMenu.items.firstIndex {
      $0.action == #selector(NSDocumentController.openDocument(_:))
    }
    let itemIndex = min((openIndex ?? 1) + 1, mainFileMenu.items.count)
    mainFileMenu.insertItem(item, at: itemIndex)

    let recentItem = NSMenuItem(title: Localized.Resource.recentResources, action: nil, keyEquivalent: "")
    let recentMenu = NSMenu(title: Localized.Resource.recentResources)
    recentItem.submenu = recentMenu
    recentResourcesMenu = recentMenu
    mainFileMenu.insertItem(recentItem, at: min(itemIndex + 1, mainFileMenu.items.count))
    refreshRecentResourcesMenu()
  }

  @IBAction func openResource(_ sender: Any?) {
    let tabbingWindow = NSApp.keyWindow
    let openPanel = NSOpenPanel()
    openPanel.prompt = Localized.Resource.open
    openPanel.message = Localized.Resource.openDescription
    openPanel.canChooseDirectories = true
    openPanel.canChooseFiles = true
    openPanel.allowsMultipleSelection = false
    openPanel.resolvesAliases = false

    Task {
      guard await openPanel.begin() == .OK, let url = openPanel.url else {
        return
      }
      await openResourceURL(url, tabbingWindow: tabbingWindow)
    }
  }

  func openResourceURL(_ url: URL, tabbingWindow: NSWindow?) async {
    do {
      try await resourceModuleHost.open(url, tabbingWindow: tabbingWindow)
      rememberResource(url)
    } catch {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = Localized.Resource.openFailed
      alert.informativeText = error.localizedDescription
      alert.addButton(withTitle: Localized.General.done)
      if let window = NSApp.keyWindow {
        await alert.beginSheetModal(for: window)
      } else {
        alert.runModal()
      }
    }
  }

  @objc func openRecentResource(_ sender: NSMenuItem) {
    guard let bookmark = sender.representedObject as? Data else {
      return
    }
    do {
      var isStale = false
      let url = try URL(
        resolvingBookmarkData: bookmark,
        options: [.withSecurityScope, .withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      guard url.startAccessingSecurityScopedResource() else {
        throw CocoaError(.fileReadNoPermission)
      }
      if activeResourceSecurityScopes.contains(url) {
        url.stopAccessingSecurityScopedResource()
      } else {
        activeResourceSecurityScopes.append(url)
      }
      Task {
        await openResourceURL(url, tabbingWindow: NSApp.keyWindow)
      }
    } catch {
      let alert = NSAlert(error: error)
      alert.messageText = Localized.Resource.openFailed
      alert.runModal()
    }
  }

  @objc func clearRecentResources(_ sender: Any?) {
    AppPreferences.General.recentResourceBookmarks = []
    refreshRecentResourcesMenu()
  }

  func confirmResourceModuleInstallation(_ entry: ResourceModuleCatalogEntryV1) async -> Bool {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = Localized.Resource.installModule
    alert.informativeText = String(
      format: Localized.Resource.installModuleDescription,
      locale: .current,
      entry.displayName,
      entry.version,
      formatter.string(fromByteCount: Int64(entry.downloadBytes))
    )
    alert.addButton(withTitle: Localized.Resource.install)
    alert.addButton(withTitle: Localized.General.cancel)
    let response: NSApplication.ModalResponse
    if let window = NSApp.keyWindow {
      response = await alert.beginSheetModal(for: window)
    } else {
      response = alert.runModal()
    }
    return response == .alertFirstButtonReturn
  }

  func saveGrantedFolderAsBookmark() async {
    let openPanel = NSOpenPanel()
    openPanel.prompt = Localized.General.grantAccess
    openPanel.canChooseDirectories = true
    openPanel.canChooseFiles = false
    openPanel.allowsMultipleSelection = false

    guard await openPanel.begin() == .OK, let url = openPanel.url else {
      return
    }

    guard let newBookmark = try? url.bookmarkData(
      options: .withSecurityScope,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    ) else {
      return Logger.log(.error, "Failed to create bookmark data")
    }

    let bookmarkData = AppPreferences.General.grantedFolderBookmark
    let bookmarkList: [Data] = {
      if let dataArray = bookmarkData?.decodeToDataArray() {
        return dataArray
      }

      if let bookmarkData {
        return [bookmarkData]
      }

      return []
    }()

    let encodedData = bookmarkList.appendingData(newBookmark).encodeToData()
    AppPreferences.General.grantedFolderBookmark = encodedData
  }

  func startAccessingGrantedFolder() {
    guard let bookmarkData = AppPreferences.General.grantedFolderBookmark else {
      return
    }

    if let bookmarkList = bookmarkData.decodeToDataArray() {
      bookmarkList.forEach {
        startAccessingBookmarkData($0)
      }
    } else {
      startAccessingBookmarkData(bookmarkData)
    }
  }
}

// MARK: - Private

private extension AppDelegate {
  func rememberResource(_ url: URL) {
    guard let bookmark = try? url.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: [.nameKey, .isDirectoryKey],
      relativeTo: nil
    ) else {
      return
    }
    var bookmarks = AppPreferences.General.recentResourceBookmarks.filter { existing in
      var isStale = false
      guard let existingURL = try? URL(
        resolvingBookmarkData: existing,
        options: [.withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      ) else {
        return true
      }
      return existingURL.standardizedFileURL != url.standardizedFileURL
    }
    bookmarks.insert(bookmark, at: 0)
    AppPreferences.General.recentResourceBookmarks = Array(bookmarks.prefix(10))
    refreshRecentResourcesMenu()
  }

  func refreshRecentResourcesMenu() {
    guard let recentResourcesMenu else {
      return
    }
    recentResourcesMenu.removeAllItems()
    let bookmarks = AppPreferences.General.recentResourceBookmarks
    for bookmark in bookmarks {
      var isStale = false
      guard let url = try? URL(
        resolvingBookmarkData: bookmark,
        options: [.withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      ) else {
        continue
      }
      let item = NSMenuItem(
        title: url.lastPathComponent,
        action: #selector(openRecentResource(_:)),
        keyEquivalent: ""
      )
      item.target = self
      item.representedObject = bookmark
      item.toolTip = url.path
      recentResourcesMenu.addItem(item)
    }
    if recentResourcesMenu.items.isEmpty {
      let item = NSMenuItem(title: Localized.Resource.noRecentResources, action: nil, keyEquivalent: "")
      item.isEnabled = false
      recentResourcesMenu.addItem(item)
    }
    recentResourcesMenu.addItem(.separator())
    let clearItem = NSMenuItem(
      title: Localized.Resource.clearRecentResources,
      action: #selector(clearRecentResources(_:)),
      keyEquivalent: ""
    )
    clearItem.target = self
    clearItem.isEnabled = !bookmarks.isEmpty
    recentResourcesMenu.addItem(clearItem)
  }

  func startAccessingBookmarkData(_ bookmarkData: Data) {
    do {
      var isStale = false
      let bookmarkURL = try URL(
        resolvingBookmarkData: bookmarkData,
        options: [.withSecurityScope, .withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )

      guard bookmarkURL.startAccessingSecurityScopedResource() else {
        return Logger.log(.error, "Saved folder access is unavailable; the bookmark was retained")
      }
      if activeResourceSecurityScopes.contains(bookmarkURL) {
        bookmarkURL.stopAccessingSecurityScopedResource()
      } else {
        activeResourceSecurityScopes.append(bookmarkURL)
      }
      if isStale, let refreshed = try? bookmarkURL.bookmarkData(
        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
      ), let saved = AppPreferences.General.grantedFolderBookmark {
        if let list = saved.decodeToDataArray() {
          AppPreferences.General.grantedFolderBookmark = list.map {
            $0 == bookmarkData ? refreshed : $0
          }
          .encodeToData()
        } else if saved == bookmarkData {
          AppPreferences.General.grantedFolderBookmark = refreshed
        }
      }
    } catch {
      Logger.log(.error, "Failed to resolve bookmark data")
    }
  }
}
