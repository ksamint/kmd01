//
//  EditorHistoryStorage.swift
//  MarkEditMac
//
//  Created by cyan on 4/17/26.
//

import Foundation
import MarkEditCore

@MainActor
enum EditorHistory {
  struct Activity: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
      case opened
      case edited
      case saved
      case renamed
    }

    let id: UUID
    var path: String
    var title: String
    var kind: Kind
    var timestamp: Date
    var count: Int
  }

  struct ClosedTab: Codable {
    let bookmark: Data
    let tabIndex: Int?
    let wasStandalone: Bool?
  }

  struct SelectionRangeEntry: Codable {
    let selectionRange: SelectionRange
    let fileSize: Int
    let lastAccessed: Date

    init(_ selectionRange: SelectionRange, fileSize: Int) {
      self.selectionRange = selectionRange
      self.fileSize = fileSize
      self.lastAccessed = .now
    }
  }

  @Storage(key: "editor-history.closed-tabs", defaultValue: [])
  static var closedTabs: [ClosedTab]

  @Storage(key: "editor-history.selection-ranges", defaultValue: [:])
  static var selectionRanges: [String: SelectionRangeEntry]

  @Storage(key: "editor-history.activity", defaultValue: [])
  static var activity: [Activity]
}

@MainActor
final class ActivityHistoryStore {
  static let shared = ActivityHistoryStore()

  private let maximumEntries = 5_000
  private let retentionInterval: TimeInterval = 90 * 24 * 60 * 60
  private let coalescingInterval: TimeInterval = 5 * 60
  private static let persistDelay: Duration = .seconds(1)
  private var pendingEdits = [String: Task<Void, Never>]()

  // The activity list (up to 5,000 entries) used to be JSON-decoded from
  // UserDefaults on every read and re-encoded on every write, on the main
  // thread, for every open, save, and idle autosave. Keep it in memory and
  // persist with a short debounce instead.
  private var cachedEntries: [EditorHistory.Activity]?
  private var persistTask: Task<Void, Never>?

  private init() {
    purge()
  }

  private var currentEntries: [EditorHistory.Activity] {
    if let cachedEntries {
      return cachedEntries
    }
    let loaded = EditorHistory.activity
    cachedEntries = loaded
    return loaded
  }

  private func store(_ entries: [EditorHistory.Activity]) {
    cachedEntries = entries
    persistTask?.cancel()
    persistTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.persistDelay)
      guard let self, !Task.isCancelled else { return }
      self.persistTask = nil
      self.flush()
    }
  }

  /// Writes any pending change to UserDefaults immediately.
  func flush() {
    persistTask?.cancel()
    persistTask = nil
    if let cachedEntries {
      EditorHistory.activity = cachedEntries
    }
  }

  func record(_ kind: EditorHistory.Activity.Kind, url: URL) {
    let path = url.standardizedFileURL.path
    let now = Date.now
    var entries = currentEntries.filter {
      now.timeIntervalSince($0.timestamp) <= retentionInterval
    }

    if let index = entries.firstIndex(where: {
      $0.path == path && $0.kind == kind && now.timeIntervalSince($0.timestamp) <= coalescingInterval
    }) {
      var entry = entries.remove(at: index)
      entry.timestamp = now
      entry.title = url.lastPathComponent
      entry.count += 1
      entries.insert(entry, at: 0)
    } else {
      entries.insert(EditorHistory.Activity(
        id: UUID(),
        path: path,
        title: url.lastPathComponent,
        kind: kind,
        timestamp: now,
        count: 1
      ), at: 0)
    }

    store(Array(entries.prefix(maximumEntries)))
  }

  func scheduleEdit(url: URL?) {
    guard let url else { return }
    let path = url.standardizedFileURL.path
    pendingEdits[path]?.cancel()
    pendingEdits[path] = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard let self, !Task.isCancelled else { return }
      self.pendingEdits[path] = nil
      self.record(.edited, url: url)
    }
  }

  func entries(limit: Int = 200) -> [EditorHistory.Activity] {
    purge()
    return Array(currentEntries.prefix(max(0, limit)))
  }

  func recentDocuments(limit: Int = 20) -> [EditorHistory.Activity] {
    // Stop as soon as enough existing documents are found instead of
    // stat-ing every unique path in the whole history.
    var seen = Set<String>()
    var documents = [EditorHistory.Activity]()
    for entry in entries(limit: maximumEntries) {
      if documents.count >= limit {
        break
      }
      guard seen.insert(entry.path).inserted,
            FileManager.default.fileExists(atPath: entry.path) else {
        continue
      }
      documents.append(entry)
    }
    return documents
  }

  func clear() {
    pendingEdits.values.forEach { $0.cancel() }
    pendingEdits.removeAll()
    cachedEntries = []
    flush()
  }

  func purge() {
    let cutoff = Date.now.addingTimeInterval(-retentionInterval)
    let entries = currentEntries
    let purged = Array(entries.filter { $0.timestamp >= cutoff }.prefix(maximumEntries))
    if purged.count != entries.count {
      store(purged)
    }
  }
}
