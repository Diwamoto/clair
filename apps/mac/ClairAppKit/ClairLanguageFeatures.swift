#if os(macOS)
  import ClairShared
  import AppKit
  import ClairDesignSystem
  import ClairEditorCore
  import ClairEditorLanguage
  import ClairEditorView
  import Observation
  import SwiftUI

  private typealias C = DesignTokens.Color
  private typealias L = DesignTokens.Line

  /// The language features of one editor surface beyond completion: hover information under a resting pointer
  /// (or `editor.hover` at the caret), the parameter hint while typing a call, rename (F2 / `editor.rename`) and
  /// quick fixes (⌘. / `editor.codeAction`). One popup at a time sits on the view, drawn like the completion list.
  /// Edits a feature produces across files go to `LanguageServices.onWorkspaceEdit`, which the workbench store applies.
  @MainActor @Observable final class LanguageFeatures {
    enum Popup: Equatable {
      case none
      /// Hover information or a message, anchored under `anchor`.
      case info(String)
      case signature(LanguageServerSignature)
      case actions([LanguageServerCodeAction])
      case rename
    }

    @ObservationIgnored weak var view: ClairEditorView?
    @ObservationIgnored private let language: LanguageServices
    @ObservationIgnored private let path: String
    @ObservationIgnored private let root: String
    private(set) var popup: Popup = .none
    var selected = 0
    /// The rename field's text.
    var name = ""
    @ObservationIgnored private var host: NSHostingView<LanguagePopupView>?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    /// The word the pointer rests on, while its hover is pending or shown.
    @ObservationIgnored private var hoverWord: TextUTF8Range?
    @ObservationIgnored private var signatureTask: Task<Void, Never>?
    @ObservationIgnored private var signatureTriggers: Set<String> = []
    @ObservationIgnored private var renaming: (range: TextUTF8Range, offset: UTF8Offset, revision: TextRevision)?
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    /// Hands a request to this Project's agent (the action list's "Agent で直す" row).
    @ObservationIgnored private let askAgent: (String) -> Void
    /// The request the action list offers to send to an agent: the diagnostics at the caret's line, if any.
    private(set) var agentPrompt: String?

    /// The pointer must rest this long before hover information is asked for.
    static let hoverDelay: Duration = .milliseconds(450)

    init(language: LanguageServices, path: String, root: String, askAgent: @escaping (String) -> Void = { _ in }) {
      self.language = language
      self.path = path
      self.root = root
      self.askAgent = askAgent
      Task { [weak self] in self?.signatureTriggers = await language.signatureTriggerCharacters(path, root: root) }
    }

    var isOpen: Bool { popup != .none }

    // MARK: keys

    /// Runs before the completion list's handler in `ClairEditorView.keyInterceptor`.
    func handle(_ event: NSEvent) -> Bool {
      let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
      if event.keyCode == 120, mods.isEmpty, popup != .rename { rename(); return true }  // F2
      switch popup {
      case .actions(let actions):
        guard mods.isEmpty else { return false }
        switch event.keyCode {
        case 125: selected = min(selected + 1, actions.count - (agentPrompt == nil ? 1 : 0))
        case 126: selected = max(selected - 1, 0)
        case 36, 76, 48: choose(selected)
        case 53: close()
        default: close(); return false
        }
        return true
      case .info:
        close()
        return event.keyCode == 53 && mods.isEmpty
      case .signature:
        if event.keyCode == 53, mods.isEmpty { close(); return true }
        return false
      case .rename, .none: return false
      }
    }

    // MARK: hover

    /// `ClairEditorView.onPointerOffset`.
    func pointer(at offset: UTF8Offset?) {
      if let host, let view, let window = view.window,
        host.frame.contains(view.convert(window.mouseLocationOutsideOfEventStream, from: nil))
      { return }  // reading or scrolling the popup
      guard let offset, let view, let word = view.word(at: offset), word.lowerBound != word.upperBound else {
        hoverWord = nil; hoverTask?.cancel()
        if case .info = popup { close() }
        return
      }
      guard word != hoverWord else { return }
      hoverWord = word
      hoverTask?.cancel()
      if case .info = popup { close() }
      guard popup == .none else { return }  // a signature hint, action list or rename stays put
      hoverTask = Task { [weak self] in
        try? await Task.sleep(for: Self.hoverDelay)
        guard !Task.isCancelled, let self else { return }
        await self.hover(at: word.lowerBound, word: word)
      }
    }

    /// Hover information at the caret (`editor.hover`).
    func hoverAtCaret() {
      guard let view, let caret = view.selection.selections.last?.head else { return }
      let word = view.word(at: caret)
      hoverWord = word
      hoverTask?.cancel()
      hoverTask = Task { [weak self] in await self?.hover(at: caret, word: word, fromCaret: true) }
    }

    private func hover(at offset: UTF8Offset, word: TextUTF8Range?, fromCaret: Bool = false) async {
      guard let view else { return }
      let revision = view.snapshot.revision
      let text = await language.hover(path, root: root, at: offset)
      guard !Task.isCancelled, view.snapshot.revision == revision, fromCaret || hoverWord == word, popup == .none || fromCaret else { return }
      guard let text else {
        if fromCaret { message(tr("ホバー情報はありません")) }
        return
      }
      show(.info(text), at: word?.lowerBound ?? offset)
    }

    // MARK: signature help

    /// After a committed edit: open the parameter hint on a trigger character, keep it current while open.
    func didEdit(_ edits: [TextEdit]) {
      if case .info = popup { close() }
      let typed = edits.count == 1 ? edits[0].replacement : ""
      if case .signature = popup { return requestSignature() }
      if typed == ")" { return }
      if signatureTriggers.contains(typed) { requestSignature() }
    }

    /// The caret moved without an edit.
    func didMoveCaret() {
      switch popup {
      case .signature: requestSignature()
      case .info, .actions: close()
      case .rename, .none: break
      }
    }

    private func requestSignature() {
      signatureTask?.cancel()
      signatureTask = Task { [weak self] in
        guard let self, let view = self.view, let caret = view.selection.selections.last?.head else { return }
        let revision = view.snapshot.revision
        let help = await self.language.signatureHelp(self.path, root: self.root, at: caret)
        guard !Task.isCancelled, view.snapshot.revision == revision else { return }
        switch (help, self.popup) {
        case (let help?, .none), (let help?, .signature): self.show(.signature(help), at: caret, above: true)
        case (nil, .signature): self.close()
        default: break
        }
      }
    }

    // MARK: code actions

    /// Quick fixes and refactorings for the selection, or the caret (`editor.codeAction`, ⌘.). Diagnostics on the caret's
    /// line add a last row that hands them to the Project's agent.
    func codeActions() {
      guard let view, let range = view.selection.selections.last?.range else { return }
      close()
      let revision = view.snapshot.revision
      let prompt = diagnosticPrompt(view, at: range.lowerBound)
      Task { [weak self] in
        guard let self else { return }
        let actions = await self.language.codeActions(self.path, root: self.root, range: range)
        guard let view = self.view, view.snapshot.revision == revision else { return }
        guard !actions.isEmpty || prompt != nil else { return self.message(tr("利用できるアクションはありません")) }
        self.agentPrompt = prompt
        self.selected = 0
        self.show(.actions(actions), at: range.lowerBound)
      }
    }

    /// `path:line: message …` for the diagnostics on `offset`'s line, as one line an agent prompt can take.
    private func diagnosticPrompt(_ view: ClairEditorView, at offset: UTF8Offset) -> String? {
      guard let position = try? view.snapshot.position(at: offset, columnUnit: UTF16Unit.self, rounding: .down),
        let line = try? view.snapshot.line(at: position.line)
      else { return nil }
      let hits = view.diagnostics.filter {
        $0.range.lowerBound.value <= line.contentRange.upperBound.value && $0.range.upperBound.value >= line.contentRange.lowerBound.value
          && !$0.message.isEmpty
      }
      guard !hits.isEmpty else { return nil }
      let rel = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
      let messages = hits.map { $0.message.replacingOccurrences(of: "\n", with: " ") }.joined(separator: " / ")
      return tr("@%@ の %@ 行目の問題を直してください: %@", rel, position.line.value + 1, messages)
    }

    func choose(_ index: Int) {
      if case .actions(let actions) = popup, index == actions.count, let prompt = agentPrompt {
        close()
        return askAgent(prompt)
      }
      guard case .actions(let actions) = popup, actions.indices.contains(index) else { return close() }
      let action = actions[index]
      close()
      if let edit = action.edit, !edit.isEmpty, language.onWorkspaceEdit?(edit) != true {
        return message(tr("編集を適用できませんでした"))
      }
      if action.runsCommand { Task { await language.run(action, path: path, root: root) } }
    }

    // MARK: rename

    /// Renames the symbol at the caret across the workspace (F2, `editor.rename`).
    func rename() {
      guard let view, let caret = view.selection.selections.last?.head else { return }
      close()
      let revision = view.snapshot.revision
      Task { [weak self] in
        guard let self else { return }
        let target = await self.language.prepareRename(self.path, root: self.root, at: caret, fallback: view.word(at: caret))
        guard self.view?.snapshot.revision == revision else { return }
        guard let target else { return self.message(tr("ここでは名前を変更できません")) }
        self.renaming = (target.range, caret, revision)
        self.name = target.placeholder
        self.show(.rename, at: target.range.lowerBound)
      }
    }

    func submitRename() {
      guard let r = renaming else { return close() }
      let newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      let old = try? view?.snapshot.text(in: r.range)
      close()
      guard !newName.isEmpty, newName != old, view?.snapshot.revision == r.revision else { return }
      Task { [weak self] in
        guard let self else { return }
        guard let edit = await self.language.rename(self.path, root: self.root, at: r.offset, to: newName), !edit.isEmpty else {
          return self.message(tr("名前を変更できませんでした"))
        }
        if edit.unsupported || self.language.onWorkspaceEdit?(edit) != true { self.message(tr("編集を適用できませんでした")) }
      }
    }

    // MARK: popup

    /// A short note in place of a result ("no actions here"), gone after a moment.
    private func message(_ text: String) {
      guard let view, let caret = view.selection.selections.last?.head else { return }
      show(.info(text), at: caret)
      messageTask?.cancel()
      messageTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled, let self, case .info(text) = self.popup else { return }
        self.close()
      }
    }

    private func show(_ next: Popup, at offset: UTF8Offset, above: Bool = false) {
      guard let view, let anchor = view.rect(for: offset) else { return }
      popup = next
      let size = LanguagePopupView.size(next)
      let x = min(max(anchor.minX - 8, 0), max(view.visibleRect.maxX - size.width - 4, 0))
      let y = above && anchor.minY - size.height - 2 >= view.visibleRect.minY ? anchor.minY - size.height - 2 : anchor.maxY + 2
      if host == nil {
        let h = NSHostingView(rootView: LanguagePopupView(features: self))
        view.addSubview(h)
        host = h
      }
      host?.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    func close() {
      let wasRenaming = popup == .rename
      popup = .none
      renaming = nil
      host?.removeFromSuperview()
      host = nil
      // The rename field had the keyboard; give it back to the text.
      if wasRenaming, let view { view.window?.makeFirstResponder(view) }
    }
  }

  /// The single popup of `LanguageFeatures`, in the completion list's chrome.
  struct LanguagePopupView: View {
    let features: LanguageFeatures
    @FocusState private var fieldFocused: Bool
    static let row: CGFloat = 22

    /// Width and height for `popup`; text is measured roughly (12pt mono ≈ 7.3pt/char) and capped.
    static func size(_ popup: LanguageFeatures.Popup) -> CGSize {
      switch popup {
      case .none: return .zero
      case .info(let text):
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let longest = lines.map(\.count).max() ?? 0
        let wraps = lines.reduce(0) { $0 + max(1, Int((Double($1.count) * 7.3 / 480).rounded(.up))) }
        return CGSize(width: min(max(CGFloat(longest) * 7.3 + 24, 160), 504), height: min(CGFloat(wraps) * 17 + 18, 260))
      case .signature(let s):
        let docLines = s.documentation.map { min($0.split(separator: "\n").count, 4) } ?? 0
        return CGSize(width: min(max(CGFloat(s.label.count) * 7.3 + 24, 160), 560), height: 30 + CGFloat(docLines) * 16)
      case .actions(let actions):
        let rows = CGFloat(actions.count + 1)  // room for the "Agent で直す" row when there is one
        return CGSize(width: 380, height: min(rows * row + 8, 8 * row + 8))
      case .rename: return CGSize(width: 280, height: 36)
      }
    }

    var body: some View {
      Group {
        switch features.popup {
        case .none: EmptyView()
        case .info(let text):
          ScrollView {
            Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(C.textSecondary)
              .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(9)
          }.accessibilityLabel(tr("ホバー情報"))
        case .signature(let s): signature(s)
        case .actions(let actions): list(actions)
        case .rename:
          TextField("", text: Binding(get: { features.name }, set: { features.name = $0 }))
            .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).foregroundStyle(C.textPrimary)
            .focused($fieldFocused).onAppear { fieldFocused = true }
            .onSubmit { features.submitRename() }
            .onExitCommand { features.close() }
            .padding(.horizontal, 10).frame(maxHeight: .infinity)
            .accessibilityLabel(tr("新しい名前"))
        }
      }
      .background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.card))
      .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(L.strong))
    }

    private func signature(_ s: LanguageServerSignature) -> some View {
      let label = Array(s.label)
      let active = s.activeParameter.map { $0.clamped(to: 0..<label.count) }
      let head = String(label[..<(active?.lowerBound ?? label.count)])
      let param = active.map { String(label[$0]) } ?? ""
      let tail = active.map { String(label[$0.upperBound...]) } ?? ""
      return VStack(alignment: .leading, spacing: 2) {
        (Text(head).foregroundStyle(C.textSecondary) + Text(param).foregroundStyle(C.textPrimary).bold() + Text(tail).foregroundStyle(C.textSecondary))
          .font(.system(size: 12, design: .monospaced)).lineLimit(1)
        if let doc = s.documentation {
          Text(doc).font(.system(size: 11)).foregroundStyle(C.textQuaternary).lineLimit(4)
        }
      }
      .padding(.horizontal, 10).padding(.vertical, 6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .accessibilityElement(children: .combine).accessibilityLabel(tr("引数のヒント"))
    }

    private func list(_ actions: [LanguageServerCodeAction]) -> some View {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.offset) { i, action in
              HStack(spacing: 8) {
                Image(systemName: action.kind?.hasPrefix("quickfix") == true ? "wrench.adjustable" : "lightbulb")
                  .font(.system(size: 10)).foregroundStyle(C.textTertiary).frame(width: 14)
                Text(action.title).font(.system(size: 12)).lineLimit(1)
                  .foregroundStyle(i == features.selected ? C.textPrimary : C.textSecondary)
                Spacer(minLength: 0)
              }
              .padding(.horizontal, 8).frame(height: Self.row)
              .background(i == features.selected ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
              .contentShape(Rectangle())
              .onTapGesture { features.choose(i) }
              .id(i)
            }
            if features.agentPrompt != nil {
              let i = actions.count
              HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(C.textTertiary).frame(width: 14)
                Text(tr("Agent で直す")).font(.system(size: 12)).lineLimit(1)
                  .foregroundStyle(i == features.selected ? C.textPrimary : C.textSecondary)
                Spacer(minLength: 0)
              }
              .padding(.horizontal, 8).frame(height: Self.row)
              .background(i == features.selected ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
              .contentShape(Rectangle())
              .onTapGesture { features.choose(i) }
              .id(i)
            }
          }.padding(4)
        }
        .onChange(of: features.selected) { proxy.scrollTo(features.selected) }
      }
      .accessibilityElement(children: .contain).accessibilityLabel(tr("クイックフィックス"))
    }
  }
#endif
