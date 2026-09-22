#if os(macOS)
  import AppKit
  import ClairDesignSystem
  import ClairEditorCore
  import ClairEditorLanguage
  import ClairEditorView
  import Observation
  import SwiftUI

  private typealias C = DesignTokens.Color
  private typealias L = DesignTokens.Line

  /// E12: the completion list of one editor surface. Opens on ⌃Space / Esc,
  /// or by itself after typing an identifier character or one of the
  /// server's trigger characters; filters locally while typing; ↑↓ choose,
  /// Return/Tab accept, Esc closes. Accepting is an ordinary edit through
  /// `onCommitEdits`, so it is one undo unit and reaches the server like typing.
  @MainActor @Observable final class CompletionController {
    @ObservationIgnored weak var view: ClairEditorView?
    @ObservationIgnored private let language: LanguageServices
    @ObservationIgnored private let path: String
    @ObservationIgnored private let root: String
    private(set) var shown: [LanguageServerCompletionItem] = []
    var selected = 0
    @ObservationIgnored private var all: [LanguageServerCompletionItem] = []
    @ObservationIgnored private var source: TextSnapshot?
    /// Start of the word being completed; the list closes if the caret leaves it.
    @ObservationIgnored private var start: UTF8Offset?
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private(set) var triggers: Set<String> = []
    @ObservationIgnored private var host: NSHostingView<CompletionList>?

    /// More than this is noise and costs SwiftUI layout for nothing.
    static let limit = 200

    init(language: LanguageServices, path: String, root: String) {
      self.language = language
      self.path = path
      self.root = root
      Task { [weak self] in self?.triggers = await language.triggerCharacters(path, root: root) }
    }

    var isOpen: Bool { host != nil }

    /// `ClairEditorView.keyInterceptor`.
    func handle(_ event: NSEvent) -> Bool {
      let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
      if event.keyCode == 49, mods == .control { trigger(); return true }  // ⌃Space
      guard isOpen else {
        if event.keyCode == 53, mods.isEmpty { trigger(); return true }  // Esc
        return false
      }
      if event.keyCode == 53 { dismiss(); return true }
      guard mods.isEmpty else { return false }
      switch event.keyCode {
      case 125: selected = min(selected + 1, shown.count - 1)
      case 126: selected = max(selected - 1, 0)
      case 36, 76, 48: accept()  // Return, Enter, Tab
      default: return false
      }
      return true
    }

    /// After a committed edit (the view already shows it).
    func didEdit(_ edits: [TextEdit]) {
      guard edits.count == 1, let typed = edits.first?.replacement else { return dismiss() }
      let identifier = typed.count == 1 && typed.unicodeScalars.allSatisfy(Self.isIdentifier)
      if triggers.contains(typed) { return trigger() }
      if isOpen { return refilter() }
      // A request already in flight re-asks by itself once it sees the newer revision.
      if identifier, request == nil { trigger() }
    }

    /// The caret moved without an edit.
    func didMoveCaret() { if isOpen { refilter() } }

    func trigger() {
      request?.cancel()
      request = Task { [weak self] in
        // An edit landing before the answer makes it stale (rejected as nil); ask again for the new revision.
        for _ in 0..<3 {
          guard let self, let view = self.view, let caret = view.selection.selections.last?.head else { return }
          let revision = view.snapshot.revision
          let result = await self.language.completion(self.path, root: self.root, at: caret)
          guard !Task.isCancelled else { return }
          if let result {
            self.all = result.items
            self.source = result.snapshot
            self.start = self.wordStart(caret)
            self.request = nil
            self.refilter()
            return
          }
          if view.snapshot.revision == revision { break }
        }
        self?.request = nil
      }
    }

    private func refilter() {
      guard let view, let start, let caret = view.selection.selections.last?.head, caret.value >= start.value,
        let prefix = try? view.snapshot.text(in: TextUTF8Range(start, caret)),
        prefix.unicodeScalars.allSatisfy(Self.isIdentifier)
      else { return dismiss() }
      let p = prefix.lowercased()
      let starts = all.filter { $0.filterText.lowercased().hasPrefix(p) }
      let contains = p.isEmpty ? [] : all.filter { !$0.filterText.lowercased().hasPrefix(p) && $0.filterText.lowercased().contains(p) }
      shown = Array((starts + contains).prefix(Self.limit))
      selected = min(selected, max(shown.count - 1, 0))
      guard !shown.isEmpty else { return hide() }
      show()
    }

    func accept(_ index: Int? = nil) {
      let i = index ?? selected
      guard let view, i < shown.count, let start, let caret = view.selection.selections.last?.head else { return dismiss() }
      let item = shown[i]
      var lower = start
      var upper = caret
      if let range = item.range, range.lowerBound.value <= caret.value {
        lower = range.lowerBound
        // Same revision: the server's range may also cover the rest of the word after the caret.
        if source?.revision == view.snapshot.revision { upper = UTF8Offset(max(caret.value, range.upperBound.value)) }
      }
      dismiss()
      view.onCommitEdits?([TextEdit(range: TextUTF8Range(lower, upper), replacement: item.text)])
    }

    func dismiss() {
      request?.cancel()
      request = nil
      all = []
      start = nil
      hide()
    }

    private func hide() {
      shown = []
      selected = 0
      host?.removeFromSuperview()
      host = nil
    }

    private func show() {
      guard let view, let caret = view.primaryCaretRect() else { return hide() }
      let height = min(CGFloat(shown.count) * CompletionList.row + 8, 8 * CompletionList.row + 8)
      let frame = NSRect(x: max(caret.minX - 8, 0), y: caret.maxY + 2, width: 360, height: height)
      if host == nil {
        let h = NSHostingView(rootView: CompletionList(controller: self))
        view.addSubview(h)
        host = h
      }
      host?.frame = frame
    }

    private func wordStart(_ caret: UTF8Offset) -> UTF8Offset {
      guard let view, let pos = try? view.snapshot.position(at: caret, columnUnit: UTF8Unit.self),
        let line = try? view.snapshot.line(at: pos.line),
        let before = try? view.snapshot.text(in: TextUTF8Range(line.contentRange.lowerBound, caret))
      else { return caret }
      let word = before.unicodeScalars.reversed().prefix { Self.isIdentifier($0) }
      return UTF8Offset(caret.value - String(String.UnicodeScalarView(word)).utf8.count)
    }

    static func isIdentifier(_ s: Unicode.Scalar) -> Bool {
      s == "_" || s == "$" || s.properties.isAlphabetic || s.properties.numericType != nil
    }
  }

  struct CompletionList: View {
    static let row: CGFloat = 22
    let controller: CompletionController

    var body: some View {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(Array(controller.shown.enumerated()), id: \.offset) { i, item in
              HStack(spacing: 8) {
                Text(item.label).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                  .foregroundStyle(i == controller.selected ? C.textPrimary : C.textSecondary)
                Spacer(minLength: 0)
                if let detail = item.detail {
                  Text(detail).font(.system(size: 11)).lineLimit(1).truncationMode(.tail).foregroundStyle(C.textQuaternary)
                }
              }
              .padding(.horizontal, 8).frame(height: Self.row)
              .background(i == controller.selected ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
              .contentShape(Rectangle())
              .onTapGesture { controller.accept(i) }
              .id(i)
            }
          }.padding(4)
        }
        .onChange(of: controller.selected) { proxy.scrollTo(controller.selected) }
      }
      .background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.card))
      .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(L.strong))
      .accessibilityElement(children: .contain).accessibilityLabel("補完候補")
    }
  }
#endif
