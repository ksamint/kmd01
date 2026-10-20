//
//  Application.swift
//  MarkEditMac
//
//  Created by cyan on 4/24/24.
//

import AppKit
import Darwin
import Dispatch
import ExtensionCore
import MarkEditKit
import SharedUI

@main
final class Application: NSApplication {
  static func main() {
    // The Agent panel and the MCP bridges write to Unix sockets and pipes whose
    // peer (a CLI the user can cancel) may already be gone. Without this, the
    // resulting EPIPE is delivered as SIGPIPE and terminates the whole app
    // instead of surfacing as a write error.
    signal(SIGPIPE, SIG_IGN)

    if let socketIndex = CommandLine.arguments.firstIndex(of: "--mcp-live-socket"),
       let capabilityIndex = CommandLine.arguments.firstIndex(of: "--mcp-capability-file"),
       CommandLine.arguments.indices.contains(socketIndex + 1),
       CommandLine.arguments.indices.contains(capabilityIndex + 1) {
      let socketPath = CommandLine.arguments[socketIndex + 1]
      let capabilityFileURL = URL(fileURLWithPath: CommandLine.arguments[capabilityIndex + 1])
      Task.detached {
        do {
          try await LocalMCPUnixClient.run(
            socketPath: socketPath,
            capabilityFileURL: capabilityFileURL
          )
          Darwin.exit(EXIT_SUCCESS)
        } catch {
          let message = Data("kmd live MCP: \(error.localizedDescription)\n".utf8)
          try? FileHandle.standardError.write(contentsOf: message)
          Darwin.exit(EXIT_FAILURE)
        }
      }
      dispatchMain()
    }

    if CommandLine.arguments.contains("--mcp-stdio") {
      Task.detached {
        do {
          try await LocalMCPServer.run()
          Darwin.exit(EXIT_SUCCESS)
        } catch {
          let message = Data("kmd MCP: \(error.localizedDescription)\n".utf8)
          try? FileHandle.standardError.write(contentsOf: message)
          Darwin.exit(EXIT_FAILURE)
        }
      }
      dispatchMain()
    }

    NSObject.swizzleAccessibilityBundlesOnce
    NSMenu.swizzleIsUpdatedExcludingContentTypesOnce
    NSSpellChecker.swizzleInlineCompletionEnabledOnce
    NSSpellChecker.swizzleShowCompletionForCandidateOnce
    NSSpellChecker.swizzleCorrectionIndicatorOnce

    UserDefaults.overwriteTextCheckerOnce()
    AppCustomization.createFiles()
    ExtensionConfig.reconcileInstalled()

    let application = Self.shared
    let delegate = AppDelegate()

    application.delegate = delegate
    delegate.startAccessingGrantedFolder()

    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
  }

  override func sendAction(_ action: Selector, to target: Any?, from sender: Any?) -> Bool {
    if action == #selector(NSText.paste(_:)) {
      sanitizePasteboard()
    }

    // Ensure lines are fully selected for a better Writing Tools experience
    if #available(macOS 15.1, *), action == sel_getUid("showWritingTools:") {
      Logger.assert(sender is NSMenuItem, "Invalid sender was found")
      Logger.assert(target == nil || (target as? AnyObject)?.className == "WKMenuTarget", "Invalid target was found")

      if AppWritingTools.shouldReselect(withItem: sender) {
        ensureWritingToolsSelectionRect()
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        super.sendAction(action, to: target, from: sender)
      }

      return true
    }

    return super.sendAction(action, to: target, from: sender)
  }
}

// MARK: - Private

private extension Application {
  func sanitizePasteboard() {
    let textContent = currentEditor?.document?.stringValue
    let lineEndings = AppPreferences.General.defaultLineEndings.characters
    NSPasteboard.general.sanitize(lineBreak: textContent?.getLineBreak(defaultValue: lineEndings))
  }

  func ensureWritingToolsSelectionRect() {
    guard let currentEditor else {
      return Logger.assertFail("Invalid keyWindow was found")
    }

    currentEditor.ensureWritingToolsSelectionRect()
  }
}
