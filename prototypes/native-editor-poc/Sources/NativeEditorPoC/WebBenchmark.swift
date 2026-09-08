import AppKit
import WebKit

// Runs the frozen Clair EditorWeb assets, not the whole Clair application.
final class WebBenchmark: NSObject, NSApplicationDelegate, WKURLSchemeHandler, WKScriptMessageHandler {
    var window: NSWindow!, web: WKWebView!
    let root = URL(fileURLWithPath: ".build/baseline-web", isDirectory: true)
    var launch = DispatchTime.now().uptimeNanoseconds
    var bytesReceived = 0, messages = 0
    var started = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(self, forURLScheme: "clair-editor")
        config.userContentController.add(self, name: "clairEditor")
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1164, height: 710), configuration: config)
        window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Clair Web baseline harness"; window.contentView = web
        window.makeKeyAndOrderFront(nil)
        web.load(URLRequest(url: URL(string: "clair-editor://editor/index.html")!))
    }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let path = task.request.url!.path
        let url = root.appendingPathComponent(path == "/" ? "index.html" : String(path.dropFirst()))
        do {
            let data = try Data(contentsOf: url)
            let mime = ["html":"text/html", "js":"application/javascript", "css":"text/css"][url.pathExtension] ?? "application/octet-stream"
            task.didReceive(URLResponse(url: task.request.url!, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8")); task.didReceive(data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let value = message.body as? [String: Any] else { return }
        if let content = value["content"] as? String { bytesReceived += content.utf8.count; messages += 1 }
        if value["type"] as? String == "ready", !started {
            started = true
            Task { @MainActor in await run() }
        }
    }
    @MainActor func eval(_ js: String) async throws -> Any? { try await web.evaluateJavaScript(js) }
    @MainActor func run() async {
        var results: [[String: Any]] = [["asset_ready_ms": Double(DispatchTime.now().uptimeNanoseconds - launch)/1e6]]
        do {
            for name in ["normal.swift", "1mb.swift", "10mb.swift", "long-line.ts"] {
                print("WEB START \(name)"); fflush(stdout)
                let text = try String(contentsOfFile: "fixtures/" + name, encoding: .utf8)
                let json = String(data: try JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!
                _ = try await eval("window.clairEditor.configure({path:'\(name)',fontSize:13,wordWrap:false})")
                let start = DispatchTime.now().uptimeNanoseconds
                _ = try await eval("window.clairEditor.setDocument(\(json)[0])")
                let open = Double(DispatchTime.now().uptimeNanoseconds - start)/1e6
                await pump(1)
                bytesReceived = 0; messages = 0
                var select: [Double] = [], scroll: [Double] = []
                for i in 0..<20 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    _ = try await eval("window.clairEditor.reveal({from:\(i),to:\(i)})")
                    select.append(Double(DispatchTime.now().uptimeNanoseconds - start)/1e6)
                    await pump(0.02)
                }
                for i in 0..<20 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    _ = try await eval("document.querySelector('.cm-scroller').scrollTop=\(i * 200)")
                    scroll.append(Double(DispatchTime.now().uptimeNanoseconds - start)/1e6)
                    await pump(0.02)
                }
                results.append(["fixture":name,"bytes":text.utf8.count,"set_document_roundtrip_ms":open,"selection_roundtrip_ms":select,"scroll_roundtrip_ms":scroll,"selection_bridge_content_bytes":bytesReceived,"selection_bridge_messages":messages,"note":"WKWebView isolated current working-copy assets; includes JS/native roundtrip; no whole Clair host or actual key-to-photon measurement"])
                let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted,.sortedKeys])
                try data.write(to: URL(fileURLWithPath:"evidence/web.json"))
            }
        } catch { print("WEB ERROR \(error)") }
        fflush(stdout); NSApp.terminate(nil)
    }
}
