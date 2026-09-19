#if os(macOS)
  import ClairV2DesignSystem
  import ClairV2Workspace
  import SwiftUI

  private typealias C = DesignTokens.Color
  private typealias L = DesignTokens.Line

  private struct ShellFile: Sendable { let path: String; let status: Character? }
  // ponytail: static sample tree mirroring the workbench `files`; real catalog binding (H02) comes with U05.
  private let sampleFiles = [
    ShellFile(path: "apple/ClairApp/ContentView.swift", status: "M"),
    ShellFile(path: "apple/ClairApp/ProjectWorkspace.swift", status: "M"),
    ShellFile(path: "apple/ClairApp/PaneSplit.swift", status: "A"),
    ShellFile(path: "apple/ClairApp/SessionRail.swift", status: "A"),
    ShellFile(path: "docs/architecture/pane-layout.md", status: nil),
  ]

  private struct Command: Sendable { let title: String; let shortcut: String; let risk: String; let run: @Sendable (inout ShellState) -> Void }

  private struct ShellState: Sendable {
    var tree = PaneTree()
    var project = "clair"
    var tabs = [sampleFiles[0].path]
    var active = sampleFiles[0].path
    var dirty: Set<String> = []
    var collapsed: Set<String> = []
    var settings = false
    var section = "一般"
    var palette: Palette?
    var toggles: [String: Bool] = ["restoreLayout": true, "confirmClose": true, "showQuota": false]
    enum Palette { case commands, files }

    mutating func open(_ path: String) {
      if !tabs.contains(path) { tabs.append(path) }
      active = path; settings = false; palette = nil
    }
  }

  private let commands: [Command] = [
    Command(title: "ペインを右に分割", shortcut: "⌃⌘D", risk: "追加") { $0.tree.splitFocused(.horizontal) },
    Command(title: "ペインを下に分割", shortcut: "⌃⌘⇧D", risk: "追加") { $0.tree.splitFocused(.vertical) },
    Command(title: "ペインのフォーカスを右へ", shortcut: "⌃⌘→", risk: "読み取り") { $0.tree.focusNext() },
    Command(title: "ペインを最大化", shortcut: "⌃⌘M", risk: "読み取り") { $0.tree.toggleMaximize() },
    Command(title: "分割を均等化", shortcut: "⌃⌘=", risk: "読み取り") { $0.tree.equalize() },
    Command(title: "ペインを閉じる", shortcut: "⌃⌘W", risk: "破壊的") { $0.tree.closeFocused() },
    Command(title: "設定を開く", shortcut: "⌘,", risk: "読み取り") { $0.settings = true },
  ]

  /// U04: AppShell chrome (checklist §3) — titlebar 48 + sidebar 286 + main +
  /// status 26. Built once; only sidebar panel and main are swapped. Pane
  /// contents other than the terminal are placeholders owned by U05/U06.
  public struct ClairV2AppShell: View {
    @State private var st = ShellState()
    @State private var query = ""
    @State private var selection = 0
    private let projects: [(name: String, color: SwiftUI.Color)] = [
      ("clair", C.debugBlue), ("ccedit", C.success), ("clair-releases", C.attention),
    ]

    public init() {}

    public var body: some View {
      VStack(spacing: 0) {
        titlebar
        HStack(spacing: 0) {
          sidebar
          Rectangle().fill(L.hairline).frame(width: 1)
          if st.settings { settingsMain } else { main }
        }
        statusBar
      }
      .background(C.canvas)
      .frame(minWidth: 900, minHeight: 560)
      .overlay { if let p = st.palette { paletteView(p) } }
      .animation(.easeOut(duration: 0.09), value: st.palette == nil)
      .background(shortcuts)
    }

    private var titlebar: some View {
      HStack(spacing: 8) {
        HStack(spacing: 8) {
          ForEach([C.close, C.minimize, C.zoom], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
        }
        .padding(.trailing, 12)
        ForEach(projects, id: \.name) { p in
          let on = st.project == p.name
          Button { st.project = p.name } label: {
            Text(p.name).font(Typography.font(Typography.chromeStrong))
              .foregroundStyle(C.textPrimary)
              .padding(.horizontal, 10).frame(height: 26)
              .background(p.color.opacity(on ? 0.22 : 0.14), in: RoundedRectangle(cornerRadius: Radius.card))
              .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(p.color.opacity(on ? 0.55 : 0.28)))
          }.buttonStyle(.plain)
        }
        Spacer()
        Button { st.settings.toggle() } label: {
          Image(systemName: "gearshape").foregroundStyle(C.chromeInk)
        }.buttonStyle(.plain)
      }
      .padding(.horizontal, 16)
      .frame(height: ChromeBudget.titlebar)
      .background(C.chrome)
      .overlay(alignment: .bottom) { Rectangle().fill(L.chrome).frame(height: 1) }
    }

    // MARK: sidebar

    private var sidebar: some View {
      VStack(spacing: 0) {
        HStack(spacing: 12) {
          ForEach(["folder", "shield", "bell", "ladybug"], id: \.self) {
            Image(systemName: $0).font(.system(size: 13)).foregroundStyle(C.chromeInkMuted)
          }
          Spacer()
        }
        .padding(.horizontal, 12).frame(height: ChromeBudget.sidebarStrip)
        Rectangle().fill(L.hairline).frame(height: 1)
        ScrollView { VStack(alignment: .leading, spacing: 0) { st.settings ? AnyView(sections) : AnyView(explorer) } }
        Spacer(minLength: 0)
      }
      .frame(width: 286)
      .background(C.chromeRaised)
    }

    private var sections: some View {
      ForEach(["一般", "AIプロバイダー", "エディタ", "ターミナル", "モバイル", "アップデート"], id: \.self) { s in
        row(s, depth: 0, selected: st.section == s) { st.section = s }
      }
    }

    /// Folders derived from the file paths; click toggles, files open a tab.
    private var explorer: some View {
      var out: [(id: String, label: String, depth: Int, file: ShellFile?)] = []
      var seen = Set<String>()
      for f in sampleFiles {
        let parts = f.path.split(separator: "/").map(String.init)
        for d in 0..<parts.count - 1 {
          let id = parts[0...d].joined(separator: "/")
          if seen.insert(id).inserted { out.append((id, parts[d], d, nil)) }
        }
        out.append((f.path, parts.last!, parts.count - 1, f))
      }
      return ForEach(out.filter { r in !st.collapsed.contains { r.id.hasPrefix($0 + "/") } }, id: \.id) { r in
        if let f = r.file {
          row(r.label, depth: r.depth, selected: st.active == f.path && !st.settings, badge: f.status) { st.open(f.path) }
        } else {
          row((st.collapsed.contains(r.id) ? "▸ " : "▾ ") + r.label, depth: r.depth, selected: false) {
            if !st.collapsed.insert(r.id).inserted { st.collapsed.remove(r.id) }
          }
        }
      }
    }

    private func row(_ title: String, depth: Int, selected: Bool, badge: Character? = nil, _ action: @escaping () -> Void) -> some View {
      Button(action: action) {
        HStack {
          Text(title).font(Typography.font(Typography.chrome)).foregroundStyle(selected ? C.textPrimary : C.textSecondary)
          Spacer()
          if let b = badge { Text(String(b)).font(Typography.font(Typography.micro)).foregroundStyle(C.textTertiary) }
        }
        .padding(.leading, 12 + CGFloat(depth) * 12).padding(.trailing, 12).frame(height: 24)
        .background(selected ? C.surfaceActive : .clear).contentShape(Rectangle())
      }.buttonStyle(.plain)
    }

    // MARK: main

    private func name(_ path: String) -> String { String(path.split(separator: "/").last ?? "") }

    private var main: some View {
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          ForEach(st.tabs, id: \.self) { p in
            HStack(spacing: 6) {
              Circle().fill(C.textTertiary).frame(width: 6, height: 6).opacity(st.dirty.contains(p) ? 1 : 0)
              Text(name(p)).font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary).lineLimit(1)
                // ponytail: fade by name length, not measured width; measure if font/width tokens change.
                .mask(LinearGradient(stops: [.init(color: .black, location: name(p).count > 16 ? 0.8 : 1), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
                .help(p)
            }
            .padding(.horizontal, 12).frame(width: 168, height: 32, alignment: .leading)
            .background(p == st.active ? C.surfaceActive : .clear)
            .onTapGesture { st.active = p }
          }
          Spacer(minLength: 0)
        }
        .background(C.chromeRaised)
        PaneView(
          node: st.tree.maximized.flatMap { id in st.tree.leaves.first { $0.id == id }.map { .leaf(id: $0.id, kind: $0.kind) } } ?? st.tree.root,
          focused: st.tree.focused, onFocus: { st.tree.focus($0) }, onRatio: { st.tree.setRatio(splitContaining: $0, $1) })
      }
    }

    private var settingsMain: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text(st.section).font(.system(size: 20, weight: .semibold)).foregroundStyle(C.textPrimary)
          if st.section == "一般" {
            toggle("前回のレイアウトを復元", "restoreLayout")
            toggle("閉じる前に確認", "confirmClose")
            toggle("ステータスバーの利用枠を表示", "showQuota")
          } else if st.section == "モバイル" {
            Text("同じネットワーク上の端末からセッションを確認します。").foregroundStyle(C.textTertiary)
          } else {
            // Undefined in the canvas (checklist §6.3): placeholder only, no invented content.
            Text("この画面はデザインキャンバスにまだ存在しません。").foregroundStyle(C.textMuted)
          }
        }
        .font(Typography.font(Typography.chrome)).padding(40).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
      }
      .background(C.chromeRaised)
    }

    private func toggle(_ title: String, _ key: String) -> some View {
      Toggle(title, isOn: Binding(get: { st.toggles[key] ?? false }, set: { st.toggles[key] = $0 })).foregroundStyle(C.textSecondary)
    }

    private var statusBar: some View {
      HStack {
        Text(st.settings ? "設定 · \(st.section)" : "Ln 1, Col 1").font(Typography.font(Typography.chrome, family: .mono)).foregroundStyle(C.chromeInkMuted)
        Spacer()
      }
      .padding(.horizontal, 12).frame(height: ChromeBudget.statusBar)
      .background(C.chrome)
      .overlay(alignment: .top) { Rectangle().fill(L.chrome).frame(height: 1) }
    }

    // MARK: palette (⌘K commands, ⌘P files)

    private func items(_ p: ShellState.Palette) -> [(title: String, hint: String, run: (inout ShellState) -> Void)] {
      let q = query.lowercased()
      switch p {
      case .commands: return commands.filter { q.isEmpty || $0.title.lowercased().contains(q) }.map { ($0.title, $0.shortcut, $0.run) }
      case .files: return sampleFiles.filter { q.isEmpty || $0.path.lowercased().contains(q) }.map { f in (f.path, "", { $0.open(f.path) }) }
      }
    }

    private func paletteView(_ p: ShellState.Palette) -> some View {
      let list = items(p)
      return ZStack(alignment: .top) {
        Color.black.opacity(0.35).onTapGesture { st.palette = nil }
        VStack(spacing: 0) {
          TextField(p == .commands ? "コマンドを入力" : "ファイルへ移動", text: $query)
            .textFieldStyle(.plain).padding(12)
            .onSubmit { run(list) }
            .onKeyPress(.downArrow) { selection = min(selection + 1, max(list.count - 1, 0)); return .handled }
            .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
            .onKeyPress(.escape) { st.palette = nil; return .handled }
            .onChange(of: query) { selection = 0 }
          ForEach(Array(list.enumerated()), id: \.offset) { i, it in
            HStack { Text(it.title); Spacer(); Text(it.hint).foregroundStyle(C.textTertiary) }
              .font(Typography.font(Typography.chrome)).foregroundStyle(C.textPrimary)
              .padding(.horizontal, 12).frame(height: 28)
              .background(i == selection ? C.surfaceActive : .clear)
              .onTapGesture { selection = i; run(list) }
          }
        }
        .frame(width: 520).background(C.panel, in: RoundedRectangle(cornerRadius: Radius.overlay))
        .overlay(RoundedRectangle(cornerRadius: Radius.overlay).stroke(L.strong))
        .padding(.top, 80)
        .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
      }
    }

    private func run(_ list: [(title: String, hint: String, run: (inout ShellState) -> Void)]) {
      guard selection < list.count else { return }
      let f = list[selection].run
      st.palette = nil
      f(&st)
    }

    private func showPalette(_ p: ShellState.Palette) { query = ""; selection = 0; st.palette = p }

    /// ⌃⌘D / ⌃⌘⇧D split, ⌃⌘W close, ⌃⌘M maximize, ⌃⌘= equalize, ⌃⌘→ focus next, ⌘S, ⌘K, ⌘P, ⌘,.
    private var shortcuts: some View {
      Group {
        Button("") { st.tree.splitFocused(.horizontal) }.keyboardShortcut("d", modifiers: [.control, .command])
        Button("") { st.tree.splitFocused(.vertical) }.keyboardShortcut("d", modifiers: [.control, .command, .shift])
        Button("") { st.tree.closeFocused() }.keyboardShortcut("w", modifiers: [.control, .command])
        Button("") { st.tree.toggleMaximize() }.keyboardShortcut("m", modifiers: [.control, .command])
        Button("") { st.tree.equalize() }.keyboardShortcut("=", modifiers: [.control, .command])
        Button("") { st.tree.focusNext() }.keyboardShortcut(.rightArrow, modifiers: [.control, .command])
        Button("") { st.dirty.remove(st.active) }.keyboardShortcut("s", modifiers: .command)
        Button("") { showPalette(.commands) }.keyboardShortcut("k", modifiers: .command)
        Button("") { showPalette(.files) }.keyboardShortcut("p", modifiers: .command)
        Button("") { st.settings = true }.keyboardShortcut(",", modifiers: .command)
      }.opacity(0).frame(width: 0, height: 0)
    }
  }

  private struct PaneView: View {
    let node: PaneTree.Node
    let focused: Int
    let onFocus: (Int) -> Void
    let onRatio: (Int, Double) -> Void

    private func firstLeaf(_ n: PaneTree.Node) -> Int {
      switch n {
      case .leaf(let id, _): return id
      case .split(_, _, let a, _): return firstLeaf(a)
      }
    }

    @ViewBuilder
    private func parts(_ axis: PaneTree.Axis, _ total: CGFloat, _ a: PaneTree.Node, _ b: PaneTree.Node, ratio: Double) -> some View {
      let h = axis == .horizontal
      PaneView(node: a, focused: focused, onFocus: onFocus, onRatio: onRatio)
        .frame(width: h ? total * ratio : nil, height: h ? nil : total * ratio)
      Rectangle().fill(L.paneDivider).frame(width: h ? 1 : nil, height: h ? nil : 1)
        .padding(h ? .horizontal : .vertical, -3).contentShape(Rectangle())
        .gesture(
          DragGesture(coordinateSpace: .named("split")).onChanged { v in
            onRatio(firstLeaf(a), Double((h ? v.location.x : v.location.y) / total))
          })
      PaneView(node: b, focused: focused, onFocus: onFocus, onRatio: onRatio)
    }

    var body: some View {
      switch node {
      case .leaf(let id, let kind):
        ZStack {
          C.surface
          if kind == .terminal { ClairV2GhosttySurface() }  // ponytail: one surface per terminal leaf; session binding is U06
          else { Text(kind.rawValue).foregroundStyle(C.textMuted) }  // editor/agent content: U05/U06
        }
        .overlay(Rectangle().stroke(id == focused ? L.ring : .clear))
        .onTapGesture { onFocus(id) }
      case .split(let axis, let ratio, let a, let b):
        GeometryReader { g in
          let total = axis == .horizontal ? g.size.width : g.size.height
          if axis == .horizontal {
            HStack(spacing: 0) { parts(axis, total, a, b, ratio: ratio) }
          } else {
            VStack(spacing: 0) { parts(axis, total, a, b, ratio: ratio) }
          }
        }
        .coordinateSpace(name: "split")
      }
    }
  }
#endif
