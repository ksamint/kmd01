import AppKit
import WebKit

@MainActor
final class Harness: NSObject, NSApplicationDelegate, WKNavigationDelegate {
  private var windows: [NSWindow] = []
  private var views: [WKWebView] = []
  private var finished: Set<Int> = []
  private var ready: Set<Int> = []
  private var completing = false
  private let cycle = CommandLine.arguments.dropFirst().first ?? "unknown"

  private let variant = "public-default"

  private func log(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
  }

  private func fail(_ message: String) {
    guard !completing else { return }
    completing = true
    // Remain alive for the external watchdog to capture the failing state.
    log("AB_FAILURE \(message)")
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    log("AB_START variant=\(variant) cycle=\(cycle) pid=\(ProcessInfo.processInfo.processIdentifier)")
    // Two independent document windows, followed by two hidden previews.
    for index in 0..<4 { createView(index: index, visible: index < 2) }
    // Match the app's delayed creation of its retained spare editor.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      self?.createView(index: 4, visible: false)
    }
    NSApp.activate(ignoringOtherApps: true)
  }

  private func createView(index: Int, visible: Bool) {
    // Public WebKit API control: no production configuration or private selectors.
    let configuration = WKWebViewConfiguration()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = self
    views.append(webView)
    if visible {
      let window = NSWindow(
        contentRect: NSRect(x: 60 + index * 80, y: 70 + index * 60, width: 720, height: 480),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
      )
      window.title = "WebKit A/B \(cycle) view \(index)"
      window.isReleasedWhenClosed = false
      window.contentView = webView
      windows.append(window)
      window.makeKeyAndOrderFront(nil)
    }
    log("AB_VIEW index=\(index) visible=\(visible)")
    // Identical local data for all five views. No external resources or requests.
    let html = """
    <!doctype html><html><head><meta charset="utf-8"><title>WebKit A/B</title>
    <style>html,body{margin:0;background:#fff;color:#161616;font:18px monospace}
    main{padding:30px;border-left:solid 12px #3865bb;min-height:200px}</style></head>
    <body><main id="marker">WK_AB_MARKER_\(cycle)</main><script>
    window.__abFrames = [];
    requestAnimationFrame(first => {
      window.__abFrames.push(first);
      requestAnimationFrame(second => window.__abFrames.push(second));
    });
    </script></body></html>
    """
    webView.loadHTMLString(html, baseURL: URL(string: "https://webkit-ab.invalid/"))
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
    guard let index = views.firstIndex(where: { $0 === webView }) else { return }
    finished.insert(index)
    log("AB_LOADED index=\(index)")
    if index < 2 { checkVisible(webView, index: index) }
    completeIfReady()
  }

  private func checkVisible(_ webView: WKWebView, index: Int) {
    guard !completing else { return }
    // Evaluation only reads state. The page itself records two real rAF ticks.
    webView.evaluateJavaScript("""
      (() => {
        const node = document.getElementById('marker');
        const rect = node?.getBoundingClientRect();
        return {marker: node?.textContent, state: document.readyState,
          frames: window.__abFrames, width: rect?.width, height: rect?.height,
          visibility: document.visibilityState};
      })()
      """) { [weak self, weak webView] value, error in
      guard let self, let webView, !self.completing else { return }
      if let error { self.fail("evaluate index=\(index) error=\(error)"); return }
      guard let result = value as? [String: Any],
            result["marker"] as? String == "WK_AB_MARKER_\(self.cycle)",
            result["state"] as? String == "complete",
            let width = result["width"] as? Double, width > 0,
            let height = result["height"] as? Double, height > 0 else {
        self.fail("unexpected DOM index=\(index) value=\(String(describing: value))")
        return
      }
      let frames = result["frames"] as? [Double] ?? []
      guard frames.count == 2, frames[1] > frames[0],
            result["visibility"] as? String == "visible" else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak webView] in
          guard let self, let webView else { return }
          self.checkVisible(webView, index: index)
        }
        return
      }
      // A snapshot callback provides a rendering completion check beyond rAF.
      // Pixels are not saved or OCR-verified; rAF alone would not prove GPU output.
      webView.takeSnapshot(with: nil) { [weak self] image, error in
        guard let self, !self.completing else { return }
        guard error == nil, let image, image.size.width > 0, image.size.height > 0 else {
          self.fail("snapshot index=\(index) error=\(String(describing: error))")
          return
        }
        self.ready.insert(index)
        self.log("AB_READY index=\(index) marker=WK_AB_MARKER_\(self.cycle) frames=\(frames) snapshot=\(image.size)")
        self.completeIfReady()
      }
    }
  }

  private func completeIfReady() {
    guard !completing, ready.count == 2, finished.count == 5 else { return }
    completing = true
    // Keep hidden peers alive long enough for idle scheduling to occur.
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
      guard let self else { return }
      self.log("AB_PASS variant=\(self.variant) cycle=\(self.cycle) visible=2 loaded=5")
      NSApp.terminate(nil)
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
    fail("navigation \(error)")
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
    fail("provisional \(error)")
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    fail("web-content-terminated")
  }
}

@main
struct Main {
  @MainActor static func main() {
    let app = NSApplication.shared
    let delegate = Harness()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}
