@preconcurrency import AppKit
import Foundation
import SwiftUI
@preconcurrency import WebKit

enum ProjectEditorCommand {
  case undo
  case redo
}

@MainActor
struct CodeMirrorEditorView: NSViewRepresentable {
  @ObservedObject var document: ProjectEditorTab
  let selection: ProjectEditorSelection?
  let fontSize: CGFloat
  let wordWrap: Bool
  let onSave: () -> Void

  init(
    document: ProjectEditorTab,
    selection: ProjectEditorSelection? = nil,
    fontSize: CGFloat = 13,
    wordWrap: Bool = false,
    onSave: @escaping () -> Void
  ) {
    self.document = document
    self.selection = selection
    self.fontSize = fontSize
    self.wordWrap = wordWrap
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

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.underPageBackgroundColor = WorkspaceChrome.nsCanvas
    context.coordinator.webView = webView
    context.coordinator.update(
      document: document,
      selection: selection,
      fontSize: fontSize,
      wordWrap: wordWrap,
      onSave: onSave
    )

    if let editorURL = Bundle.main.url(
      forResource: "index",
      withExtension: "html",
      subdirectory: "EditorWeb"
    ) {
      webView.loadFileURL(
        editorURL,
        allowingReadAccessTo: editorURL.deletingLastPathComponent()
      )
    } else {
      webView.loadHTMLString(
        "<html><body style=\"background:#121416;color:#f1f3ef;font:13px monospace\">Editor resource is missing.</body></html>",
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
    private var lastRenderedContent: String?
    private var lastConfiguration: WebEditorConfiguration?
    private var lastSelectionRequest: ProjectEditorSelection?
    private var lastEditorSelection: WebEditorSelection?
    private var onSave: (() -> Void)?
    private var requestedFontSize: CGFloat = 13
    private var requestedWordWrap = false

    init(document: ProjectEditorTab) {
      self.document = document
    }

    func update(
      document: ProjectEditorTab,
      selection: ProjectEditorSelection?,
      fontSize: CGFloat,
      wordWrap: Bool,
      onSave: @escaping () -> Void
    ) {
      if self.document.id != document.id {
        self.document.detachEditorCommandHandler()
        self.document = document
        lastRenderedContent = nil
        lastConfiguration = nil
        lastSelectionRequest = nil
        attachCommandHandler()
      }
      self.onSave = onSave
      requestedFontSize = fontSize
      requestedWordWrap = wordWrap
      guard isReady else {
        return
      }

      let nextConfiguration = WebEditorConfiguration(
        path: document.url.path,
        fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
        fontSize: fontSize,
        background: "#121416",
        textColor: "#f1f3ef",
        wordWrap: wordWrap,
        readOnly: document.isMissing || document.isReadOnly || document.loadError != nil
      )
      if lastConfiguration != nextConfiguration {
        lastConfiguration = nextConfiguration
        evaluate(
          method: "configure",
          argument: nextConfiguration
        )
      }

      if lastRenderedContent != document.content {
        lastRenderedContent = document.content
        let requestedSelection = selection.flatMap { webSelection(for: $0) }
        sendDocument(document.content, selection: requestedSelection ?? preservedSelection())
      } else if let selection, selection != lastSelectionRequest {
        reveal(selection)
      }
    }

    func detach() {
      document.detachEditorCommandHandler()
      onSave = nil
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
        update(
          document: document,
          selection: lastSelectionRequest,
          fontSize: requestedFontSize,
          wordWrap: requestedWordWrap,
          onSave: onSave ?? {}
        )
      case "change":
        guard let content = body["content"] as? String,
          let selection = WebEditorSelection(dictionary: body["selection"] as? [String: Any]),
          let canUndo = body["canUndo"] as? Bool,
          let canRedo = body["canRedo"] as? Bool
        else {
          return
        }
        lastRenderedContent = content
        lastEditorSelection = selection
        document.updateFromEditor(
          content,
          canUndo: canUndo,
          canRedo: canRedo
        )
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

    private func sendDocument(_ content: String, selection: WebEditorSelection?) {
      let argument = WebEditorDocument(content: content, selection: selection)
      evaluate(method: "setDocument", argument: argument)
      if let selection {
        lastEditorSelection = selection
      }
      applySelectionRequestIfNeeded()
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
      guard let lastEditorSelection else {
        return nil
      }
      let length = document.content.utf16.count
      return WebEditorSelection(
        from: min(lastEditorSelection.from, length),
        to: min(lastEditorSelection.to, length)
      )
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
}

private struct WebEditorDocument: Codable {
  let content: String
  let selection: WebEditorSelection?
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
