#if os(macOS)
  import ClairV2DesignSystem
  import ClairV2Workspace
  import Observation
  import SwiftUI

  private typealias C = DesignTokens.Color
  private typealias L = DesignTokens.Line

  /// V01: the GUI process owns `WorkbenchState` (ADR-0007 state owner). Every
  /// mutation goes through `CommandRegistry.workbench`; a destructive effective
  /// risk parks the call in `pending` until the native confirmation approves it.
  @MainActor @Observable public final class ClairV2WorkbenchStore {
    public var state = WorkbenchState()
    public var pending: (id: String, input: CommandInput)?
    public var lastError: CommandError?
    public let registry = CommandRegistry.workbench

    /// V02: serves this store to `clair` CLI. Only the first window's store wins the socket.
    // ponytail: multi-window shares one socket owner; route by window when V04 adds per-Project windows.
    private var ipc: WorkbenchIPCServer?

    /// V04: workspace file (Projects + per-Project layout). nil disables persistence.
    // ponytail: single shared path; Stable/Dev data separation lands with V09.
    private let persistURL: URL?

    public init(persistAt url: URL? = ClairV2WorkbenchStore.defaultPersistURL) {
      persistURL = url
      if let url, let restored = WorkbenchState.restore(from: url) { state = restored }
      if state.projects.isEmpty { run("project.open", ["path": .string(Self.seedRoot)]) }
      let store = self
      let server = WorkbenchIPCServer { id, input in
        DispatchQueue.main.sync { MainActor.assumeIsolated { store.run(id, input) } }
      }
      if (try? server.start()) != nil { ipc = server }
    }

    isolated deinit { ipc?.stop() }

    public static var defaultPersistURL: URL {
      ProcessInfo.processInfo.environment["CLAIR_WORKSPACE_FILE"].map { URL(fileURLWithPath: $0) }
        ?? URL.applicationSupportDirectory.appending(path: "Clair/workspace.json")
    }

    /// First launch: `CLAIR_PROJECT_ROOT`, else the launch directory, else home.
    private static var seedRoot: String {
      let cwd = FileManager.default.currentDirectoryPath
      return ProcessInfo.processInfo.environment["CLAIR_PROJECT_ROOT"] ?? (cwd == "/" ? NSHomeDirectory() : cwd)
    }

    @discardableResult
    public func run(_ id: String, _ input: CommandInput = [:], confirmed: Bool = false) -> Result<CommandResult, CommandError> {
      let r = registry.execute(id, input, confirmed: confirmed, state: &state)
      switch r {
      case .failure(let e) where e.code == .confirmationRequired: pending = (id, input)
      // ponytail: kept for inspection only; no canvas error surface yet (U05/U07).
      case .failure(let e): lastError = e
      case .success:
        lastError = nil
        if let persistURL { try? state.save(to: persistURL) }
      }
      return r
    }

    public func confirm() {
      guard let p = pending else { return }
      pending = nil
      run(p.id, p.input, confirmed: true)
    }
  }

  private struct StoreKey: FocusedValueKey { typealias Value = ClairV2WorkbenchStore }
  extension FocusedValues {
    var clairWorkbench: ClairV2WorkbenchStore? {
      get { self[StoreKey.self] }
      set { self[StoreKey.self] = newValue }
    }
  }

  /// Menu bar projection of the registry; default shortcuts live here, so the
  /// hidden-button shortcut layer is gone.
  public struct ClairV2CommandMenu: Commands {
    @FocusedValue(\.clairWorkbench) private var store
    public init() {}

    public var body: some Commands {
      CommandMenu("Clair") {
        ForEach(CommandRegistry.workbench.commands.filter { $0.shortcut != nil }, id: \.id) { d in
          Button(d.title) { store?.run(d.id) }
            .keyboardShortcut(Self.shortcut(d.shortcut!))
            .disabled(store == nil)
        }
      }
    }

    /// `⌃⌘⇧D` → modifiers from the symbols, key from the last character.
    static func shortcut(_ s: String) -> KeyboardShortcut {
      var m: EventModifiers = []
      for (sym, mod) in [("⌘", EventModifiers.command), ("⌃", .control), ("⇧", .shift), ("⌥", .option)] where s.contains(sym) {
        m.insert(mod)
      }
      let k = s.last!
      return KeyboardShortcut(k == "→" ? .rightArrow : KeyEquivalent(Character(k.lowercased())), modifiers: m)
    }
  }

  /// U04: AppShell chrome (checklist §3) — titlebar 48 + sidebar 286 + main +
  /// status 26. Built once; only sidebar panel and main are swapped. Pane
  /// contents other than the terminal are placeholders owned by U05/U06.
  public struct ClairV2AppShell: View {
    @State private var store = ClairV2WorkbenchStore()
    private var st: WorkbenchState { store.state }
    @State private var query = ""
    @State private var selection = 0
    private let projectColors = [C.debugBlue, C.success, C.attention]

    public init() {}

    public var body: some View {
      VStack(spacing: 0) {
        titlebar
        HStack(spacing: 0) {
          sidebar
          Rectangle().fill(L.hairline).frame(width: 1)
          if st.settingsOpen { settingsMain } else { main }
        }
        statusBar
      }
      .background(C.canvas)
      .frame(minWidth: 900, minHeight: 560)
      .overlay { if let p = st.palette { paletteView(p) } }
      .animation(.easeOut(duration: 0.09), value: st.palette == nil)
      .onChange(of: st.palette) { query = ""; selection = 0 }
      .focusedSceneValue(\.clairWorkbench, store)
      .confirmationDialog(
        "未保存の変更を破棄しますか？", isPresented: Binding(get: { store.pending != nil }, set: { if !$0 { store.pending = nil } })
      ) {
        Button("破棄して続行", role: .destructive) { store.confirm() }
      }
    }

    private var titlebar: some View {
      HStack(spacing: 8) {
        HStack(spacing: 8) {
          ForEach([C.close, C.minimize, C.zoom], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
        }
        .padding(.trailing, 12)
        ForEach(Array(st.projects.enumerated()), id: \.element.name) { i, p in
          let color = projectColors[i % projectColors.count]
          let on = st.project == p.name
          Button { store.run("project.switch", ["name": .string(p.name)]) } label: {
            Text(p.name).font(Typography.font(Typography.chromeStrong))
              .foregroundStyle(C.textPrimary)
              .padding(.horizontal, 10).frame(height: 26)
              .background(color.opacity(on ? 0.22 : 0.14), in: RoundedRectangle(cornerRadius: Radius.card))
              .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(color.opacity(on ? 0.55 : 0.28)))
          }.buttonStyle(.plain)
        }
        Button(action: openFolder) { Image(systemName: "plus").foregroundStyle(C.chromeInk) }.buttonStyle(.plain)
        Spacer()
        Button { store.run(st.settingsOpen ? "settings.close" : "settings.open") } label: {
          Image(systemName: "gearshape").foregroundStyle(C.chromeInk)
        }.buttonStyle(.plain)
      }
      .padding(.horizontal, 16)
      .frame(height: ChromeBudget.titlebar)
      .background(C.chrome)
      .overlay(alignment: .bottom) { Rectangle().fill(L.chrome).frame(height: 1) }
    }

    private func openFolder() {
      let panel = NSOpenPanel()
      panel.canChooseFiles = false; panel.canChooseDirectories = true
      if panel.runModal() == .OK, let url = panel.url { store.run("project.open", ["path": .string(url.path)]) }
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
        ScrollView { VStack(alignment: .leading, spacing: 0) { st.settingsOpen ? AnyView(sections) : AnyView(explorer) } }
        Spacer(minLength: 0)
      }
      .frame(width: 286)
      .background(C.chromeRaised)
    }

    private var sections: some View {
      ForEach(["一般", "AIプロバイダー", "エディタ", "ターミナル", "モバイル", "アップデート"], id: \.self) { s in
        row(s, depth: 0, selected: st.section == s) { store.run("settings.open", ["section": .string(s)]) }
      }
    }

    /// Folders derived from the file paths; click toggles, files open a tab.
    private var explorer: some View {
      var out: [(id: String, label: String, depth: Int, file: WorkbenchFile?)] = []
      var seen = Set<String>()
      for f in st.files {
        let parts = f.path.split(separator: "/").map(String.init)
        for d in 0..<parts.count - 1 {
          let id = parts[0...d].joined(separator: "/")
          if seen.insert(id).inserted { out.append((id, parts[d], d, nil)) }
        }
        out.append((f.path, parts.last!, parts.count - 1, f))
      }
      return ForEach(out.filter { r in !st.collapsed.contains { r.id.hasPrefix($0 + "/") } }, id: \.id) { r in
        if let f = r.file {
          row(r.label, depth: r.depth, selected: st.active == f.path && !st.settingsOpen, badge: f.status?.first) { store.run("tab.open", ["path": .string(f.path)]) }
        } else {
          row((st.collapsed.contains(r.id) ? "▸ " : "▾ ") + r.label, depth: r.depth, selected: false) {
            store.run("explorer.toggle", ["path": .string(r.id)])
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
            .onTapGesture { store.run("tab.activate", ["path": .string(p)]) }
          }
          Spacer(minLength: 0)
        }
        .background(C.chromeRaised)
        PaneView(
          node: st.tree.maximized.flatMap { id in st.tree.leaves.first { $0.id == id }.map { .leaf(id: $0.id, kind: $0.kind) } } ?? st.tree.root,
          focused: st.tree.focused, onFocus: { store.run("pane.focus", ["id": .int($0)]) },
          onRatio: { store.run("pane.setRatio", ["id": .int($0), "ratio": .double($1)]) })
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
      Toggle(title, isOn: Binding(get: { st.toggles[key] ?? false }, set: { store.run("settings.set", ["key": .string(key), "value": .bool($0)]) })).foregroundStyle(C.textSecondary)
    }

    private var statusBar: some View {
      HStack {
        Text(st.settingsOpen ? "設定 · \(st.section)" : "Ln 1, Col 1").font(Typography.font(Typography.chrome, family: .mono)).foregroundStyle(C.chromeInkMuted)
        Spacer()
      }
      .padding(.horizontal, 12).frame(height: ChromeBudget.statusBar)
      .background(C.chrome)
      .overlay(alignment: .top) { Rectangle().fill(L.chrome).frame(height: 1) }
    }

    // MARK: palette (⌘K commands, ⌘P files)

    private func items(_ p: WorkbenchState.Palette) -> [PaletteItem] {
      store.registry.paletteItems(p, query: query, state: st)
    }

    private func paletteView(_ p: WorkbenchState.Palette) -> some View {
      let list = items(p)
      return ZStack(alignment: .top) {
        Color.black.opacity(0.35).onTapGesture { store.run("palette.close") }
        VStack(spacing: 0) {
          TextField(p == .commands ? "コマンドを入力" : "ファイルへ移動", text: $query)
            .textFieldStyle(.plain).padding(12)
            .onSubmit { run(list) }
            .onKeyPress(.downArrow) { selection = min(selection + 1, max(list.count - 1, 0)); return .handled }
            .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
            .onKeyPress(.escape) { store.run("palette.close"); return .handled }
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

    private func run(_ list: [PaletteItem]) {
      guard selection < list.count else { return }
      store.run("palette.close")
      store.run(list[selection].id, list[selection].input)
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
