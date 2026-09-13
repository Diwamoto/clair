@preconcurrency import AppKit
import Foundation
import SwiftUI
@preconcurrency import WebKit

enum ProjectEditorCommand {
  case undo
  case redo
}

private final class CodeMirrorEditorSchemeHandler: NSObject, WKURLSchemeHandler {
  private let rootURL: URL

  init(rootURL: URL) {
    self.rootURL = rootURL.standardizedFileURL
  }

  func webView(_: WKWebView, start task: WKURLSchemeTask) {
    do {
      guard let requestURL = task.request.url else {
        throw NSError(
          domain: "Clair.EditorWeb",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "The editor resource URL was missing."]
        )
      }

      let path = requestURL.path
      let relativePath = path.hasPrefix("/") ? String(path.dropFirst()) : path
      guard !relativePath.isEmpty,
        !relativePath.split(separator: "/").contains("..")
      else {
        throw NSError(
          domain: "Clair.EditorWeb",
          code: 2,
          userInfo: [NSLocalizedDescriptionKey: "The editor resource path was invalid."]
        )
      }

      let fileURL = rootURL.appendingPathComponent(relativePath).standardizedFileURL
      guard fileURL.path == rootURL.path || fileURL.path.hasPrefix(rootURL.path + "/") else {
        throw NSError(
          domain: "Clair.EditorWeb",
          code: 3,
          userInfo: [NSLocalizedDescriptionKey: "The editor resource escaped its bundle."]
        )
      }

      let data = try Data(contentsOf: fileURL)
      let response = URLResponse(
        url: requestURL,
        mimeType: Self.mimeType(for: fileURL.pathExtension),
        expectedContentLength: data.count,
        textEncodingName: Self.isTextResource(fileURL.pathExtension) ? "utf-8" : nil
      )
      task.didReceive(response)
      task.didReceive(data)
      task.didFinish()
    } catch {
      task.didFailWithError(error)
    }
  }

  func webView(_: WKWebView, stop _: WKURLSchemeTask) {}

  private static func isTextResource(_ pathExtension: String) -> Bool {
    ["css", "html", "js", "json", "map", "txt"].contains(pathExtension.lowercased())
  }

  private static func mimeType(for pathExtension: String) -> String {
    switch pathExtension.lowercased() {
    case "css":
      "text/css"
    case "html":
      "text/html"
    case "js", "mjs":
      "text/javascript"
    case "json", "map":
      "application/json"
    default:
      "application/octet-stream"
    }
  }
}

@MainActor
struct CodeMirrorEditorView: NSViewRepresentable {
  @ObservedObject var document: ProjectEditorTab
  let selection: ProjectEditorSelection?
  let fontSize: CGFloat
  let wordWrap: Bool
  let breakpoints: [Int]
  let onToggleBreakpoint: ((Int) -> Void)?
  let onSave: () -> Void

  init(
    document: ProjectEditorTab,
    selection: ProjectEditorSelection? = nil,
    fontSize: CGFloat = 13,
    wordWrap: Bool = false,
    breakpoints: [Int] = [],
    onToggleBreakpoint: ((Int) -> Void)? = nil,
    onSave: @escaping () -> Void
  ) {
    self.document = document
    self.selection = selection
    self.fontSize = fontSize
    self.wordWrap = wordWrap
    self.breakpoints = breakpoints
    self.onToggleBreakpoint = onToggleBreakpoint
    self.onSave = onSave
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(document: document)
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    let userContentController = WKUserContentController()
    userContentController.add(context.coordinator, name: "clairEditor")
    configuration.userContentController = userContentController

    let editorRootURL = Bundle.main.url(
      forResource: "index",
      withExtension: "html",
      subdirectory: "EditorWeb"
    )?.deletingLastPathComponent()
    if let editorRootURL {
      configuration.setURLSchemeHandler(
        CodeMirrorEditorSchemeHandler(rootURL: editorRootURL),
        forURLScheme: "clair-editor"
      )
    }

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.underPageBackgroundColor = WorkspaceChrome.nsCanvas
    context.coordinator.webView = webView
    context.coordinator.update(
      document: document,
      selection: selection,
      fontSize: fontSize,
      wordWrap: wordWrap,
      breakpoints: breakpoints,
      onToggleBreakpoint: onToggleBreakpoint,
      onSave: onSave
    )

    if editorRootURL != nil {
      webView.load(URLRequest(url: URL(string: "clair-editor://editor/index.html")!))
    } else {
      webView.loadHTMLString(
        "<html><body style=\"background:#282c34;color:#f1f3ef;font:13px monospace\">Editor resource is missing.</body></html>",
        baseURL: nil
      )
    }
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    context.coordinator.webView = webView
    context.coordinator.update(
      document: document,
      selection: selection,
      fontSize: fontSize,
      wordWrap: wordWrap,
      breakpoints: breakpoints,
      onToggleBreakpoint: onToggleBreakpoint,
      onSave: onSave
    )
  }

  static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
    webView.navigationDelegate = nil
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: "clairEditor"
    )
    coordinator.detach()
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private(set) var document: ProjectEditorTab
    weak var webView: WKWebView?
    private var isReady = false
    private var isApplyingEditorChange = false
    private var lastRenderedContent: String?
    private var lastRenderedRevision: UInt64?
    private var lastConfiguration: WebEditorConfiguration?
    private var lastSelectionRequest: ProjectEditorSelection?
    private var lastEditorSelection: WebEditorSelection?
    private var lastEditorScrollTop: Double?
    private var onSave: (() -> Void)?
    private var onToggleBreakpoint: ((Int) -> Void)?
    private var requestedFontSize: CGFloat = 13
    private var requestedWordWrap = false
    private var requestedBreakpoints: [Int] = []

    init(document: ProjectEditorTab) {
      self.document = document
    }

    func update(
      document: ProjectEditorTab,
      selection: ProjectEditorSelection?,
      fontSize: CGFloat,
      wordWrap: Bool,
      breakpoints: [Int],
      onToggleBreakpoint: ((Int) -> Void)?,
      onSave: @escaping () -> Void
    ) {
      if self.document.id != document.id {
        self.document.detachEditorCommandHandler()
        self.document = document
        lastRenderedContent = nil
        lastRenderedRevision = nil
        lastConfiguration = nil
        lastSelectionRequest = nil
        lastEditorSelection = nil
        lastEditorScrollTop = nil
        attachCommandHandler()
      }
      self.onSave = onSave
      self.onToggleBreakpoint = onToggleBreakpoint
      requestedFontSize = fontSize
      requestedWordWrap = wordWrap
      requestedBreakpoints = breakpoints
      guard isReady, !isApplyingEditorChange else {
        return
      }

      let nextConfiguration = WebEditorConfiguration(
        path: document.url.path,
        fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
        fontSize: fontSize,
        background: "#282c34",
        textColor: "#f1f3ef",
        wordWrap: wordWrap,
        readOnly: document.isMissing || document.isReadOnly || document.loadError != nil,
        breakpoints: Array(Set(breakpoints)).sorted()
      )
      if lastConfiguration != nextConfiguration {
        lastConfiguration = nextConfiguration
        evaluate(
          method: "configure",
          argument: nextConfiguration
        )
      }

      if lastRenderedContent != document.content
        || lastRenderedRevision != document.editorRevision
      {
        lastRenderedContent = document.content
        lastRenderedRevision = document.editorRevision
        let requestedSelection = selection.flatMap { webSelection(for: $0) }
        sendDocument(
          document.content,
          selection: requestedSelection ?? preservedSelection(),
          restoreScroll: requestedSelection == nil
        )
      } else if let selection, selection != lastSelectionRequest {
        reveal(selection)
      }
    }

    func detach() {
      if isReady {
        evaluate(method: "releaseDocument", argument: document.url.path)
      }
      document.detachEditorCommandHandler()
      onSave = nil
      onToggleBreakpoint = nil
      webView = nil
      isReady = false
    }

    func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      guard message.name == "clairEditor", let body = message.body as? [String: Any],
        let type = body["type"] as? String
      else {
        return
      }

      switch type {
      case "ready":
        isReady = true
        attachCommandHandler()
        lastConfiguration = nil
        lastRenderedContent = nil
        lastRenderedRevision = nil
        update(
          document: document,
          selection: lastSelectionRequest,
          fontSize: requestedFontSize,
          wordWrap: requestedWordWrap,
          breakpoints: requestedBreakpoints,
          onToggleBreakpoint: onToggleBreakpoint,
          onSave: onSave ?? {}
        )
      case "change":
        guard let change = ProjectEditorWebChange(messageBody: body)
        else {
          return
        }
        do {
          isApplyingEditorChange = true
          defer { isApplyingEditorChange = false }
          _ = try document.applyEditorChange(change)
          lastRenderedContent = document.content
          lastRenderedRevision = document.editorRevision
          lastEditorSelection = document.editorSelection.map {
            WebEditorSelection(from: $0.location, to: $0.end)
          }
          lastEditorScrollTop = document.editorScrollTop
        } catch {
          // A stale or malformed transaction must not be silently dropped.
          // Send the authoritative native snapshot back to the web editor.
          resynchronizeEditor()
        }
      case "selection":
        guard let change = ProjectEditorWebSelectionChange(messageBody: body) else {
          return
        }
        document.applyEditorSelection(change)
        lastEditorSelection = document.editorSelection.map {
          WebEditorSelection(from: $0.location, to: $0.end)
        }
        lastEditorScrollTop = document.editorScrollTop
      case "breakpoint":
        guard let line = (body["line"] as? NSNumber)?.intValue, line > 0 else {
          return
        }
        onToggleBreakpoint?(line)
      case "save":
        onSave?()
      default:
        break
      }
    }

    func webView(
      _ webView: WKWebView,
      didFinish navigation: WKNavigation!
    ) {
      WorkspaceChrome.configureThinScrollbars(in: webView)
    }

    func webView(
      _ webView: WKWebView,
      didFail navigation: WKNavigation!,
      withError _: Error
    ) {
      isReady = false
    }

    private func attachCommandHandler() {
      document.setEditorCommandHandler { [weak self] command in
        self?.perform(command)
      }
    }

    private func perform(_ command: ProjectEditorCommand) {
      guard isReady else {
        return
      }
      switch command {
      case .undo:
        evaluate(method: "undo")
      case .redo:
        evaluate(method: "redo")
      }
    }

    private func sendDocument(
      _ content: String,
      selection: WebEditorSelection?,
      restoreScroll: Bool = true
    ) {
      let argument = WebEditorDocument(
        content: content,
        revision: document.editorRevision,
        selection: selection,
        scrollTop: restoreScroll ? preservedScrollTop() : nil
      )
      evaluate(method: "setDocument", argument: argument)
      lastRenderedContent = content
      lastRenderedRevision = document.editorRevision
      if let selection {
        lastEditorSelection = selection
      }
      applySelectionRequestIfNeeded()
    }

    private func resynchronizeEditor() {
      guard isReady else {
        return
      }
      sendDocument(document.content, selection: preservedSelection())
    }

    private func webSelection(for selection: ProjectEditorSelection) -> WebEditorSelection? {
      guard let range = document.selectionRange(for: selection) else {
        return nil
      }
      return WebEditorSelection(
        from: range.location,
        to: range.location + range.length
      )
    }

    private func reveal(_ selection: ProjectEditorSelection) {
      guard let range = document.selectionRange(for: selection) else {
        return
      }
      let webSelection = WebEditorSelection(
        from: range.location,
        to: range.location + range.length
      )
      evaluate(method: "reveal", argument: webSelection)
      lastEditorSelection = webSelection
      lastSelectionRequest = selection
      clearSelectionRequestIfStillCurrent(selection)
    }

    private func applySelectionRequestIfNeeded() {
      guard let selection = currentSelectionRequest,
        selection != lastSelectionRequest
      else {
        return
      }
      reveal(selection)
    }

    private var currentSelectionRequest: ProjectEditorSelection? {
      document.selectionRequest
    }

    private func clearSelectionRequestIfStillCurrent(_ selection: ProjectEditorSelection) {
      DispatchQueue.main.async { [weak self] in
        guard let self, self.document.selectionRequest == selection else {
          return
        }
        self.document.clearSelectionRequest()
      }
    }

    private func preservedSelection() -> WebEditorSelection? {
      if let selection = document.editorSelection {
        return WebEditorSelection(from: selection.location, to: selection.end)
      }
      guard let lastEditorSelection else {
        return nil
      }
      let length = document.content.utf16.count
      let from = min(max(lastEditorSelection.from, 0), length)
      let to = min(max(lastEditorSelection.to, from), length)
      return WebEditorSelection(
        from: from,
        to: to
      )
    }

    private func preservedScrollTop() -> Double? {
      if document.editorScrollTop > 0 {
        return document.editorScrollTop
      }
      return lastEditorScrollTop
    }

    private func evaluate<T: Encodable>(method: String, argument: T) {
      guard let webView else {
        return
      }
      guard let data = try? JSONEncoder().encode(argument),
        let json = String(data: data, encoding: .utf8)
      else {
        return
      }
      webView.evaluateJavaScript("window.clairEditor?.\(method)(\(json));")
    }

    private func evaluate(method: String) {
      webView?.evaluateJavaScript("window.clairEditor?.\(method)();")
    }
  }
}

private struct WebEditorConfiguration: Codable, Equatable {
  let path: String
  let fontFamily: String
  let fontSize: CGFloat
  let background: String
  let textColor: String
  let wordWrap: Bool
  let readOnly: Bool
  let breakpoints: [Int]
}

private struct WebEditorDocument: Codable {
  let content: String
  let revision: UInt64
  let selection: WebEditorSelection?
  let scrollTop: Double?
}

private struct WebEditorSelection: Codable {
  let from: Int
  let to: Int

  init(from: Int, to: Int) {
    self.from = from
    self.to = to
  }

  init?(dictionary: [String: Any]?) {
    guard let dictionary,
      let from = (dictionary["from"] as? NSNumber)?.intValue,
      let to = (dictionary["to"] as? NSNumber)?.intValue
    else {
      return nil
    }
    self.init(from: from, to: to)
  }
}

@MainActor
struct CodeMirrorDiffView: NSViewRepresentable {
  let path: String
  let patch: String
  let fontSize: CGFloat

  init(path: String, patch: String, fontSize: CGFloat = 12) {
    self.path = path
    self.patch = patch
    self.fontSize = fontSize
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    let userContentController = WKUserContentController()
    userContentController.add(context.coordinator, name: "clairDiffViewer")
    configuration.userContentController = userContentController

    let editorRootURL = Bundle.main.url(
      forResource: "index",
      withExtension: "html",
      subdirectory: "EditorWeb"
    )?.deletingLastPathComponent()
    if let editorRootURL {
      configuration.setURLSchemeHandler(
        CodeMirrorEditorSchemeHandler(rootURL: editorRootURL),
        forURLScheme: "clair-editor"
      )
    }

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.underPageBackgroundColor = WorkspaceChrome.nsCanvas
    context.coordinator.webView = webView
    context.coordinator.update(path: path, patch: patch, fontSize: fontSize)

    if editorRootURL != nil {
      webView.load(URLRequest(url: URL(string: "clair-editor://editor/diff.html")!))
    } else {
      webView.loadHTMLString(
        "<html><body style=\"background:#282c34;color:#f1f3ef;font:13px monospace\">Editor resource is missing.</body></html>",
        baseURL: nil
      )
    }
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    context.coordinator.webView = webView
    context.coordinator.update(path: path, patch: patch, fontSize: fontSize)
  }

  static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
    webView.navigationDelegate = nil
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: "clairDiffViewer"
    )
    coordinator.detach()
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    weak var webView: WKWebView?
    private var isReady = false
    private var lastConfiguration: WebDiffConfiguration?
    private var lastPatch: String?

    func update(path: String, patch: String, fontSize: CGFloat) {
      guard isReady else {
        pendingPath = path
        pendingPatch = patch
        pendingFontSize = fontSize
        return
      }

      let nextConfiguration = WebDiffConfiguration(
        path: path,
        fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
        fontSize: fontSize,
        background: "#282c34",
        textColor: "#f1f3ef",
        wordWrap: false
      )
      if lastConfiguration != nextConfiguration {
        lastConfiguration = nextConfiguration
        evaluate(method: "configure", argument: nextConfiguration)
      }

      if lastPatch != patch {
        lastPatch = patch
        evaluate(method: "setDiff", argument: patch)
      }
    }

    func detach() {
      webView = nil
      isReady = false
    }

    private var pendingPath: String?
    private var pendingPatch: String?
    private var pendingFontSize: CGFloat = 12

    func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      guard message.name == "clairDiffViewer", let body = message.body as? [String: Any],
        let type = body["type"] as? String
      else {
        return
      }

      if type == "ready" {
        isReady = true
        lastConfiguration = nil
        lastPatch = nil
        if let pendingPath, let pendingPatch {
          update(path: pendingPath, patch: pendingPatch, fontSize: pendingFontSize)
        }
      }
    }

    func webView(
      _ webView: WKWebView,
      didFinish navigation: WKNavigation!
    ) {
      WorkspaceChrome.configureThinScrollbars(in: webView)
    }

    func webView(
      _ webView: WKWebView,
      didFail navigation: WKNavigation!,
      withError _: Error
    ) {
      isReady = false
    }

    private func evaluate<T: Encodable>(method: String, argument: T) {
      guard let webView else {
        return
      }
      guard let data = try? JSONEncoder().encode(argument),
        let json = String(data: data, encoding: .utf8)
      else {
        return
      }
      webView.evaluateJavaScript("window.clairDiffViewer?.\(method)(\(json));")
    }
  }
}

private struct WebDiffConfiguration: Codable, Equatable {
  let path: String
  let fontFamily: String
  let fontSize: CGFloat
  let background: String
  let textColor: String
  let wordWrap: Bool
}
