import AppKit
import ApplicationServices
import Carbon.HIToolbox

private enum ClipboardPaletteFilter: Equatable, Sendable {
  case recent
  case pinned
  case permanent
  case tag(String)
}

private struct ClipboardSidebarEntry {
  let filter: ClipboardPaletteFilter
  let title: String
  let systemImage: String
  let count: Int
}

@MainActor
final class ClipboardPaletteController: NSObject {
  typealias CommitHandler = (ClipboardHistoryItem, NSRunningApplication?) -> Void

  private let store: ClipboardHistoryStore
  private let onCommit: CommitHandler
  private let onDismiss: () -> Void
  private let panel = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: 680, height: 430),
    styleMask: [.titled, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  private let searchField = NSSearchField()
  private let sidebarTable = NSTableView()
  private let sidebarScrollView = NSScrollView()
  private let addTagButton = NSButton()
  private let renameTagButton = NSButton()
  private let deleteTagButton = NSButton()
  private let tableView = NSTableView()
  private let scrollView = NSScrollView()
  private let itemMenu = NSMenu()
  private let hintLabel = NSTextField(labelWithString: "")
  private var sidebarEntries = [ClipboardSidebarEntry]()
  private var filteredItems = [ClipboardHistoryItem]()
  private var activeFilter = ClipboardPaletteFilter.recent
  private var contextItemID: String?
  private var previousApplication: NSRunningApplication?
  private var eventMonitor: Any?
  private var filterTask: Task<Void, Never>?

  init(
    store: ClipboardHistoryStore,
    onCommit: @escaping CommitHandler,
    onDismiss: @escaping () -> Void
  ) {
    self.store = store
    self.onCommit = onCommit
    self.onDismiss = onDismiss
    super.init()
    setUp()
  }

  var isVisible: Bool { panel.isVisible }

  func toggle() {
    if panel.isVisible {
      close()
    } else {
      show()
    }
  }

  func reload() {
    reloadSidebar(selecting: activeFilter)
    applyFilter()
  }

  func close() {
    filterTask?.cancel()
    filterTask = nil
    panel.orderOut(nil)
    removeEventMonitor()
    previousApplication?.activate(options: [.activateAllWindows])
    onDismiss()
  }
}

private extension ClipboardPaletteController {
  func setUp() {
    panel.title = String(localized: "Clipboard History")
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isMovableByWindowBackground = true
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.backgroundColor = .windowBackgroundColor
    panel.delegate = self

    searchField.placeholderString = String(localized: "Search recent clipboard content")
    searchField.delegate = self

    let sidebarColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ClipboardSidebar"))
    sidebarColumn.resizingMask = .autoresizingMask
    sidebarTable.addTableColumn(sidebarColumn)
    sidebarTable.headerView = nil
    sidebarTable.rowHeight = 30
    sidebarTable.intercellSpacing = NSSize(width: 0, height: 2)
    sidebarTable.dataSource = self
    sidebarTable.delegate = self
    sidebarTable.target = self
    sidebarTable.doubleAction = #selector(renameSelectedTag)
    sidebarTable.style = .sourceList
    sidebarTable.setAccessibilityLabel(String(localized: "Clipboard labels"))

    sidebarScrollView.documentView = sidebarTable
    sidebarScrollView.hasVerticalScroller = true
    sidebarScrollView.drawsBackground = false

    configureTagButton(addTagButton, symbol: "plus", label: String(localized: "New Label"), action: #selector(addTagAction))
    configureTagButton(renameTagButton, symbol: "pencil", label: String(localized: "Rename Label"), action: #selector(renameSelectedTag))
    configureTagButton(deleteTagButton, symbol: "minus", label: String(localized: "Delete Label"), action: #selector(deleteSelectedTag))

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ClipboardItem"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.rowHeight = 58
    tableView.intercellSpacing = NSSize(width: 0, height: 1)
    tableView.dataSource = self
    tableView.delegate = self
    tableView.target = self
    tableView.doubleAction = #selector(commitSelection)
    tableView.setAccessibilityLabel(String(localized: "Recent clipboard content"))
    itemMenu.delegate = self
    itemMenu.autoenablesItems = false
    tableView.menu = itemMenu

    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false

    hintLabel.stringValue = accessibilityTrusted
      ? String(localized: "↑↓ Select · Return Paste · Esc Close")
      : String(localized: "↑↓ Select · Return Copy · Esc Close")
    hintLabel.font = .systemFont(ofSize: 10)
    hintLabel.textColor = .tertiaryLabelColor
    hintLabel.alignment = .center

    let contentView = NSView()
    panel.contentView = contentView
    [searchField, sidebarScrollView, addTagButton, renameTagButton, deleteTagButton, scrollView, hintLabel].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview($0)
    }
    NSLayoutConstraint.activate([
      searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
      searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
      searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

      sidebarScrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
      sidebarScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
      sidebarScrollView.widthAnchor.constraint(equalToConstant: 158),
      sidebarScrollView.bottomAnchor.constraint(equalTo: addTagButton.topAnchor, constant: -6),

      addTagButton.leadingAnchor.constraint(equalTo: sidebarScrollView.leadingAnchor, constant: 2),
      addTagButton.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -6),
      addTagButton.widthAnchor.constraint(equalToConstant: 26),
      addTagButton.heightAnchor.constraint(equalToConstant: 24),

      renameTagButton.leadingAnchor.constraint(equalTo: addTagButton.trailingAnchor, constant: 4),
      renameTagButton.centerYAnchor.constraint(equalTo: addTagButton.centerYAnchor),
      renameTagButton.widthAnchor.constraint(equalToConstant: 26),
      renameTagButton.heightAnchor.constraint(equalToConstant: 24),

      deleteTagButton.leadingAnchor.constraint(equalTo: renameTagButton.trailingAnchor, constant: 4),
      deleteTagButton.centerYAnchor.constraint(equalTo: addTagButton.centerYAnchor),
      deleteTagButton.widthAnchor.constraint(equalToConstant: 26),
      deleteTagButton.heightAnchor.constraint(equalToConstant: 24),

      scrollView.topAnchor.constraint(equalTo: sidebarScrollView.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: sidebarScrollView.trailingAnchor, constant: 10),
      scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -6),

      hintLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
      hintLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
      hintLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
      hintLabel.heightAnchor.constraint(equalToConstant: 16),
    ])
    reloadSidebar(selecting: .recent)
    applyFilter()
  }

  func show() {
    let helperBundleID = Bundle.main.bundleIdentifier
    let frontmost = NSWorkspace.shared.frontmostApplication
    previousApplication = frontmost?.bundleIdentifier == helperBundleID ? nil : frontmost
    searchField.stringValue = ""
    activeFilter = .recent
    reloadSidebar(selecting: activeFilter)
    updateHint()
    applyFilter()
    positionPanel()
    installEventMonitor()
    panel.makeKeyAndOrderFront(nil)
    panel.orderFrontRegardless()
    NSRunningApplication(
      processIdentifier: ProcessInfo.processInfo.processIdentifier
    )?.activate(options: [.activateAllWindows])
    panel.makeKey()
    panel.makeFirstResponder(searchField)
  }

  func configureTagButton(_ button: NSButton, symbol: String, label: String, action: Selector) {
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    button.bezelStyle = .accessoryBarAction
    button.imagePosition = .imageOnly
    button.toolTip = label
    button.setAccessibilityLabel(label)
    button.target = self
    button.action = action
  }

  func updateHint() {
    hintLabel.stringValue = accessibilityTrusted
      ? String(localized: "↑↓ Select · Return Paste · Esc Close")
      : String(localized: "↑↓ Select · Return Copy · Esc Close")
  }

  func positionPanel() {
    let mouseLocation = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
    guard let visibleFrame = screen?.visibleFrame else {
      panel.center()
      return
    }
    let origin = NSPoint(
      x: min(max(mouseLocation.x - panel.frame.width / 2, visibleFrame.minX), visibleFrame.maxX - panel.frame.width),
      y: min(max(mouseLocation.y - panel.frame.height / 2, visibleFrame.minY), visibleFrame.maxY - panel.frame.height)
    )
    panel.setFrameOrigin(origin)
  }

  func installEventMonitor() {
    removeEventMonitor()
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return event }
      switch event.keyCode {
      case UInt16(kVK_UpArrow):
        moveSelection(by: -1)
        return nil
      case UInt16(kVK_DownArrow):
        moveSelection(by: 1)
        return nil
      case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
        commitSelection()
        return nil
      case UInt16(kVK_Escape):
        close()
        return nil
      default:
        return event
      }
    }
  }

  func removeEventMonitor() {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
  }

  func moveSelection(by offset: Int) {
    guard !filteredItems.isEmpty else { return }
    let current = tableView.selectedRow < 0 ? 0 : tableView.selectedRow
    let next = min(max(current + offset, 0), filteredItems.count - 1)
    tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
    tableView.scrollRowToVisible(next)
  }

  @objc func commitSelection() {
    guard filteredItems.indices.contains(tableView.selectedRow) else { return }
    let item = filteredItems[tableView.selectedRow]
    panel.orderOut(nil)
    removeEventMonitor()
    onCommit(item, previousApplication)
    onDismiss()
  }

  func applyFilter() {
    let query = searchField.stringValue
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCompatibilityMapping
    let items = store.items
    let tags = store.tags
    let filter = activeFilter
    filterTask?.cancel()
    filterTask = Task { [weak self] in
      let values = await Task.detached(priority: .userInitiated) {
        Self.filtered(items: items, tags: tags, filter: filter, query: query)
      }.value
      guard !Task.isCancelled, let self else { return }
      filteredItems = values
      tableView.reloadData()
      if !filteredItems.isEmpty {
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
      }
      updateTagButtons()
    }
  }

  nonisolated static func filtered(
    items: [ClipboardHistoryItem],
    tags: [ClipboardUserTag],
    filter: ClipboardPaletteFilter,
    query: String
  ) -> [ClipboardHistoryItem] {
    let tagNames = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0.name) })
    return items.filter { item in
      guard !Task.isCancelled else { return false }
      let matchesFilter = switch filter {
      case .recent: true
      case .pinned: item.isPinned
      case .permanent: item.isPermanent
      case let .tag(tagID): item.tagIDs.contains(tagID)
      }
      guard matchesFilter, !query.isEmpty else { return matchesFilter }
      let tagText = item.tagIDs.compactMap { tagNames[$0] }.joined(separator: " ")
      let sourceText = [item.sourceName, item.sessionName, item.sourceURL]
        .compactMap { $0 }
        .joined(separator: " ")
      return item.content.localizedStandardContains(query)
        || tagText.localizedStandardContains(query)
        || sourceText.localizedStandardContains(query)
    }.sorted { lhs, rhs in
      if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
      return lhs.capturedAt > rhs.capturedAt
    }
  }

  func reloadSidebar(selecting filter: ClipboardPaletteFilter? = nil) {
    let target = filter ?? activeFilter
    sidebarEntries = [
      ClipboardSidebarEntry(
        filter: .recent,
        title: String(localized: "Recent"),
        systemImage: "clock",
        count: store.items.count
      ),
      ClipboardSidebarEntry(
        filter: .pinned,
        title: String(localized: "Favorites"),
        systemImage: "star.fill",
        count: store.items.filter(\.isPinned).count
      ),
      ClipboardSidebarEntry(
        filter: .permanent,
        title: String(localized: "Permanent"),
        systemImage: "archivebox.fill",
        count: store.items.filter(\.isPermanent).count
      ),
    ]
    sidebarEntries.append(contentsOf: store.tags.map { tag in
      ClipboardSidebarEntry(
        filter: .tag(tag.id),
        title: tag.name,
        systemImage: "tag",
        count: store.items.filter { $0.tagIDs.contains(tag.id) }.count
      )
    })
    sidebarTable.reloadData()
    if let index = sidebarEntries.firstIndex(where: { $0.filter == target }) {
      activeFilter = target
      sidebarTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    } else {
      activeFilter = .recent
      sidebarTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }
    updateTagButtons()
  }

  func updateTagButtons() {
    let canEdit = if case .tag = activeFilter { true } else { false }
    renameTagButton.isEnabled = canEdit
    deleteTagButton.isEnabled = canEdit
  }

  @objc func addTagAction() {
    addTag(assigningTo: nil)
  }

  func addTag(assigningTo itemID: String?) {
    guard let name = promptForTagName(
      title: String(localized: "New Label"),
      actionTitle: String(localized: "Create"),
      initialValue: ""
    ), let tag = store.createTag(named: name) else {
      return
    }
    if let itemID,
       store.items.first(where: { $0.id == itemID })?.tagIDs.contains(tag.id) == false {
      _ = store.toggleTag(tag.id, for: itemID)
    }
    activeFilter = .tag(tag.id)
    reloadSidebar(selecting: activeFilter)
    applyFilter()
  }

  @objc func renameSelectedTag() {
    guard case let .tag(tagID) = activeFilter,
          let tag = store.tags.first(where: { $0.id == tagID }),
          let name = promptForTagName(
            title: String(localized: "Rename Label"),
            actionTitle: String(localized: "Rename"),
            initialValue: tag.name
          ) else { return }
    guard store.renameTag(id: tagID, to: name) else {
      NSSound.beep()
      return
    }
    reloadSidebar(selecting: activeFilter)
    applyFilter()
  }

  @objc func deleteSelectedTag() {
    guard case let .tag(tagID) = activeFilter,
          let tag = store.tags.first(where: { $0.id == tagID }) else { return }
    let alert = NSAlert()
    alert.messageText = String(localized: "Delete Label?")
    alert.informativeText = String(
      format: String(localized: "The label “%@” will be removed. Clipboard items will not be deleted."),
      tag.name
    )
    alert.addButton(withTitle: String(localized: "Delete"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    guard runPaletteModal(alert) == .alertFirstButtonReturn else { return }
    store.deleteTag(id: tagID)
    activeFilter = .recent
    reloadSidebar(selecting: activeFilter)
    applyFilter()
  }

  func promptForTagName(title: String, actionTitle: String, initialValue: String) -> String? {
    let input = NSTextField(string: initialValue)
    input.placeholderString = String(localized: "Label name")
    input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
    let alert = NSAlert()
    alert.messageText = title
    alert.accessoryView = input
    alert.addButton(withTitle: actionTitle)
    alert.addButton(withTitle: String(localized: "Cancel"))
    alert.window.initialFirstResponder = input
    guard runPaletteModal(alert) == .alertFirstButtonReturn else { return nil }
    let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  func runPaletteModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
    removeEventMonitor()
    defer {
      if panel.isVisible { installEventMonitor() }
    }
    return alert.runModal()
  }

  func togglePin(itemID: String) {
    guard store.togglePinned(itemID: itemID) != nil else {
      NSSound.beep()
      return
    }
    reloadSidebar(selecting: activeFilter)
    applyFilter()
  }

  func togglePermanent(itemID: String) {
    guard store.togglePermanent(itemID: itemID) != nil else {
      NSSound.beep()
      return
    }
    reloadSidebar(selecting: activeFilter)
    applyFilter()
  }

  @objc func togglePinnedFromMenu() {
    guard let contextItemID else { return }
    togglePin(itemID: contextItemID)
  }

  @objc func togglePermanentFromMenu() {
    guard let contextItemID else { return }
    togglePermanent(itemID: contextItemID)
  }

  @objc func toggleTagFromMenu(_ sender: NSMenuItem) {
    guard let contextItemID,
          let tagID = sender.representedObject as? String else { return }
    _ = store.toggleTag(tagID, for: contextItemID)
    reloadSidebar(selecting: activeFilter)
    applyFilter()
  }

  @objc func createTagFromMenu() {
    guard let contextItemID else { return }
    addTag(assigningTo: contextItemID)
  }

  func showLabels(for itemID: String, relativeTo view: NSView) {
    contextItemID = itemID
    let menu = NSMenu(title: String(localized: "Labels"))
    for tag in store.tags {
      let item = NSMenuItem(title: tag.name, action: #selector(toggleTagFromMenu(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = tag.id
      item.state = store.items.first(where: { $0.id == itemID })?.tagIDs.contains(tag.id) == true ? .on : .off
      menu.addItem(item)
    }
    if !store.tags.isEmpty { menu.addItem(.separator()) }
    let create = NSMenuItem(
      title: String(localized: "New Label…"),
      action: #selector(createTagFromMenu),
      keyEquivalent: ""
    )
    create.target = self
    menu.addItem(create)
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 4), in: view)
  }

  var accessibilityTrusted: Bool {
    AXIsProcessTrusted()
  }
}

extension ClipboardPaletteController: NSWindowDelegate {
  func windowWillClose(_ notification: Notification) {
    removeEventMonitor()
    onDismiss()
  }
}

extension ClipboardPaletteController: NSSearchFieldDelegate {
  func controlTextDidChange(_ obj: Notification) {
    applyFilter()
  }
}

extension ClipboardPaletteController: NSTableViewDataSource, NSTableViewDelegate {
  func numberOfRows(in tableView: NSTableView) -> Int {
    tableView === sidebarTable ? sidebarEntries.count : filteredItems.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    if tableView === sidebarTable {
      guard sidebarEntries.indices.contains(row) else { return nil }
      let identifier = NSUserInterfaceItemIdentifier("ClipboardSidebarCell")
      let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? ClipboardSidebarCellView)
        ?? ClipboardSidebarCellView()
      cell.identifier = identifier
      cell.configure(with: sidebarEntries[row])
      return cell
    }
    guard filteredItems.indices.contains(row) else { return nil }
    let identifier = NSUserInterfaceItemIdentifier("ClipboardHistoryCell")
    let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? ClipboardHistoryCellView)
      ?? ClipboardHistoryCellView()
    cell.identifier = identifier
    let item = filteredItems[row]
    cell.configure(
      with: item,
      tagNames: store.tagNames(for: item),
      onEditTags: { [weak self, weak cell] in
        guard let self, let cell else { return }
        showLabels(for: item.id, relativeTo: cell)
      },
      onTogglePin: { [weak self] in
        self?.togglePin(itemID: item.id)
      }
    )
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard notification.object as? NSTableView === sidebarTable,
          sidebarEntries.indices.contains(sidebarTable.selectedRow) else { return }
    activeFilter = sidebarEntries[sidebarTable.selectedRow].filter
    applyFilter()
  }
}

extension ClipboardPaletteController: NSMenuDelegate {
  func menuNeedsUpdate(_ menu: NSMenu) {
    guard menu === itemMenu else { return }
    menu.removeAllItems()
    let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
    guard filteredItems.indices.contains(row) else {
      contextItemID = nil
      return
    }
    let item = filteredItems[row]
    contextItemID = item.id

    let pinItem = NSMenuItem(
      title: item.isPinned ? String(localized: "Remove Favorite") : String(localized: "Favorite"),
      action: #selector(togglePinnedFromMenu),
      keyEquivalent: ""
    )
    pinItem.target = self
    pinItem.isEnabled = true
    menu.addItem(pinItem)

    let permanentItem = NSMenuItem(
      title: item.isPermanent ? String(localized: "Use Normal Retention") : String(localized: "Keep Permanently"),
      action: #selector(togglePermanentFromMenu),
      keyEquivalent: ""
    )
    permanentItem.target = self
    permanentItem.isEnabled = !item.isPinned && item.tagIDs.isEmpty
    menu.addItem(permanentItem)
    menu.addItem(.separator())

    for tag in store.tags {
      let tagItem = NSMenuItem(title: tag.name, action: #selector(toggleTagFromMenu(_:)), keyEquivalent: "")
      tagItem.target = self
      tagItem.representedObject = tag.id
      tagItem.state = item.tagIDs.contains(tag.id) ? .on : .off
      tagItem.isEnabled = true
      menu.addItem(tagItem)
    }
    if !store.tags.isEmpty { menu.addItem(.separator()) }
    let newTagItem = NSMenuItem(
      title: String(localized: "New Label…"),
      action: #selector(createTagFromMenu),
      keyEquivalent: ""
    )
    newTagItem.target = self
    newTagItem.isEnabled = true
    menu.addItem(newTagItem)
  }
}

@MainActor
private final class ClipboardSidebarCellView: NSTableCellView {
  private let iconView = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let countLabel = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    iconView.contentTintColor = .secondaryLabelColor
    titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
    titleLabel.lineBreakMode = .byTruncatingTail
    countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    countLabel.textColor = .tertiaryLabelColor
    countLabel.alignment = .right
    [iconView, titleLabel, countLabel].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      addSubview($0)
    }
    textField = titleLabel
    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 15),
      iconView.heightAnchor.constraint(equalToConstant: 15),
      titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -5),
      countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
      countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(with entry: ClipboardSidebarEntry) {
    titleLabel.stringValue = entry.title
    countLabel.stringValue = String(entry.count)
    iconView.image = NSImage(systemSymbolName: entry.systemImage, accessibilityDescription: entry.title)
    setAccessibilityLabel("\(entry.title), \(entry.count)")
  }
}

@MainActor
private final class ClipboardHistoryCellView: NSTableCellView {
  private let iconView = NSImageView()
  private let contentLabel = NSTextField(labelWithString: "")
  private let metadataLabel = NSTextField(labelWithString: "")
  private let tagButton = NSButton()
  private let favoriteButton = NSButton()
  private var onEditTags: (() -> Void)?
  private var onTogglePin: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    iconView.contentTintColor = .secondaryLabelColor
    contentLabel.font = .systemFont(ofSize: 13, weight: .medium)
    contentLabel.lineBreakMode = .byTruncatingTail
    metadataLabel.font = .systemFont(ofSize: 10)
    metadataLabel.textColor = .tertiaryLabelColor
    metadataLabel.lineBreakMode = .byTruncatingTail
    tagButton.bezelStyle = .inline
    tagButton.imagePosition = .imageOnly
    tagButton.target = self
    tagButton.action = #selector(editTags)
    favoriteButton.bezelStyle = .inline
    favoriteButton.imagePosition = .imageOnly
    favoriteButton.target = self
    favoriteButton.action = #selector(togglePin)

    [iconView, contentLabel, metadataLabel, tagButton, favoriteButton].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      addSubview($0)
    }
    textField = contentLabel
    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 18),
      iconView.heightAnchor.constraint(equalToConstant: 18),

      contentLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      contentLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
      contentLabel.trailingAnchor.constraint(equalTo: tagButton.leadingAnchor, constant: -8),

      metadataLabel.topAnchor.constraint(equalTo: contentLabel.bottomAnchor, constant: 5),
      metadataLabel.leadingAnchor.constraint(equalTo: contentLabel.leadingAnchor),
      metadataLabel.trailingAnchor.constraint(equalTo: contentLabel.trailingAnchor),

      tagButton.trailingAnchor.constraint(equalTo: favoriteButton.leadingAnchor, constant: -3),
      tagButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      tagButton.widthAnchor.constraint(equalToConstant: 28),
      tagButton.heightAnchor.constraint(equalToConstant: 28),
      favoriteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      favoriteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      favoriteButton.widthAnchor.constraint(equalToConstant: 24),
      favoriteButton.heightAnchor.constraint(equalToConstant: 24),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(
    with item: ClipboardHistoryItem,
    tagNames: [String],
    onEditTags: @escaping () -> Void,
    onTogglePin: @escaping () -> Void
  ) {
    self.onEditTags = onEditTags
    self.onTogglePin = onTogglePin
    // Only the visible prefix is needed; items can be megabytes long.
    let preview = String(item.content.prefix(400))
      .replacingOccurrences(of: "\n", with: "  ")
      .replacingOccurrences(of: "\t", with: " ")
    contentLabel.stringValue = String(preview.prefix(180))
    iconView.image = NSImage(
      systemSymbolName: item.category.systemImage,
      accessibilityDescription: item.category.localizedTitle
    )
    let source = item.sessionName ?? item.sourceName ?? String(localized: "Unknown application")
    let sourceLocation = item.sourceURL.flatMap { URL(string: $0)?.host(percentEncoded: false) }
    let sourceSummary = sourceLocation.map { " · \($0)" } ?? ""
    let permanentSummary = item.isPermanent ? " · \(String(localized: "Permanent"))" : ""
    let tagSummary = tagNames.isEmpty ? "" : " · \(tagNames.joined(separator: ", "))"
    metadataLabel.stringValue = "\(item.category.localizedTitle) · \(source)\(sourceSummary) · \(relativeDate(item.capturedAt))\(permanentSummary)\(tagSummary)"
    let tagLabel = String(localized: "Add Labels…")
    tagButton.image = NSImage(
      systemSymbolName: tagNames.isEmpty ? "tag" : "tag.fill",
      accessibilityDescription: tagLabel
    )
    tagButton.contentTintColor = tagNames.isEmpty ? .secondaryLabelColor : .controlAccentColor
    tagButton.toolTip = tagLabel
    tagButton.setAccessibilityLabel(tagLabel)
    let favoriteLabel = item.isPinned ? String(localized: "Remove Favorite") : String(localized: "Favorite")
    favoriteButton.image = NSImage(
      systemSymbolName: item.isPinned ? "star.fill" : "star",
      accessibilityDescription: favoriteLabel
    )
    favoriteButton.contentTintColor = item.isPinned ? .systemYellow : .secondaryLabelColor
    favoriteButton.toolTip = favoriteLabel
    favoriteButton.setAccessibilityLabel(favoriteLabel)
    setAccessibilityLabel("\(item.category.localizedTitle), \(contentLabel.stringValue)")
  }

  @objc private func editTags() {
    onEditTags?()
  }

  @objc private func togglePin() {
    onTogglePin?()
  }

  private static let relativeDateFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter
  }()

  private func relativeDate(_ date: Date) -> String {
    Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
  }
}

@MainActor
final class ClipboardPaletteHotKey {
  private static let signature: UInt32 = 0x4B4D4456 // KMDV
  private let action: () -> Void
  private var hotKeyRef: EventHotKeyRef?
  private var handlerRef: EventHandlerRef?

  init(action: @escaping () -> Void) {
    self.action = action
  }

  @discardableResult
  func register() -> Bool {
    guard hotKeyRef == nil,
          let target = GetApplicationEventTarget() else { return hotKeyRef != nil }
    let eventTypes = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed)
      ),
    ]
    let installStatus = InstallEventHandler(
      target,
      { _, event, userData in
        guard let event,
              GetEventKind(event) == UInt32(kEventHotKeyPressed),
              let userData else { return OSStatus(eventNotHandledErr) }
        let instance = Unmanaged<ClipboardPaletteHotKey>.fromOpaque(userData).takeUnretainedValue()
        Task { @MainActor in instance.action() }
        return noErr
      },
      eventTypes.count,
      eventTypes,
      Unmanaged.passUnretained(self).toOpaque(),
      &handlerRef
    )
    guard installStatus == noErr else { return false }

    let registrationStatus = RegisterEventHotKey(
      UInt32(kVK_ANSI_V),
      UInt32(controlKey | shiftKey),
      EventHotKeyID(signature: Self.signature, id: 1),
      target,
      0,
      &hotKeyRef
    )
    guard registrationStatus == noErr else {
      if let handlerRef {
        RemoveEventHandler(handlerRef)
        self.handlerRef = nil
      }
      return false
    }
    return true
  }
}
