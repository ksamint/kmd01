//
//  NSDocumentController+Extras.swift
//  MarkEditMac
//
//  Created by cyan on 10/14/24.
//

import AppKit
import MarkEditKit

extension NSDocumentController {
  var editorDocuments: [EditorDocument] {
    documents.compactMap { $0 as? EditorDocument }
  }

  var hasOutdatedDocuments: Bool {
    !outdatedDocuments.isEmpty
  }

  func saveOutdatedDocuments(userInitiated: Bool = false) async -> Bool {
    for document in outdatedDocuments {
      guard await document.waitUntilSaveCompleted(userInitiated: userInitiated) else {
        return false
      }
    }
    // Another document can receive edits while a save panel is open.
    return !hasOutdatedDocuments
  }
}

// MARK: - Private

private extension NSDocumentController {
  var outdatedDocuments: [EditorDocument] {
    editorDocuments.filter { $0.isOutdated || $0.isDocumentEdited || $0.hasUnautosavedChanges }
  }
}
