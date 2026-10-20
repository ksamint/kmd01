// swiftlint:disable file_length
//
//  WorkspaceIndex.swift
//
//  Created by ksamint on 7/27/26.
//

import CryptoKit
import Foundation
import SQLite3
import UniformTypeIdentifiers

public struct WorkspaceSearchResult: Sendable, Equatable {
  public let url: URL
  public let relativePath: String
  public let lineNumber: Int
  public let snippet: String

  public init(url: URL, relativePath: String, lineNumber: Int, snippet: String) {
    self.url = url
    self.relativePath = relativePath
    self.lineNumber = lineNumber
    self.snippet = snippet
  }
}

public struct WorkspaceTagSummary: Sendable, Equatable, Codable {
  public let identity: String
  public let displayName: String
  public let fileCount: Int

  public init(identity: String, displayName: String, fileCount: Int) {
    self.identity = identity
    self.displayName = displayName
    self.fileCount = fileCount
  }
}

public struct WorkspaceCategorySummary: Sendable, Equatable, Codable {
  public let path: String
  public let fileCount: Int

  public init(path: String, fileCount: Int) {
    self.path = path
    self.fileCount = fileCount
  }
}

public enum WorkspaceLinkKind: Int, Sendable, Equatable, Codable {
  case markdown
  case wiki
}

public struct WorkspaceGraphNode: Sendable, Equatable, Codable {
  public let path: String
  public let title: String
  public let category: String?
  public let tags: [String]

  public init(path: String, title: String, category: String?, tags: [String]) {
    self.path = path
    self.title = title
    self.category = category
    self.tags = tags
  }
}

public struct WorkspaceGraphEdge: Sendable, Equatable, Codable {
  public let sourcePath: String
  public let targetPath: String
  public let kind: WorkspaceLinkKind

  public init(sourcePath: String, targetPath: String, kind: WorkspaceLinkKind) {
    self.sourcePath = sourcePath
    self.targetPath = targetPath
    self.kind = kind
  }
}

public struct WorkspaceGraph: Sendable, Equatable, Codable {
  public let nodes: [WorkspaceGraphNode]
  public let edges: [WorkspaceGraphEdge]

  public init(nodes: [WorkspaceGraphNode], edges: [WorkspaceGraphEdge]) {
    self.nodes = nodes
    self.edges = edges
  }
}

public struct WorkspaceFileSummary: Sendable, Equatable, Codable {
  public let path: String
  public let modifiedAt: Date
  public let category: String?
  public let tags: [String]

  public init(path: String, modifiedAt: Date, category: String?, tags: [String]) {
    self.path = path
    self.modifiedAt = modifiedAt
    self.category = category
    self.tags = tags
  }
}

public enum WorkspaceIndexState: Sendable, Equatable {
  case idle
  case indexing
  case ready(fileCount: Int)
  case failed
}

public actor WorkspaceIndex {
  public static let maximumFileSize = 10 * 1024 * 1024
  public static let maximumResultCount = 500
  public static let defaultGraphNodeLimit = 300
  public static let maximumGraphNodeLimit = 2_000

  public private(set) var state = WorkspaceIndexState.idle

  private let rootURL: URL
  private let databaseURL: URL

  /// One connection for the lifetime of the actor. Opening SQLite and replaying
  /// the schema on every call used to dominate search and refresh latency.
  private var connection: OpaquePointer?
  private var isConfigured = false

  public init(rootURL: URL, databaseURL: URL? = nil) {
    self.rootURL = rootURL.standardizedFileURL
    self.databaseURL = databaseURL ?? Self.defaultDatabaseURL(rootURL: rootURL)
  }

  deinit {
    if let connection {
      sqlite3_close(connection)
    }
  }

  @discardableResult
  public func rebuild() throws -> Int {
    state = .indexing

    do {
      let files = indexableFiles()
      var indexedFileCount = 0
      try withDatabase { database in
        try configure(database)
        try execute(database, sql: "BEGIN IMMEDIATE")

        do {
          // Incremental: files whose modification date and size are unchanged
          // keep their rows, so a rebuild of a large, mostly unchanged
          // workspace costs a directory walk instead of re-reading, hashing,
          // folding, and re-tokenizing every note.
          let existingRecords = try existingFileRecords(database)
          var seenPaths = Set<String>()
          seenPaths.reserveCapacity(files.count)

          for url in files {
            guard !Task.isCancelled else {
              throw CancellationError()
            }

            let relativePath = url.relativePath(from: rootURL)
            seenPaths.insert(relativePath)

            if let record = existingRecords[relativePath] {
              if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                 let modifiedAt = values.contentModificationDate?.timeIntervalSince1970,
                 let byteSize = values.fileSize,
                 record.modifiedAt == modifiedAt,
                 record.byteSize == Int64(byteSize) {
                indexedFileCount += 1
                continue
              }
              try remove(path: relativePath, database: database)
            }
            indexedFileCount += try insert(url, database: database) ? 1 : 0
          }

          for path in existingRecords.keys where !seenPaths.contains(path) {
            try remove(path: path, database: database)
          }
          try execute(database, sql: "COMMIT")
        } catch {
          try? execute(database, sql: "ROLLBACK")
          throw error
        }
      }

      state = .ready(fileCount: indexedFileCount)
      return indexedFileCount
    } catch {
      state = .failed
      throw error
    }
  }

  public func refresh(url: URL) throws {
    let standardizedURL = url.standardizedFileURL
    guard standardizedURL.isDescendant(of: rootURL) else {
      return
    }

    let values = try? standardizedURL.resourceValues(forKeys: [.isDirectoryKey])
    if values?.isDirectory == true {
      _ = try rebuild()
      return
    }

    try withDatabase { database in
      try configure(database)
      try execute(database, sql: "BEGIN IMMEDIATE")
      do {
        try remove(standardizedURL, database: database)
        if isIndexable(standardizedURL) {
          try insert(standardizedURL, database: database)
        }
        try execute(database, sql: "COMMIT")
      } catch {
        try? execute(database, sql: "ROLLBACK")
        throw error
      }
    }
  }

  public func search(_ input: String) -> [WorkspaceSearchResult] {
    let query = WorkspaceQuery(input)
    guard !query.groups.isEmpty else {
      return []
    }

    do {
      return try searchDatabase(query)
    } catch {
      return linearSearch(query)
    }
  }

  public func tags() -> [WorkspaceTagSummary] {
    (try? withDatabase { database in
      try configure(database)
      let sql = """
      SELECT t.canonical, t.display_name, COUNT(ft.file_id)
      FROM tags t
      LEFT JOIN file_tags ft ON ft.tag_id = t.id
      GROUP BY t.id
      ORDER BY t.display_name COLLATE NOCASE
      """
      return try rows(database, sql: sql) { statement in
        WorkspaceTagSummary(
          identity: Self.string(statement, column: 0),
          displayName: Self.string(statement, column: 1),
          fileCount: Int(sqlite3_column_int64(statement, 2))
        )
      }
    }) ?? []
  }

  public func categories() -> [WorkspaceCategorySummary] {
    (try? withDatabase { database in
      try configure(database)
      let sql = """
      SELECT category, COUNT(*)
      FROM files
      WHERE category IS NOT NULL AND category != ''
      GROUP BY category_key
      ORDER BY category COLLATE NOCASE
      """
      return try rows(database, sql: sql) { statement in
        WorkspaceCategorySummary(
          path: Self.string(statement, column: 0),
          fileCount: Int(sqlite3_column_int64(statement, 1))
        )
      }
    }) ?? []
  }

  public func files(tagIdentity: String) -> [URL] {
    let identity = WorkspaceDocumentMetadata.canonicalTagIdentity(tagIdentity)
    return (try? withDatabase { database in
      try configure(database)
      let paths = try preparedRows(
        database,
        sql: """
        SELECT f.path
        FROM files f
        JOIN file_tags ft ON ft.file_id = f.id
        JOIN tags t ON t.id = ft.tag_id
        WHERE t.canonical = ?
        ORDER BY f.path COLLATE NOCASE
        """,
        values: [identity]
      ) {
        Self.string($0, column: 0)
      }
      return paths.map { rootURL.appending(path: $0) }
    }) ?? []
  }

  public func files(categoryPath: String) -> [URL] {
    let key = Self.fold(categoryPath)
    return (try? withDatabase { database in
      try configure(database)
      let paths = try preparedRows(
        database,
        sql: """
        SELECT path
        FROM files
        WHERE category_key = ? OR category_key LIKE ?
        ORDER BY path COLLATE NOCASE
        """,
        values: [key, "\(key)/%"]
      ) {
        Self.string($0, column: 0)
      }
      return paths.map { rootURL.appending(path: $0) }
    }) ?? []
  }

  public func recentFiles(limit requestedLimit: Int = 20) -> [WorkspaceFileSummary] {
    let limit = min(max(1, requestedLimit), 100)
    return (try? withDatabase { database in
      try configure(database)
      let files = try rows(
        database,
        sql: """
        SELECT path, modified_at, category
        FROM files
        ORDER BY modified_at DESC, path COLLATE NOCASE
        LIMIT \(limit)
        """
      ) { statement in
        (
          Self.string(statement, column: 0),
          sqlite3_column_double(statement, 1),
          sqlite3_column_type(statement, 2) == SQLITE_NULL
            ? nil
            : Self.string(statement, column: 2)
        )
      }

      let tagsByPath = try tagsByPath(database, paths: files.map(\.0))
      return files.map { path, modifiedAt, category in
        WorkspaceFileSummary(
          path: path,
          modifiedAt: Date(timeIntervalSince1970: modifiedAt),
          category: category,
          tags: tagsByPath[path] ?? []
        )
      }
    }) ?? []
  }

  public func backlinks(to url: URL) -> [WorkspaceSearchResult] {
    let keys = Self.linkTargetKeys(for: url.relativePath(from: rootURL))
    guard !keys.isEmpty else {
      return []
    }

    return (try? withDatabase { database in
      try configure(database)
      let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ", ")
      let sql = """
      SELECT DISTINCT f.path, f.body
      FROM files f
      JOIN links l ON l.source_file_id = f.id
      WHERE l.target_key IN (\(placeholders))
      ORDER BY f.path COLLATE NOCASE
      LIMIT \(Self.maximumResultCount)
      """
      return try preparedRows(database, sql: sql, values: keys) { statement in
        let path = Self.string(statement, column: 0)
        let body = Self.string(statement, column: 1)
        return Self.result(
          rootURL: rootURL,
          relativePath: path,
          body: body,
          lineNumber: 1
        )
      }
    }) ?? []
  }

  public func graph(limit requestedLimit: Int = defaultGraphNodeLimit) -> WorkspaceGraph {
    let limit = min(max(1, requestedLimit), Self.maximumGraphNodeLimit)
    return (try? withDatabase { database in
      try configure(database)
      return try graph(database: database, limit: limit)
    }) ?? WorkspaceGraph(nodes: [], edges: [])
  }
}

// MARK: - SQLite

private extension WorkspaceIndex {
  enum DatabaseError: Error {
    case open(String)
    case execute(String)
    case prepare(String)
  }

  static let schemaVersion: Int64 = 4

  func withDatabase<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
    try operation(openDatabaseIfNeeded())
  }

  func openDatabaseIfNeeded() throws -> OpaquePointer {
    if let connection {
      return connection
    }

    try FileManager.default.createDirectory(
      at: databaseURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    var database: OpaquePointer?
    guard sqlite3_open_v2(
      databaseURL.path(percentEncoded: false),
      &database,
      SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil
    ) == SQLITE_OK, let database else {
      let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
      sqlite3_close(database)
      throw DatabaseError.open(message)
    }

    sqlite3_busy_timeout(database, 2_000)
    connection = database
    return database
  }

  func configure(_ database: OpaquePointer) throws {
    guard !isConfigured else {
      return
    }

    try execute(database, sql: "PRAGMA journal_mode=WAL")
    try execute(database, sql: "PRAGMA synchronous=NORMAL")
    try execute(database, sql: "PRAGMA foreign_keys=ON")
    try execute(
      database,
      sql: """
      CREATE TABLE IF NOT EXISTS files (
        id INTEGER PRIMARY KEY,
        path TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        body TEXT NOT NULL,
        folded TEXT NOT NULL,
        category TEXT,
        category_key TEXT,
        modified_at REAL NOT NULL,
        byte_size INTEGER NOT NULL,
        content_hash TEXT NOT NULL
      )
      """
    )
    try execute(
      database,
      sql: """
      CREATE TABLE IF NOT EXISTS tags (
        id INTEGER PRIMARY KEY,
        canonical TEXT NOT NULL UNIQUE,
        display_name TEXT NOT NULL
      )
      """
    )
    try execute(
      database,
      sql: """
      CREATE TABLE IF NOT EXISTS file_tags (
        file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
        PRIMARY KEY (file_id, tag_id)
      )
      """
    )
    try execute(
      database,
      sql: """
      CREATE TABLE IF NOT EXISTS links (
        id INTEGER PRIMARY KEY,
        source_file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        target TEXT NOT NULL,
        target_key TEXT NOT NULL,
        alias TEXT,
        kind INTEGER NOT NULL
      )
      """
    )
    try execute(
      database,
      sql: """
      CREATE VIRTUAL TABLE IF NOT EXISTS workspace_fts USING fts5(
        file_id UNINDEXED,
        path,
        name,
        body,
        folded,
        tokenize='trigram'
      )
      """
    )
    try execute(database, sql: "CREATE INDEX IF NOT EXISTS files_category_idx ON files(category_key)")
    try execute(database, sql: "CREATE INDEX IF NOT EXISTS links_target_idx ON links(target_key)")
    try execute(database, sql: "CREATE INDEX IF NOT EXISTS file_tags_tag_idx ON file_tags(tag_id)")

    // Rows written by an older parser or schema are dropped once, so the next
    // (incremental) rebuild re-indexes everything instead of trusting them.
    let storedVersion = try scalarInt(database, sql: "PRAGMA user_version") ?? 0
    if storedVersion != Self.schemaVersion {
      try execute(database, sql: "DELETE FROM workspace_fts")
      try execute(database, sql: "DELETE FROM files")
      try execute(database, sql: "DELETE FROM tags")
      try execute(database, sql: "PRAGMA user_version=\(Self.schemaVersion)")
    }
    isConfigured = true
  }

  struct ExistingFileRecord {
    let modifiedAt: Double
    let byteSize: Int64
  }

  func existingFileRecords(_ database: OpaquePointer) throws -> [String: ExistingFileRecord] {
    var records = [String: ExistingFileRecord]()
    _ = try rows(database, sql: "SELECT path, modified_at, byte_size FROM files") { statement in
      records[Self.string(statement, column: 0)] = ExistingFileRecord(
        modifiedAt: sqlite3_column_double(statement, 1),
        byteSize: sqlite3_column_int64(statement, 2)
      )
    }
    return records
  }

  /// Tags for many files in one query instead of one query per file.
  func tagsByPath(_ database: OpaquePointer, paths: [String]) throws -> [String: [String]] {
    guard !paths.isEmpty else {
      return [:]
    }

    let allowedPaths = Set(paths)
    var tagsByPath = [String: [String]]()
    _ = try rows(
      database,
      sql: """
      SELECT f.path, t.display_name
      FROM file_tags ft
      JOIN files f ON f.id = ft.file_id
      JOIN tags t ON t.id = ft.tag_id
      ORDER BY t.display_name COLLATE NOCASE
      """
    ) { statement in
      let path = Self.string(statement, column: 0)
      if allowedPaths.contains(path) {
        tagsByPath[path, default: []].append(Self.string(statement, column: 1))
      }
    }
    return tagsByPath
  }

  func execute(_ database: OpaquePointer, sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) }
        ?? String(cString: sqlite3_errmsg(database))
      sqlite3_free(errorMessage)
      throw DatabaseError.execute(message)
    }
  }

  @discardableResult
  func insert(_ url: URL, database: OpaquePointer) throws -> Bool {
    guard let contents = fileContents(url) else {
      return false
    }

    let body = contents.text
    let relativePath = url.relativePath(from: rootURL)
    let metadata = WorkspaceDocumentMetadata.parse(body)
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    let modifiedAt = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
    let byteSize = values?.fileSize ?? contents.data.count
    let hash = SHA256.hash(data: contents.data).map { String(format: "%02x", $0) }.joined()
    let folded = Self.fold("\(relativePath)\n\(body)")
    let sql = """
    INSERT INTO files(
      path, name, body, folded, category, category_key, modified_at, byte_size, content_hash
    ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
    """

    try run(
      database,
      sql: sql,
      values: [
        .text(relativePath),
        .text(url.lastPathComponent),
        .text(body),
        .text(folded),
        metadata.category.map(BoundValue.text) ?? .null,
        metadata.category.map { .text(Self.fold($0)) } ?? .null,
        .double(modifiedAt),
        .integer(Int64(byteSize)),
        .text(hash),
      ]
    )
    let fileID = sqlite3_last_insert_rowid(database)

    try run(
      database,
      sql: """
      INSERT INTO workspace_fts(rowid, file_id, path, name, body, folded)
      VALUES(?, ?, ?, ?, ?, ?)
      """,
      values: [
        .integer(fileID),
        .integer(fileID),
        .text(relativePath),
        .text(url.lastPathComponent),
        .text(body),
        .text(folded),
      ]
    )

    for tag in metadata.tags {
      let identity = WorkspaceDocumentMetadata.canonicalTagIdentity(tag)
      try run(
        database,
        sql: "INSERT OR IGNORE INTO tags(canonical, display_name) VALUES(?, ?)",
        values: [.text(identity), .text(tag)]
      )
      guard let tagID = try scalarInt(
        database,
        sql: "SELECT id FROM tags WHERE canonical = ?",
        values: [.text(identity)]
      ) else {
        continue
      }
      try run(
        database,
        sql: "INSERT OR IGNORE INTO file_tags(file_id, tag_id) VALUES(?, ?)",
        values: [.integer(fileID), .integer(tagID)]
      )
    }

    for link in Self.links(in: body, sourcePath: relativePath) {
      try run(
        database,
        sql: """
        INSERT INTO links(source_file_id, target, target_key, alias, kind)
        VALUES(?, ?, ?, ?, ?)
        """,
        values: [
          .integer(fileID),
          .text(link.target),
          .text(link.targetKey),
          link.alias.map(BoundValue.text) ?? .null,
          .integer(Int64(link.kind.rawValue)),
        ]
      )
    }
    return true
  }

  func remove(_ url: URL, database: OpaquePointer) throws {
    try remove(path: url.relativePath(from: rootURL), database: database)
  }

  func remove(path: String, database: OpaquePointer) throws {
    try run(
      database,
      sql: "DELETE FROM workspace_fts WHERE rowid IN (SELECT id FROM files WHERE path = ?)",
      values: [.text(path)]
    )
    try run(database, sql: "DELETE FROM files WHERE path = ?", values: [.text(path)])
    try execute(
      database,
      sql: "DELETE FROM tags WHERE NOT EXISTS (SELECT 1 FROM file_tags WHERE file_tags.tag_id = tags.id)"
    )
  }

  enum BoundValue {
    case text(String)
    case integer(Int64)
    case double(Double)
    case null
  }

  func run(_ database: OpaquePointer, sql: String, values: [BoundValue] = []) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw DatabaseError.prepare(String(cString: sqlite3_errmsg(database)))
    }
    defer {
      sqlite3_finalize(statement)
    }

    bind(values, statement: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw DatabaseError.execute(String(cString: sqlite3_errmsg(database)))
    }
  }

  func scalarInt(
    _ database: OpaquePointer,
    sql: String,
    values: [BoundValue] = []
  ) throws -> Int64? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw DatabaseError.prepare(String(cString: sqlite3_errmsg(database)))
    }
    defer {
      sqlite3_finalize(statement)
    }

    bind(values, statement: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else {
      return nil
    }
    return sqlite3_column_int64(statement, 0)
  }

  func preparedRows<T>(
    _ database: OpaquePointer,
    sql: String,
    values: [String],
    transform: (OpaquePointer) throws -> T
  ) throws -> [T] {
    try preparedRows(
      database,
      sql: sql,
      boundValues: values.map(BoundValue.text),
      transform: transform
    )
  }

  func preparedRows<T>(
    _ database: OpaquePointer,
    sql: String,
    boundValues: [BoundValue],
    transform: (OpaquePointer) throws -> T
  ) throws -> [T] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw DatabaseError.prepare(String(cString: sqlite3_errmsg(database)))
    }
    defer {
      sqlite3_finalize(statement)
    }

    bind(boundValues, statement: statement)
    var values = [T]()
    while sqlite3_step(statement) == SQLITE_ROW {
      guard !Task.isCancelled else {
        break
      }
      values.append(try transform(statement))
    }
    return values
  }

  func rows<T>(
    _ database: OpaquePointer,
    sql: String,
    transform: (OpaquePointer) throws -> T
  ) throws -> [T] {
    try preparedRows(database, sql: sql, boundValues: [], transform: transform)
  }

  func bind(_ values: [BoundValue], statement: OpaquePointer) {
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      switch value {
      case let .text(value):
        sqlite3_bind_text(
          statement,
          index,
          value,
          -1,
          unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        )
      case let .integer(value):
        sqlite3_bind_int64(statement, index, value)
      case let .double(value):
        sqlite3_bind_double(statement, index, value)
      case .null:
        sqlite3_bind_null(statement, index)
      }
    }
  }

  static func string(_ statement: OpaquePointer, column: Int32) -> String {
    sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
  }
}

// MARK: - Search

private extension WorkspaceIndex {
  struct WorkspaceQuery {
    let groups: [QueryGroup]

    init(_ input: String) {
      var groups = [QueryGroup]()
      var current = QueryGroup()

      for token in Self.tokens(input) {
        if token.caseInsensitiveCompare("OR") == .orderedSame {
          if !current.isEmpty {
            groups.append(current)
          }
          current = QueryGroup()
        } else if token.caseInsensitiveCompare("AND") != .orderedSame {
          current.add(token)
        }
      }

      if !current.isEmpty {
        groups.append(current)
      }
      self.groups = groups
    }

    static func tokens(_ input: String) -> [String] {
      var tokens = [String]()
      var buffer = ""
      var quote: Character?
      var escaped = false

      for character in input {
        if escaped {
          buffer.append(character)
          escaped = false
        } else if character == "\\" {
          buffer.append(character)
          escaped = true
        } else if character == "\"" || character == "'" {
          quote = quote == character ? nil : (quote ?? character)
          buffer.append(character)
        } else if character.isWhitespace, quote == nil {
          if !buffer.isEmpty {
            tokens.append(buffer)
            buffer = ""
          }
        } else {
          buffer.append(character)
        }
      }

      if !buffer.isEmpty {
        tokens.append(buffer)
      }
      return tokens
    }
  }

  struct QueryGroup {
    var text = [String]()
    var excludedText = [String]()
    var tags = [String]()
    var categories = [String]()
    var paths = [String]()
    var before: Date?
    var after: Date?
    var regularExpressions = [NSRegularExpression]()
    var backlinkTargets = [String]()

    var isEmpty: Bool {
      text.isEmpty
        && excludedText.isEmpty
        && tags.isEmpty
        && categories.isEmpty
        && paths.isEmpty
        && before == nil
        && after == nil
        && regularExpressions.isEmpty
        && backlinkTargets.isEmpty
    }

    mutating func add(_ token: String) {
      let excluded = token.hasPrefix("-")
      let token = excluded ? String(token.dropFirst()) : token
      let pair = token.split(separator: ":", maxSplits: 1).map(String.init)

      if pair.count == 2 {
        let key = pair[0].lowercased()
        let value = Self.unquote(pair[1])
        switch key {
        case "tag":
          tags.append(WorkspaceDocumentMetadata.canonicalTagIdentity(value))
          return
        case "category":
          categories.append(WorkspaceIndex.fold(value))
          return
        case "path":
          paths.append(WorkspaceIndex.fold(value))
          return
        case "before":
          before = Self.date(value)
          return
        case "after":
          after = Self.date(value)
          return
        case "backlinks", "backlink":
          backlinkTargets.append(contentsOf: WorkspaceIndex.linkTargetKeys(for: value))
          return
        case "regex":
          if let expression = Self.regularExpression(value) {
            regularExpressions.append(expression)
          }
          return
        default:
          break
        }
      }

      let value = Self.unquote(token)
      if let expression = Self.regularExpression(value), value.hasPrefix("/") {
        regularExpressions.append(expression)
      } else if excluded {
        excludedText.append(value)
      } else if !value.isEmpty {
        text.append(value)
      }
    }

    static func unquote(_ value: String) -> String {
      guard value.count >= 2,
            let first = value.first,
            let last = value.last,
            (first == "\"" && last == "\"") || (first == "'" && last == "'") else {
        return value
      }
      return String(value.dropFirst().dropLast())
    }

    static func date(_ value: String) -> Date? {
      let values = value.split(separator: "-").compactMap { Int($0) }
      guard values.count == 3 else {
        return nil
      }
      var components = DateComponents()
      components.calendar = Calendar(identifier: .iso8601)
      components.timeZone = TimeZone(secondsFromGMT: 0)
      components.year = values[0]
      components.month = values[1]
      components.day = values[2]
      return components.date
    }

    static func regularExpression(_ value: String) -> NSRegularExpression? {
      var pattern = value
      var options = NSRegularExpression.Options()
      if value.hasPrefix("/"), let closingIndex = value.dropFirst().lastIndex(of: "/") {
        pattern = String(value[value.index(after: value.startIndex)..<closingIndex])
        let flags = value[value.index(after: closingIndex)...]
        if flags.contains("i") {
          options.insert(.caseInsensitive)
        }
      }
      return try? NSRegularExpression(pattern: pattern, options: options)
    }
  }

  func searchDatabase(_ query: WorkspaceQuery) throws -> [WorkspaceSearchResult] {
    try withDatabase { database in
      try configure(database)
      var results = [WorkspaceSearchResult]()
      var seen = Set<String>()

      for group in query.groups {
        let candidates = try searchGroup(group, database: database)
        for candidate in candidates {
          guard !Task.isCancelled, results.count < Self.maximumResultCount else {
            return results
          }

          let key = "\(candidate.path):\(candidate.lineNumber)"
          guard seen.insert(key).inserted else {
            continue
          }
          results.append(
            WorkspaceSearchResult(
              url: rootURL.appending(path: candidate.path),
              relativePath: candidate.path,
              lineNumber: candidate.lineNumber,
              snippet: candidate.snippet
            )
          )
        }
      }
      return results
    }
  }

  struct SearchCandidate {
    let path: String
    let lineNumber: Int
    let snippet: String
  }

  func searchGroup(_ group: QueryGroup, database: OpaquePointer) throws -> [SearchCandidate] {
    var conditions = ["1 = 1"]
    var values = [BoundValue]()

    if !group.text.isEmpty {
      let foldedTerms = group.text.map(Self.fold)
      if foldedTerms.allSatisfy({ $0.count >= 3 }) {
        let query = foldedTerms.map(Self.ftsPhrase).joined(separator: " AND ")
        conditions.append("f.id IN (SELECT rowid FROM workspace_fts WHERE workspace_fts MATCH ?)")
        values.append(.text(query))
      } else {
        for term in foldedTerms {
          conditions.append("instr(f.folded, ?) > 0")
          values.append(.text(term))
        }
      }
    }

    for term in group.excludedText {
      conditions.append("instr(f.folded, ?) = 0")
      values.append(.text(Self.fold(term)))
    }
    for tag in group.tags {
      conditions.append(
        """
        EXISTS (
          SELECT 1 FROM file_tags ft
          JOIN tags t ON t.id = ft.tag_id
          WHERE ft.file_id = f.id AND t.canonical = ?
        )
        """
      )
      values.append(.text(tag))
    }
    for category in group.categories {
      conditions.append("(f.category_key = ? OR f.category_key LIKE ?)")
      values.append(.text(category))
      values.append(.text("\(category)/%"))
    }
    for path in group.paths {
      conditions.append("instr(lower(f.path), ?) > 0")
      values.append(.text(path))
    }
    if let before = group.before {
      conditions.append("f.modified_at < ?")
      values.append(.double(before.timeIntervalSince1970))
    }
    if let after = group.after {
      conditions.append("f.modified_at >= ?")
      values.append(.double(after.timeIntervalSince1970))
    }
    if !group.backlinkTargets.isEmpty {
      let placeholders = Array(
        repeating: "?",
        count: group.backlinkTargets.count
      ).joined(separator: ", ")
      conditions.append(
        """
        EXISTS (
          SELECT 1 FROM links l
          WHERE l.source_file_id = f.id AND l.target_key IN (\(placeholders))
        )
        """
      )
      values.append(contentsOf: group.backlinkTargets.map(BoundValue.text))
    }

    let sql = """
    SELECT f.path, f.body
    FROM files f
    WHERE \(conditions.joined(separator: " AND "))
    ORDER BY f.path COLLATE NOCASE
    LIMIT \(Self.maximumResultCount)
    """
    let rows = try preparedRows(database, sql: sql, boundValues: values) { statement in
      (
        Self.string(statement, column: 0),
        Self.string(statement, column: 1)
      )
    }
    var candidates = [SearchCandidate]()

    for (path, body) in rows {
      let searchable = "\(path)\n\(body)"
      let range = NSRange(searchable.startIndex..<searchable.endIndex, in: searchable)
      guard group.regularExpressions.allSatisfy({
        $0.firstMatch(in: searchable, range: range) != nil
      }) else {
        continue
      }

      let terms = group.text.isEmpty ? group.regularExpressions.map(\.pattern) : group.text
      let matches = Self.resultLines(
        relativePath: path,
        body: body,
        terms: terms,
        remainingCount: Self.maximumResultCount - candidates.count
      )
      candidates.append(contentsOf: matches.map {
        SearchCandidate(path: path, lineNumber: $0.0, snippet: $0.1)
      })
      if candidates.count >= Self.maximumResultCount {
        break
      }
    }
    return candidates
  }

  static func ftsPhrase(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
  }
}

// MARK: - Graph

private extension WorkspaceIndex {
  struct GraphFile {
    let path: String
    let name: String
    let category: String?
  }

  func graph(database: OpaquePointer, limit: Int) throws -> WorkspaceGraph {
    let files = try rows(
      database,
      sql: """
      SELECT f.path, f.name, f.category
      FROM files f
      LEFT JOIN links l ON l.source_file_id = f.id
      GROUP BY f.id
      ORDER BY COUNT(l.id) DESC, f.path COLLATE NOCASE
      LIMIT \(limit)
      """
    ) { statement in
      GraphFile(
        path: Self.string(statement, column: 0),
        name: Self.string(statement, column: 1),
        category: sqlite3_column_type(statement, 2) == SQLITE_NULL
          ? nil
          : Self.string(statement, column: 2)
      )
    }
    let allowedPaths = Set(files.map(\.path))
    let targetMap = Self.targetMap(paths: Array(allowedPaths))
    var nodes = [WorkspaceGraphNode]()

    let tagsByPath = try tagsByPath(database, paths: files.map(\.path))
    for file in files {
      nodes.append(
        WorkspaceGraphNode(
          path: file.path,
          title: URL(fileURLWithPath: file.name).deletingPathExtension().lastPathComponent,
          category: file.category,
          tags: tagsByPath[file.path] ?? []
        )
      )
    }

    let linkRows = try rows(
      database,
      sql: """
      SELECT f.path, l.target_key, l.kind
      FROM links l
      JOIN files f ON f.id = l.source_file_id
      """
    ) { statement in
      (
        Self.string(statement, column: 0),
        Self.string(statement, column: 1),
        Int(sqlite3_column_int(statement, 2))
      )
    }
    var seenEdges = Set<String>()
    let edges = linkRows.compactMap { source, targetKey, kind -> WorkspaceGraphEdge? in
      guard allowedPaths.contains(source),
            let target = targetMap[targetKey],
            allowedPaths.contains(target),
            let linkKind = WorkspaceLinkKind(rawValue: kind),
            seenEdges.insert("\(source)\u{0}\(target)\u{0}\(kind)").inserted else {
        return nil
      }
      return WorkspaceGraphEdge(sourcePath: source, targetPath: target, kind: linkKind)
    }
    return WorkspaceGraph(nodes: nodes, edges: edges)
  }

  static func targetMap(paths: [String]) -> [String: String] {
    var targets = [String: String]()
    for path in paths {
      for key in linkTargetKeys(for: path) where targets[key] == nil {
        targets[key] = path
      }
    }
    return targets
  }
}

// MARK: - Links

private extension WorkspaceIndex {
  struct ParsedLink {
    let target: String
    let targetKey: String
    let alias: String?
    let kind: WorkspaceLinkKind
  }

  // Compiled once; NSRegularExpression is immutable and thread-safe.
  nonisolated(unsafe) static let wikiLinkExpression = try? NSRegularExpression(
    pattern: #"\[\[([^\]\|\n]+)(?:\|([^\]\n]+))?\]\]"#
  )
  nonisolated(unsafe) static let markdownLinkExpression = try? NSRegularExpression(
    pattern: #"!?\[[^\]\n]*\]\(([^)\s]+)(?:\s+["'][^"']*["'])?\)"#
  )

  static func links(in body: String, sourcePath: String) -> [ParsedLink] {
    let sourceDirectory = (sourcePath as NSString).deletingLastPathComponent
    var links = [ParsedLink]()

    if let expression = wikiLinkExpression {
      let range = NSRange(body.startIndex..<body.endIndex, in: body)
      for match in expression.matches(in: body, range: range) {
        guard let targetRange = Range(match.range(at: 1), in: body) else {
          continue
        }
        let target = String(body[targetRange]).trimmingCharacters(in: .whitespaces)
        let alias = Range(match.range(at: 2), in: body).map {
          String(body[$0]).trimmingCharacters(in: .whitespaces)
        }
        for key in linkTargetKeys(for: target) {
          links.append(ParsedLink(target: target, targetKey: key, alias: alias, kind: .wiki))
        }
      }
    }

    if let expression = markdownLinkExpression {
      let range = NSRange(body.startIndex..<body.endIndex, in: body)
      for match in expression.matches(in: body, range: range) {
        guard let targetRange = Range(match.range(at: 1), in: body) else {
          continue
        }
        let originalTarget = String(body[targetRange])
        guard !originalTarget.hasPrefix("#"),
              URL(string: originalTarget)?.scheme == nil else {
          continue
        }

        let target = originalTarget
          .removingPercentEncoding?
          .split(separator: "#", maxSplits: 1)
          .first
          .map(String.init) ?? originalTarget
        let resolved = (sourceDirectory as NSString)
          .appendingPathComponent(target) as NSString
        let normalized = resolved.standardizingPath
        guard !normalized.hasPrefix("../"), normalized != ".." else {
          continue
        }
        for key in linkTargetKeys(for: normalized) {
          links.append(
            ParsedLink(target: originalTarget, targetKey: key, alias: nil, kind: .markdown)
          )
        }
      }
    }
    return links
  }

  static func linkTargetKeys(for rawPath: String) -> [String] {
    var value = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("[["), value.hasSuffix("]]") {
      value = String(value.dropFirst(2).dropLast(2))
    }
    value = value.split(separator: "|", maxSplits: 1).first.map(String.init) ?? value
    value = value.split(separator: "#", maxSplits: 1).first.map(String.init) ?? value
    value = value.removingPercentEncoding ?? value
    value = (value as NSString).standardizingPath

    let path = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !path.isEmpty else {
      return []
    }

    let pathWithoutExtension = (path as NSString).deletingPathExtension
    let name = (path as NSString).lastPathComponent
    let stem = (name as NSString).deletingPathExtension
    var seen = Set<String>()
    return [path, pathWithoutExtension, name, stem]
      .map(Self.fold)
      .filter { !$0.isEmpty && seen.insert($0).inserted }
  }
}

// MARK: - Files

private extension WorkspaceIndex {
  struct FileContents {
    let data: Data
    let text: String
  }

  static let excludedDirectories: Set<String> = [
    ".build",
    ".git",
    ".hg",
    ".ksamint",
    ".svn",
    "DerivedData",
    "Pods",
    "build",
    "dist",
    "node_modules",
  ]

  func indexableFiles() -> [URL] {
    let keys: [URLResourceKey] = [
      .fileSizeKey,
      .isDirectoryKey,
      .isRegularFileKey,
      .isSymbolicLinkKey,
    ]

    guard let enumerator = FileManager.default.enumerator(
      at: rootURL,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      return []
    }

    var files = [URL]()
    for case let url as URL in enumerator {
      let values = try? url.resourceValues(forKeys: Set(keys))

      if values?.isDirectory == true {
        if Self.excludedDirectories.contains(url.lastPathComponent) || values?.isSymbolicLink == true {
          enumerator.skipDescendants()
        }
        continue
      }

      if isIndexable(url, values: values) {
        files.append(url)
      }
    }

    return files
  }

  func isIndexable(_ url: URL, values providedValues: URLResourceValues? = nil) -> Bool {
    let values = providedValues ?? (try? url.resourceValues(forKeys: [
      .fileSizeKey,
      .isRegularFileKey,
      .isSymbolicLinkKey,
    ]))

    guard values?.isRegularFile == true,
          values?.isSymbolicLink != true,
          (values?.fileSize ?? Self.maximumFileSize + 1) <= Self.maximumFileSize else {
      return false
    }

    let pathExtension = url.pathExtension.lowercased()
    if Self.textExtensions.contains(pathExtension) {
      return true
    }
    return UTType(filenameExtension: pathExtension)?.conforms(to: .text) == true
  }

  func fileContents(_ url: URL) -> FileContents? {
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
      return nil
    }

    if data.prefix(8_192).contains(0) {
      return nil
    }

    for encoding in Self.encodings {
      if let value = String(data: data, encoding: encoding) {
        return FileContents(
          data: data,
          text: value.precomposedStringWithCanonicalMapping
        )
      }
    }
    return nil
  }

  func linearSearch(_ query: WorkspaceQuery) -> [WorkspaceSearchResult] {
    var results = [WorkspaceSearchResult]()
    var seen = Set<String>()

    for url in indexableFiles() {
      guard !Task.isCancelled, results.count < Self.maximumResultCount else {
        break
      }
      guard let body = fileContents(url)?.text else {
        continue
      }

      let relativePath = url.relativePath(from: rootURL)
      let metadata = WorkspaceDocumentMetadata.parse(body)
      for group in query.groups where Self.matches(
        group,
        relativePath: relativePath,
        body: body,
        metadata: metadata
      ) {
        let lines = Self.resultLines(
          relativePath: relativePath,
          body: body,
          terms: group.text,
          remainingCount: Self.maximumResultCount - results.count
        )
        for (lineNumber, snippet) in lines {
          let key = "\(relativePath):\(lineNumber)"
          guard seen.insert(key).inserted else {
            continue
          }
          results.append(
            WorkspaceSearchResult(
              url: url,
              relativePath: relativePath,
              lineNumber: lineNumber,
              snippet: snippet
            )
          )
        }
      }
    }
    return results
  }

  static func matches(
    _ group: QueryGroup,
    relativePath: String,
    body: String,
    metadata: WorkspaceDocumentMetadata
  ) -> Bool {
    let searchable = fold("\(relativePath)\n\(body)")
    let tagIdentities = Set(metadata.tags.map(WorkspaceDocumentMetadata.canonicalTagIdentity))
    let category = metadata.category.map(fold)
    let range = NSRange(searchable.startIndex..<searchable.endIndex, in: searchable)

    return group.text.allSatisfy { searchable.contains(fold($0)) }
      && group.excludedText.allSatisfy { !searchable.contains(fold($0)) }
      && group.tags.allSatisfy(tagIdentities.contains)
      && group.categories.allSatisfy {
        category == $0 || category?.hasPrefix("\($0)/") == true
      }
      && group.paths.allSatisfy { fold(relativePath).contains($0) }
      && group.regularExpressions.allSatisfy {
        $0.firstMatch(in: searchable, range: range) != nil
      }
      && group.backlinkTargets.isEmpty
  }

  static let textExtensions: Set<String> = [
    "adoc",
    "markdown",
    "md",
    "mdown",
    "mdx",
    "mkd",
    "qmd",
    "rmd",
    "text",
    "txt",
  ]

  static let encodings: [String.Encoding] = [
    .utf8,
    .utf16,
    .utf16LittleEndian,
    .utf16BigEndian,
    .windowsCP1252,
    .shiftJIS,
    .japaneseEUC,
  ]
}

// MARK: - Helpers

private extension WorkspaceIndex {
  static func defaultDatabaseURL(rootURL: URL) -> URL {
    let hash = SHA256.hash(data: Data(rootURL.standardizedFileURL.path.utf8))
      .map { String(format: "%02x", $0) }
      .joined()

    let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory

    return cacheURL
      .appending(path: "WorkspaceIndex", directoryHint: .isDirectory)
      .appending(path: "\(hash).sqlite", directoryHint: .notDirectory)
  }

  static func fold(_ value: String) -> String {
    value
      .precomposedStringWithCompatibilityMapping
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
      )
  }

  static func resultLines(
    relativePath: String,
    body: String,
    terms: [String],
    remainingCount: Int
  ) -> [(Int, String)] {
    let lines = body.components(separatedBy: .newlines)
    let foldedTerms = terms.map(fold)
    let maximumCount = max(0, remainingCount)
    var matchingLineIndices = [Int]()

    if foldedTerms.isEmpty {
      matchingLineIndices = [lines.startIndex]
    } else {
      for index in lines.indices where matchingLineIndices.count < maximumCount {
        let foldedLine = fold(lines[index])
        if foldedTerms.contains(where: { foldedLine.contains($0) }) {
          matchingLineIndices.append(index)
        }
      }
    }

    if matchingLineIndices.isEmpty {
      let foldedPath = fold(relativePath)
      if foldedTerms.contains(where: { foldedPath.contains($0) }) {
        matchingLineIndices = [0]
      }
    }
    if matchingLineIndices.isEmpty {
      matchingLineIndices = [0]
    }

    return matchingLineIndices.prefix(max(0, remainingCount)).map { lineIndex in
      (
        lineIndex + 1,
        lines.indices.contains(lineIndex)
          ? lines[lineIndex].trimmingCharacters(in: .whitespaces)
          : ""
      )
    }
  }

  static func result(
    rootURL: URL,
    relativePath: String,
    body: String,
    lineNumber: Int
  ) -> WorkspaceSearchResult {
    let lines = body.components(separatedBy: .newlines)
    let index = max(0, lineNumber - 1)
    return WorkspaceSearchResult(
      url: rootURL.appending(path: relativePath),
      relativePath: relativePath,
      lineNumber: lineNumber,
      snippet: lines.indices.contains(index)
        ? lines[index].trimmingCharacters(in: .whitespaces)
        : ""
    )
  }
}

private extension URL {
  func isDescendant(of rootURL: URL) -> Bool {
    let rootComponents = rootURL.standardizedFileURL.pathComponents
    let components = standardizedFileURL.pathComponents
    return components.count > rootComponents.count
      && components.prefix(rootComponents.count) == rootComponents[...]
  }

  func relativePath(from rootURL: URL) -> String {
    let rootComponents = rootURL.standardizedFileURL.pathComponents
    let components = standardizedFileURL.pathComponents

    guard components.prefix(rootComponents.count) == rootComponents[...] else {
      return lastPathComponent
    }

    return components.dropFirst(rootComponents.count).joined(separator: "/")
  }
}
