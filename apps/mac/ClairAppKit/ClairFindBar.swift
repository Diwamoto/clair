#if os(macOS)
  import ClairShared
  import AppKit
  import ClairDesignSystem
  import ClairEditorCore
  import ClairEditorView
  import Observation
  import SwiftUI

  private typealias C = DesignTokens.Color
  private typealias L = DesignTokens.Line

  /// ⌘F's floating panel at the top-right of the focused pane: one search row, plus a replace row for the
  /// editor. Return / ⇧Return step through matches, Esc closes. The editor and the terminal drive it differently
  /// (`EditorFindBar`, `TerminalFindBar`).
  struct FindPanel: View {
    @Binding var query: String
    /// nil hides the replace row and its toggle (the terminal).
    var replacement: Binding<String>? = nil
    @Binding var showReplace: Bool
    var options: Binding<SearchOptions>? = nil
    let status: String
    let nonce: Int
    let step: (Int) -> Void
    var replace: ((Bool) -> Void)? = nil
    let close: () -> Void

    struct SearchOptions: Equatable { var caseSensitive = false, regex = false }
    private enum Field { case find, replace }
    @FocusState private var field: Field?

    var body: some View {
      HStack(alignment: .top, spacing: 4) {
        if replacement != nil {
          Button { showReplace.toggle() } label: { Image(systemName: showReplace ? "chevron.down" : "chevron.right") }
            .buttonStyle(.hoverWash).foregroundStyle(C.textTertiary).frame(width: 16, height: 24)
            .help(tr("置換の切り替え")).accessibilityLabel(tr("置換の切り替え"))
        }
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 4) {
            input(tr("検索"), $query, .find).onSubmit { step(NSEvent.modifierFlags.contains(.shift) ? -1 : 1) }
            if let options {
              toggle("Aa", tr("大文字と小文字を区別"), options.caseSensitive)
              toggle(".*", tr("正規表現"), options.regex)
            }
            Text(status).foregroundStyle(C.textTertiary).monospacedDigit().frame(minWidth: 56)
            Button { step(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.hoverWash).foregroundStyle(C.textSecondary)
              .help(tr("前を検索 (⇧Return)")).accessibilityLabel(tr("前を検索"))
            Button { step(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.hoverWash).foregroundStyle(C.textSecondary)
              .help(tr("次を検索 (Return)")).accessibilityLabel(tr("次を検索"))
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.hoverWash).foregroundStyle(C.textSecondary)
              .help(tr("閉じる (Esc)")).accessibilityLabel(tr("閉じる"))
          }
          if let replacement, showReplace, let replace {
            HStack(spacing: 4) {
              input(tr("置換"), replacement, .replace).onSubmit { replace(false) }
              Button(tr("置換")) { replace(false) }.buttonStyle(.hoverWash).foregroundStyle(C.textSecondary)
              Button(tr("すべて置換")) { replace(true) }.buttonStyle(.hoverWash).foregroundStyle(C.textSecondary)
            }
          }
        }
      }
      .font(Typography.font(Typography.chrome)).lineLimit(1)
      .padding(6)
      .background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.card))
      .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(L.strong))
      .padding(8)
      .onExitCommand(perform: close)
      .accessibilityElement(children: .contain).accessibilityLabel(tr("検索"))
      .task(id: nonce) { field = showReplace && replacement != nil && !query.isEmpty ? .replace : .find }
    }

    private func input(_ label: String, _ text: Binding<String>, _ f: Field) -> some View {
      TextField(label, text: text).textFieldStyle(.plain).foregroundStyle(C.textPrimary)
        .focused($field, equals: f).frame(width: 200, height: 24).padding(.horizontal, 6)
        .background(C.canvas, in: RoundedRectangle(cornerRadius: Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(field == f ? L.ring : L.strong))
        .accessibilityLabel(label)
    }

    private func toggle(_ glyph: String, _ help: String, _ on: Binding<Bool>) -> some View {
      Button { on.wrappedValue.toggle() } label: { Text(glyph).font(.system(size: 11, weight: .semibold, design: .monospaced)) }
        .buttonStyle(.hoverWash).foregroundStyle(on.wrappedValue ? C.textPrimary : C.textQuaternary)
        .background(on.wrappedValue ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
        .help(help).accessibilityLabel(help).accessibilityAddTraits(on.wrappedValue ? .isSelected : [])
    }
  }

  // MARK: - Editor

  /// The editor's find & replace over the open buffer (`TextSearch`). Matches are re-found after every edit;
  /// a replacement is an ordinary edit through `onCommitEdits`, so "すべて置換" is one undo unit.
  struct EditorFindBar: View {
    let buffers: EditorBuffers
    let path: String
    let request: EditorBuffers.FindRequest

    @State private var query = ""
    @State private var replacement = ""
    @State private var showReplace = false
    @State private var options = FindPanel.SearchOptions()
    @State private var matches: [TextUTF8Range] = []
    @State private var current: Int?
    @State private var invalid = false

    var body: some View {
      FindPanel(
        query: $query, replacement: $replacement, showReplace: $showReplace, options: $options,
        status: invalid ? tr("正規表現が不正です") : query.isEmpty ? "" : matches.isEmpty ? tr("結果なし") : "\((current ?? -1) + 1)/\(matches.count)",
        nonce: request.nonce, step: step, replace: replace, close: close)
      .task(id: request.nonce) {
        if let seed = request.seed { query = seed }
        if request.replace { showReplace = true }
        search(select: true)
      }
      .onChange(of: query) { search(select: true) }
      .onChange(of: options) { search(select: true) }
      .onChange(of: buffers.edits[path]) { search(select: false) }
      .onDisappear { buffers.view(path)?.findMatches = [] }
    }

    private var pattern: SearchPattern {
      options.regex ? .regex(query, caseSensitive: options.caseSensitive) : .literal(query, caseSensitive: options.caseSensitive)
    }

    /// Re-finds every match; `select` moves to the first one at or after the caret.
    private func search(select: Bool) {
      guard let view = buffers.view(path) else { return }
      invalid = false
      guard !query.isEmpty else { matches = []; current = nil; view.findMatches = []; return }
      do {
        matches = try TextSearch.find(pattern, in: view.snapshot).map(\.range).filter { $0.lowerBound < $0.upperBound }
      } catch {
        invalid = true; matches = []
      }
      view.findMatches = matches
      let from = view.selection.selections.first?.range.lowerBound.value ?? 0
      current = matches.isEmpty ? nil : matches.firstIndex { $0.lowerBound.value >= from } ?? 0
      if select, let current { view.reveal(matches[current]) }
    }

    private func step(_ d: Int) {
      guard !matches.isEmpty, let view = buffers.view(path) else { return }
      // Continue from the selected match, or from the caret if the user moved it.
      let sel = view.selection.selections.first?.range
      let i: Int
      if let c = current, sel == matches[c] {
        i = c + d
      } else {
        let from = sel?.lowerBound.value ?? 0
        let next = matches.firstIndex { $0.lowerBound.value >= from } ?? matches.count
        i = d > 0 ? next : next - 1
      }
      current = (i % matches.count + matches.count) % matches.count
      view.reveal(matches[current!])
    }

    private func replace(_ all: Bool) {
      search(select: false)  // never apply against stale ranges
      guard let view = buffers.view(path), !matches.isEmpty else { return }
      if all {
        view.onCommitEdits?(matches.map { TextEdit(range: $0, replacement: replacement) })
        return
      }
      // The first press selects the match; the next one replaces it and moves on.
      guard let c = current else { return }
      guard view.selection.selections.first?.range == matches[c] else { view.reveal(matches[c]); return }
      let after = matches[c].lowerBound.value + replacement.utf8.count
      view.onCommitEdits?([TextEdit(range: matches[c], replacement: replacement)])
      search(select: false)
      if let next = matches.firstIndex(where: { $0.lowerBound.value >= after }) ?? (matches.isEmpty ? nil : 0) {
        current = next; view.reveal(matches[next])
      }
    }

    private func close() {
      buffers.find = nil
      if let view = buffers.view(path) { view.findMatches = []; view.window?.makeFirstResponder(view) }
    }
  }

  // MARK: - Terminal

  /// Open terminal searches by pane id. Ghostty finds and highlights the matches itself
  /// (`search:` / `navigate_search:` binding actions) and reports the count back through the surface's poll.
  /// ponytail: keyed by pane id like `ClairGhosttySurfaceView.byPane`; only the visible Project's panes are mounted.
  @MainActor @Observable final class TerminalFind {
    static let shared = TerminalFind()
    struct Entry: Equatable { var query = ""; var total: Int?; var selected: Int?; var nonce = 0 }
    var open: [Int: Entry] = [:]

    func show(pane: Int, seed: String?) {
      var e = open[pane] ?? Entry()
      if let seed, !seed.contains("\n") { e.query = seed }
      e.nonce += 1
      open[pane] = e
    }
  }

  struct TerminalFindBar: View {
    let pane: Int
    @State private var showReplace = false
    private var find: TerminalFind { .shared }

    var body: some View {
      if let entry = find.open[pane] {
        FindPanel(
          query: Binding(get: { find.open[pane]?.query ?? "" }, set: { find.open[pane]?.query = $0 }),
          showReplace: $showReplace,
          status: entry.query.isEmpty ? "" : entry.total == 0 ? tr("結果なし")
            : entry.total.map { t in entry.selected.map { "\($0 + 1)/\(t)" } ?? "\(t)" } ?? "",
          nonce: entry.nonce,
          step: { d in ClairGhosttySurfaceView.searchAction(d < 0 ? "navigate_search:previous" : "navigate_search:next", pane: pane) },
          close: {
            ClairGhosttySurfaceView.searchAction("end_search", pane: pane)
            find.open[pane] = nil
            ClairGhosttySurfaceView.focus(pane: pane)
          })
        .task(id: entry.query) {
          ClairGhosttySurfaceView.searchAction(entry.query.isEmpty ? "end_search" : "search:" + entry.query, pane: pane)
        }
      }
    }
  }
#endif
