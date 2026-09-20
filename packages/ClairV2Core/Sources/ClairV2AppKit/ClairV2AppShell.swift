#if os(macOS)
  import ClairV2DesignSystem
  import ClairV2EditorCore
  import ClairV2Workspace
  import IOKit.pwr_mgt
import IOKit.ps
import Observation
  import SwiftUI
@preconcurrency import UserNotifications

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
    /// U05: open editor buffers of the active Project, keyed by relative path.
    public let buffers = EditorBuffers()
    let reviews = ReviewStore()

    /// V09: update flow state (Stable only; Dev has no feed).
    public enum UpdateStatus: Equatable { case idle, checking, available(ClairV2Update), installing, failed(String) }
    public var update: UpdateStatus = .idle
    public let updateConfig = ClairV2UpdateConfiguration.live()
    private var updateTask: Task<Void, Never>?
    private var sleepAssertion: IOPMAssertionID = 0

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
      let server = WorkbenchIPCServer { req in
        if req.via == .mcp {
          return MCPGate.handle(
            req, registry: CommandRegistry.workbench,
            snapshot: { DispatchQueue.main.sync { MainActor.assumeIsolated { store.state } } },
            approve: { store.requestMCPApproval($0, $1, $2) },
            run: { id, input in DispatchQueue.main.sync { MainActor.assumeIsolated { store.run(id, input, confirmed: true) } } })
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { store.run(req.command, req.input) } }
      }
      if (try? server.start()) != nil { ipc = server }
      ClairV2Updater.markStartupSuccess(updateConfig)  // tells a pending update helper this launch is healthy
      startAutomaticUpdateChecks()
    }

    isolated deinit { ipc?.stop(); updateTask?.cancel(); releaseSleepAssertion() }

    /// ADR-0009: 5 s after launch, then hourly. Never applies on its own.
    private func startAutomaticUpdateChecks() {
      guard updateConfig.channel == .stable, updateConfig.publicKeyBase64 != nil, updateConfig.isInstalled else { return }
      updateTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(5))
        while !Task.isCancelled {
          await self?.checkForUpdate(manual: false)
          try? await Task.sleep(for: .seconds(3600))
        }
      }
    }

    public func checkForUpdate(manual: Bool) async {
      if case .installing = update { return }
      update = .checking
      do { update = .available(try await ClairV2Updater.check(updateConfig)) } catch {
        if case ClairV2UpdateError.notNewer = error { update = .idle } else { update = manual ? .failed("\(error)") : .idle }
      }
    }

    /// The user pressed 適用: download, verify, stage, then quit so the helper can swap and relaunch.
    public func installUpdate() async {
      guard case .available(let u) = update else { return }
      update = .installing
      do {
        try await ClairV2Updater.install(u, updateConfig)
        NSApp.terminate(nil)
      } catch { update = .failed("\(error)") }
    }

    /// V09: block idle system sleep while agents run (AC power; battery only if opted in). Display may still sleep.
    private func refreshSleepAssertion() {
      let ac = (IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as String?) == kIOPSACPowerValue
      if state.preventsSleep(onACPower: ac) {
        guard sleepAssertion == 0 else { return }
        IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
          "Clair: agent running" as CFString, &sleepAssertion)
      } else { releaseSleepAssertion() }
    }

    private func releaseSleepAssertion() {
      guard sleepAssertion != 0 else { return }
      IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0
    }

    public static var defaultPersistURL: URL {
      ProcessInfo.processInfo.environment["CLAIR_WORKSPACE_FILE"].map { URL(fileURLWithPath: $0) }
        ?? ClairV2Channel.current.dataURL.appending(path: "workspace.json")
    }

    /// First launch: `CLAIR_PROJECT_ROOT`, else the launch directory, else home.
    private static var seedRoot: String {
      let cwd = FileManager.default.currentDirectoryPath
      return ProcessInfo.processInfo.environment["CLAIR_PROJECT_ROOT"] ?? (cwd == "/" ? NSHomeDirectory() : cwd)
    }

    @discardableResult
    public func run(_ id: String, _ input: CommandInput = [:], confirmed: Bool = false) -> Result<CommandResult, CommandError> {
      // `file.save` from any caller (⌘S, CLI, MCP) writes the buffer first; a failed write keeps the dirty marker.
      if id == "file.save", let p = state.active, let root = activeRoot, buffers.isOpen(p) {
        do {
          try? Self.history.record(root: root, path: p)  // pre-save content; best effort, never blocks a save
          try buffers.save(p, root: root)
        } catch {
          let e = CommandError(.preconditionFailed, "保存できません: \(error.localizedDescription)")
          lastError = e; return .failure(e)
        }
      }
      let r = registry.execute(id, input, confirmed: confirmed, state: &state)
      switch r {
      case .failure(let e) where e.code == .confirmationRequired: pending = (id, input)
      // ponytail: kept for inspection only; no canvas error surface yet (U05/U07).
      case .failure(let e): lastError = e
      case .success:
        lastError = nil
        refreshSleepAssertion()
        watchProject()
        if let persistURL { try? state.save(to: persistURL) }
      }
      return r
    }

    var activeRoot: String? { state.projects.first { $0.name == state.project }?.path }

    /// U05: called by the editor surface on every committed edit.
    static let history = LocalHistory(dir: URL.applicationSupportDirectory.appending(path: "Clair/history"))

    func dropDirty(_ path: String) { state.dirty.remove(path) }

    func edited(_ path: String) { state.dirty.insert(path) }  // the GUI owns dirty; never persisted (principle 8)

    /// V05: agent/external disk changes refresh the tree and drop unsaved markers (principle 8).
    private var watcher: FileWatcher?
    private var watched = ""

    private func watchProject() {
      guard watched != state.project else { return }
      watched = state.project
      guard let root = state.projects.first(where: { $0.name == state.project })?.path else { watcher = nil; return }
      watcher = FileWatcher(root: root) { [weak self] paths in
        DispatchQueue.main.async {
          guard let self, self.watched == self.state.project else { return }
          self.state.applyDiskChange(paths, root: root)
          self.buffers.drop(paths)
        }
      }
    }

    /// V08: a terminal fact becomes a history entry (and a macOS banner unless muted or the app is frontmost).
    public func facts(pane: Int, bells: Int, exit: Int?) {
      // Only this GUI writes facts (no command records them), so an agent cannot fabricate notifications.
      var fresh: WorkbenchNotice?
      if bells > 0 { fresh = state.notices.record(project: state.project, pane: pane, kind: .bell) ?? fresh }
      if let exit { fresh = state.notices.record(project: state.project, pane: pane, kind: .exited, exitCode: exit) ?? fresh }
      refreshSleepAssertion()
      guard let n = fresh, !NSApp.isActive,
        Bundle.main.bundleIdentifier != nil  // UNUserNotificationCenter traps outside an app bundle (swift run)
      else { return }
      let body = state.launches[n.pane].flatMap { AgentProfile.named($0.profile)?.title }.map { "\($0): \(n.title)" } ?? n.title
      let c = UNUserNotificationCenter.current()
      c.requestAuthorization(options: [.alert]) { granted, _ in
        guard granted else { return }
        let m = UNMutableNotificationContent()
        m.title = n.project; m.body = body
        c.add(UNNotificationRequest(identifier: "clair-\(n.id)", content: m, trigger: nil))
      }
    }

    /// V03: an AI call at write-or-above risk waits here (IPC thread, never main) for a native
    /// approval. No answer within `timeout` is a denial.
    public var mcpApproval: (id: String, input: CommandInput, risk: CommandRisk)?
    public private(set) var mcpApprovalDeadline = Date()
    private var mcpDecision: DispatchSemaphore?
    private var mcpApproved = false

    nonisolated func requestMCPApproval(_ id: String, _ input: CommandInput, _ risk: CommandRisk, timeout: TimeInterval = 60) -> Bool {
      let sem = DispatchSemaphore(value: 0)
      DispatchQueue.main.sync {
        MainActor.assumeIsolated { mcpApproval = (id, input, risk); mcpApprovalDeadline = Date().addingTimeInterval(timeout); mcpDecision = sem; mcpApproved = false }
      }
      _ = sem.wait(timeout: .now() + timeout)
      return DispatchQueue.main.sync {
        MainActor.assumeIsolated {
          defer { mcpApproval = nil; mcpDecision = nil }  // timeout: nobody answered
          return mcpApproved
        }
      }
    }

    public func resolveMCPApproval(_ approved: Bool) {
      // First answer wins: dismissing the dialog after "許可" must not turn it into a denial.
      guard let sem = mcpDecision else { return }
      mcpDecision = nil
      mcpApproved = approved
      sem.signal()
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
    @State private var store: ClairV2WorkbenchStore
    private var st: WorkbenchState { store.state }
    @State private var query = ""
    @State private var selection = 0
    // U05: sidebar mode + source-control view. GUI-local (no command); the stage buttons go through git.stage/unstage.
    @State private var sidebarMode = "folder"
    @State private var collapsedGroups: Set<String> = []
    @State private var rootFolded = false
    @State private var changes: [GitChange] = []
    @State private var branch: String?
    @State private var sync: (behind: Int, ahead: Int)?
    @State private var diff: DiffTarget?
    // V05: search panel state (GUI-local).
    @State private var searchQuery = ""
    @State private var replaceText = ""
    @State private var searchRegex = false
    @State private var searchCase = false
    @State private var hits: [SearchHit] = []
    @State private var searchMessage = ""
    private let projectColors = [C.debugBlue, C.success, C.attention]

    public init() { _store = State(initialValue: ClairV2WorkbenchStore()) }
    /// Snapshot tests inject a fixture store.
    init(store: ClairV2WorkbenchStore) { _store = State(initialValue: store) }

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
      .onChange(of: st.project) { diff = nil; reloadChanges() }
      .onChange(of: st.files) { reloadChanges() }
      .onAppear { reloadChanges() }
      .focusedSceneValue(\.clairWorkbench, store)
      .confirmationDialog(
        "未保存の変更を破棄しますか？", isPresented: Binding(get: { store.pending != nil }, set: { if !$0 { store.pending = nil } })
      ) {
        Button("破棄して続行", role: .destructive) { store.confirm() }
      }
      .overlay(alignment: .topTrailing) {
        if let a = store.mcpApproval {
          ApprovalCard(id: a.id, input: a.input, risk: a.risk, deadline: store.mcpApprovalDeadline, decide: store.resolveMCPApproval)
            .padding(.top, 56).padding(.trailing, 12).transition(.move(edge: .trailing).combined(with: .opacity))
        }
      }
      .animation(.easeOut(duration: 0.18), value: store.mcpApproval?.id)
    }

    /// Mock `AppTitlebar`: traffic lights, one tab group per Project (dot + name chip, then its file tabs), then the search field and window actions.
    private var titlebar: some View {
      HStack(spacing: 0) {
        HStack(spacing: 8) {
          ForEach([C.close, C.minimize, C.zoom], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
        }
        .frame(width: 76, alignment: .leading).padding(.leading, 20)
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 4) {
            ForEach(Array(st.projects.enumerated()), id: \.element.name) { i, p in
              if i > 0 { Rectangle().fill(Color(white: 0.95, opacity: 0.09)).frame(width: 1, height: 22).padding(.horizontal, 4) }
              projectGroup(p, color: projectColors[i % projectColors.count])
            }
            Button(action: openFolder) { Image(systemName: "plus").font(.system(size: 13)).foregroundStyle(C.chromeInk).frame(width: 30, height: 30) }
              .buttonStyle(.plain).help("フォルダを開く")
          }
        }
        HStack(spacing: 4) {
          Button { sidebarMode = "magnifyingglass"; reloadChanges() } label: {
            HStack(spacing: 4) {
              Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(C.textQuaternary)
              Text("ファイル、シンボル").font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
              Spacer(minLength: 0)
              Text("⌘⇧F").font(Typography.font(Typography.chrome)).foregroundStyle(C.textQuaternary)
            }
            .padding(.horizontal, 8).frame(width: 200, height: 28)
            .background(C.chrome, in: RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(L.hairline))
          }.buttonStyle(.plain).help("検索")
          titlebarAction("command", "コマンドパレット", on: st.palette == .commands) { store.run("palette.commands") }
          titlebarAction("gearshape", "設定", on: st.settingsOpen) { store.run(st.settingsOpen ? "settings.close" : "settings.open") }
        }.padding(.horizontal, 12)
      }
      .frame(height: ChromeBudget.titlebar)
      .background(C.chrome)
      .overlay(alignment: .bottom) { Rectangle().fill(L.hairline).frame(height: 1) }
    }

    private func titlebarAction(_ icon: String, _ help: String, on: Bool, _ action: @escaping () -> Void) -> some View {
      Button(action: action) {
        Image(systemName: icon).font(.system(size: 13)).foregroundStyle(on ? C.chromeInk : C.chromeInkMuted)
          .frame(width: 30, height: 30).background(on ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.card))
      }.buttonStyle(.plain).help(help)
    }

    /// The chip toggles the group's tab strip (GUI-local; it never changes the active Project).
    private func projectGroup(_ p: WorkbenchProject, color: Color) -> some View {
      let active = st.project == p.name
      let tabs = active ? st.tabs : (st.layouts[p.name]?.tabs ?? [])
      let current = active ? st.active : st.layouts[p.name]?.active
      let dirty = active ? st.dirty : (st.layouts[p.name]?.dirty ?? [])
      let folded = collapsedGroups.contains(p.name)
      return HStack(spacing: 0) {
        Button { if folded { collapsedGroups.remove(p.name) } else { collapsedGroups.insert(p.name) } } label: {
          HStack(spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(p.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(active ? C.textPrimary : C.textSecondary).lineLimit(1)
          }
          .padding(.horizontal, 8).frame(height: 26)
          .overlay(alignment: .topTrailing) {
            if st.notices.unread(p.name) > 0 {
              Text("\(st.notices.unread(p.name))").font(.system(size: 9, weight: .bold)).foregroundStyle(C.textPrimary)
                .padding(.horizontal, 4).background(color, in: Capsule()).offset(x: 2, y: -4)
            }
          }
        }
        .buttonStyle(.plain).help("\(p.name) タブグループを\(folded ? "展開" : "折りたたむ")")
        .contextMenu {
          let muted = st.notices.mutedProjects.contains(p.name)
          Button(muted ? "通知のミュートを解除" : "通知をミュート") {
            store.run("notice.muteProject", ["name": .string(p.name), "muted": .bool(!muted)])
          }
        }
        if !folded {
          HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element) { i, path in
              if i > 0 { Rectangle().fill(L.chromeSoft).frame(width: 1, height: 18) }
              fileTab(path, projectActive: active, project: p.name, selected: path == current && active, dirty: dirty.contains(path))
            }
          }.padding(.leading, 4)
        }
      }
    }

    private func fileTab(_ path: String, projectActive: Bool, project: String, selected: Bool, dirty: Bool) -> some View {
      let tint = selected ? C.chromeInk : C.textTertiary
      return HStack(spacing: 4) {
        Image(systemName: path.hasSuffix(".md") ? "text.alignleft" : "doc.text").font(.system(size: 11)).foregroundStyle(tint)
        Text(name(path)).font(.system(size: 11, weight: selected ? .semibold : .regular)).foregroundStyle(tint).lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 0)
        if dirty { Circle().fill(selected ? C.textTertiary : C.textQuaternary).frame(width: 6, height: 6) }
        if selected {
          Button { store.run("tab.close", ["path": .string(path)]) } label: {
            Image(systemName: "xmark").font(.system(size: 9, weight: .medium)).foregroundStyle(C.textTertiary)
          }.buttonStyle(.plain).help("閉じる")
        }
      }
      .padding(.horizontal, 8).frame(width: 200, height: 38)
      .background(selected ? C.canvas : .clear, in: RoundedRectangle(cornerRadius: Radius.card))
      .overlay(alignment: .bottom) { if selected { Rectangle().fill(C.textPrimary).frame(height: 1.5) } }
      .contentShape(Rectangle())
      .onTapGesture {
        if !projectActive { store.run("project.switch", ["name": .string(project)]) }
        store.run("tab.activate", ["path": .string(path)])
      }
      .help(path)
      .contextMenu { if projectActive { fileMenu(path, tab: true) } }
    }

    private func openFolder() {
      let panel = NSOpenPanel()
      panel.canChooseFiles = false; panel.canChooseDirectories = true
      if panel.runModal() == .OK, let url = panel.url { store.run("project.open", ["path": .string(url.path)]) }
    }

    // MARK: sidebar

    private var sidebar: some View {
      VStack(spacing: 0) {
        HStack(spacing: 2) {
          ForEach(["folder", "magnifyingglass", "clock.arrow.circlepath", "shield", "terminal", "bell", "ladybug"], id: \.self) { icon in
            let on = sidebarMode == icon && !st.settingsOpen
            Button { if icon != "ladybug" { sidebarMode = icon; if icon == "folder" { diff = nil }; reloadChanges() } } label: {
              Image(systemName: icon).font(.system(size: 13)).foregroundStyle(on ? C.chromeInk : C.chromeInkMuted)
                .frame(width: 30, height: 28)
                .background(on ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.card))
                .overlay(alignment: .topTrailing) { if icon == "bell", st.notices.unread() > 0 { Circle().fill(C.attention).frame(width: 6, height: 6).offset(x: -6, y: 5) } }
            }.buttonStyle(.plain)
          }
          Spacer()
          Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(C.chromeInkMuted).frame(width: 24, height: 28)
        }
        // ponytail: the mock strip has 4 entries (files/review/agents/debug); search/history/notices stay as extra native entries, so icons are 30 wide instead of 38.
        .padding(.horizontal, 8).frame(height: ChromeBudget.sidebarStrip)
        Rectangle().fill(L.chromeSoft).frame(height: 1)
        ScrollView { VStack(alignment: .leading, spacing: 0) { st.settingsOpen ? AnyView(sections) : sidebarMode == "magnifyingglass" ? AnyView(searchPanel) : sidebarMode == "clock.arrow.circlepath" ? AnyView(historyPanel) : sidebarMode == "shield" ? AnyView(changesList) : sidebarMode == "bell" ? AnyView(noticeList) : sidebarMode == "terminal" ? AnyView(sessionList) : AnyView(explorer) } }
        Spacer(minLength: 0)
      }
      .frame(width: 286)
      .background(C.chromeRaised)
    }

    private var searchPattern: SearchPattern {
      searchRegex ? .regex(searchQuery, caseSensitive: searchCase) : .literal(searchQuery, caseSensitive: searchCase)
    }

    private func runSearch() {
      guard let root = store.activeRoot, !searchQuery.isEmpty else { hits = []; searchMessage = ""; return }
      hits = (try? ProjectSearch.find(root: root, files: st.files, searchPattern)) ?? []  // unreadable files are skipped; only a bad regex yields nothing
      searchMessage = hits.isEmpty ? "一致なし（正規表現を確認）" : "\(hits.count) 件 / \(Set(hits.map(\.path)).count) ファイル"
    }

    private func runReplace() {
      guard let root = store.activeRoot else { return }
      let history = ClairV2WorkbenchStore.history
      do {
        let n = try ProjectSearch.replace(root: root, files: st.files, searchPattern, with: replaceText, history: history)
        runSearch(); searchMessage = "\(n) 件を置換しました（履歴に退避済み）"
      } catch { searchMessage = "置換できません: \(error)" }
    }

    private var searchPanel: some View {
      SearchPanel(
        query: $searchQuery, replacement: $replaceText, regex: $searchRegex, caseSensitive: $searchCase,
        hits: hits, message: searchMessage, search: runSearch, replaceAll: runReplace,
        open: { store.run("tab.open", ["path": .string($0.path)]); store.buffers.reveal($0.path, line: $0.line) })
    }

    private var historyPanel: some View {
      let history = ClairV2WorkbenchStore.history
      return HistoryList(
        path: st.active, versions: st.active.flatMap { p in store.activeRoot.flatMap { try? history.versions(root: $0, path: p) } } ?? [],
        preview: { v in
          guard let root = store.activeRoot, let p = st.active else { return [] }
          return history.preview(v, root: root, path: p)
        },
        restore: { v in
          guard let root = store.activeRoot, let p = st.active else { return }
          try? history.restore(v, root: root, path: p)
          store.buffers.drop([p]); store.dropDirty(p)  // reload from disk; the pre-restore content is itself a new version
        })
    }

    private var sessionList: some View {
      SessionList(sessions: st.agentSessions, current: st.project) { s in
        if s.project != st.project { store.run("project.switch", ["name": .string(s.project)]) }
        store.run("pane.focus", ["id": .int(s.pane)])
      }
    }

    private var noticeList: some View {
      NoticeList(
        log: st.notices, current: st.project,
        agentTitle: { n in st.project == n.project ? st.launches[n.pane].flatMap { AgentProfile.named($0.profile)?.title } : nil },
        run: { store.run($0, $1) })
    }

    private var changesList: some View {
      ChangesList(
        changes: changes, selected: diff, onSelect: { diff = $0 },
        onToggle: { c, stage in
          store.run(stage ? "git.stage" : "git.unstage", ["path": .string(c.path)]); reloadChanges()
        },
        onBulk: { rows, stage in
          for c in rows { store.run(stage ? "git.stage" : "git.unstage", ["path": .string(c.path)]) }
          reloadChanges()
        },
        onCommit: { msg in
          defer { reloadChanges() }
          switch store.run("git.commit", ["message": .string(msg)]) {
          case .failure(let e): return e.message
          case .success(.text(let t)): return t
          default: return nil
          }
        })
    }

    private func reloadChanges() {
      changes = store.activeRoot.map(WorkbenchGit.changes) ?? []
      branch = store.activeRoot.flatMap(WorkbenchGit.currentBranch)
      sync = store.activeRoot.flatMap(WorkbenchGit.aheadBehind)
      if let d = diff, !changes.contains(where: { $0.path == d.path }) { diff = nil }
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
          if seen.insert(id).inserted { out.append((id, parts[d], d + 1, nil)) }
        }
        out.append((f.path, parts.last!, parts.count, f))
      }
      return VStack(alignment: .leading, spacing: 0) {
        // Project root: bold, branch glyph; folds the whole tree (GUI-local).
        treeRow(depth: 0, selected: false, action: { rootFolded.toggle() }) {
          chevron(open: !rootFolded)
          Image(systemName: "arrow.triangle.branch").font(.system(size: 9)).foregroundStyle(C.textTertiary)
          Text(st.project).font(.system(size: 11, weight: .semibold)).foregroundStyle(C.textPrimary)
          Spacer(minLength: 0)
        }
        if !rootFolded {
          ForEach(out.filter { r in !st.collapsed.contains { r.id.hasPrefix($0 + "/") } }, id: \.id) { r in
            if let f = r.file {
              let on = st.active == f.path && !st.settingsOpen
              let badge = st.dirty.contains(f.path) ? "M" : f.status
              treeRow(depth: r.depth, selected: on, action: { store.run("tab.open", ["path": .string(f.path)]) }) {
                Image(systemName: f.path.hasSuffix(".md") ? "text.alignleft" : "doc.text").font(.system(size: 10)).foregroundStyle(on ? C.textSecondary : C.textTertiary).frame(width: 12)
                Text(r.label).font(.system(size: 11, weight: on ? .semibold : .regular)).foregroundStyle(on ? C.textPrimary : C.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
                if let b = badge { Text(b).font(.system(size: 11, weight: .semibold)).foregroundStyle(b == "A" || b == "?" ? C.success : C.attention) }
              }
              .contextMenu { fileMenu(f.path, tab: false) }
            } else {
              let open = !st.collapsed.contains(r.id)
              treeRow(depth: r.depth, selected: false, action: { store.run("explorer.toggle", ["path": .string(r.id)]) }) {
                chevron(open: open)
                Text(r.label).font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
              }
              .contextMenu {
                Button(open ? "折りたたむ" : "開く") { store.run("explorer.toggle", ["path": .string(r.id)]) }
                Divider()
                pathItems(r.id)
              }
            }
          }
        }
      }.padding(.vertical, 4)
    }

    private func row(_ title: String, depth: Int, selected: Bool, badge: Character? = nil, _ action: @escaping () -> Void) -> some View {
      treeRow(depth: depth, selected: selected, action: action) {
        Text(title).font(Typography.font(Typography.chrome)).foregroundStyle(selected ? C.textPrimary : C.textSecondary)
        Spacer(minLength: 0)
        if let b = badge { Text(String(b)).font(Typography.font(Typography.micro)).foregroundStyle(C.textTertiary) }
      }
    }

    private func chevron(open: Bool) -> some View {
      Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(C.textTertiary)
        .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10)
    }

    /// Mock explorer row: an inset 26px pill (8px margin outside the fill), 12px indent per level.
    private func treeRow<Content: View>(depth: Int, selected: Bool, action: @escaping () -> Void, @ViewBuilder _ content: () -> Content) -> some View {
      Button(action: action) {
        HStack(spacing: 4, content: content)
          .padding(.leading, 8 + CGFloat(depth) * 12).padding(.trailing, 8).frame(height: 26)
          .background(selected ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
          .padding(.horizontal, 8).contentShape(Rectangle())
      }.buttonStyle(.plain)
    }

    // MARK: context menus (checklist §3.6). ponytail: native NSMenu, not the canvas's custom overlay;

    @ViewBuilder private func fileMenu(_ path: String, tab: Bool) -> some View {
      if tab {
        Button("タブを閉じる") { store.run("tab.close", ["path": .string(path)]) }
        Button("分割して開く") { store.run("tab.activate", ["path": .string(path)]); store.run("pane.splitRight") }
      } else {
        Button("開く") { store.run("tab.open", ["path": .string(path)]) }
      }
      let change = changes.first { $0.path == path }
      Button("変更を確認") {
        if let c = change { diff = DiffTarget(path: c.path, staged: c.staged && !c.unstaged, untracked: c.untracked) }
      }.disabled(change == nil)
      Divider()
      agentItems(path)
      pathItems(path)
    }

    /// "Agent に送る ›": types `@path ` into a running agent terminal of this Project. No Return; the user reviews and sends.
    @ViewBuilder private func agentItems(_ path: String) -> some View {
      let agents = st.agentSessions.filter { $0.project == st.project && !$0.status.isExited }
      Menu("Agent に送る") {
        ForEach(agents) { a in
          Button("\(a.title) · pane \(a.pane)") {
            if ClairV2GhosttySurfaceView.send("@\(path) ", toPane: a.pane) { store.run("pane.focus", ["id": .int(a.pane)]) }
          }
        }
      }.disabled(agents.isEmpty)
    }

    @ViewBuilder private func pathItems(_ path: String) -> some View {
      let full = store.activeRoot.map { ($0 as NSString).appendingPathComponent(path) }
      Button("パスをコピー") {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string)
      }
      Button("Finder で表示") { full.map { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0)]) } }.disabled(full == nil)
    }

    // MARK: main

    private func name(_ path: String) -> String { String(path.split(separator: "/").last ?? "") }

    private var main: some View {
      VStack(spacing: 0) {
        if let d = diff, let root = store.activeRoot {
          let fileLines = (try? String(contentsOfFile: root + "/" + d.path, encoding: .utf8))?.split(separator: "\n", omittingEmptySubsequences: false)
          let buffer: EditorTransactionManager? = { if case .ready(let m) = store.buffers.load(d.path, root: root) { m } else { nil } }()
          DiffView(
            target: d, text: WorkbenchGit.diff(root, d.path, staged: d.staged, untracked: d.untracked),
            threads: store.reviews.threads(root: root, d.path, in: fileLines),
            suggestions: store.reviews.suggestions(root: root, d.path, current: buffer?.buffer.snapshot.revision),
            onComment: { n, text, body in
              if let m = buffer { store.reviews.add(root: root, path: d.path, line: n, text: text, body: body, snapshot: m.buffer.snapshot) }
            },
            onSuggest: { n, replacement in
              if let m = buffer { store.reviews.suggest(root: root, path: d.path, line: n, replacement: replacement, snapshot: m.buffer.snapshot) }
            },
            onResolve: { store.reviews.resolve(root: root, path: d.path, id: $0) },
            onApply: { id in
              guard let m = buffer else { return "ファイルを開けません。" }
              let e = store.reviews.apply(root: root, path: d.path, id: id, in: m)
              if e == nil { store.buffers.refresh(d.path); store.edited(d.path) }
              return e
            },
            onReject: { store.reviews.reject(root: root, path: d.path, id: $0) },
            onSend: store.reviews.prompt(root: root, path: d.path, in: fileLines).map { text in
              {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                // Paste is left to the user: a review comment must not run as an agent command unseen.
                if let a = st.agentSessions.first(where: { $0.project == st.project && !$0.status.isExited }) { store.run("pane.focus", ["id": .int(a.pane)]); diff = nil }
              }
            },
            onClose: { diff = nil })
        } else {
        PaneView(
          node: st.tree.maximized.flatMap { id in st.tree.leaves.first { $0.id == id }.map { .leaf(id: $0.id, kind: $0.kind) } } ?? st.tree.root,
          focused: st.tree.focused, launches: st.launches, onFocus: { store.run("pane.focus", ["id": .int($0)]) },
          onFacts: { store.facts(pane: $0, bells: $1, exit: $2) },
          onRatio: { store.run("pane.setRatio", ["id": .int($0), "ratio": .double($1)]) },
          editor: EditorPane(buffers: store.buffers, root: store.activeRoot, path: st.active, onEdit: { store.edited($0) }, onCaret: { store.buffers.setCaret($0, $1, in: $2) }),
          run: { _ = store.run($0, $1) })
        }
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
          } else if st.section == "ターミナル" {
            toggle("バッテリー駆動中もエージェント実行中はスリープさせない", "preventSleepOnBattery")
          } else if st.section == "アップデート" {
            updateSection
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

    @ViewBuilder private var updateSection: some View {
      let c = store.updateConfig
      Text("\(c.channel.displayName) \(c.currentVersion)").foregroundStyle(C.textSecondary)
      if c.channel == .dev {
        Text("Dev ビルドは更新フィードを持ちません。").foregroundStyle(C.textMuted)
      } else {
        switch store.update {
        case .idle: Text("最新の状態です。").foregroundStyle(C.textTertiary)
        case .checking: Text("確認中…").foregroundStyle(C.textTertiary)
        case .installing: Text("更新を適用しています。完了後に再起動します。").foregroundStyle(C.textTertiary)
        case .failed(let m): Text(m).foregroundStyle(C.textTertiary)
        case .available(let u):
          Text("\(u.version) が利用できます。\(u.notes ?? "")").foregroundStyle(C.textSecondary)
          Button("適用して再起動") { Task { await store.installUpdate() } }
        }
        Button("更新を確認") { Task { await store.checkForUpdate(manual: true) } }
      }
    }

    private func toggle(_ title: String, _ key: String) -> some View {
      Toggle(title, isOn: Binding(get: { st.toggles[key] ?? false }, set: { store.run("settings.set", ["key": .string(key), "value": .bool($0)]) })).foregroundStyle(C.textSecondary)
    }

    /// U06/U05: facts only — branch, change/dirty counts, agent state. Ln/Col waits on an editor caret callback.
    /// Mock `AppStatusBar`: branch, ahead/behind, change count, caret, then the session count on the right. 26px, sans, `textTertiary`.
    // ponytail: no quota meter (needs a provider usage source; the showQuota toggle exists but has no data yet).
    private var statusBar: some View {
      let agents = st.agentSessions.filter { $0.project == st.project && !$0.status.isExited }
      let waiting = agents.filter { $0.status == .attention }.count
      let caret = st.active.flatMap { store.buffers.caret[$0] }
      return HStack(spacing: 12) {
        if st.settingsOpen {
          Text("設定 · \(st.section)")
        } else {
          if let branch {
            HStack(spacing: 4) { Image(systemName: "arrow.triangle.branch").font(.system(size: 10)); Text(branch) }
          }
          if let sync { Text("↓\(sync.behind) ↑\(sync.ahead)").foregroundStyle(C.textQuaternary) }
          if !changes.isEmpty { Text("\(changes.count) 変更") }
          if !st.dirty.isEmpty { Text("未保存 \(st.dirty.count)").foregroundStyle(C.attention) }
          if let caret { Text("Ln \(caret.line), Col \(caret.col)") }
        }
        Spacer()
        Button { sidebarMode = "terminal" } label: {
          HStack(spacing: 5) {
            if waiting > 0 { Circle().fill(C.attention).frame(width: 6, height: 6) }
            Text("\(agents.count) セッション" + (waiting > 0 ? " · 入力待ち \(waiting)" : ""))
          }
        }.buttonStyle(.plain)
      }
      .font(Typography.font(Typography.chrome)).monospacedDigit().foregroundStyle(C.textTertiary)
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
    let launches: [Int: AgentLaunch]
    let onFocus: (Int) -> Void
    let onFacts: (Int, Int, Int?) -> Void
    let onRatio: (Int, Double) -> Void
    let editor: EditorPane
    let run: (String, CommandInput) -> Void

    private func firstLeaf(_ n: PaneTree.Node) -> Int {
      switch n {
      case .leaf(let id, _): return id
      case .split(_, _, let a, _): return firstLeaf(a)
      }
    }

    @ViewBuilder
    private func parts(_ axis: PaneTree.Axis, _ total: CGFloat, _ a: PaneTree.Node, _ b: PaneTree.Node, ratio: Double) -> some View {
      let h = axis == .horizontal
      PaneView(node: a, focused: focused, launches: launches, onFocus: onFocus, onFacts: onFacts, onRatio: onRatio, editor: editor, run: run)
        .frame(width: h ? total * ratio : nil, height: h ? nil : total * ratio)
      Rectangle().fill(L.paneDivider).frame(width: h ? 1 : nil, height: h ? nil : 1)
        .padding(h ? .horizontal : .vertical, -3).contentShape(Rectangle())
        .gesture(
          DragGesture(coordinateSpace: .named("split")).onChanged { v in
            onRatio(firstLeaf(a), Double((h ? v.location.x : v.location.y) / total))
          })
      PaneView(node: b, focused: focused, launches: launches, onFocus: onFocus, onFacts: onFacts, onRatio: onRatio, editor: editor, run: run)
    }

    var body: some View {
      switch node {
      case .leaf(let id, let kind):
        ZStack {
          C.surface
          if kind == .terminal { ClairV2GhosttySurface(launch: launches[id].map { ($0.command, $0.cwd) }, pane: id, onFacts: { onFacts(id, $0, $1) }) }  // ponytail: one surface per terminal leaf; session binding is U06
          else if kind == .editor { editor }
          else { Text(kind.rawValue).foregroundStyle(C.textMuted) }  // agent content: U06
        }
        .overlay(Rectangle().stroke(id == focused ? L.ring : .clear))
        .onTapGesture { onFocus(id) }
        // ponytail: the libghostty NSView may consume right-clicks, so terminal panes might not show this; copy/paste/clear items wait on U06 surface commands.
        .contextMenu {
          Button("右に分割") { run("pane.focus", ["id": .int(id)]); run("pane.splitRight", [:]) }
          Button("下に分割") { run("pane.focus", ["id": .int(id)]); run("pane.splitDown", [:]) }
          Button("最大化") { run("pane.focus", ["id": .int(id)]); run("pane.maximize", [:]) }
          Divider()
          Button("ペインを閉じる", role: .destructive) { run("pane.focus", ["id": .int(id)]); run("pane.close", [:]) }
        }
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
