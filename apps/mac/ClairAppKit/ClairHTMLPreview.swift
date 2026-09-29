#if os(macOS)
  import ClairShared
  import AppKit
  import ClairDesignSystem
  import SwiftUI
  import WebKit

  /// Renders a self-contained artifact from the editor buffer. Relative `<script src>` /
  /// `<link href>` references resolve against the file's own folder (never elsewhere in the
  /// Project or the rest of the Mac); a file with no known folder falls back to no base URL.
  struct HTMLPreviewPane: View {
    let buffers: EditorBuffers
    let root: String?
    let path: String

    var body: some View {
      if case .ready(let manager)? = buffers.peek(path) {
        let _ = buffers.edits[path]
        HTMLWebView(html: manager.buffer.snapshot.string(), directory: HTMLPreviewPane.directory(root: root, path: path))
          .accessibilityLabel(tr("HTML プレビュー"))
      } else {
        Text(tr("HTML ファイルを開くとプレビューを表示します。"))
          .font(.system(size: 12)).foregroundStyle(DesignTokens.Color.textTertiary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(DesignTokens.Color.canvas)
      }
    }

    /// The file's own containing folder, provided it can't resolve (via `..`/symlinks) outside `root`.
    static func directory(root: String?, path: String) -> URL? {
      guard let root, !path.isEmpty else { return nil }
      let dir = (root as NSString).appendingPathComponent((path as NSString).deletingLastPathComponent)
      let resolved = URL(fileURLWithPath: dir).standardizedFileURL.resolvingSymlinksInPath()
      let top = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
      let prefix = top.hasSuffix("/") ? top : top + "/"
      return resolved.path == top || resolved.path.hasPrefix(prefix) ? resolved : nil
    }
  }

  private struct HTMLWebView: NSViewRepresentable {
    let html: String
    let directory: URL?

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
      guard context.coordinator.loadedHTML != html || context.coordinator.grantedDirectory != directory else { return }
      context.coordinator.loadedHTML = html
      // Granting read access to the folder is sticky for the WKWebView's lifetime, so it only
      // needs to happen once per folder; loadHTMLString below still carries every live edit.
      if let directory, context.coordinator.grantedDirectory != directory {
        context.coordinator.grantedDirectory = directory
        webView.loadFileURL(directory, allowingReadAccessTo: directory)
      }
      webView.loadHTMLString(html, baseURL: directory)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
      var loadedHTML: String?
      var grantedDirectory: URL?

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
        // Lets our own loadFileURL call (granting sibling-file read access) through; it navigates
        // to a file:// URL with navigationType .other, same as this call itself would produce.
        if navigationAction.navigationType == .other, url.isFileURL {
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
