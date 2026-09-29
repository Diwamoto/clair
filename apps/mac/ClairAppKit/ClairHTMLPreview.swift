#if os(macOS)
  import AppKit
  import ClairDesignSystem
  import SwiftUI
  import WebKit

  /// Renders a self-contained artifact from the editor buffer. A nil base URL keeps
  /// relative file references away from the Project and the rest of the Mac.
  struct HTMLPreviewPane: View {
    let buffers: EditorBuffers
    let path: String

    var body: some View {
      if case .ready(let manager)? = buffers.peek(path) {
        let _ = buffers.edits[path]
        HTMLWebView(html: manager.buffer.snapshot.string())
          .accessibilityLabel("HTML プレビュー")
      } else {
        Text("HTML ファイルを開くとプレビューを表示します。")
          .font(.system(size: 12)).foregroundStyle(DesignTokens.Color.textTertiary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(DesignTokens.Color.canvas)
      }
    }
  }

  private struct HTMLWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
      let configuration = WKWebViewConfiguration()
      configuration.websiteDataStore = .nonPersistent()
      configuration.defaultWebpagePreferences.allowsContentJavaScript = true
      let webView = WKWebView(frame: .zero, configuration: configuration)
      webView.navigationDelegate = context.coordinator
      return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
      guard context.coordinator.loadedHTML != html else { return }
      context.coordinator.loadedHTML = html
      webView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
      var loadedHTML: String?

      func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
      ) {
        guard let url = navigationAction.request.url else {
          decisionHandler(.cancel)
          return
        }
        if url.scheme == "about" {
          decisionHandler(.allow)
          return
        }
        if navigationAction.navigationType == .linkActivated,
           ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
          NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
      }
    }
  }
#endif
