//
//  WorkspaceIndexTests.swift
//
//  Created by ksamint on 7/27/26.
//

import SharedUI
import SQLite3
import XCTest

final class WorkspaceIndexTests: XCTestCase {
  func testReleasingIndexClosesDatabase() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let database = root.appending(path: "index.sqlite")
    try "persisted note".write(
      to: root.appending(path: "note.md"),
      atomically: true,
      encoding: .utf8
    )

    var index: WorkspaceIndex? = WorkspaceIndex(rootURL: root, databaseURL: database)
    let count = try await index?.rebuild()
    XCTAssertEqual(count, 1)

    // A second connection cannot leave WAL mode while the index still owns its
    // connection. WAL file deletion itself is not portable across SQLite builds.
    var probe: OpaquePointer?
    XCTAssertEqual(sqlite3_open(database.path, &probe), SQLITE_OK)
    defer { sqlite3_close(probe) }
    XCTAssertEqual(sqlite3_exec(probe, "PRAGMA journal_mode=DELETE", nil, nil, nil), SQLITE_BUSY)
    weak var releasedIndex = index
    index = nil

    // An actor's last task reference may be released just after its await returns.
    for _ in 0..<100 {
      if releasedIndex == nil {
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNil(releasedIndex)
    XCTAssertEqual(sqlite3_exec(probe, "PRAGMA journal_mode=DELETE", nil, nil, nil), SQLITE_OK)

    let reopened = WorkspaceIndex(rootURL: root, databaseURL: database)
    let files = await reopened.recentFiles()
    XCTAssertEqual(files.map(\.path), ["note.md"])
  }

  func testMultilingualSearchAndShortQueries() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let database = root.appending(path: "index.sqlite")

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    try "简体中文测试\n第二行".write(
      to: root.appending(path: "中文.md"),
      atomically: true,
      encoding: .utf8
    )
    try "日本語の文章です。".write(
      to: root.appending(path: "日本語.md"),
      atomically: true,
      encoding: .utf8
    )
    try "Café déjà vu — été".write(
      to: root.appending(path: "français.md"),
      atomically: true,
      encoding: .utf8
    )

    let index = WorkspaceIndex(rootURL: root, databaseURL: database)
    let fileCount = try await index.rebuild()
    let chineseResult = await index.search("中文").first
    let japaneseResult = await index.search("日本語").first
    let frenchResult = await index.search("cafe").first

    XCTAssertEqual(fileCount, 3)
    XCTAssertEqual(chineseResult?.lineNumber, 1)
    XCTAssertEqual(japaneseResult?.relativePath, "日本語.md")
    XCTAssertEqual(frenchResult?.relativePath, "français.md")
  }

  func testSkipsBinaryLargeHiddenAndExternalSymlinkFiles() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let database = root.appending(path: "index.sqlite")
    let external = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appending(path: ".git", directoryHint: .isDirectory),
      withIntermediateDirectories: true
    )
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: external)
    }

    try "visible".write(to: root.appending(path: "visible.md"), atomically: true, encoding: .utf8)
    try "hidden".write(to: root.appending(path: ".git/hidden.md"), atomically: true, encoding: .utf8)
    try Data([0, 1, 2, 3]).write(to: root.appending(path: "binary.txt"))
    try Data(count: WorkspaceIndex.maximumFileSize + 1).write(to: root.appending(path: "large.md"))
    let outsideFile = external.appending(path: "outside.md")
    try "outside workspace".write(to: outsideFile, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: root.appending(path: "linked.md"),
      withDestinationURL: outsideFile
    )

    let index = WorkspaceIndex(rootURL: root, databaseURL: database)
    let fileCount = try await index.rebuild()
    let visibleResults = await index.search("visible")
    let hiddenResults = await index.search("hidden")
    let binaryResults = await index.search("binary")
    let largeResults = await index.search("large")
    let outsideResults = await index.search("outside")

    XCTAssertEqual(fileCount, 1)
    XCTAssertEqual(visibleResults.count, 1)
    XCTAssertTrue(hiddenResults.isEmpty)
    XCTAssertTrue(binaryResults.isEmpty)
    XCTAssertTrue(largeResults.isEmpty)
    XCTAssertTrue(outsideResults.isEmpty)
  }

  func testRefreshAddsAndRemovesFile() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let database = root.appending(path: "index.sqlite")
    let file = root.appending(path: "note.md")

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    let index = WorkspaceIndex(rootURL: root, databaseURL: database)
    _ = try await index.rebuild()

    try "new content".write(to: file, atomically: true, encoding: .utf8)
    try await index.refresh(url: file)
    let addedResults = await index.search("content")
    XCTAssertEqual(addedResults.count, 1)

    try FileManager.default.removeItem(at: file)
    try await index.refresh(url: file)
    let removedResults = await index.search("content")
    XCTAssertTrue(removedResults.isEmpty)
  }

  func testCancelledShortQueryStopsScanning() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let database = root.appending(path: "index.sqlite")

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    for index in 0..<100 {
      try "短词 \(index)".write(
        to: root.appending(path: "\(index).md"),
        atomically: true,
        encoding: .utf8
      )
    }

    let workspaceIndex = WorkspaceIndex(rootURL: root, databaseURL: database)
    _ = try await workspaceIndex.rebuild()

    let task = Task {
      await workspaceIndex.search("短")
    }
    task.cancel()
    let results = await task.value
    XCTAssertTrue(results.isEmpty)
  }

  func testMetadataFiltersBooleanQueriesAndRegularExpressions() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let database = root.appending(path: "index.sqlite")

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    try """
    ---
    category: Projects/AI
    tags: [Research, "Café"]
    ---
    Swift semantic retrieval
    """.write(
      to: root.appending(path: "model.md"),
      atomically: true,
      encoding: .utf8
    )
    try """
    ---
    category: Journal
    tags: [personal]
    ---
    garden notes
    """.write(
      to: root.appending(path: "journal.md"),
      atomically: true,
      encoding: .utf8
    )

    let index = WorkspaceIndex(rootURL: root, databaseURL: database)
    _ = try await index.rebuild()

    let tagged = await index.search("tag:research category:Projects")
    let excluded = await index.search("notes -garden")
    let disjunction = await index.search("\"semantic retrieval\" OR tag:personal")
    let regex = await index.search("regex:/SWIFT/i")
    let tags = await index.tags()
    let categories = await index.categories()

    XCTAssertEqual(tagged.map(\.relativePath), ["model.md"])
    XCTAssertTrue(excluded.isEmpty)
    XCTAssertEqual(Set(disjunction.map(\.relativePath)), ["model.md", "journal.md"])
    XCTAssertEqual(regex.first?.relativePath, "model.md")
    XCTAssertEqual(tags.first { $0.identity == "research" }?.fileCount, 1)
    XCTAssertEqual(categories.map(\.path), ["Journal", "Projects/AI"])
  }

  func testCaptureHistoryPathFilterOnlyReturnsConversationFiles() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let database = root.appending(path: "index.sqlite")
    let conversations = root.appending(path: "Conversations", directoryHint: .isDirectory)

    try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try "captured transcript".write(
      to: conversations.appending(path: "Captured.md"),
      atomically: true,
      encoding: .utf8
    )
    try "ordinary note".write(
      to: root.appending(path: "Note.md"),
      atomically: true,
      encoding: .utf8
    )

    let index = WorkspaceIndex(rootURL: root, databaseURL: database)
    _ = try await index.rebuild()
    let results = await index.search(#"path:"Conversations/""#)

    XCTAssertEqual(results.map(\.relativePath), ["Conversations/Captured.md"])
  }

  func testWikiLinksMarkdownLinksBacklinksAndGraph() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let database = root.appending(path: "index.sqlite")
    let folder = root.appending(path: "Folder", directoryHint: .isDirectory)

    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    try "# Target".write(
      to: folder.appending(path: "Target.md"),
      atomically: true,
      encoding: .utf8
    )
    try "See [[Folder/Target|目标]]".write(
      to: root.appending(path: "Wiki.md"),
      atomically: true,
      encoding: .utf8
    )
    try "See [target](Folder/Target.md)".write(
      to: root.appending(path: "Markdown.md"),
      atomically: true,
      encoding: .utf8
    )

    let index = WorkspaceIndex(rootURL: root, databaseURL: database)
    _ = try await index.rebuild()
    let target = folder.appending(path: "Target.md")
    let backlinks = await index.backlinks(to: target)
    let graph = await index.graph()

    XCTAssertEqual(Set(backlinks.map(\.relativePath)), ["Wiki.md", "Markdown.md"])
    XCTAssertEqual(graph.nodes.count, 3)
    XCTAssertEqual(graph.edges.count, 2)
    XCTAssertTrue(graph.edges.allSatisfy { $0.targetPath == "Folder/Target.md" })
  }
}
