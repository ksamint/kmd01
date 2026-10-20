// swiftlint:disable file_length
//
//  WorkspaceSidebarView.swift
//  MarkEditMac
//
//  Created by ksamint on 7/27/26.
//

import AppKit
import MarkEditKit
import SharedUI

@MainActor
final class WorkspaceSidebarView: NSView {
  var onModeSelected: ((WorkspaceSidebarMode) -> Void)?
  var onChooseWorkspace: (() -> Void)?
  var onRetryWorkspace: (() -> Void)?
  var onOpenResult: ((URL, Int?) -> Void)?
  var onCreateFile: ((URL) -> Void)?
  var onCreateFolder: ((URL) -> Void)?
  var onRename: ((URL) -> Void)?
  var onMoveToTrash: ((URL) -> Void)?
  var onMove: ((URL, URL) -> Bool)?
  var onTaxonomyAction: ((WorkspaceTaxonomyAction, WorkspaceTaxonomyItem) -> Void)?
  var onResize: ((Double) -> Void)?
  var onPreviewSyncChanged: ((Bool) -> Void)?
  var onVisualEditingChanged: ((Bool) -> Void)?
  var onHeadingSelected: ((HeadingInfo) -> Void)?

  var mode: WorkspaceSidebarMode = .files {
    didSet {
      modeControl.selectedSegment = segment(for: mode)
      documentOutlineContainer.isHidden = mode != .outline
      filesContainer.isHidden = mode != .files
      searchContainer.isHidden = mode != .search
      taxonomyContainer.isHidden = mode != .tags
      previewContainer.isHidden = true
      if mode == .search {
        window?.makeFirstResponder(searchField)
      } else if mode == .tags {
        reloadTaxonomy()
      }
    }
  }

  var session: WorkspaceSession? {
    didSet {
      // Re-binding the same session (sidebar toggles, tab binding, opening a
      // file from the tree) must not reload the tree or re-index the workspace.
      guard session !== oldValue else {
        return
      }

      session?.onFileSystemChange = { [weak self] in
        self?.reloadTree()
        self?.reloadTaxonomy()
      }
      session?.onIndexStateChange = { [weak self] state in
        self?.updateIndexState(state)
      }

      reloadTree()
      reloadTaxonomy()
      updateAuthorizationState()
      session?.rebuildIndex()
    }
  }

  var restorationIssue: WorkspaceAccessIssue? {
    didSet { updateAuthorizationState() }
  }

  private var accessIssue: WorkspaceAccessIssue? {
    restorationIssue ?? session?.accessIssue
  }

  private var fileIconCache = [String: NSImage]()
  private let modeControl = NSSegmentedControl()
  private let documentOutlineContainer = NSView()
  private let documentOutlineView = DocumentOutlineView()
  private let filesContainer = NSView()
  private let searchContainer = NSView()
  private let taxonomyContainer = NSView()
  private let previewContainer = NSView()
  private let previewContentContainer = NSView()
  private let previewSyncButton = NSButton()
  private let previewEditorModeControl = NSSegmentedControl()
  private let rootLabel = NSTextField(labelWithString: "")
  private let authorizationLabel = NSTextField(wrappingLabelWithString: "")
  private let authorizeButton = NSButton()
  private let outlineView = NSOutlineView()
  private let outlineScrollView = NSScrollView()
  private let addButton = NSButton()
  private let refreshButton = NSButton()
  private let searchField = NSSearchField()
  private let searchModeControl = NSSegmentedControl()
  private let searchTableView = NSTableView()
  private let searchScrollView = NSScrollView()
  private let searchStatusLabel = NSTextField(labelWithString: "")
  private let deepSearchDownloadButton = NSButton()
  private let taxonomyModeControl = NSSegmentedControl()
  private let taxonomySearchField = NSSearchField()
  private let taxonomyTableView = NSTableView()
  private let taxonomyScrollView = NSScrollView()
  private let taxonomyStatusLabel = NSTextField(labelWithString: "")
  private let taxonomyActionsButton = NSButton()
  private let resizeHandle = WorkspaceResizeHandle()

  private var rootNode: WorkspaceTreeNode?
  private var searchResults = [WorkspaceSearchResult]()
  private var searchTask: Task<Void, Never>?
  private var taxonomyTags = [WorkspaceTagSummary]()
  private var taxonomyCategories = [WorkspaceCategorySummary]()
  private var taxonomyItems = [WorkspaceTaxonomyItem]()
  private var taxonomyTask: Task<Void, Never>?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setUp()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    searchTask?.cancel()
    taxonomyTask?.cancel()
  }

  func reloadTree() {
    rootNode = session.map { WorkspaceTreeNode(url: $0.rootURL) }
    rootLabel.stringValue = session?.rootURL.lastPathComponent ?? Localized.Workspace.noFolder
    rootLabel.toolTip = session?.rootURL.path
    outlineView.reloadData()
  }

  func focusSearch() {
    window?.makeFirstResponder(searchField)
  }

  func showSearch(query: String) {
    mode = .search
    searchModeControl.selectedSegment = 0
    searchField.stringValue = query
    search(searchField)
    focusSearch()
  }

  func reloadTaxonomy() {
    taxonomyTask?.cancel()
    taxonomyStatusLabel.stringValue = Localized.Workspace.loadingMetadata
    taxonomyTask = Task { [weak self] in
      guard let self else {
        return
      }
      guard let session = self.session else {
        self.taxonomyTags = []
        self.taxonomyCategories = []
        self.updateTaxonomyItems()
        return
      }

      let (tags, categories) = await session.taxonomy()
      guard !Task.isCancelled else {
        return
      }
      self.taxonomyTags = tags
      self.taxonomyCategories = categories
      self.updateTaxonomyItems()
    }
  }

  func setPreviewView(_ previewView: NSView) {
    previewContentContainer.subviews.forEach { $0.removeFromSuperview() }
    previewView.translatesAutoresizingMaskIntoConstraints = false
    previewContentContainer.addSubview(previewView)
    NSLayoutConstraint.activate([
      previewView.topAnchor.constraint(equalTo: previewContentContainer.topAnchor),
      previewView.leadingAnchor.constraint(equalTo: previewContentContainer.leadingAnchor),
      previewView.trailingAnchor.constraint(equalTo: previewContentContainer.trailingAnchor),
      previewView.bottomAnchor.constraint(equalTo: previewContentContainer.bottomAnchor),
    ])
  }

  func setPreviewSyncEnabled(_ enabled: Bool) {
    previewSyncButton.state = enabled ? .on : .off
  }

  func setVisualEditingEnabled(_ enabled: Bool) {
    previewEditorModeControl.selectedSegment = enabled ? 1 : 0
  }

  func updateDocumentOutline(_ headings: [HeadingInfo]) {
    documentOutlineView.update(headings: headings)
  }
}

// MARK: - Setup

private extension WorkspaceSidebarView {
  func setUp() {
    wantsLayer = true
    layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

    modeControl.segmentCount = 4
    setModeSegment(0, symbol: "list.bullet.indent", accessibilityDescription: Localized.Toolbar.tableOfContents)
    setModeSegment(
      1,
      symbol: "folder",
      accessibilityDescription: Localized.Workspace.files
    )
    setModeSegment(
      2,
      symbol: "magnifyingglass",
      accessibilityDescription: Localized.Workspace.search
    )
    setModeSegment(
      3,
      symbol: "tag",
      accessibilityDescription: Localized.Workspace.tags
    )
    modeControl.segmentStyle = .texturedRounded
    modeControl.trackingMode = .selectOne
    modeControl.selectedSegment = 0
    modeControl.target = self
    modeControl.action = #selector(selectMode(_:))

    rootLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    rootLabel.lineBreakMode = .byTruncatingMiddle
    rootLabel.toolTip = session?.rootURL.path

    configureOutlineView()
    configureSearchView()
    configureTaxonomyView()
    configurePreviewView()
    configureAuthorizationView()
    documentOutlineView.onSelect = { [weak self] heading in
      self?.onHeadingSelected?(heading)
    }

    addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: Localized.Workspace.newFile)
    addButton.bezelStyle = .accessoryBarAction
    addButton.target = self
    addButton.action = #selector(showAddMenu(_:))

    refreshButton.image = NSImage(
      systemSymbolName: "arrow.clockwise",
      accessibilityDescription: Localized.Workspace.refresh
    )
    refreshButton.bezelStyle = .accessoryBarAction
    refreshButton.target = self
    refreshButton.action = #selector(refresh(_:))

    resizeHandle.onDrag = { [weak self] delta in
      self?.onResize?(delta)
    }

    [
      modeControl,
      documentOutlineContainer,
      filesContainer,
      searchContainer,
      taxonomyContainer,
      previewContainer,
      resizeHandle,
    ].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      addSubview($0)
    }
    documentOutlineView.translatesAutoresizingMaskIntoConstraints = false
    documentOutlineContainer.addSubview(documentOutlineView)
    [rootLabel, outlineScrollView, authorizationLabel, authorizeButton, addButton, refreshButton].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      filesContainer.addSubview($0)
    }
    [searchModeControl, searchField, searchScrollView, searchStatusLabel, deepSearchDownloadButton].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      searchContainer.addSubview($0)
    }
    [
      taxonomyModeControl,
      taxonomySearchField,
      taxonomyScrollView,
      taxonomyStatusLabel,
      taxonomyActionsButton,
    ].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      taxonomyContainer.addSubview($0)
    }
    [previewSyncButton, previewEditorModeControl, previewContentContainer].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      previewContainer.addSubview($0)
    }

    NSLayoutConstraint.activate([
      modeControl.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      modeControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      modeControl.trailingAnchor.constraint(equalTo: resizeHandle.leadingAnchor, constant: -8),

      filesContainer.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 6),
      filesContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
      filesContainer.trailingAnchor.constraint(equalTo: resizeHandle.leadingAnchor),
      filesContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

      documentOutlineContainer.topAnchor.constraint(equalTo: filesContainer.topAnchor),
      documentOutlineContainer.leadingAnchor.constraint(equalTo: filesContainer.leadingAnchor),
      documentOutlineContainer.trailingAnchor.constraint(equalTo: filesContainer.trailingAnchor),
      documentOutlineContainer.bottomAnchor.constraint(equalTo: filesContainer.bottomAnchor),
      documentOutlineView.topAnchor.constraint(equalTo: documentOutlineContainer.topAnchor),
      documentOutlineView.leadingAnchor.constraint(equalTo: documentOutlineContainer.leadingAnchor),
      documentOutlineView.trailingAnchor.constraint(equalTo: documentOutlineContainer.trailingAnchor),
      documentOutlineView.bottomAnchor.constraint(equalTo: documentOutlineContainer.bottomAnchor),

      searchContainer.topAnchor.constraint(equalTo: filesContainer.topAnchor),
      searchContainer.leadingAnchor.constraint(equalTo: filesContainer.leadingAnchor),
      searchContainer.trailingAnchor.constraint(equalTo: filesContainer.trailingAnchor),
      searchContainer.bottomAnchor.constraint(equalTo: filesContainer.bottomAnchor),

      taxonomyContainer.topAnchor.constraint(equalTo: filesContainer.topAnchor),
      taxonomyContainer.leadingAnchor.constraint(equalTo: filesContainer.leadingAnchor),
      taxonomyContainer.trailingAnchor.constraint(equalTo: filesContainer.trailingAnchor),
      taxonomyContainer.bottomAnchor.constraint(equalTo: filesContainer.bottomAnchor),

      previewContainer.topAnchor.constraint(equalTo: filesContainer.topAnchor),
      previewContainer.leadingAnchor.constraint(equalTo: filesContainer.leadingAnchor),
      previewContainer.trailingAnchor.constraint(equalTo: filesContainer.trailingAnchor),
      previewContainer.bottomAnchor.constraint(equalTo: filesContainer.bottomAnchor),

      resizeHandle.topAnchor.constraint(equalTo: topAnchor),
      resizeHandle.trailingAnchor.constraint(equalTo: trailingAnchor),
      resizeHandle.bottomAnchor.constraint(equalTo: bottomAnchor),
      resizeHandle.widthAnchor.constraint(equalToConstant: 5),

      rootLabel.topAnchor.constraint(equalTo: filesContainer.topAnchor, constant: 6),
      rootLabel.leadingAnchor.constraint(equalTo: filesContainer.leadingAnchor, constant: 10),
      rootLabel.trailingAnchor.constraint(equalTo: filesContainer.trailingAnchor, constant: -10),

      outlineScrollView.topAnchor.constraint(equalTo: rootLabel.bottomAnchor, constant: 5),
      outlineScrollView.leadingAnchor.constraint(equalTo: filesContainer.leadingAnchor),
      outlineScrollView.trailingAnchor.constraint(equalTo: filesContainer.trailingAnchor),
      outlineScrollView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -5),

      authorizationLabel.centerYAnchor.constraint(equalTo: outlineScrollView.centerYAnchor, constant: -18),
      authorizationLabel.leadingAnchor.constraint(equalTo: filesContainer.leadingAnchor, constant: 22),
      authorizationLabel.trailingAnchor.constraint(equalTo: filesContainer.trailingAnchor, constant: -22),
      authorizeButton.topAnchor.constraint(equalTo: authorizationLabel.bottomAnchor, constant: 10),
      authorizeButton.centerXAnchor.constraint(equalTo: filesContainer.centerXAnchor),

      addButton.leadingAnchor.constraint(equalTo: filesContainer.leadingAnchor, constant: 8),
      addButton.bottomAnchor.constraint(equalTo: filesContainer.bottomAnchor, constant: -5),
      refreshButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 4),
      refreshButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),

      searchModeControl.topAnchor.constraint(equalTo: searchContainer.topAnchor, constant: 6),
      searchModeControl.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 8),
      searchModeControl.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -8),
      searchField.topAnchor.constraint(equalTo: searchModeControl.bottomAnchor, constant: 6),
      searchField.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 8),
      searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -8),
      searchScrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
      searchScrollView.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor),
      searchScrollView.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor),
      searchScrollView.bottomAnchor.constraint(equalTo: searchStatusLabel.topAnchor, constant: -4),
      searchStatusLabel.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 10),
      searchStatusLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: deepSearchDownloadButton.leadingAnchor,
        constant: -6
      ),
      searchStatusLabel.bottomAnchor.constraint(equalTo: searchContainer.bottomAnchor, constant: -7),
      deepSearchDownloadButton.trailingAnchor.constraint(
        equalTo: searchContainer.trailingAnchor,
        constant: -8
      ),
      deepSearchDownloadButton.centerYAnchor.constraint(equalTo: searchStatusLabel.centerYAnchor),

      taxonomyModeControl.topAnchor.constraint(equalTo: taxonomyContainer.topAnchor, constant: 6),
      taxonomyModeControl.leadingAnchor.constraint(equalTo: taxonomyContainer.leadingAnchor, constant: 8),
      taxonomyModeControl.trailingAnchor.constraint(equalTo: taxonomyContainer.trailingAnchor, constant: -8),
      taxonomySearchField.topAnchor.constraint(equalTo: taxonomyModeControl.bottomAnchor, constant: 6),
      taxonomySearchField.leadingAnchor.constraint(equalTo: taxonomyContainer.leadingAnchor, constant: 8),
      taxonomySearchField.trailingAnchor.constraint(equalTo: taxonomyContainer.trailingAnchor, constant: -8),
      taxonomyScrollView.topAnchor.constraint(equalTo: taxonomySearchField.bottomAnchor, constant: 6),
      taxonomyScrollView.leadingAnchor.constraint(equalTo: taxonomyContainer.leadingAnchor),
      taxonomyScrollView.trailingAnchor.constraint(equalTo: taxonomyContainer.trailingAnchor),
      taxonomyScrollView.bottomAnchor.constraint(equalTo: taxonomyActionsButton.topAnchor, constant: -5),
      taxonomyActionsButton.leadingAnchor.constraint(equalTo: taxonomyContainer.leadingAnchor, constant: 8),
      taxonomyActionsButton.bottomAnchor.constraint(equalTo: taxonomyContainer.bottomAnchor, constant: -5),
      taxonomyStatusLabel.leadingAnchor.constraint(equalTo: taxonomyActionsButton.trailingAnchor, constant: 8),
      taxonomyStatusLabel.trailingAnchor.constraint(equalTo: taxonomyContainer.trailingAnchor, constant: -10),
      taxonomyStatusLabel.centerYAnchor.constraint(equalTo: taxonomyActionsButton.centerYAnchor),

      previewSyncButton.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 5),
      previewSyncButton.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 8),
      previewSyncButton.trailingAnchor.constraint(lessThanOrEqualTo: previewContainer.trailingAnchor, constant: -8),
      previewEditorModeControl.topAnchor.constraint(equalTo: previewSyncButton.bottomAnchor, constant: 5),
      previewEditorModeControl.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 8),
      previewEditorModeControl.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -8),
      previewContentContainer.topAnchor.constraint(equalTo: previewEditorModeControl.bottomAnchor, constant: 6),
      previewContentContainer.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
      previewContentContainer.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
      previewContentContainer.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
    ])

    searchContainer.isHidden = true
    taxonomyContainer.isHidden = true
    previewContainer.isHidden = true
    documentOutlineContainer.isHidden = mode != .outline
    updateAuthorizationState()
  }

  func segment(for mode: WorkspaceSidebarMode) -> Int {
    switch mode {
    case .outline: return 0
    case .files: return 1
    case .search: return 2
    case .tags: return 3
    case .preview: return 0
    }
  }

  func mode(for segment: Int) -> WorkspaceSidebarMode? {
    switch segment {
    case 0: return .outline
    case 1: return .files
    case 2: return .search
    case 3: return .tags
    default: return nil
    }
  }

  func setModeSegment(
    _ segment: Int,
    symbol: String,
    accessibilityDescription: String
  ) {
    modeControl.setImage(
      NSImage(
        systemSymbolName: symbol,
        accessibilityDescription: accessibilityDescription
      ),
      forSegment: segment
    )
    modeControl.setToolTip(accessibilityDescription, forSegment: segment)
  }

  func configureOutlineView() {
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("WorkspaceFile"))
    column.resizingMask = .autoresizingMask
    outlineView.addTableColumn(column)
    outlineView.outlineTableColumn = column
    outlineView.headerView = nil
    outlineView.rowSizeStyle = .default
    outlineView.delegate = self
    outlineView.dataSource = self
    outlineView.target = self
    outlineView.doubleAction = #selector(openSelectedFile(_:))
    outlineView.registerForDraggedTypes([.workspaceFileURL])
    outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
    outlineView.menu = makeContextMenu()

    outlineScrollView.documentView = outlineView
    outlineScrollView.hasVerticalScroller = true
    outlineScrollView.drawsBackground = false
  }

  func configureSearchView() {
    searchModeControl.segmentCount = 2
    searchModeControl.setLabel(Localized.Workspace.fullTextSearch, forSegment: 0)
    searchModeControl.setLabel(Localized.Workspace.deepSearch, forSegment: 1)
    searchModeControl.segmentStyle = .texturedRounded
    searchModeControl.trackingMode = .selectOne
    searchModeControl.selectedSegment = 0
    searchModeControl.target = self
    searchModeControl.action = #selector(selectSearchMode(_:))

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("WorkspaceSearchResult"))
    column.resizingMask = .autoresizingMask
    searchTableView.addTableColumn(column)
    searchTableView.headerView = nil
    searchTableView.rowHeight = 44
    searchTableView.delegate = self
    searchTableView.dataSource = self
    searchTableView.target = self
    searchTableView.doubleAction = #selector(openSelectedSearchResult(_:))

    searchScrollView.documentView = searchTableView
    searchScrollView.hasVerticalScroller = true
    searchScrollView.drawsBackground = false

    searchField.placeholderString = Localized.Workspace.searchPlaceholder
    searchField.sendsSearchStringImmediately = true
    searchField.target = self
    searchField.action = #selector(search(_:))

    searchStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    searchStatusLabel.textColor = .secondaryLabelColor
    searchStatusLabel.lineBreakMode = .byTruncatingTail
    searchStatusLabel.stringValue = Localized.Workspace.indexing

    deepSearchDownloadButton.title = Localized.Workspace.downloadModel
    deepSearchDownloadButton.bezelStyle = .accessoryBarAction
    deepSearchDownloadButton.target = self
    deepSearchDownloadButton.action = #selector(downloadDeepSearchModel(_:))
    deepSearchDownloadButton.isHidden = true
  }

  func configureTaxonomyView() {
    taxonomyModeControl.segmentCount = 2
    taxonomyModeControl.setLabel(Localized.Workspace.tags, forSegment: 0)
    taxonomyModeControl.setLabel(Localized.Workspace.categories, forSegment: 1)
    taxonomyModeControl.segmentStyle = .texturedRounded
    taxonomyModeControl.trackingMode = .selectOne
    taxonomyModeControl.selectedSegment = 0
    taxonomyModeControl.target = self
    taxonomyModeControl.action = #selector(selectTaxonomyMode(_:))

    taxonomySearchField.placeholderString = Localized.Workspace.filterMetadata
    taxonomySearchField.sendsSearchStringImmediately = true
    taxonomySearchField.target = self
    taxonomySearchField.action = #selector(filterTaxonomy(_:))

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("WorkspaceTaxonomy"))
    column.resizingMask = .autoresizingMask
    taxonomyTableView.addTableColumn(column)
    taxonomyTableView.headerView = nil
    taxonomyTableView.rowHeight = 28
    taxonomyTableView.delegate = self
    taxonomyTableView.dataSource = self
    taxonomyTableView.target = self
    taxonomyTableView.doubleAction = #selector(openSelectedTaxonomy(_:))

    taxonomyScrollView.documentView = taxonomyTableView
    taxonomyScrollView.hasVerticalScroller = true
    taxonomyScrollView.drawsBackground = false

    taxonomyActionsButton.title = Localized.Workspace.manage
    taxonomyActionsButton.image = NSImage(
      systemSymbolName: "ellipsis.circle",
      accessibilityDescription: Localized.Workspace.manage
    )
    taxonomyActionsButton.imagePosition = .imageLeading
    taxonomyActionsButton.bezelStyle = .accessoryBarAction
    taxonomyActionsButton.target = self
    taxonomyActionsButton.action = #selector(showTaxonomyActions(_:))

    taxonomyStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    taxonomyStatusLabel.textColor = .secondaryLabelColor
    taxonomyStatusLabel.alignment = .right
  }

  func configureAuthorizationView() {
    authorizationLabel.alignment = .center
    authorizationLabel.textColor = .secondaryLabelColor
    authorizeButton.bezelStyle = .rounded
    authorizeButton.target = self
    authorizeButton.action = #selector(chooseWorkspace(_:))
  }

  func configurePreviewView() {
    previewSyncButton.setButtonType(.switch)
    previewSyncButton.title = Localized.Workspace.syncPreview
    previewSyncButton.state = AppPreferences.Window.workspacePreviewSync ? .on : .off
    previewSyncButton.target = self
    previewSyncButton.action = #selector(togglePreviewSync(_:))

    previewEditorModeControl.segmentCount = 2
    previewEditorModeControl.setLabel(Localized.Workspace.sourceEditing, forSegment: 0)
    previewEditorModeControl.setLabel(Localized.Workspace.visualEditing, forSegment: 1)
    previewEditorModeControl.segmentStyle = .texturedRounded
    previewEditorModeControl.trackingMode = .selectOne
    previewEditorModeControl.selectedSegment = AppPreferences.Editor.visualEditingMode ? 1 : 0
    previewEditorModeControl.target = self
    previewEditorModeControl.action = #selector(selectEditorMode(_:))
  }

  func updateAuthorizationState() {
    let hasSession = session != nil
    let isAuthorized = session?.isAuthorized == true && accessIssue == nil

    authorizationLabel.stringValue = accessIssue.map(Localized.Workspace.accessIssue)
      ?? Localized.Workspace.noFolderDescription
    authorizeButton.title = accessIssue == .permissionRequired
      ? Localized.Workspace.reauthorize
      : accessIssue != nil ? Localized.Workspace.retryAccess : Localized.Workspace.openFolder
    authorizeButton.action = accessIssue != nil && accessIssue != .permissionRequired
      ? #selector(retryWorkspace(_:)) : #selector(chooseWorkspace(_:))
    if let accessIssue {
      searchStatusLabel.stringValue = Localized.Workspace.accessIssue(accessIssue)
      taxonomyStatusLabel.stringValue = Localized.Workspace.accessIssue(accessIssue)
    } else if !hasSession {
      searchStatusLabel.stringValue = ""
    }

    authorizationLabel.isHidden = isAuthorized
    authorizeButton.isHidden = isAuthorized
    outlineScrollView.isHidden = !isAuthorized
    addButton.isEnabled = isAuthorized
    refreshButton.isEnabled = isAuthorized
    searchField.isEnabled = isAuthorized
    taxonomyModeControl.isEnabled = isAuthorized
    taxonomySearchField.isEnabled = isAuthorized
    taxonomyActionsButton.isEnabled = isAuthorized
  }

  func updateIndexState(_ state: WorkspaceIndexState) {
    updateAuthorizationState()
    guard accessIssue == nil else { return }
    switch state {
    case .idle:
      searchStatusLabel.stringValue = ""
    case .indexing:
      searchStatusLabel.stringValue = Localized.Workspace.indexing
    case let .ready(fileCount):
      searchStatusLabel.stringValue = String(
        format: Localized.Workspace.indexedFilesFormat,
        fileCount
      )
      reloadTaxonomy()
    case .failed:
      searchStatusLabel.stringValue = Localized.Workspace.indexFailed
    }
  }

  func updateTaxonomyItems() {
    let filter = taxonomySearchField.stringValue.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let allItems: [WorkspaceTaxonomyItem] = taxonomyModeControl.selectedSegment == 0
      ? taxonomyTags.map(WorkspaceTaxonomyItem.tag)
      : taxonomyCategories.map(WorkspaceTaxonomyItem.category)
    taxonomyItems = filter.isEmpty
      ? allItems
      : allItems.filter {
        $0.displayName.localizedCaseInsensitiveContains(filter)
      }
    taxonomyTableView.reloadData()
    taxonomyStatusLabel.stringValue = accessIssue.map(Localized.Workspace.accessIssue) ?? String(
      format: Localized.Workspace.metadataCountFormat,
      taxonomyItems.count
    )
  }

  func selectedDirectory() -> URL? {
    guard let selectedNode = outlineView.item(atRow: outlineView.selectedRow) as? WorkspaceTreeNode else {
      return session?.rootURL
    }

    return selectedNode.isDirectory ? selectedNode.url : selectedNode.url.deletingLastPathComponent()
  }

  func makeContextMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(withTitle: Localized.Workspace.open, action: #selector(openSelectedFile(_:)), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: Localized.Workspace.newFile, action: #selector(createFile(_:)), keyEquivalent: "")
    menu.addItem(withTitle: Localized.Workspace.newFolder, action: #selector(createFolder(_:)), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: Localized.Workspace.rename, action: #selector(rename(_:)), keyEquivalent: "")
    menu.addItem(withTitle: Localized.Workspace.moveToTrash, action: #selector(moveToTrash(_:)), keyEquivalent: "")
    menu.items.forEach { $0.target = self }
    return menu
  }
}

// MARK: - Actions

private extension WorkspaceSidebarView {
  @objc func selectMode(_ sender: NSSegmentedControl) {
    guard let mode = mode(for: sender.selectedSegment) else {
      return
    }
    onModeSelected?(mode)
  }

  @objc func togglePreviewSync(_ sender: NSButton) {
    onPreviewSyncChanged?(sender.state == .on)
  }

  @objc func selectEditorMode(_ sender: NSSegmentedControl) {
    onVisualEditingChanged?(sender.selectedSegment == 1)
  }

  @objc func chooseWorkspace(_ sender: Any?) {
    onChooseWorkspace?()
  }

  @objc func retryWorkspace(_ sender: Any?) {
    onRetryWorkspace?()
  }

  @objc func refresh(_ sender: Any?) {
    reloadTree()
    session?.rebuildIndex()
  }

  @objc func showAddMenu(_ sender: NSButton) {
    let menu = NSMenu()
    menu.addItem(withTitle: Localized.Workspace.newFile, action: #selector(createFile(_:)), keyEquivalent: "")
    menu.addItem(withTitle: Localized.Workspace.newFolder, action: #selector(createFolder(_:)), keyEquivalent: "")
    menu.items.forEach { $0.target = self }
    menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY), in: sender)
  }

  @objc func createFile(_ sender: Any?) {
    guard let directory = selectedDirectory() else {
      return
    }
    onCreateFile?(directory)
  }

  @objc func createFolder(_ sender: Any?) {
    guard let directory = selectedDirectory() else {
      return
    }
    onCreateFolder?(directory)
  }

  @objc func rename(_ sender: Any?) {
    guard let node = outlineView.item(atRow: outlineView.selectedRow) as? WorkspaceTreeNode else {
      return
    }
    onRename?(node.url)
  }

  @objc func moveToTrash(_ sender: Any?) {
    guard let node = outlineView.item(atRow: outlineView.selectedRow) as? WorkspaceTreeNode else {
      return
    }
    onMoveToTrash?(node.url)
  }

  @objc func openSelectedFile(_ sender: Any?) {
    guard let node = outlineView.item(atRow: outlineView.selectedRow) as? WorkspaceTreeNode else {
      return
    }

    if node.isDirectory && !node.isSymbolicLink {
      if outlineView.isItemExpanded(node) {
        outlineView.collapseItem(node)
      } else {
        outlineView.expandItem(node)
      }
    } else {
      onOpenResult?(node.url, nil)
    }
  }

  @objc func search(_ sender: NSSearchField) {
    searchTask?.cancel()
    let query = sender.stringValue
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      searchResults = []
      searchTableView.reloadData()
      return
    }

    searchStatusLabel.stringValue = Localized.Workspace.searching
    searchTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(120))
      guard let self, !Task.isCancelled, let session = self.session else {
        return
      }

      let results: [WorkspaceSearchResult]
      if searchModeControl.selectedSegment == 1 {
        do {
          results = try await session.deepSearch(query)
          deepSearchDownloadButton.isHidden = true
        } catch WorkspaceDeepSearchError.modelNotInstalled {
          searchResults = []
          searchTableView.reloadData()
          searchStatusLabel.stringValue = Localized.Workspace.modelNotDownloaded
          deepSearchDownloadButton.isHidden = false
          return
        } catch {
          searchResults = []
          searchTableView.reloadData()
          searchStatusLabel.stringValue = Localized.Workspace.deepSearchFailed
          return
        }
      } else {
        results = await session.search(query)
        deepSearchDownloadButton.isHidden = true
      }
      guard !Task.isCancelled else {
        return
      }

      searchResults = results
      searchTableView.reloadData()
      searchStatusLabel.stringValue = String(
        format: Localized.Workspace.resultCountFormat,
        results.count
      )
    }
  }

  @objc func selectSearchMode(_ sender: NSSegmentedControl) {
    deepSearchDownloadButton.isHidden = true
    if sender.selectedSegment == 1,
       searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       let session {
      searchTask?.cancel()
      searchTask = Task { [weak self] in
        guard let self else {
          return
        }
        let state = await session.deepSearchState()
        if state == .modelNotInstalled {
          searchStatusLabel.stringValue = Localized.Workspace.modelNotDownloaded
          deepSearchDownloadButton.isHidden = false
        } else {
          searchStatusLabel.stringValue = Localized.Workspace.preparingDeepSearch
        }
      }
      return
    }
    search(searchField)
  }

  @objc func downloadDeepSearchModel(_ sender: NSButton) {
    guard let session else {
      return
    }
    sender.isEnabled = false
    searchStatusLabel.stringValue = Localized.Workspace.preparingDeepSearch
    searchTask?.cancel()
    searchTask = Task { [weak self] in
      guard let self else {
        return
      }
      do {
        try await session.installAndIndexDeepSearch()
        guard !Task.isCancelled else {
          return
        }
        sender.isEnabled = true
        sender.isHidden = true
        search(searchField)
      } catch {
        sender.isEnabled = true
        sender.isHidden = false
        searchStatusLabel.stringValue = Localized.Workspace.deepSearchFailed
      }
    }
  }

  @objc func selectTaxonomyMode(_ sender: NSSegmentedControl) {
    updateTaxonomyItems()
  }

  @objc func filterTaxonomy(_ sender: NSSearchField) {
    updateTaxonomyItems()
  }

  @objc func openSelectedTaxonomy(_ sender: Any?) {
    guard let item = selectedTaxonomyItem() else {
      return
    }

    switch item {
    case let .tag(tag):
      searchField.stringValue = "tag:\"\(tag.displayName)\""
    case let .category(category):
      searchField.stringValue = "category:\"\(category.path)\""
    }
    onModeSelected?(.search)
    search(searchField)
  }

  @objc func showTaxonomyActions(_ sender: NSButton) {
    guard selectedTaxonomyItem() != nil else {
      NSSound.beep()
      return
    }

    let menu = NSMenu()
    menu.addItem(
      withTitle: Localized.Workspace.rename,
      action: #selector(renameTaxonomy(_:)),
      keyEquivalent: ""
    )
    if case .tag? = selectedTaxonomyItem() {
      menu.addItem(
        withTitle: Localized.Workspace.mergeTag,
        action: #selector(mergeTaxonomy(_:)),
        keyEquivalent: ""
      )
    }
    menu.addItem(.separator())
    menu.addItem(
      withTitle: Localized.Workspace.deleteMetadata,
      action: #selector(deleteTaxonomy(_:)),
      keyEquivalent: ""
    )
    menu.items.forEach { $0.target = self }
    menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY), in: sender)
  }

  @objc func renameTaxonomy(_ sender: Any?) {
    performTaxonomyAction(.rename)
  }

  @objc func mergeTaxonomy(_ sender: Any?) {
    performTaxonomyAction(.merge)
  }

  @objc func deleteTaxonomy(_ sender: Any?) {
    performTaxonomyAction(.delete)
  }

  func performTaxonomyAction(_ action: WorkspaceTaxonomyAction) {
    guard let item = selectedTaxonomyItem() else {
      return
    }
    onTaxonomyAction?(action, item)
  }

  func selectedTaxonomyItem() -> WorkspaceTaxonomyItem? {
    let row = taxonomyTableView.selectedRow
    return taxonomyItems.indices.contains(row) ? taxonomyItems[row] : nil
  }

  @objc func openSelectedSearchResult(_ sender: Any?) {
    let row = searchTableView.selectedRow
    guard searchResults.indices.contains(row) else {
      return
    }

    let result = searchResults[row]
    onOpenResult?(result.url, result.lineNumber)
  }
}

// MARK: - Outline View

extension WorkspaceSidebarView: NSOutlineViewDataSource, NSOutlineViewDelegate {
  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    if let node = item as? WorkspaceTreeNode {
      return node.children(showHiddenFiles: AppPreferences.General.showHiddenFiles).count
    }

    let children = rootNode?.children(showHiddenFiles: AppPreferences.General.showHiddenFiles) ?? []
    if let error = rootNode?.accessError {
      session?.recordAccessFailure(error)
    }
    return children.count
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    let children = (item as? WorkspaceTreeNode)?.children(
      showHiddenFiles: AppPreferences.General.showHiddenFiles
    ) ?? rootNode?.children(showHiddenFiles: AppPreferences.General.showHiddenFiles) ?? []
    return children[index]
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    guard let node = item as? WorkspaceTreeNode else {
      return false
    }
    return node.isDirectory && !node.isSymbolicLink
  }

  func outlineView(
    _ outlineView: NSOutlineView,
    viewFor tableColumn: NSTableColumn?,
    item: Any
  ) -> NSView? {
    guard let node = item as? WorkspaceTreeNode else {
      return nil
    }

    let identifier = NSUserInterfaceItemIdentifier("WorkspaceFileCell")
    let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
      ?? makeFileCell(identifier: identifier)

    cell.textField?.stringValue = node.url.lastPathComponent
    cell.imageView?.image = fileIcon(for: node)
    cell.toolTip = node.url.path
    return cell
  }

  /// `NSWorkspace.icon(forFile:)` is a LaunchServices lookup per call; rows
  /// are re-created on every tree reload, so cache by kind and extension.
  private func fileIcon(for node: WorkspaceTreeNode) -> NSImage {
    let key = node.isDirectory ? "\u{0}directory" : node.url.pathExtension.lowercased()
    if let cached = fileIconCache[key] {
      return cached
    }
    let icon = NSWorkspace.shared.icon(forFile: node.url.path)
    fileIconCache[key] = icon
    return icon
  }

  func outlineView(
    _ outlineView: NSOutlineView,
    pasteboardWriterForItem item: Any
  ) -> NSPasteboardWriting? {
    guard let node = item as? WorkspaceTreeNode else {
      return nil
    }

    let item = NSPasteboardItem()
    item.setString(node.url.path, forType: .workspaceFileURL)
    return item
  }

  func outlineView(
    _ outlineView: NSOutlineView,
    validateDrop info: NSDraggingInfo,
    proposedItem item: Any?,
    proposedChildIndex index: Int
  ) -> NSDragOperation {
    guard let node = item as? WorkspaceTreeNode, node.isDirectory, !node.isSymbolicLink else {
      return []
    }
    return .move
  }

  func outlineView(
    _ outlineView: NSOutlineView,
    acceptDrop info: NSDraggingInfo,
    item: Any?,
    childIndex index: Int
  ) -> Bool {
    guard let target = item as? WorkspaceTreeNode,
          let path = info.draggingPasteboard.string(forType: .workspaceFileURL) else {
      return false
    }

    let sourceURL = URL(filePath: path)
    let moved = onMove?(sourceURL, target.url) == true
    if moved {
      reloadTree()
    }
    return moved
  }

  private func makeFileCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = identifier

    let imageView = NSImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.imageScaling = .scaleProportionallyDown
    cell.imageView = imageView
    cell.addSubview(imageView)

    let label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.lineBreakMode = .byTruncatingMiddle
    cell.textField = label
    cell.addSubview(label)

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
      imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      imageView.widthAnchor.constraint(equalToConstant: 16),
      imageView.heightAnchor.constraint(equalToConstant: 16),
      label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 5),
      label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }
}

// MARK: - Search Results

extension WorkspaceSidebarView: NSTableViewDataSource, NSTableViewDelegate {
  func numberOfRows(in tableView: NSTableView) -> Int {
    tableView === taxonomyTableView ? taxonomyItems.count : searchResults.count
  }

  func tableView(
    _ tableView: NSTableView,
    viewFor tableColumn: NSTableColumn?,
    row: Int
  ) -> NSView? {
    if tableView === taxonomyTableView {
      return taxonomyCell(tableView: tableView, row: row)
    }

    guard searchResults.indices.contains(row) else {
      return nil
    }

    let identifier = NSUserInterfaceItemIdentifier("WorkspaceSearchCell")
    let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
      ?? makeSearchCell(identifier: identifier)
    let result = searchResults[row]

    cell.textField?.stringValue = "\(result.relativePath):\(result.lineNumber)\n\(result.snippet)"
    cell.toolTip = result.url.path
    return cell
  }

  private func taxonomyCell(tableView: NSTableView, row: Int) -> NSView? {
    guard taxonomyItems.indices.contains(row) else {
      return nil
    }

    let identifier = NSUserInterfaceItemIdentifier("WorkspaceTaxonomyCell")
    let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
      ?? makeTaxonomyCell(identifier: identifier)
    let item = taxonomyItems[row]
    cell.textField?.stringValue = item.displayName
    cell.imageView?.image = NSImage(
      systemSymbolName: {
        if case .tag = item {
          return "tag"
        }
        return "folder"
      }(),
      accessibilityDescription: item.displayName
    )
    cell.objectValue = item.fileCount
    (cell.subviews.compactMap { $0 as? WorkspaceCountLabel }.first)?.stringValue = "\(item.fileCount)"
    cell.toolTip = String(
      format: Localized.Workspace.filesUsingMetadataFormat,
      item.fileCount
    )
    return cell
  }

  private func makeTaxonomyCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = identifier

    let imageView = NSImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.imageScaling = .scaleProportionallyDown
    cell.imageView = imageView
    cell.addSubview(imageView)

    let label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.lineBreakMode = .byTruncatingMiddle
    cell.textField = label
    cell.addSubview(label)

    let countLabel = WorkspaceCountLabel(labelWithString: "")
    countLabel.translatesAutoresizingMaskIntoConstraints = false
    countLabel.font = .monospacedDigitSystemFont(
      ofSize: NSFont.smallSystemFontSize,
      weight: .regular
    )
    countLabel.textColor = .secondaryLabelColor
    countLabel.alignment = .right
    cell.addSubview(countLabel)

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7),
      imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      imageView.widthAnchor.constraint(equalToConstant: 15),
      imageView.heightAnchor.constraint(equalToConstant: 15),
      label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
      label.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -6),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      countLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
      countLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 26),
    ])
    return cell
  }

  private func makeSearchCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = identifier

    let label = NSTextField(wrappingLabelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.maximumNumberOfLines = 2
    label.lineBreakMode = .byTruncatingTail
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    cell.textField = label
    cell.addSubview(label)

    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7),
      label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -7),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }
}

private final class WorkspaceResizeHandle: NSView {
  var onDrag: ((Double) -> Void)?
  private var previousX: Double?

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .resizeLeftRight)
  }

  override func mouseDown(with event: NSEvent) {
    previousX = event.locationInWindow.x
  }

  override func mouseDragged(with event: NSEvent) {
    guard let previousX else {
      return
    }

    let x = event.locationInWindow.x
    onDrag?(x - previousX)
    self.previousX = x
  }

  override func mouseUp(with event: NSEvent) {
    previousX = nil
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.separatorColor.setFill()
    NSRect(x: bounds.midX, y: bounds.minY, width: 1, height: bounds.height).fill()
  }
}

private final class WorkspaceCountLabel: NSTextField {}

private extension NSPasteboard.PasteboardType {
  static let workspaceFileURL = NSPasteboard.PasteboardType("art.apuch.ksamint-markedit.workspace-file")
}
