#if os(macOS)
  import AppKit
  import SwiftUI
  import WebKit

  /// A ```mermaid fence drawn by the bundled mermaid.js (Resources/mermaid.min.js, v11) in a WKWebView.
  /// Preview-only, never on the editor path (spec §5.8 `006`). The page is offline: a CSP forbids every
  /// network load and mermaid runs with `securityLevel: strict`, so a document cannot make it fetch or run script.
  struct MermaidView: NSViewRepresentable {
    let source: String
    @Environment(\.colorScheme) private var scheme
    @State private var height: CGFloat = 60

    private static let script: String? = Bundle.module.url(forResource: "mermaid.min", withExtension: "js")
      .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
      let config = WKWebViewConfiguration()
      if let js = Self.script {
        config.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
      }
      config.userContentController.add(context.coordinator, name: "height")
      let web = WKWebView(frame: .zero, configuration: config)
      web.setValue(false, forKey: "drawsBackground")  // show the preview's canvas behind the diagram
      context.coordinator.onHeight = { h in height = h }
      web.loadHTMLString(Self.page(dark: scheme == .dark), baseURL: nil)
      context.coordinator.web = web
      return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
      context.coordinator.render(source)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
      CGSize(width: proposal.width ?? 600, height: height)
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
      web.configuration.userContentController.removeScriptMessageHandler(forName: "height")
    }

    private static func page(dark: Bool) -> String {
      """
      <!doctype html><html><head><meta charset="utf-8">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:">
      <style>html,body{margin:0;background:transparent;font:13px -apple-system}#d{overflow-x:auto}
      #e{color:#e5534b;font:12px ui-monospace,monospace;white-space:pre-wrap}</style></head>
      <body><div id="d"></div><div id="e"></div><script>
      mermaid.initialize({startOnLoad:false,securityLevel:'strict',theme:'\(dark ? "dark" : "default")'});
      let n=0;
      function post(){webkit.messageHandlers.height.postMessage(document.body.scrollHeight)}
      async function render(src){
        const id='m'+(++n);
        try{const r=await mermaid.render(id,src);if(id!=='m'+n)return;
          document.getElementById('d').innerHTML=r.svg;document.getElementById('e').textContent=''}
        catch(err){document.getElementById('e').textContent=String(err.message||err);document.getElementById(id)?.remove()}
        post()
      }
      </script></body></html>
      """
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
      weak var web: WKWebView? { didSet { web?.navigationDelegate = self } }
      var onHeight: (CGFloat) -> Void = { _ in }
      private var loaded = false, pending: String?, shown: String?

      func render(_ source: String) {
        guard source != shown else { return }
        guard loaded, let web else { pending = source; return }
        shown = source
        let arg = (try? String(data: JSONEncoder().encode(source), encoding: .utf8)) ?? "\"\""
        web.evaluateJavaScript("render(\(arg))")
      }

      func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        if let p = pending { pending = nil; render(p) }
      }

      // Links inside a diagram never navigate the preview.
      func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.navigationType == .other ? .allow : .cancel)
      }

      func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let h = message.body as? Double { onHeight(max(CGFloat(h), 20)) }
      }
    }
  }
#endif
