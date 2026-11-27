#if os(macOS)
  import ClairShared
  import AppKit
  import ClairDesignSystem
  import SwiftUI
  import UniformTypeIdentifiers
  import WebKit

  /// Renders an artifact from the editor buffer. Relative `<script src>` / `<link href>` / `fetch`
  /// references resolve against the file's own folder only (never elsewhere in the Project or the
  /// rest of the Mac); a file with no known folder falls back to no base URL.
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
          .font(Typography.font(Typography.chrome)).foregroundStyle(DesignTokens.Color.textTertiary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(DesignTokens.Color.canvas)
      }
    }

    /// The file's own containing folder (symlinks resolved). `path` is relative to `root`, or absolute; a file
    /// outside the Project (`../..`, an agent's artifact opened with `clair preview`) still gets its own folder.
    static func directory(root: String?, path: String) -> URL? {
      guard !path.isEmpty, let file = path.hasPrefix("/") ? path : root.map({ ($0 as NSString).appendingPathComponent(path) })
      else { return nil }
      return URL(fileURLWithPath: (file as NSString).deletingLastPathComponent, isDirectory: true)
        .standardizedFileURL.resolvingSymlinksInPath()
    }
  }

  /// Serves the preview's sibling files under `clair-preview://file/…`, confined to one folder. Clair reads the
  /// files itself instead of handing WebKit a file:// grant: the grant (`loadFileURL`) raced the live
  /// `loadHTMLString` and blanked the first load, and without it file:// pages could read `../` freely.
  /// Same-origin also makes `fetch('data.json')` and `<script type=module>` work.
  final class HTMLPreviewFiles: NSObject, WKURLSchemeHandler {
    static let scheme = "clair-preview"
    static let base = URL(string: "clair-preview://file/")!
    var directory: URL?

    /// The file under `directory` that `url` names, or nil when it would leave the folder (`..`, a symlink out).
    static func file(for url: URL, in directory: URL) -> URL? {
      let path = url.path.drop(while: { $0 == "/" })
      guard !path.isEmpty else { return nil }
      let file = directory.appendingPathComponent(String(path)).standardizedFileURL.resolvingSymlinksInPath()
      let top = directory.standardizedFileURL.resolvingSymlinksInPath().path
      return file.path.hasPrefix(top.hasSuffix("/") ? top : top + "/") ? file : nil
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
      // ponytail: synchronous read on the main thread — preview siblings are small local files.
      guard let url = task.request.url, let directory, let file = Self.file(for: url, in: directory),
        let data = FileManager.default.contents(atPath: file.path)
      else {
        task.didFailWithError(URLError(.fileDoesNotExist))
        return
      }
      let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
      task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)", "Cache-Control": "no-store"])!)
      task.didReceive(data)
      task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
  }

  struct HTMLWebView: NSViewRepresentable {
    let html: String
    let directory: URL?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
      let configuration = WKWebViewConfiguration()
      configuration.websiteDataStore = .nonPersistent()
      configuration.defaultWebpagePreferences.allowsContentJavaScript = true
      configuration.setURLSchemeHandler(context.coordinator.files, forURLScheme: HTMLPreviewFiles.scheme)
      let webView = WKWebView(frame: .zero, configuration: configuration)
      webView.navigationDelegate = context.coordinator
      return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
      let files = context.coordinator.files
      guard context.coordinator.loadedHTML != html || files.directory != directory else { return }
      context.coordinator.loadedHTML = html
      files.directory = directory
      webView.loadHTMLString(html, baseURL: directory == nil ? nil : HTMLPreviewFiles.base)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
      var loadedHTML: String?
      let files = HTMLPreviewFiles()

      func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
      ) {
        guard let url = navigationAction.request.url else {
          decisionHandler(.cancel)
          return
        }
        // The page itself (loadHTMLString), in-page `#anchor` jumps, and sibling-file iframes; no other navigation.
        let page = URL(string: url.absoluteString.components(separatedBy: "#")[0])
        if url.scheme == "about" || (navigationAction.targetFrame?.isMainFrame == false && url.scheme == HTMLPreviewFiles.scheme)
          || (page == HTMLPreviewFiles.base && (navigationAction.navigationType == .other || url.fragment != nil))
        {
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
