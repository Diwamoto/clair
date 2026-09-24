#if os(macOS)
  import ClairDesignSystem
  import ClairEditorCore
  import ClairEditorLanguage
  import ClairWorkspace
  import IOKit.pwr_mgt
import IOKit.ps
import Observation
  import SwiftUI
@preconcurrency import UserNotifications
  import UniformTypeIdentifiers

  private typealias C = DesignTokens.Color
  private typealias L = DesignTokens.Line
  private typealias W = DesignTokens.Wash

  /// Plain button plus the Workbench hover wash, so every chrome control answers the pointer.
  struct HoverWashStyle: ButtonStyle {
    var radius: CGFloat = Radius.card
    func makeBody(configuration: Configuration) -> some View { HoverBody(configuration: configuration, radius: radius) }
    private struct HoverBody: View {
      let configuration: ButtonStyleConfiguration
      let radius: CGFloat
      @State private var hovered = false
      @Environment(\.isEnabled) private var enabled
      @Environment(\.accessibilityReduceMotion) private var reduceMotion
      var body: some View {
        configuration.label
          .overlay((hovered && enabled) || configuration.isPressed ? DesignTokens.Wash.selected : .clear, in: RoundedRectangle(cornerRadius: radius))
          .contentShape(Rectangle())
          .onHover { hovered = $0 }
          .animation(reduceMotion ? nil : .easeOut(duration: Motion.overlayDuration), value: hovered)
      }
    }
  }

  extension ButtonStyle where Self == HoverWashStyle {
    static var hoverWash: HoverWashStyle { HoverWashStyle() }
  }

  /// V01: the GUI process owns `WorkbenchState` (ADR-0007 state owner). Every
  /// mutation goes through `CommandRegistry.workbench`; a destructive effective
  /// risk parks the call in `pending` until the native confirmation approves it.
  @MainActor @Observable public final class ClairWorkbenchStore {
    public var state = WorkbenchState()
    public var pending: (id: String, input: CommandInput)?
    public var lastError: CommandError?
    public let registry = CommandRegistry.workbench
    /// U05: open editor buffers of the active Project, keyed by relative path.
    public let buffers = EditorBuffers()
    let reviews = ReviewStore()
    /// V13: a managed worktree is a separate Project and keeps its own debug session.
    private var debugSessions: [String: ClairDebugSession] = [:]
    var debugSession: ClairDebugSession? { activeRoot.flatMap { debugSessions[$0] } }
    private func debugger() -> ClairDebugSession? {
      guard let project = state.projects.first(where: { $0.name == state.project }) else { return nil }
      if let existing = debugSessions[project.path] { return existing }
      let session = ClairDebugSession(project: project)
      debugSessions[project.path] = session
      return session
    }

    /// V09: update flow state (Stable only; Dev has no feed).
    public enum UpdateStatus: Equatable { case idle, checking, available(ClairUpdate), installing, failed(String) }
    public var update: UpdateStatus = .idle
    public let updateConfig = ClairUpdateConfiguration.live()
    private var updateTask: Task<Void, Never>?
    private var sleepAssertion: IOPMAssertionID = 0
    private var persistenceTask: Task<Void, Never>?

    /// Map manually started CLI processes back to the terminal panes Clair already owns.
    func refreshDetectedAgents() async {
      var candidates: [String: (project: String, pane: Int, cwd: String)] = [:]
      for project in state.projects {
        let tree = project.name == state.project ? state.tree : state.layouts[project.name]?.tree
        let launches = project.name == state.project ? state.launches : state.layouts[project.name]?.launches
        guard let tree else { continue }
        for leaf in tree.leaves where leaf.kind == .terminal && launches?[leaf.id] == nil {
          candidates[Self.terminalKey(root: project.path, pane: leaf.id)] = (project.name, leaf.id, project.path)
        }
      }
      let keys = Array(candidates.keys)
      let found = await Task.detached(priority: .utility) {
        ClairCLIProcessScanner.profiles(keys: keys)
      }.value
      guard !Task.isCancelled else { return }
      var detected: [String: [Int: AgentLaunch]] = [:]
      for (key, profile) in found {
        guard let candidate = candidates[key] else { continue }
        detected[candidate.project, default: [:]][candidate.pane] = AgentLaunch(profile: profile, cwd: candidate.cwd)
      }
      if state.detectedLaunches != detected {
        state.detectedLaunches = detected
        refreshSleepAssertion()
      }
    }

    /// V02: serves this store to `clair` CLI. Only the first window's store wins the socket.
    // ponytail: multi-window shares one socket owner; route by window when V04 adds per-Project windows.
    private var ipc: WorkbenchIPCServer?

    /// V04: workspace file (Projects + per-Project layout). nil disables persistence.
    // ponytail: single shared path; Stable/Dev data separation lands with V09.
    private let persistURL: URL?
    private let scanFiles: @Sendable (String) -> [WorkbenchFile]

    public convenience init(persistAt url: URL? = ClairWorkbenchStore.defaultPersistURL) {
      self.init(persistAt: url, scanFiles: WorkbenchFiles.scan)
    }

    /// Injectable so the checkout/watcher race can be tested without slowing production scans.
    init(
      persistAt url: URL?,
      scanFiles: @escaping @Sendable (String) -> [WorkbenchFile]
    ) {
      persistURL = url
      self.scanFiles = scanFiles
      if let url, let restored = WorkbenchState.restore(from: url, scanFiles: false) { state = restored }
      if state.projects.isEmpty {
        let root = Self.seedRoot
        state.openProject(WorkbenchProject(name: URL(fileURLWithPath: root).lastPathComponent, path: root), scanFiles: false)
      }
      let store = self
      let server = WorkbenchIPCServer { req in
        if req.via == .mcp {
          return MCPGate.handle(
            req, registry: CommandRegistry.workbench,
            snapshot: { DispatchQueue.main.sync { MainActor.assumeIsolated { store.state } } },
            approve: { store.requestMCPApproval($0, $1, $2) },
            run: { recheck, confirmed in
              DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                  if let e = recheck(store.state) { return .failure(e) }
                  return store.run(req.command, req.input, confirmed: confirmed)
                }
              }
            })
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { store.run(req.command, req.input) } }
      }
      Task.detached(priority: .utility) { [weak self] in
        let started = (try? server.start()) != nil
        await MainActor.run {
          guard started, let self else { if started { server.stop() }; return }
          self.ipc = server
        }
      }
      let config = updateConfig
      Task.detached(priority: .utility) { _ = ClairUpdater.markStartupSuccess(config) }
      startAutomaticUpdateChecks()
      watchProject(refresh: true)
    }

    isolated deinit { ipc?.stop(); updateTask?.cancel(); persistenceTask?.cancel(); releaseSleepAssertion() }

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
      do { update = .available(try await ClairUpdater.check(updateConfig)) } catch {
        if case ClairUpdateError.notNewer = error { update = .idle } else { update = manual ? .failed("\(error)") : .idle }
      }
    }

    /// The user pressed 適用: download, verify, stage, then quit so the helper can swap and relaunch.
    public func installUpdate() async {
      guard case .available(let u) = update else { return }
      update = .installing
      do {
        try await ClairUpdater.install(u, updateConfig)
        // The relaunched app must restore these pane ids to find its shells again: flush now, not in 100 ms.
        persistenceTask?.cancel()
        if let persistURL { try? state.save(to: persistURL) }
        ClairDaemonLauncher.keepsSessionsOnQuit = true
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
      ClairChannel.current.migrateLegacyWorkspace()
      return ProcessInfo.processInfo.environment["CLAIR_WORKSPACE_FILE"].map { URL(fileURLWithPath: $0) }
        ?? ClairChannel.current.dataURL.appending(path: "workspace.json")
    }

    /// First launch: `CLAIR_PROJECT_ROOT`, else the launch directory, else home.
    private static var seedRoot: String {
      let cwd = FileManager.default.currentDirectoryPath
      return ProcessInfo.processInfo.environment["CLAIR_PROJECT_ROOT"] ?? (cwd == "/" ? NSHomeDirectory() : cwd)
    }

    @discardableResult
    public func run(_ id: String, _ input: CommandInput = [:], confirmed: Bool = false) -> Result<CommandResult, CommandError> {
      if id.hasPrefix("debug.") {
        state.debugPhase = switch debugSession?.phase {
        case .idle, nil: "idle"
        case .starting: "starting"
        case .configuring: "configuring"
        case .running: "running"
        case .stopped: "stopped"
        case .ended: "ended"
        case .failed: "failed"
        }
      }
      // `file.save` from any caller (⌘S, CLI, MCP) writes the buffer first; a failed write keeps the dirty marker.
      if id == "file.save", let p = state.active, let root = activeRoot, buffers.isOpen(p) {
        do {
          try buffers.save(p, root: root)
        } catch {
          let e = CommandError(.preconditionFailed, "保存できません: \(error.localizedDescription)")
          lastError = e; return .failure(e)
        }
      }
      let closing = id == "pane.close" ? Self.terminalKey(root: activeRoot ?? state.project, pane: state.tree.focused) : nil
      let r: Result<CommandResult, CommandError>
      if id == "project.open", input.count == 1, case .string(let raw)? = input["path"],
        let path = WorkbenchProject.normalized(raw)
      {
        state.openProject(
          WorkbenchProject(name: URL(fileURLWithPath: path).lastPathComponent, path: path),
          scanFiles: false)
        r = .success(.ok)
      } else {
        r = registry.execute(id, input, confirmed: confirmed, state: &state)
      }
      switch r {
      case .failure(let e) where e.code == .confirmationRequired: pending = (id, input)
      // ponytail: kept for inspection only; no canvas error surface yet (U05/U07).
      case .failure(let e): lastError = e
      case .success:
        lastError = nil
        if id == "pane.focus", case .int(let pane)? = input["id"] {
          state.notices.markRead(project: state.project, pane: pane)
        }
        if id == "file.open", case .int(let line)? = input["line"], let p = state.active {
          let column: Int = if case .int(let c)? = input["column"] { c } else { 0 }
          buffers.reveal(p, line: line, column: column)
        }
        if id == "editor.definition" || id == "editor.references" { navigate(references: id == "editor.references") }
        if id.hasPrefix("debug.") { runDebugCommand(id, input) }
        if let view = state.active.flatMap(buffers.view) {
          switch id {
          case "editor.fold": view.foldAtCaret()
          case "editor.unfold": view.unfoldAtCaret()
          case "editor.foldAll": view.foldAll()
          case "editor.unfoldAll": view.unfoldAll()
          default: break
          }
        }
        if let closing { ClairDaemonLauncher.closeSession(key: closing) }  // T09: closing a pane ends its shell; closing a window does not
        if id == "agent.launch" || id == "pane.close"
          || (id == "settings.set" && input["key"] == .string("preventSleepOnBattery"))
        { refreshSleepAssertion() }
        watchProject()
        persistState()
      }
      return r
    }

    private func runDebugCommand(_ id: String, _ input: CommandInput) {
      guard let session = debugger() else { return }
      switch id {
      case "debug.launch":
        guard case .string(let program)? = input["program"] else { return }
        let mode: String = if case .string(let value)? = input["mode"] { value } else { "debug" }
        Task { await session.start(.launch(program: program, mode: mode)) }
      case "debug.attach":
        guard case .int(let pid)? = input["pid"] else { return }
        Task { await session.start(.attach(pid: pid)) }
      case "debug.breakpoint":
        guard case .string(let path)? = input["path"], case .int(let line)? = input["line"] else { return }
        session.toggleBreakpoint(path: URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path, line: line)
      case "debug.selectThread":
        if case .int(let id)? = input["id"] { session.selectThread(id) }
      case "debug.selectFrame":
        if case .int(let id)? = input["id"] { session.selectFrame(id) }
      case "debug.expandVariable":
        if case .string(let id)? = input["id"], let variable = session.variables.first(where: { $0.id == id }) { session.expandVariable(variable) }
      case "debug.continue", "debug.pause", "debug.stepOver", "debug.stepInto", "debug.stepOut":
        let request = ["debug.stepOver": "next", "debug.stepInto": "stepIn", "debug.stepOut": "stepOut"][id] ?? String(id.dropFirst(6))
        Task { await session.control(request) }
      case "debug.restart": Task { await session.restart() }
      case "debug.stop": Task { await session.stop() }
      default: break
      }
    }

    // MARK: - E12 language-server navigation

    /// Rows of the symbols / references palette (filled from the language server, not the registry).
    private(set) var languageItems: [PaletteItem] = []
    /// A one-line result of the last navigation ("定義が見つかりません" …), shown in the status bar.
    private(set) var languageNotice: String?

    private func item(_ l: LanguageServerLocation, root: String) -> PaletteItem {
      let shown = l.path.hasPrefix(root + "/") ? String(l.path.dropFirst(root.count + 1)) : l.path
      return PaletteItem(
        title: l.title, hint: "\(shown):\(l.line + 1)", id: "file.open",
        input: ["path": .string(l.path), "line": .int(l.line + 1), "column": .int(l.character)])
    }

    /// Definition jumps straight to the (first) target; references open as a palette list.
    private func navigate(references: Bool) {
      guard let rel = state.active, let root = activeRoot, case .ready(let m)? = buffers.peek(rel),
        let caret = m.selection.selections.last?.head
      else { return }
      let path = root + "/" + rel
      guard EditorLanguageID.detect(path: rel)?.languageServer != nil else {
        languageNotice = "このファイルの言語サーバーはありません"
        return
      }
      languageNotice = nil
      Task {
        let found =
          references
          ? await buffers.language.references(path, root: root, at: caret)
          : await buffers.language.definition(path, root: root, at: caret)
        guard activeRoot == root, state.active == rel else { return }
        guard let found, !found.isEmpty else {
          languageNotice =
            found == nil
            ? "言語サーバーが応答しません" : (references ? "参照が見つかりません" : "定義が見つかりません")
          return
        }
        if references {
          languageItems = found.map { item($0, root: root) }
          run("palette.references")
        } else {
          let target = found[0]
          run("file.open", ["path": .string(target.path), "line": .int(target.line + 1), "column": .int(target.character)])
        }
      }
    }

    /// `workspace/symbol` for the ⌘T palette, across the active Project's running servers.
    func searchSymbols(_ query: String) async {
      guard let root = activeRoot else { languageItems = []; return }
      let found = await buffers.language.symbols(root: root, matching: query)
      // `.task(id: query)` cancels the previous search; servers may answer out of order, so an older
      // query's late reply must not replace the newer one.
      guard !Task.isCancelled, activeRoot == root, state.palette == .symbols else { return }
      languageItems = found.prefix(200).map { item($0, root: root) }
    }

    /// Menu/palette entry point. Saving may materialise and write a 10 MiB snapshot, so the native
    /// UI acknowledges the shortcut immediately and completes the durable write off-main.
    public func performFromUI(_ id: String, _ input: CommandInput = [:]) {
      if id == "pane.close", state.panesClosed { _ = run("pane.open", ["kind": .string("editor")]); return }
      if id == "pane.close", state.tree.leaves.first(where: { $0.id == state.tree.focused })?.kind == .editor {
        if state.active != nil { _ = run("tab.close") }
        return
      }
      guard id == "file.save" else { _ = run(id, input); return }
      Task { await saveActiveFile() }
    }

    /// Runs Git commands through the same typed registry as CLI/MCP without blocking SwiftUI.
    /// A click on an explicitly labelled Pull/Push control is the native confirmation for its
    /// external risk; non-UI callers still have to pass the registry confirmation gate.
    func performGitFromUI(_ commands: [(String, CommandInput)], confirmed: Bool = false) async -> String? {
      guard let root = activeRoot else { return "Git Project ではありません。" }
      let project = state.project
      let snapshot = state
      let registry = registry
      let changesWorkingTree = commands.contains { $0.0 == "git.switch" || $0.0 == "git.pull" }
      if changesWorkingTree { beginGitFilesystemMutation(root: root) }
      let result = await Task.detached(priority: .userInitiated) {
        var detached = snapshot
        for (id, input) in commands {
          switch registry.execute(id, input, confirmed: confirmed, state: &detached) {
          case .failure(let error): return (error.message as String?, detached)
          case .success(.text(let message)): return (message as String?, detached)
          case .success: continue
          }
        }
        return (nil as String?, detached)
      }.value
      if changesWorkingTree { endGitFilesystemMutation(root: root) }
      guard state.project == project, activeRoot == root else { return result.0 }
      if changesWorkingTree {
        buffers.dropAll(except: state.dirty)
      }
      if result.0 == nil {
        state.files = result.1.files
        if let updated = result.1.projects.first(where: { $0.name == project }),
          let index = state.projects.firstIndex(where: { $0.name == project })
        {
          state.projects[index].branch = updated.branch
        }
        if changesWorkingTree {
          let existing = Set(state.files.map(\.path))
          let currentTabs = state.tabs
          let dirty = state.dirty
          state.tabs = currentTabs.filter { existing.contains($0) || dirty.contains($0) }
          if state.active.map(state.tabs.contains) != true { state.active = state.tabs.last }
        }
        persistState()
      }
      return result.0
    }

    private func saveActiveFile() async {
      guard let path = state.active, let root = activeRoot,
        case .ready(let manager)? = buffers.peek(path)
      else { _ = run("file.save"); return }
      let project = state.project
      let snapshot = manager.buffer.snapshot
      let result = await Task.detached(priority: .userInitiated) {
        Result<Void, Error> {
          try snapshot.string().write(toFile: root + "/" + path, atomically: true, encoding: .utf8)
        }
      }.value
      switch result {
      case .success:
        // An edit made while the snapshot was being written is still unsaved.
        if manager.buffer.snapshot.revision == snapshot.revision {
          if state.project == project { state.dirty.remove(path) }
          else { state.layouts[project]?.dirty.remove(path) }
        }
        lastError = nil; persistState()
      case .failure(let error):
        lastError = CommandError(.preconditionFailed, "保存できません: \(error.localizedDescription)")
      }
    }

    /// Names the daemon shell behind one terminal pane. Keyed on the project path, not its name, so two
    /// projects with the same folder name never share a shell.
    static func terminalKey(root: String, pane: Int) -> String { "\(root)#\(pane)" }

    var activeRoot: String? { state.projects.first { $0.name == state.project }?.path }

    /// U05: called by the editor surface on every committed edit.
    func edited(_ path: String) { state.dirty.insert(path) }  // the GUI owns dirty; never persisted (principle 8)

    /// Workspace commands must never synchronously encode and replace the persistence file on the
    /// main actor. Coalescing also keeps resize/focus bursts from queueing obsolete snapshots.
    private func persistState() {
      guard let persistURL else { return }
      let snapshot = state
      persistenceTask?.cancel()
      persistenceTask = Task.detached(priority: .utility) {
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled else { return }
        try? snapshot.save(to: persistURL)
      }
    }

    /// V05: agent/external disk changes refresh the tree and drop unsaved markers (principle 8).
    private var watcher: FileWatcher?
    private var watched = ""
    private var scanGeneration = 0
    private var gitFilesystemMutationRoot: String?
    private var gitFilesystemMutationGeneration = 0

    private func beginGitFilesystemMutation(root: String) {
      gitFilesystemMutationGeneration += 1
      gitFilesystemMutationRoot = root
    }

    private func endGitFilesystemMutation(root: String) {
      let generation = gitFilesystemMutationGeneration
      Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(500))
        guard let self, generation == self.gitFilesystemMutationGeneration,
          self.gitFilesystemMutationRoot == root
        else { return }
        self.gitFilesystemMutationRoot = nil
        guard let pending = self.pendingScan, pending.root == root else { return }
        self.pendingScan = nil
        self.diskChanged(
          pending.paths, root: pending.root, generation: pending.generation,
          preserveDirty: true)
      }
    }

    private func watchProject(refresh: Bool = false) {
      guard watched != state.project else { return }
      let first = watched.isEmpty
      watched = state.project
      scanGeneration += 1
      let generation = scanGeneration
      guard let root = state.projects.first(where: { $0.name == state.project })?.path else { watcher = nil; return }
      watcher = FileWatcher(root: root) { [weak self] paths in
        // Scan (directory walk + `git status`) off the main thread; only the state swap runs on it.
        // One scan at a time: events arriving meanwhile are merged and rescanned once.
        DispatchQueue.main.async { self?.diskChanged(paths, root: root, generation: generation) }
      }
      if refresh || !first { diskChanged([], root: root, generation: generation) }
    }

    func refreshProjectFiles() {
      guard let root = activeRoot else { return }
      diskChanged([], root: root, generation: scanGeneration)
    }

    private(set) var scanning = false
    private var pendingScan: (
      paths: Set<String>, root: String, generation: Int, preserveDirty: Bool
    )?

    private func diskChanged(
      _ paths: Set<String>, root: String, generation: Int, preserveDirty: Bool = false
    ) {
      guard generation == scanGeneration, root == activeRoot else { return }
      if gitFilesystemMutationRoot == root {
        if var pending = pendingScan, pending.generation == generation {
          pending.paths.formUnion(paths)
          pending.preserveDirty = pending.preserveDirty || preserveDirty
          pendingScan = pending
        } else { pendingScan = (paths, root, generation, preserveDirty) }
        return
      }
      guard !scanning else {
        if var pending = pendingScan, pending.generation == generation {
          pending.paths.formUnion(paths)
          pending.preserveDirty = pending.preserveDirty || preserveDirty
          pendingScan = pending
        } else { pendingScan = (paths, root, generation, preserveDirty) }
        return
      }
      scanning = true
      DispatchQueue.global(qos: .utility).async { [weak self] in
        let files = self?.scanFiles(root) ?? []
        DispatchQueue.main.async {
          guard let self else { return }
          self.scanning = false
          if generation == self.scanGeneration, root == self.activeRoot,
            self.gitFilesystemMutationRoot != root
          {
            let changed = preserveDirty ? paths.subtracting(self.state.dirty) : paths
            self.state.applyDiskChange(changed, files: files)
            self.buffers.drop(changed)
          } else if generation == self.scanGeneration, self.gitFilesystemMutationRoot == root {
            if var pending = self.pendingScan, pending.generation == generation {
              pending.paths.formUnion(paths)
              pending.preserveDirty = pending.preserveDirty || preserveDirty
              self.pendingScan = pending
            } else { self.pendingScan = (paths, root, generation, preserveDirty) }
          }
          if let pending = self.pendingScan {
            self.pendingScan = nil
            self.diskChanged(
              pending.paths, root: pending.root, generation: pending.generation,
              preserveDirty: pending.preserveDirty)
          }
        }
      }
    }

    /// Only facts from an agent running in a Clair terminal can produce a macOS notification.
    public func facts(pane: Int, bells: Int, exit: Int?) {
      guard let agent = state.agentLaunch(in: state.project, pane: pane) else { return }
      // Only this GUI writes facts (no command records them), so an agent cannot fabricate notifications.
      var fresh: WorkbenchNotice?
      if bells > 0 { fresh = state.notices.record(project: state.project, pane: pane, kind: .bell) ?? fresh }
      if let exit { fresh = state.notices.record(project: state.project, pane: pane, kind: .exited, exitCode: exit) ?? fresh }
      refreshSleepAssertion()
      guard let n = fresh, !NSApp.isActive,
        Bundle.main.bundleURL.pathExtension == "app",
        Bundle.main.bundleIdentifier != nil  // UNUserNotificationCenter traps outside an app bundle (swift run / XCTest)
      else { return }
      let body = [AgentProfile.named(agent.profile)?.title ?? agent.profile, n.title].joined(separator: ": ")
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

  private struct StoreKey: FocusedValueKey { typealias Value = ClairWorkbenchStore }
  extension FocusedValues {
    var clairWorkbench: ClairWorkbenchStore? {
      get { self[StoreKey.self] }
      set { self[StoreKey.self] = newValue }
    }
  }

  /// Menu bar projection of the registry; default shortcuts live here, so the
  /// hidden-button shortcut layer is gone.
  public struct ClairCommandMenu: Commands {
    @FocusedValue(\.clairWorkbench) private var store
    public init() {}

    public var body: some Commands {
      CommandMenu("Clair") {
        let state = store?.state ?? WorkbenchState()
        ForEach(CommandRegistry.workbench.commands.filter { state.shortcut(for: $0) != nil }, id: \.id) { d in
          Button(d.id == "pane.close" ? "タブまたはペインを閉じる" : d.title) { store?.performFromUI(d.id) }
            .keyboardShortcut(Self.shortcut(state.shortcut(for: d)!))
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
      let arrows: [Character: KeyEquivalent] = ["→": .rightArrow, "←": .leftArrow, "↑": .upArrow, "↓": .downArrow]
      return KeyboardShortcut(arrows[k] ?? KeyEquivalent(Character(k.lowercased())), modifiers: m)
    }
  }

  /// U04: AppShell chrome (checklist §3) — titlebar 48 + sidebar 286 + main +
  /// status 26. Built once; only sidebar panel and main are swapped. Pane
  /// contents other than the terminal are placeholders owned by U05/U06.
  public struct ClairAppShell: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var store: ClairWorkbenchStore
    @State private var draggingPane: Int?
    private var st: WorkbenchState { store.state }
    @State private var query = ""
    @State private var selection = 0
    // U05: sidebar mode + source-control view. GUI-local (no command); the stage buttons go through git.stage/unstage.
    @State private var sidebarMode = "folder"
    @State private var debugMode = "debug"
    @State private var debugPID = ""
    @State private var quota: [ProviderQuota] = []
    @State private var quotaHovered = false
    @State private var noticesOpen = false
    @State private var collapsedGroups: Set<String> = []
    @State private var rootFolded = false
    @State private var changes: [GitChange] = []
    @State private var branch: String?
    @State private var branches: [String] = []
    @State private var sync: (behind: Int, ahead: Int)?
    @State private var changesTask: Task<Void, Never>?
    @State private var gitOperation: String?
    @State private var gitMessage: String?
    @State private var gitFailed = false
    @State private var diff: DiffTarget?
    @State private var loadedDiff: LoadedDiff?
    @State private var diffTask: Task<Void, Never>?
    @State private var explorerRows: [ExplorerRow] = []
    @State private var visibleExplorerRows: [ExplorerRow] = []
    @State private var explorerTask: Task<Void, Never>?
    @State private var explorerVisibilityTask: Task<Void, Never>?
    // V05: search panel state (GUI-local).
    @State private var searchQuery = ""
    @State private var replaceText = ""
    @State private var searchRegex = false
    @State private var searchCase = false
    @State private var hits: [SearchHit] = []
    @State private var searchMessage = ""
    @State private var searching = false
    @State private var replacing = false
    @State private var searchSelection = 0
    @State private var searchGeneration = 0
    @State private var searchTask: Task<Void, Never>?
    @State private var replaceTask: Task<Void, Never>?
    private let projectColors = [C.debugBlue, C.success, C.attention]

    public init() { _store = State(initialValue: ClairWorkbenchStore()) }
    /// Snapshot tests inject a fixture store.
    init(store: ClairWorkbenchStore) { _store = State(initialValue: store) }

    public var body: some View {
      VStack(spacing: 0) {
        if st.settingsOpen {
          settingsHeader
          HStack(spacing: 0) {
            settingsPanel
            Rectangle().fill(L.hairline).frame(width: 1)
            settingsMain
          }
        } else {
          titlebar
          HStack(spacing: 0) {
            activityBar
            sidebar
            Rectangle().fill(C.surfaceActive).frame(width: 1)
            main
          }
        }
        statusBar
      }
      .background(C.canvas)
      .frame(minWidth: 900, minHeight: 560)
      .overlay {
        if st.palette == .search { searchOverlay }
        else if let p = st.palette { paletteView(p) }
      }
      .animation(.easeOut(duration: 0.09), value: st.palette == nil)
      .onChange(of: st.palette) {
        query = ""; selection = 0
        if st.palette == .search { searchSelection = 0; runSearch() }
      }
      .onChange(of: st.debugNavigationGeneration) { sidebarMode = "ladybug" }
      .onChange(of: store.debugSession?.frames.first) { _, frame in
        if sidebarMode == "ladybug", let frame { openDebugFrame(frame) }
      }
      .onChange(of: st.project) {
        diff = nil; loadedDiff = nil; gitMessage = nil; gitFailed = false
        if !st.isRepo && sidebarMode == "shield" { sidebarMode = "folder" }
        rebuildExplorer(); reloadChanges()
      }
      .onChange(of: st.files) { rebuildExplorer(); reloadChanges() }
      .onChange(of: st.collapsed) { rebuildVisibleExplorer() }
      .onChange(of: diff) { loadDiff() }
      .onAppear { rebuildExplorer(); reloadChanges() }
      .task {
        while !Task.isCancelled {
          await store.refreshDetectedAgents()
          try? await Task.sleep(for: .seconds(2))
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ClairCloseFocusedPaneShortcut"))) { _ in
        store.performFromUI("pane.close")
      }
      .focusedSceneValue(\.clairWorkbench, store)
      .confirmationDialog(
        store.pending?.id == "debug.restart" ? "デバッグを再起動しますか？" : "未保存の変更を破棄しますか？", isPresented: Binding(get: { store.pending != nil }, set: { if !$0 { store.pending = nil } })
      ) {
        if store.pending?.id == "debug.restart" { Button("再起動") { store.confirm() } }
        else { Button("破棄して続行", role: .destructive) { store.confirm() } }
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
        Color.clear.frame(width: 76 + 25)  // room for the native traffic lights (inset 5pt by AppDelegate)
        // The scroll view swallows clicks on its empty tail, so the strip itself spans the viewport and carries the titlebar area.
        GeometryReader { g in
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
              ForEach(Array(st.projects.enumerated()), id: \.element.name) { i, p in
                if i > 0 { Rectangle().fill(Color(white: 0.95, opacity: 0.09)).frame(width: 1, height: 22).padding(.horizontal, 4) }
                projectGroup(p, color: projectColors[i % projectColors.count])
              }
              Button(action: openFolder) { Image(systemName: "plus").font(.system(size: 13)).foregroundStyle(C.chromeInk).frame(width: 30, height: 30) }
                .buttonStyle(.hoverWash).help("フォルダを開く")
            }
            .frame(minWidth: g.size.width, minHeight: g.size.height, alignment: .leading)
            .background(TitlebarArea())
          }
        }
        HStack(spacing: 4) {
          Button { store.run("palette.search") } label: {
            HStack(spacing: 4) {
              Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(C.textQuaternary)
              Text("ファイル、シンボル").font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
              Spacer(minLength: 0)
              Text("⌘⇧F").font(Typography.font(Typography.chrome)).foregroundStyle(C.textQuaternary)
            }
            .padding(.horizontal, 8).frame(width: 200, height: 28)
            .background(C.chrome, in: RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(L.hairlineFaint))
          }.buttonStyle(.hoverWash).help("検索")
          titlebarAction("command", "コマンドパレット", on: st.palette == .commands) { store.run("palette.commands") }
          titlebarAction("gearshape", "設定", on: st.settingsOpen) { store.run(st.settingsOpen ? "settings.close" : "settings.open") }
        }.padding(.horizontal, 12)
      }
      .frame(height: ChromeBudget.titlebar)
      .background(TitlebarArea())
      .background(C.chrome)
      .overlay(alignment: .bottom) { Rectangle().fill(C.surfaceActive).frame(height: 1) }
    }

    private func titlebarAction(_ icon: String, _ help: String, on: Bool, _ action: @escaping () -> Void) -> some View {
      Button(action: action) {
        Image(systemName: icon).font(.system(size: 13)).foregroundStyle(on ? C.chromeInk : C.chromeInkMuted)
          .frame(width: 30, height: 30).background(on ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.card))
      }.buttonStyle(.hoverWash).help(help)
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
          // The chip carries its group colour as its own fill/border (mock
          // review feedback: a small dot beside the label read as an
          // afterthought), not a separate dot — active groups get the
          // stronger alpha pair, matching the titlebar's active tab group.
          Text(p.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(active ? C.textPrimary : C.textSecondary).lineLimit(1)
            .padding(.horizontal, 10).frame(height: 26)
            .background(color.opacity(active ? 0.22 : 0.1), in: RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(color.opacity(active ? 0.55 : 0.28)))
          .overlay(alignment: .topTrailing) {
            if st.notices.unread(p.name) > 0 {
              Text("\(st.notices.unread(p.name))").font(.system(size: 9, weight: .bold)).foregroundStyle(C.textPrimary)
                .padding(.horizontal, 4).background(color, in: Capsule()).offset(x: 2, y: -4)
            }
          }
        }
        .buttonStyle(.hoverWash).help("\(p.name) タブグループを\(folded ? "展開" : "折りたたむ")")
        .background(NoWindowDrag())
        .contextMenu {
          let muted = st.notices.mutedProjects.contains(p.name)
          Button(muted ? "通知のミュートを解除" : "通知をミュート") {
            store.run("notice.muteProject", ["name": .string(p.name), "muted": .bool(!muted)])
          }
        }
        if !folded {
          HStack(spacing: 4) {
            ForEach(Array(tabs.enumerated()), id: \.element) { i, path in
              if i > 0 { Rectangle().fill(L.chromeSoft).frame(width: 1, height: 18) }
              fileTab(path, projectActive: active, project: p.name, selected: path == current && active, dirty: dirty.contains(path))
            }
          }.padding(.leading, 4)
        }
      }
    }

    private func fileTab(_ path: String, projectActive: Bool, project: String, selected: Bool, dirty: Bool) -> some View {
      FileTabButton(
        path: path, name: name(path), selected: selected, dirty: dirty,
        onActivate: {
          if !projectActive { store.run("project.switch", ["name": .string(project)]) }
          store.run("tab.activate", ["path": .string(path)])
        },
        onClose: { store.run("tab.close", ["path": .string(path)]) }
      )
      .contextMenu { if projectActive { fileMenu(path, tab: true) } }
      // Reorder within the active group only; other groups' tabs live in saved layouts.
      .onDrag { NSItemProvider(object: NSString(string: path)) }
      .onDrop(of: [.text], isTargeted: nil) { providers in
        guard projectActive, let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
          guard let from = (object as? NSString).map({ $0 as String }) else { return }
          Task { @MainActor in store.run("tab.move", ["path": .string(from), "target": .string(path)]) }
        }
        return true
      }
    }

    private func openFolder() {
      let panel = NSOpenPanel()
      panel.canChooseFiles = false; panel.canChooseDirectories = true
      if panel.runModal() == .OK, let url = panel.url { store.run("project.open", ["path": .string(url.path)]) }
    }

    // MARK: activity bar + sidebar

    /// Left vertical nav strip, full-height, outside the sidebar panel.
    /// Was a horizontal row nested at the top of `sidebar` (see checklist
    /// §2.4, 2026-09-20 amendment): hover and selected now share one
    /// `washSelected` tint instead of the old `surfaceHover`/`surfaceActive`
    /// pair, and icons are bigger now that they own a whole column.
    private var activityBar: some View {
      VStack(spacing: 2) {
        ForEach(["folder", "shield", "terminal", "ladybug"], id: \.self) { icon in
          activityBarButton(icon)
        }
        Spacer(minLength: 0)
        Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(C.chromeInkMuted).frame(width: 36, height: 32)
      }
      .padding(.vertical, 8)
      .frame(width: ChromeBudget.activityBarWidth).frame(maxHeight: .infinity)
      .background(C.chrome)
      .overlay(alignment: .trailing) { Rectangle().fill(C.surfaceActive).frame(width: 1) }
    }

    private func activityBarButton(_ icon: String) -> some View {
      let ready = icon != "shield" || st.isRepo
      return ActivityBarButton(icon: icon, on: sidebarMode == icon && !st.settingsOpen, enabled: ready) {
        sidebarMode = icon
        if icon == "folder" { diff = nil }
        if icon == "shield" { reloadChanges() }
        if icon == "ladybug" { store.run("debug.open") }
      }
    }

    private var sidebar: some View {
      VStack(spacing: 0) {
        // Lazy: a Project can list thousands of files, and an eager tree makes accessibility traversal (and layout) block the main thread.
        ScrollView { LazyVStack(alignment: .leading, spacing: 0) { sidebarMode == "shield" ? AnyView(changesList) : sidebarMode == "terminal" ? AnyView(sessionList) : sidebarMode == "ladybug" ? AnyView(debugPanel) : AnyView(explorer) }.clairScroller() }
        Spacer(minLength: 0)
      }
      .frame(width: 242)
      .background(C.chrome)
    }

    /// Settings takes over the whole window — its own header (with the one
    /// way back: a close ✕, top-right) in place of the normal titlebar, its
    /// own section-nav panel in place of the sidebar, no activity bar. It
    /// used to be a plain panel/main swap that left the titlebar's project
    /// tabs and the activity bar's other destinations clickable underneath
    /// (mock review feedback: settings had no single way out). `statusBar`
    /// already renders its settings-specific line and needs no change.
    private var settingsHeader: some View {
      HStack(spacing: 0) {
        Color.clear.frame(width: 76 + 25)  // room for the native traffic lights (inset 5pt by AppDelegate)
        Text("設定").font(.system(size: 13, weight: .semibold)).foregroundStyle(C.textPrimary)
        Spacer(minLength: 0)
        Button { store.run("settings.close") } label: {
          Image(systemName: "xmark").font(.system(size: 13, weight: .medium)).foregroundStyle(C.chromeInkMuted)
            .frame(width: 26, height: 26)
        }.buttonStyle(.hoverWash).padding(.trailing, 16).help("設定を閉じる")
      }
      .frame(height: ChromeBudget.titlebar)
      .background(TitlebarArea())
      .background(C.chrome)
      .overlay(alignment: .bottom) { Rectangle().fill(L.hairline).frame(height: 1) }
    }

    private var settingsPanel: some View {
      VStack(alignment: .leading, spacing: 12) {
        Text("設定を検索").font(.system(size: 11)).foregroundStyle(C.textQuaternary)
          .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
          .background(C.chrome, in: RoundedRectangle(cornerRadius: Radius.control))
          .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(L.hairline))
        Text("ワークスペース").font(.system(size: 11, weight: .semibold)).foregroundStyle(C.textTertiary).padding(.horizontal, 8)
        VStack(alignment: .leading, spacing: 0) {
          ForEach(["一般", "AIプロバイダー", "使用状況", "エディタ", "ターミナル", "モバイル", "アップデート"], id: \.self) { section in
            let selected = st.section == section
            Button { store.run("settings.open", ["section": .string(section)]) } label: {
              Text(section)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? C.textPrimary : C.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .padding(.horizontal, 8)
                .background(selected ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
            }
            .buttonStyle(.hoverWash)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8).padding(.vertical, 16)
      .frame(width: 220)
      .background(C.chrome)
      .overlay(alignment: .trailing) { Rectangle().fill(L.chrome).frame(width: 1) }
    }

    private var searchPattern: SearchPattern {
      searchRegex ? .regex(searchQuery, caseSensitive: searchCase) : .literal(searchQuery, caseSensitive: searchCase)
    }

    /// Runs off the main thread; a newer query cancels the running one and its result is dropped.
    private func runSearch() {
      searchTask?.cancel()
      searchGeneration += 1
      let generation = searchGeneration
      guard !replacing, let root = store.activeRoot, !searchQuery.isEmpty else {
        if !replacing { hits = []; searchMessage = ""; searching = false }
        return
      }
      let (files, pattern) = (st.files, searchPattern)
      searching = true; searchMessage = "検索中…"
      searchTask = Task {
        // ponytail: 250 ms debounce for typing; the cancel above is what keeps stale results out.
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        let worker = Task.detached(priority: .userInitiated) { Result { try ProjectSearch.find(root: root, files: files, pattern) } }
        let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled, generation == searchGeneration else { return }
        searching = false
        switch result {
        case .success(let found):
          hits = found
          searchSelection = min(searchSelection, max(found.count - 1, 0))
          searchMessage = found.isEmpty ? "一致なし" : "\(found.count) 件 / \(Set(found.map(\.path)).count) ファイル"
        case .failure(let error) where error is CancellationError:
          break
        case .failure(let error):
          hits = []
          searchMessage = error is SearchError ? "正規表現が不正です" : "検索できません: \(error)"
        }
      }
    }

    private func runReplace() {
      guard !replacing, let root = store.activeRoot, !hits.isEmpty else { return }
      let (files, pattern, r) = (st.files, searchPattern, replaceText)
      searchTask?.cancel(); searching = false; replacing = true; searchMessage = "置換中…"
      replaceTask = Task {
        let result = await Task.detached(priority: .userInitiated) { Result { try ProjectSearch.replace(root: root, files: files, pattern, with: r) } }.value
        replacing = false
        switch result {
        case .success(let n): hits = []; searchMessage = "\(n) 件を置換しました"; runSearch()
        case .failure(let error): searchMessage = "置換できません: \(error)"
        }
      }
    }

    private func closeSearch() {
      store.run("palette.close")
      searchTask?.cancel(); searching = false; searchGeneration += 1
    }

    private var searchOverlay: some View {
      ZStack(alignment: .top) {
        Color(red: 8 / 255, green: 10 / 255, blue: 12 / 255).opacity(0.68).onTapGesture(perform: closeSearch)
        SearchPanel(
          query: $searchQuery, replacement: $replaceText, regex: $searchRegex, caseSensitive: $searchCase,
          selection: $searchSelection, hits: hits, message: searchMessage, searching: searching, replacing: replacing,
          search: runSearch, replaceAll: runReplace, close: closeSearch,
          open: {
            closeSearch(); store.run("tab.open", ["path": .string($0.path)])
            store.buffers.reveal($0.path, line: $0.line)
          })
          .frame(width: 620).background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.overlay))
          .overlay(RoundedRectangle(cornerRadius: Radius.overlay).stroke(L.strong))
          .shadow(color: .black.opacity(0.62), radius: 24, y: 18).padding(.top, 44)
          .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
      }
    }

    private var sessionList: some View {
      SessionList(sessions: st.agentSessions, current: st.project) { s in
        if s.project != st.project { store.run("project.switch", ["name": .string(s.project)]) }
        store.run("pane.focus", ["id": .int(s.pane)])
      }
    }

    private var changesList: some View {
      ChangesList(
        changes: changes, selected: diff, onSelect: { diff = $0 },
        onToggle: { change, stage in
          runGit(
            [(stage ? "git.stage" : "git.unstage", ["path": .string(change.path)])],
            label: stage ? "ステージ" : "ステージ解除")
        },
        onBulk: { rows, stage in
          runGit(
            rows.map { (stage ? "git.stage" : "git.unstage", ["path": .string($0.path)]) },
            label: stage ? "一括ステージ" : "一括ステージ解除")
        },
        onCommit: { message in
          runGit([("git.commit", ["message": .string(message)])], label: "コミット")
        },
        busy: gitOperation != nil,
        operationMessage: gitOperation.map { "\($0)中…" } ?? gitMessage)
    }

    private func runGit(
      _ commands: [(String, CommandInput)], label: String, confirmed: Bool = false
    ) {
      guard gitOperation == nil, !commands.isEmpty else { return }
      let root = store.activeRoot
      gitOperation = label; gitMessage = nil; gitFailed = false
      Task {
        let error = await store.performGitFromUI(commands, confirmed: confirmed)
        gitOperation = nil
        guard store.activeRoot == root else { return }
        gitFailed = error != nil
        gitMessage = error ?? "\(label)が完了しました。"
        reloadChanges()
      }
    }

    private func reloadChanges() {
      changesTask?.cancel()
      guard let root = store.activeRoot else {
        changes = []; branch = nil; branches = []; sync = nil; diff = nil
        return
      }
      changesTask = Task {
        try? await Task.sleep(for: .milliseconds(40))
        guard !Task.isCancelled else { return }
        async let loadedChanges = Task.detached(priority: .utility) { WorkbenchGit.changes(root) }.value
        async let loadedBranch = Task.detached(priority: .utility) { WorkbenchGit.currentBranch(root) }.value
        async let loadedBranches = Task.detached(priority: .utility) { WorkbenchGit.branches(root) }.value
        async let loadedSync = Task.detached(priority: .utility) { WorkbenchGit.aheadBehind(root) }.value
        let snapshot = await (loadedChanges, loadedBranch, loadedBranches, loadedSync)
        guard !Task.isCancelled, store.activeRoot == root else { return }
        changes = snapshot.0; branch = snapshot.1; branches = snapshot.2; sync = snapshot.3
        if let d = diff, !changes.contains(where: { $0.path == d.path }) { diff = nil }
        else if diff != nil { loadDiff() }
      }
    }

    private var sections: some View {
      ForEach(["一般", "AIプロバイダー", "使用状況", "エディタ", "ターミナル", "モバイル", "アップデート"], id: \.self) { s in
        row(s, depth: 0, selected: st.section == s) { store.run("settings.open", ["section": .string(s)]) }
      }
    }

    /// Rows outside a collapsed folder. `files` is in tree order, so a folder's descendants follow it contiguously: one pass, no per-row scan of `collapsed`.
    struct ExplorerRow: Identifiable, Sendable, Equatable {
      let id: String
      let label: String
      let depth: Int
      let file: WorkbenchFile?
    }

    nonisolated static func visibleExplorerRows(_ rows: [ExplorerRow], collapsed: Set<String>) -> [ExplorerRow] {
      var hidden: String?
      return rows.filter { r in
        if let h = hidden { if r.id.hasPrefix(h) { return false }; hidden = nil }
        if r.file == nil, collapsed.contains(r.id) { hidden = r.id + "/" }
        return true
      }
    }

    /// Folders derived from the file paths; click toggles, files open a tab.
    private var explorer: some View {
      return LazyVStack(alignment: .leading, spacing: 0) {
        // Only the first scan blanks the tree; a rescan (every watcher event) swaps rows in place.
        if store.scanning && st.files.isEmpty {
          Text("Loading...").font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
            .padding(.horizontal, 16).frame(height: 28)
        } else {
          // Project root: uppercase, branch glyph, no chevron — it reads as a
          // section label, not one more row in the same list as its children.
          // Folds the whole tree (GUI-local); click-to-collapse is unchanged.
          treeRow(depth: 0, selected: false, action: { rootFolded.toggle() }) {
            Text(st.project).font(.system(size: 11, weight: .semibold)).textCase(.uppercase).foregroundStyle(C.textPrimary)
            Spacer(minLength: 0)
          }
          if !rootFolded {
            ForEach(visibleExplorerRows) { r in
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
        }
      }.padding(.vertical, 4)
    }

    private func rebuildExplorer() {
      explorerTask?.cancel()
      let files = st.files, project = st.project
      explorerTask = Task {
        let rows = await Task.detached(priority: .utility) { Self.explorerRows(for: files) }.value
        guard !Task.isCancelled, st.project == project, st.files == files else { return }
        explorerRows = rows
        rebuildVisibleExplorer()
      }
    }

    private func rebuildVisibleExplorer() {
      explorerVisibilityTask?.cancel()
      let rows = explorerRows, collapsed = st.collapsed
      explorerVisibilityTask = Task {
        let visible = await Task.detached(priority: .utility) { Self.visibleExplorerRows(rows, collapsed: collapsed) }.value
        guard !Task.isCancelled, explorerRows == rows, st.collapsed == collapsed else { return }
        visibleExplorerRows = visible
      }
    }

    nonisolated static func explorerRows(for files: [WorkbenchFile]) -> [ExplorerRow] {
      var out: [ExplorerRow] = []
      var seen = Set<String>()
      out.reserveCapacity(files.count * 2)
      for file in files {
        guard !Task.isCancelled else { return [] }
        let parts = file.path.split(separator: "/").map(String.init)
        guard let name = parts.last else { continue }
        if parts.count > 1 {
          for depth in 0..<(parts.count - 1) {
            let id = parts[0...depth].joined(separator: "/")
            if seen.insert(id).inserted { out.append(ExplorerRow(id: id, label: parts[depth], depth: depth + 1, file: nil)) }
          }
        }
        out.append(ExplorerRow(id: file.path, label: name, depth: parts.count, file: file))
      }
      return out
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

    /// Explorer row: an inset, rounded 28px tab with 12px indent per level.
    private func treeRow<Content: View>(depth: Int, selected: Bool, action: @escaping () -> Void, @ViewBuilder _ content: () -> Content) -> some View {
      Button(action: action) {
        HStack(spacing: 4, content: content)
          .padding(.leading, 8 + CGFloat(depth) * 12).padding(.trailing, 8).frame(height: 28)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(selected ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.card))
          .contentShape(Rectangle())
      }.buttonStyle(.hoverWash).padding(.horizontal, 8)
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
            if ClairGhosttySurfaceView.send("@\(path) ", toPane: a.pane) { store.run("pane.focus", ["id": .int(a.pane)]) }
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

    // MARK: V13 Debug (Workbench Debug screen, with VS Code style run configuration)

    private var debugPanel: some View {
      VStack(alignment: .leading, spacing: 0) {
        Text("実行とデバッグ").font(.system(size: 11, weight: .semibold)).foregroundStyle(C.textTertiary)
          .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 8)
        HStack(spacing: 4) {
          Button { startDebugFromUI() } label: {
            Image(systemName: "play.fill")
              .font(.system(size: 11))
              .foregroundStyle(C.debugBlueText)
              .frame(width: 28, height: 28)
              .background(C.debugBlue.opacity(0.16), in: RoundedRectangle(cornerRadius: Radius.control))
          }
          .buttonStyle(.hoverWash).help("デバッグを開始")
          .disabled(debugMode == "attach" ? (Int(debugPID) ?? 0) <= 0 : !(st.active?.hasSuffix(".go") ?? false))
          Menu {
            Button("Go: 現在のファイル") { debugMode = "debug" }
            Button("Go: 現在の package をテスト") { debugMode = "test" }
            Button("プロセスに attach") { debugMode = "attach" }
          } label: {
            HStack(spacing: 6) {
              Text(debugMode == "test" ? "Go: package テスト" : debugMode == "attach" ? "プロセスに attach" : "Go: 現在のファイル")
                .lineLimit(1)
              Spacer(minLength: 0)
              Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11))
            .foregroundStyle(C.textSecondary)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(C.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(L.strong))
          }
          .menuStyle(.borderlessButton)
          .accessibilityLabel("デバッグ構成")
        }.padding(.horizontal, 12)
        if debugMode == "attach" {
          TextField("プロセス ID (PID)", text: $debugPID)
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(C.textPrimary)
            .padding(.horizontal, 8).frame(height: 28)
            .background(C.canvas, in: RoundedRectangle(cornerRadius: Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(L.strong))
            .padding(.horizontal, 12).padding(.top, 6)
        }
        Text(debugSetupMessage)
          .font(.system(size: 11)).foregroundStyle(C.textTertiary)
          .padding(.horizontal, 12).padding(.top, 8).fixedSize(horizontal: false, vertical: true)
        debugSection("ブレークポイント")
        if let session = store.debugSession, !session.breakpoints.isEmpty {
          ForEach(session.breakpoints.keys.sorted(), id: \.self) { path in
            ForEach((session.breakpoints[path] ?? []).sorted(), id: \.self) { line in
              let status = session.breakpointStatus[path]?[line]
              Button { _ = store.run("debug.breakpoint", ["path": .string(path), "line": .int(line)]) } label: {
                Label("\(URL(fileURLWithPath: path).lastPathComponent):\(status?.line ?? line)",
                  systemImage: status?.verified == true ? "circle.fill" : "circle.dotted")
                  .font(.system(size: 11)).foregroundStyle(status?.verified == false ? C.attention : C.textSecondary)
                  .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
              }.buttonStyle(.hoverWash).help(status?.message ?? (status == nil ? "未検証" : "検証済み"))
                .padding(.horizontal, 12)
            }
          }
        } else { debugEmpty("設定されていません") }
        Button { toggleBreakpointAtCaret() } label: { Label("現在の行に追加", systemImage: "plus") }
          .buttonStyle(.hoverWash).font(.system(size: 11)).padding(.horizontal, 12).padding(.top, 6)
          .disabled(st.active == nil)
        debugSection("スレッドとコールスタック")
        if let session = store.debugSession, !session.threads.isEmpty {
          ForEach(session.threads) { thread in
            Button { _ = store.run("debug.selectThread", ["id": .int(thread.id)]) } label: {
              Label(thread.name, systemImage: session.selectedThread == thread.id ? "checkmark.circle.fill" : "circle.grid.2x2")
                .font(.system(size: 11)).foregroundStyle(session.selectedThread == thread.id ? C.textPrimary : C.textTertiary)
            }.buttonStyle(.hoverWash).padding(.horizontal, 12).frame(minHeight: 28)
          }
        }
        if let session = store.debugSession, !session.frames.isEmpty {
          ForEach(session.frames) { frame in
            Button { _ = store.run("debug.selectFrame", ["id": .int(frame.id)]); openDebugFrame(frame) } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(frame.name).foregroundStyle(C.textPrimary).lineLimit(1)
                Text(frame.path.map { "\(URL(fileURLWithPath: $0).lastPathComponent):\(frame.line)" } ?? "場所不明")
                  .foregroundStyle(C.textQuaternary)
              }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.hoverWash).padding(.horizontal, 12).frame(minHeight: 34)
              .background(session.selectedFrame == frame.id ? C.debugBlue.opacity(0.08) : Color.clear)
              .overlay(alignment: .leading) {
                if session.selectedFrame == frame.id { C.debugBlue.frame(width: 2) }
              }
          }
        } else { debugEmpty("停止すると表示されます") }
        debugSection("変数")
        if let session = store.debugSession, !session.variables.isEmpty {
          ForEach(session.variables) { variable in
            Button { _ = store.run("debug.expandVariable", ["id": .string(variable.id)]) } label: {
              HStack(alignment: .top, spacing: 4) {
                Image(systemName: variable.reference > 0 ? "chevron.right" : "")
                  .frame(width: 10)
                VStack(alignment: .leading, spacing: 2) {
                  Text(variable.name).foregroundStyle(C.textPrimary)
                  Text(variable.value).foregroundStyle(C.textQuaternary).lineLimit(2)
                }
                Spacer(minLength: 0)
              }.font(.system(size: 11)).padding(.leading, 12 + CGFloat(variable.depth * 12)).padding(.trailing, 12).padding(.vertical, 4)
            }.buttonStyle(.hoverWash).disabled(variable.reference == 0)
          }
        } else { debugEmpty("停止すると表示されます") }
        debugSection("デバッグコンソール")
        if let session = store.debugSession, !session.console.isEmpty {
          ForEach(Array(session.console.enumerated()), id: \.offset) { _, line in
            Text(line).font(.system(size: 11, design: .monospaced))
              .foregroundStyle(C.textTertiary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 12).padding(.vertical, 2)
              .textSelection(.enabled)
          }
        } else { debugEmpty("出力はありません") }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func debugSection(_ title: String) -> some View {
      Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(C.textTertiary)
        .padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 5)
    }
    private func debugEmpty(_ text: String) -> some View {
      Text(text).font(.system(size: 11)).foregroundStyle(C.textQuaternary).padding(.horizontal, 12)
    }

    private var debugSetupMessage: String {
      guard let session = store.debugSession else { return "Go ファイルを開き、構成を選んで開始してください。Delve (dlv) が必要です。" }
      switch session.phase {
      case .idle: return "構成を選んで開始してください。"
      case .starting: return "Delve に接続中…"
      case .configuring: return "ブレークポイントを設定中…"
      case .running: return "実行中 · \(session.project.name)"
      case .stopped: return "停止: \(session.stoppedReason ?? "一時停止")"
      case .ended: return "デバッグセッションは終了しました"
      case .failed(let error): return error
      }
    }

    private func startDebugFromUI() {
      if debugMode == "attach" {
        guard let pid = Int(debugPID), pid > 0 else { return }
        _ = store.run("debug.attach", ["pid": .int(pid)], confirmed: true)
      } else {
        guard let rel = st.active, rel.hasSuffix(".go"), let root = store.activeRoot else { return }
        let program = debugMode == "test" ? URL(fileURLWithPath: root + "/" + rel).deletingLastPathComponent().path : root + "/" + rel
        _ = store.run("debug.launch", ["program": .string(program), "mode": .string(debugMode)], confirmed: true)
      }
    }

    private func toggleBreakpointAtCaret() {
      guard let rel = st.active, let root = store.activeRoot, let caret = store.buffers.caret[rel] else { return }
      _ = store.run("debug.breakpoint", ["path": .string(root + "/" + rel), "line": .int(caret.line)])
    }

    private func openDebugFrame(_ frame: ClairDebugSession.Frame) {
      guard let path = frame.path, let root = store.activeRoot, path.hasPrefix(root + "/") else { return }
      _ = store.run("file.open", ["path": .string(path), "line": .int(frame.line)])
    }

    private var debugControlsVisible: Bool {
      guard let phase = store.debugSession?.phase else { return false }
      switch phase {
      case .starting, .configuring, .running, .stopped: return true
      case .idle, .ended, .failed: return false
      }
    }

    private var debugToolbar: some View {
        HStack(spacing: 2) {
          Image(systemName: "line.3.horizontal")
            .font(.system(size: 10)).foregroundStyle(C.textQuaternary)
            .frame(width: 14, height: 20)
          Rectangle().fill(L.strong).frame(width: 1, height: 18).padding(.horizontal, 4)
          debugAction("play.fill", "続行", "debug.continue", enabled: store.debugSession?.phase == .stopped)
          debugAction("pause.fill", "一時停止", "debug.pause", enabled: store.debugSession?.phase == .running)
          debugAction("arrow.turn.down.right", "ステップオーバー", "debug.stepOver", enabled: store.debugSession?.phase == .stopped)
          debugAction("arrow.down.right", "ステップイン", "debug.stepInto", enabled: store.debugSession?.phase == .stopped)
          debugAction("arrow.up.right", "ステップアウト", "debug.stepOut", enabled: store.debugSession?.phase == .stopped)
          Rectangle().fill(L.strong).frame(width: 1, height: 18).padding(.horizontal, 4)
          debugAction("arrow.clockwise", "再起動", "debug.restart", enabled: store.debugSession != nil)
          debugAction("stop.fill", "終了", "debug.stop", enabled: store.debugSession != nil)
        }
        .padding(.horizontal, 4).frame(height: 34)
        .background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(L.strong))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("デバッグ操作")
    }

    private func debugAction(_ symbol: String, _ title: String, _ command: String, enabled: Bool) -> some View {
      Button { _ = store.run(command, confirmed: command == "debug.restart") } label: {
        Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(command == "debug.stop" ? C.danger : command == "debug.continue" ? C.debugBlueText : C.textSecondary)
          .frame(width: 28, height: 28)
          .background(command == "debug.continue" && enabled ? C.debugBlue.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: Radius.control))
      }.buttonStyle(.hoverWash).help(title).disabled(!enabled)
    }

    // MARK: main

    private func name(_ path: String) -> String { String(path.split(separator: "/").last ?? "") }

    private struct LoadedDiff {
      let target: DiffTarget
      let root: String
      let model: DiffView.Model
      let fileLines: [String]?
    }

    private func loadDiff() {
      diffTask?.cancel(); loadedDiff = nil
      guard let target = diff, let root = store.activeRoot else { return }
      diffTask = Task {
        async let rendered = Task.detached(priority: .userInitiated) {
          DiffView.model(WorkbenchGit.diff(root, target.path, staged: target.staged, untracked: target.untracked))
        }.value
        async let lines = Task.detached(priority: .utility) {
          (try? String(contentsOfFile: root + "/" + target.path, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }.value
        async let prefetched: Void = store.buffers.prefetch(target.path, root: root)
        let snapshot = await (rendered, lines, prefetched)
        guard !Task.isCancelled, diff == target, store.activeRoot == root else { return }
        loadedDiff = LoadedDiff(target: target, root: root, model: snapshot.0, fileLines: snapshot.1)
      }
    }

    private var main: some View {
      VStack(spacing: 0) {
        if let d = diff, let root = store.activeRoot, let loaded = loadedDiff,
          loaded.target == d, loaded.root == root
        {
          let fileLines = loaded.fileLines
          let buffer: EditorTransactionManager? = { if case .ready(let m)? = store.buffers.peek(d.path) { m } else { nil } }()
          DiffView(
            target: d, model: loaded.model,
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
        } else if diff != nil {
          ProgressView("差分を読み込み中…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if st.panesClosed {
          EmptyPanesView(open: { store.run("pane.open", ["kind": .string($0)]) })
        } else {
        PaneView(
          node: st.tree.maximized.flatMap { id in st.tree.leaves.first { $0.id == id }.map { .leaf(id: $0.id, kind: $0.kind) } } ?? st.tree.root,
          focused: st.tree.focused, launches: st.launches, project: store.activeRoot ?? st.project, onFocus: { store.run("pane.focus", ["id": .int($0)]) },
          onFacts: { store.facts(pane: $0, bells: $1, exit: $2) },
          onRatio: { store.run("pane.setRatio", ["id": .int($0), "ratio": .double($1)]) },
          editor: EditorPane(buffers: store.buffers, root: store.activeRoot, path: st.active,
            softWrap: st.toggles["softWrap"] == true,
            debugLine: store.debugSession?.frames.first(where: { $0.id == store.debugSession?.selectedFrame }).flatMap {
              $0.path == store.activeRoot.map { $0 + "/" + (st.active ?? "") } ? $0.line : nil
            },
            debugBreakpoints: Set(store.debugSession?.breakpointStatus[(store.activeRoot ?? "") + "/" + (st.active ?? "")]?.values
              .filter(\.verified).map(\.line) ?? []),
            onToggleDebugBreakpoint: { line in
              guard let root = store.activeRoot, let path = st.active else { return }
              _ = store.run("debug.breakpoint", ["path": .string(root + "/" + path), "line": .int(line)])
            },
            onEdit: { store.edited($0) }, onCaret: { store.buffers.setCaret($0, $1, in: $2) }),
          run: { _ = store.run($0, $1) }, dragging: $draggingPane)
        }
      }
      .overlay(alignment: .top) {
        if debugControlsVisible { debugToolbar.padding(.top, 12) }
      }
    }

    private static let sectionNotes = ["一般": "ワークスペースの基本動作とアプリ全体の表示を設定します。"]

    private var settingsMain: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          Text(st.section).font(.system(size: 20, weight: .semibold)).foregroundStyle(C.textPrimary)
          Text(Self.sectionNotes[st.section] ?? "\(st.section) の設定です。").font(.system(size: 12)).foregroundStyle(C.textTertiary)
            .padding(.bottom, 16)
          switch st.section {
          case "使用状況":
            AgentUsageView()
          case "一般":
            SettingsCard(title: "ワークスペース") {
              switchRow("前回のレイアウトを復元", "restoreLayout", note: "Projectごとのファイル、ターミナル、分割位置を再開します。")
              switchRow("閉じる前に確認", "confirmClose", note: "実行中のターミナルや未保存のエディタを閉じる前に確認します。")
            }
            SettingsCard(title: "インターフェース") { switchRow("ステータスバーの利用枠を表示", "showQuota") }
          case "AIプロバイダー":
            SettingsCard(title: "Agent") {
              choiceRow("既定のAgent", "defaultAgent", note: "⌃⌘N で追加するときの初期選択。titlebarのタブは個別に選べます。")
              choiceRow("承認ポリシー", "approvalPolicy", note: "ターミナル・Agent会話での変更提案を、どこまで自動で通すか。")
            }
          case "エディタ":
            SettingsCard(title: "編集") {
              switchRow("保存時に整形", "formatOnSave", note: "⌘S のタイミングでフォーマッタを実行します。")
              choiceRow("タブ幅", "tabWidth")
              switchRow("空白文字を表示", "showWhitespace", note: "タブ・行末の空白を薄く可視化します。")
              switchRow("行の折り返し", "softWrap", note: "長い行をエディタの幅に合わせて折り返します。⌥Z でも切り替えられます。")
            }
          case "ターミナル":
            SettingsCard(title: "シェルと承認") {
              choiceRow("デフォルトシェル", "defaultShell")
              switchRow("コマンド実行前に確認", "terminalApprovals", note: "agentが実行するコマンドの承認プロンプト。")
              choiceRow("スクロールバック", "scrollback")
            }
            SettingsCard(title: "電源") {
              switchRow("バッテリー駆動中もエージェント実行中はスリープさせない", "preventSleepOnBattery")
            }
          case "アップデート":
            updateSection
          case "モバイル":
            SettingsCard(title: "モバイル") {
              SettingsRow(title: "セッションの確認", note: "同じネットワーク上の端末からセッションを確認します。") { EmptyView() }
            }
          default:
            EmptyView()
          }
        }
        .padding(.horizontal, 56).padding(.vertical, 40).frame(maxWidth: 720 + 112, alignment: .leading).frame(maxWidth: .infinity)
        // Destination change: short cross-fade on the screen token; SwiftUI retargets it mid-flight (interruptible), and reduce motion swaps instantly.
        .id(st.section).transition(.opacity)
      }
      .animation(reduceMotion ? nil : .easeOut(duration: Motion.screenDuration), value: st.section)
      .background(C.canvas)
    }

    @ViewBuilder private var updateSection: some View {
      let c = store.updateConfig
      SettingsCard(title: "更新チャンネル") {
        SettingsRow(title: "チャンネル", note: "Dev は先行ビルド。署名検証・backup/rollback はどちらも同じです。") {
          // The channel is the running bundle's identity (ADR-0008), not a preference, so it is shown, not switched.
          SettingsSegmented(options: ["Stable", "Dev"], value: c.channel.displayName, onChange: { _ in })
            .allowsHitTesting(false)
        }
      }
      SettingsCard(title: "バージョン") {
        SettingsRow(title: "現在のバージョン", note: "\(c.channel.displayName) \(c.currentVersion)") {
          if c.channel == .dev {
            Text("Dev ビルドは更新フィードを持ちません。").font(.system(size: 11)).foregroundStyle(C.textMuted)
          } else {
            switch store.update {
            case .idle: Text("最新の状態です。").font(.system(size: 11)).foregroundStyle(C.textTertiary)
            case .checking: Text("確認中…").font(.system(size: 11)).foregroundStyle(C.textTertiary)
            case .installing: Text("更新を適用しています。完了後に再起動します。").font(.system(size: 11)).foregroundStyle(C.textTertiary)
            case .failed(let m): Text(m).font(.system(size: 11)).foregroundStyle(C.textTertiary)
            case .available(let u):
              HStack(spacing: 8) {
                Text("\(u.version) が利用できます").font(.system(size: 11)).foregroundStyle(C.textSecondary)
                Button("適用して再起動") { Task { await store.installUpdate() } }
              }
            }
          }
        }
        if c.channel != .dev {
          SettingsRow(title: "更新を確認") { Button("確認") { Task { await store.checkForUpdate(manual: true) } } }
        }
      }
    }

    private func switchRow(_ title: String, _ key: String, note: String? = nil) -> some View {
      SettingsRow(title: title, note: note) {
        SettingsSwitch(on: st.toggles[key] ?? false) { store.run("settings.set", ["key": .string(key), "value": .bool($0)]) }
      }
    }

    private func choiceRow(_ title: String, _ key: String, note: String? = nil) -> some View {
      SettingsRow(title: title, note: note) {
        SettingsSegmented(options: WorkbenchState.choiceOptions[key] ?? [], value: st.choices[key] ?? "") {
          store.run("settings.choose", ["key": .string(key), "value": .string($0)])
        }
      }
    }

    /// U06/U05: facts only — branch, dirty count, agent state. The changed-file count lives in the Git panel, not here (owner, 2026-09-24).
    /// Mock `AppStatusBar`: branch, ahead/behind, caret, then the session count on the right. 26px, sans, `textTertiary`.
    /// Mock `QuotaMeter` (H11): the tightest window across providers; the tooltip lists every provider, unread ones included.
    private func quotaTint(_ usedPercent: Double) -> Color {
      if usedPercent <= 50 || usedPercent >= 100 { return C.success }
      if usedPercent <= 90 { return C.attention }
      return C.danger
    }

    /// Vendor logos are fetched from each vendor's own site favicon at runtime rather than
    /// redistributed in this repository; offline or on failure the provider's initial stands in.
    @ViewBuilder private func quotaProviderIcon(_ provider: String, size: CGFloat = 15) -> some View {
      let domain: String? = switch provider {
      case "Codex": "chatgpt.com"
      case "Claude Code": "claude.ai"
      case "OpenCode": "opencode.ai"
      default: nil
      }
      if let domain {
        AsyncImage(url: URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=64")) { phase in
          if let image = phase.image {
            image.resizable().scaledToFit()
          } else {
            Text(provider.prefix(1)).font(.system(size: size * 0.7, weight: .semibold))
              .foregroundStyle(C.textTertiary)
          }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
      }
    }

    private var quotaMeter: some View {
      let now = Date()
      let top = ProviderQuota.tightest(quota)
      let stale = quota.contains { $0.isStale(now: now) }
      return HStack(spacing: 6) {
        if let top {
          let tint = stale ? C.textQuaternary : quotaTint(top.window.usedPercent)
          quotaProviderIcon(top.provider)
          Text("\(top.provider) \(top.window.label)").foregroundStyle(C.textQuaternary)
          Capsule().fill(L.strong).frame(width: 34, height: 4)
            .overlay(alignment: .leading) { Capsule().fill(tint).frame(width: 34 * top.window.usedPercent / 100) }
          Text("残り\(top.window.remainingPercent)%").fontWeight(.semibold).foregroundStyle(tint)
        } else {
          Text(quota.isEmpty ? "利用枠を取得中…" : "利用枠 —").foregroundStyle(C.textQuaternary)
        }
      }
      .contentShape(Rectangle())
      .onHover { quotaHovered = $0 }
      .popover(isPresented: $quotaHovered, arrowEdge: .top) {
        VStack(alignment: .leading, spacing: 12) {
          if quota.isEmpty {
            Text("利用枠を取得中…").foregroundStyle(C.textTertiary)
          }
          ForEach(quota, id: \.provider) { provider in
            VStack(alignment: .leading, spacing: 7) {
              HStack {
                quotaProviderIcon(provider.provider, size: 20)
                Text(provider.provider).font(.system(size: 14, weight: .semibold))
                Spacer()
                if case .ok = provider.state {
                  Text(provider.isStale(now: now) ? "古い値 · \(provider.fetchedAt.formatted(date: .omitted, time: .shortened)) 取得" : "\(provider.fetchedAt.formatted(date: .omitted, time: .shortened)) 取得")
                    .foregroundStyle(C.textQuaternary)
                }
              }
              switch provider.state {
              case .ok(let windows):
                ForEach(windows, id: \.minutes) { window in
                  VStack(spacing: 4) {
                    HStack(spacing: 8) {
                      Text(window.label)
                      Spacer(minLength: 8)
                      Text(window.resetText(now: now)).foregroundStyle(C.textQuaternary)
                      Text("残り\(window.remainingPercent)%").fontWeight(.semibold)
                    }
                    GeometryReader { geometry in
                      Capsule().fill(L.strong)
                        .overlay(alignment: .leading) {
                          Capsule().fill(provider.isStale(now: now) ? C.textQuaternary : quotaTint(window.usedPercent))
                            .frame(width: geometry.size.width * min(max(window.usedPercent / 100, 0), 1))
                        }
                    }
                    .frame(height: 4)
                    .accessibilityHidden(true)
                  }
                  .accessibilityElement(children: .combine)
                }
              case .unavailable(let reason):
                Text("取得できません — \(reason)").foregroundStyle(C.textTertiary)
              case .unsupported(let reason):
                Text("未対応 — \(reason)").foregroundStyle(C.textTertiary)
              }
            }
          }
        }
        .font(Typography.font(Typography.chrome)).monospacedDigit()
        .frame(width: 340).padding(12)
      }
    }

    /// E12: the active file's language server and its diagnostic counts.
    @ViewBuilder private var languageStatus: some View {
      if let rel = st.active, let root = store.activeRoot {
        let path = root + "/" + rel
        if let server = store.buffers.language.statusText(path, root: root) {
          Text(server.text).foregroundStyle(server.failed ? C.attention : C.textQuaternary).lineLimit(1)
        }
        if let spans = store.buffers.language.diagnostics[path]?.spans, !spans.isEmpty {
          let errors = spans.filter { $0.severity == .error }.count
          let warnings = spans.filter { $0.severity == .warning }.count
          Text([errors > 0 ? "エラー \(errors)" : nil, warnings > 0 ? "警告 \(warnings)" : nil].compactMap { $0 }.joined(separator: " · "))
            .foregroundStyle(errors > 0 ? C.attention : C.textTertiary)
        }
        if let notice = store.languageNotice { Text(notice).foregroundStyle(C.textQuaternary).lineLimit(1) }
      }
    }

    /// V08 history: every recorded fact across Projects, newest first. A row jumps to its terminal (marks it read).
    private var noticeButton: some View {
      let unread = st.notices.unread()
      return Button { noticesOpen.toggle() } label: {
        HStack(spacing: 3) {
          Image(systemName: unread > 0 ? "bell.badge" : "bell").font(.system(size: 11))
          if unread > 0 { Text("\(unread)").foregroundStyle(C.attention) }
        }.frame(minHeight: 18)
      }
      .buttonStyle(.hoverWash).help("通知").accessibilityLabel(unread > 0 ? "通知 未読 \(unread) 件" : "通知")
      .popover(isPresented: $noticesOpen, arrowEdge: .top) {
        VStack(alignment: .leading, spacing: 0) {
          HStack {
            Text("通知").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button("すべて既読") { store.run("notice.markRead", [:]) }.disabled(unread == 0)
            Button("消去") { store.run("notice.clear", [:]) }.disabled(st.notices.items.isEmpty)
          }
          .buttonStyle(.borderless).padding(10)
          Divider()
          if st.notices.items.isEmpty {
            Text("通知はありません").foregroundStyle(C.textQuaternary).padding(12)
          } else {
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(st.notices.items) { n in
                  Button {
                    if n.project != st.project { store.run("project.switch", ["name": .string(n.project)]) }
                    store.run("pane.focus", ["id": .int(n.pane)])
                    noticesOpen = false
                  } label: {
                    HStack(spacing: 8) {
                      Circle().fill(n.read ? Color.clear : C.attention).frame(width: 6, height: 6)
                      VStack(alignment: .leading, spacing: 2) {
                        Text(st.agentLaunch(in: n.project, pane: n.pane).map { AgentProfile.named($0.profile)?.title ?? $0.profile } ?? "ターミナル \(n.pane)")
                          .foregroundStyle(C.textPrimary)
                        Text("\(n.project) · \(n.title)").foregroundStyle(n.kind == .exited && n.exitCode != 0 ? C.attention : C.textTertiary)
                      }
                      Spacer(minLength: 8)
                      Text(n.at.formatted(date: .omitted, time: .shortened)).foregroundStyle(C.textQuaternary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
                  }
                  .buttonStyle(.hoverWash)
                }
              }
            }
            .frame(maxHeight: 360)
          }
        }
        .font(Typography.font(Typography.chrome)).monospacedDigit()
        .frame(width: 320)
      }
    }

    private var statusBar: some View {
      let agents = st.agentSessions.filter { $0.project == st.project && !$0.status.isExited }
      let waiting = agents.filter { $0.status == .attention }.count
      let caret = st.active.flatMap { store.buffers.caret[$0] }
      return HStack(spacing: 12) {
        if st.settingsOpen {
          Text("設定 · \(st.section)")
        } else {
          if let branch {
            Menu {
              ForEach(branches, id: \.self) { candidate in
                Button {
                  if candidate != branch {
                    runGit([("git.switch", ["name": .string(candidate)])], label: "ブランチ切替")
                  }
                } label: {
                  if candidate == branch { Label(candidate, systemImage: "checkmark") }
                  else { Text(candidate) }
                }
              }
            } label: {
              HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                Text(branch)
              }
            }
            .menuStyle(.borderlessButton).fixedSize().disabled(gitOperation != nil)
          }
          if st.isRepo {
            // VS Code-style sync: one button shows ↓behind ↑ahead and runs pull then push.
            Button { runGit([("git.pull", [:]), ("git.push", [:])], label: "Sync", confirmed: true) } label: {
              HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10))
                if let sync, sync.behind + sync.ahead > 0 { Text("\(sync.behind)↓ \(sync.ahead)↑") }
              }.frame(minHeight: 18)
            }.buttonStyle(.hoverWash).disabled(gitOperation != nil).help(sync.map { "\(branch ?? "") の同期: pull \($0.behind) 件 / push \($0.ahead) 件\nクリックで Pull → Push" } ?? "同期 (Pull → Push)")
            if let gitOperation { ProgressView().controlSize(.small).help("\(gitOperation)中") }
            // Failures only: a success toast is noise here (owner, 2026-09-24); the Git panel still shows it.
            if let gitMessage, gitFailed, gitOperation == nil {
              HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                Text(gitMessage).lineLimit(1).truncationMode(.tail)
              }
              .foregroundStyle(C.attention)
              .frame(maxWidth: 260, alignment: .leading)
              .help(gitMessage)
            }
          }
          if !st.dirty.isEmpty { Text("未保存 \(st.dirty.count)").foregroundStyle(C.attention) }
          if let caret { Text("Ln \(caret.line), Col \(caret.col)") }
          languageStatus
        }
        Spacer()
        if st.toggles["showQuota"] == true { quotaMeter }
        Button { sidebarMode = "terminal" } label: {
          HStack(spacing: 5) {
            if waiting > 0 { Circle().fill(C.attention).frame(width: 6, height: 6) }
            Text("\(agents.count) セッション" + (waiting > 0 ? " · 入力待ち \(waiting)" : ""))
          }
        }.buttonStyle(.hoverWash)
        noticeButton
      }
      .font(Typography.font(Typography.chrome)).monospacedDigit().foregroundStyle(C.textTertiary)
      .padding(.horizontal, 12).frame(height: ChromeBudget.statusBar)
      .background(C.chrome)
      .overlay(alignment: .top) { Rectangle().fill(L.chrome).frame(height: 1) }
      // Off the main actor, every 5 min while the toggle is on; turning it off cancels the loop.
      .task(id: st.toggles["showQuota"] == true) {
        guard st.toggles["showQuota"] == true else { quota = []; return }
        while !Task.isCancelled {
          let previous = quota
          quota = await Task.detached(priority: .utility) { await ProviderQuota.fetchAll(previous: previous) }.value
          try? await Task.sleep(for: .seconds(300))
        }
      }
    }

    // MARK: palette (⌘K commands, ⌘P files)

    private func items(_ p: WorkbenchState.Palette) -> [PaletteItem] {
      switch p {
      case .symbols: return store.languageItems
      case .references:
        let q = query.lowercased()
        return store.languageItems.filter { q.isEmpty || $0.hint.lowercased().contains(q) }
      default: return store.registry.paletteItems(p, query: query, state: st)
      }
    }

    private func paletteView(_ p: WorkbenchState.Palette) -> some View {
      let list = items(p)
      return ZStack(alignment: .top) {
        Color(red: 8 / 255, green: 10 / 255, blue: 12 / 255).opacity(0.68).onTapGesture { store.run("palette.close") }
        VStack(spacing: 0) {
          HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(C.textQuaternary)
            TextField("", text: $query)
              .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(C.textPrimary)
              .onSubmit { run(list) }
              .onKeyPress(.downArrow) { selection = min(selection + 1, max(list.count - 1, 0)); return .handled }
              .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
              .onKeyPress(.escape) { store.run("palette.close"); return .handled }
              .onChange(of: query) { selection = 0 }
            Text("\(list.count) 件").font(.system(size: 11)).foregroundStyle(C.textQuaternary)
          }
          // ⌘T: ask the language servers as the query changes (debounced; a newer query cancels this one).
          .task(id: p == .symbols ? query : nil) {
            guard p == .symbols else { return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await store.searchSymbols(query)
          }
          .padding(.horizontal, 8).frame(height: 40)
          .background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.control))
          .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(L.hairline))
          .padding(12)
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(Array(list.enumerated()), id: \.offset) { i, it in
                let on = i == selection
                HStack(spacing: 8) {
                  Text(p == .files ? name(it.title) : it.title).font(.system(size: 12)).lineLimit(1)
                    .foregroundStyle(on ? C.textPrimary : C.textSecondary)
                  Spacer(minLength: 0)
                  if p == .files {
                    Text(it.title).font(.system(size: 11)).lineLimit(1).truncationMode(.head).foregroundStyle(C.textQuaternary)
                  }
                  if p == .symbols || p == .references {
                    Text(it.hint).font(.system(size: 11)).lineLimit(1).truncationMode(.head).foregroundStyle(C.textQuaternary)
                  } else { HStack(spacing: 2) {
                    ForEach(Array(it.hint), id: \.self) { k in
                      Text(String(k)).font(.system(size: 11)).monospacedDigit().foregroundStyle(on ? C.textSecondary : C.textTertiary)
                        .frame(minWidth: 20, minHeight: 20).padding(.horizontal, 4)
                        .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(L.hairline))
                    }
                  } }
                }
                .padding(.horizontal, 8).frame(height: 32)
                .background(on ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .contentShape(Rectangle())
                .onTapGesture { selection = i; run(list) }
              }
            }.padding(.horizontal, 8).padding(.bottom, 8)
          }.frame(minHeight: 322, maxHeight: 420)
          HStack(spacing: 8) {
            ForEach([("コマンド", WorkbenchState.Palette.commands), ("ファイルへ移動", .files)], id: \.1) { label, mode in
              Button { store.run(mode == .commands ? "palette.commands" : "palette.files") } label: {
                Text(label).font(.system(size: 11, weight: .semibold))
                  .foregroundStyle(p == mode ? C.textPrimary : C.textTertiary)
                  .padding(.horizontal, 8).frame(height: 20)
                  .background(p == mode ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
              }.buttonStyle(.hoverWash)
            }
            Spacer()
          }
          .padding(.horizontal, 12).frame(height: 34)
          .overlay(alignment: .top) { Rectangle().fill(L.hairline).frame(height: 1) }
        }
        .frame(width: 560).background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.overlay))
        .overlay(RoundedRectangle(cornerRadius: Radius.overlay).stroke(L.strong))
        .shadow(color: .black.opacity(0.62), radius: 24, y: 18)
        .padding(.top, 44)
        .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
      }
    }

    private func run(_ list: [PaletteItem]) {
      guard selection < list.count else { return }
      store.run("palette.close")
      store.performFromUI(list[selection].id, list[selection].input)
    }
  }

  /// Our SwiftUI titlebar covers AppKit's, so its empty areas re-implement the native titlebar: drag moves the window and
  /// a double-click does what System Settings › Desktop & Dock › "Double-click a window's title bar to" says.
  private struct TitlebarArea: NSViewRepresentable {
    final class Area: NSView {
      override var mouseDownCanMoveWindow: Bool { true }
      override func mouseDown(with event: NSEvent) {
        guard let w = window else { return }
        guard event.clickCount == 2 else { return w.performDrag(with: event) }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": w.miniaturize(nil)
        case "None": break
        default: w.zoom(nil)  // "Maximize" / "Fill" / unset
        }
      }
    }
    func makeNSView(context: Context) -> Area { Area() }
    func updateNSView(_ nsView: Area, context: Context) {}
  }

  /// Sits behind titlebar tabs/group chips so a press there drags the item, not the window (`TitlebarArea` underneath would).
  private struct NoWindowDrag: NSViewRepresentable {
    final class Blocker: NSView { override var mouseDownCanMoveWindow: Bool { false } }
    func makeNSView(context: Context) -> Blocker { Blocker() }
    func updateNSView(_ nsView: Blocker, context: Context) {}
  }

  /// A titlebar file tab. Selected and hover used to be two different
  /// treatments — a `surfaceActive`-filled background plus a 1.5px bottom
  /// rule for selected, a bare `.canvas` fill with nothing for hover — and
  /// the rule read as a stray line rather than a state (mock review
  /// feedback). Both now share the `washSelected` tint and there is no
  /// rule; see checklist §2.4, 2026-09-20 amendment.
  private struct ActivityBarButton: View {
    let icon: String
    let on: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
      Button(action: action) {
        Group {
          if icon == "shield" {
            GitBranchGlyph().stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
              .frame(width: 16, height: 16)
          } else {
            Image(systemName: icon).font(.system(size: 16))
          }
        }
          .foregroundStyle(on ? C.chromeInk : C.chromeInkMuted)
          .frame(width: 36, height: 36)
          .background(on || (hovered && enabled) ? W.selected : .clear, in: RoundedRectangle(cornerRadius: Radius.card))
          .opacity(enabled ? 1 : 0.35)
      }
      .buttonStyle(.plain).disabled(!enabled).help(enabled ? "" : "準備中")
      .onHover { hovered = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: Motion.overlayDuration), value: hovered)
    }
  }

  /// Git branch glyph: two nodes and the curved branch joining the stem.
  private struct GitBranchGlyph: Shape {
    func path(in rect: CGRect) -> Path {
      let s = min(rect.width, rect.height) / 24
      var p = Path()
      p.move(to: CGPoint(x: 6 * s, y: 3 * s))
      p.addLine(to: CGPoint(x: 6 * s, y: 15 * s))
      p.move(to: CGPoint(x: 9 * s, y: 18 * s))
      p.addArc(center: CGPoint(x: 6 * s, y: 18 * s), radius: 3 * s, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
      p.move(to: CGPoint(x: 18 * s, y: 9 * s))
      p.addCurve(to: CGPoint(x: 9 * s, y: 18 * s), control1: CGPoint(x: 18 * s, y: 14 * s), control2: CGPoint(x: 14 * s, y: 18 * s))
      p.move(to: CGPoint(x: 21 * s, y: 6 * s))
      p.addArc(center: CGPoint(x: 18 * s, y: 6 * s), radius: 3 * s, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
      return p
    }
  }

  private struct FileTabButton: View {
    let path: String
    let name: String
    let selected: Bool
    let dirty: Bool
    let onActivate: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
      let tint = selected ? C.chromeInk : C.textTertiary
      HStack(spacing: 4) {
        Image(systemName: path.hasSuffix(".md") ? "text.alignleft" : "doc.text").font(.system(size: 11)).foregroundStyle(tint)
        Text(name).font(.system(size: 11, weight: selected ? .semibold : .regular)).foregroundStyle(tint).lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 0)
        if dirty { Circle().fill(selected ? C.textTertiary : C.textQuaternary).frame(width: 6, height: 6) }
        Button(action: onClose) {
          Image(systemName: "xmark").font(.system(size: 9, weight: .medium)).foregroundStyle(C.textTertiary)
        }
        .buttonStyle(.hoverWash)
        .help("閉じる")
        .opacity((selected || isHovered) ? 1 : 0)
        .allowsHitTesting(selected || isHovered)
      }
      .padding(.horizontal, 8).frame(width: 200, height: 38)
      .background((selected || isHovered) ? W.selected : .clear, in: RoundedRectangle(cornerRadius: Radius.card))
      .background(NoWindowDrag())
      .contentShape(Rectangle())
      .onHover { isHovered = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: Motion.overlayDuration), value: isHovered)  // short fade, no flicker
      .onTapGesture(perform: onActivate)
      .help(path)
    }
  }

  /// Hover-revealed header for agent/terminal panes: a drag handle (drop another
  /// pane's handle here to swap what the two show) and a close button. Editor
  /// panes keep their breadcrumb instead (checklist §3.1, 2026-09-20 amendment;
  /// mirrors the mock's `PaneHeader`).
  private struct PaneHeaderView: View {
    let id: Int
    let label: String
    let focused: Bool
    let onSwap: (Int, Int) -> Void
    let onDragStart: () -> Void
    var onDragEnd: () -> Void = {}
    let onClose: () -> Void
    @State private var isHovered = false
    @State private var isDropTarget = false

    var body: some View {
      // Mock: the handle fades in on hover, the label stays put, and the close
      // button fades in on hover or while focused — the 24px bar itself is
      // always laid out so this never becomes a permanent line of chrome.
      HStack(spacing: Spacing.scale[0]) {
        // Top-centre drag handle; no title/label (U06).
        Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(C.textQuaternary)
          .opacity(isHovered ? 1 : 0).frame(maxWidth: .infinity)
          .accessibilityLabel(label)
        Button(action: onClose) {
          Image(systemName: "xmark").font(.system(size: 9, weight: .medium)).foregroundStyle(C.textQuaternary)
        }.buttonStyle(.hoverWash).help("パネルを閉じる").opacity((isHovered || focused) ? 1 : 0)
      }
      .padding(.horizontal, 8).frame(height: 24).frame(maxWidth: .infinity)
      .background(C.canvas)
      .overlay(Rectangle().fill(isDropTarget ? L.ring : .clear).frame(height: 1), alignment: .bottom)
      .contentShape(Rectangle())
      .onHover { isHovered = $0 }
      .onDrag({ onDragStart(); return NSItemProvider(object: NSString(string: "\(id)")) }, preview: {
        if let shot = ClairGhosttySurfaceView.snapshot(pane: id) {
          let scale = min(1, 360 / max(shot.size.width, 1))
          Image(nsImage: shot).resizable()
            .frame(width: shot.size.width * scale, height: shot.size.height * scale)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(L.ring, lineWidth: 1))
            .opacity(0.9)
        } else {
        VStack(spacing: 0) {
          Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(C.textQuaternary)
            .frame(maxWidth: .infinity).frame(height: 24).background(C.canvas)
          Image(systemName: "terminal").font(.system(size: 28, weight: .light)).foregroundStyle(C.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(C.surface)
        }
        .frame(width: 240, height: 150)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(L.ring, lineWidth: 1))
        .opacity(0.9)
        }
      })
      .onDrop(of: [.text], isTargeted: $isDropTarget) { providers in
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
          guard let fromID = (object as? NSString).flatMap({ Int($0 as String) }) else { return }
          Task { @MainActor in onSwap(fromID, id); onDragEnd() }
        }
        return true
      }
    }
  }

  /// Drag-time overlay on a pane: highlights the half nearest the cursor where the dragged pane will land.
  // ponytail: a cancelled drag (dropped outside any pane) leaves the zones up until a click; add an NSDraggingSource end hook if that annoys.
  private struct PaneDropZones: View, DropDelegate {
    let onMove: (PaneTree.Edge) -> Void
    let onCancel: () -> Void
    @State private var edge: PaneTree.Edge?
    @State private var size: CGSize = .zero

    var body: some View {
      GeometryReader { g in
        ZStack {
          Color.clear.contentShape(Rectangle()).onTapGesture(perform: onCancel)
          if let edge {
            let side = edge == .left || edge == .right
            RoundedRectangle(cornerRadius: Radius.card)
              .fill(L.ring.opacity(0.18))
              .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(L.ring, lineWidth: 1.5))
              .padding(4)
              .frame(width: side ? g.size.width / 2 : g.size.width, height: side ? g.size.height : g.size.height / 2)
              .frame(maxWidth: .infinity, maxHeight: .infinity,
                     alignment: [.left: .leading, .right: .trailing, .top: .top, .bottom: .bottom][edge]!)
              .allowsHitTesting(false)
          }
        }
        .onAppear { size = g.size }
        .onChange(of: g.size) { size = $0 }
      }
      .onDrop(of: [.text], delegate: self)
    }

    private func nearest(_ p: CGPoint) -> PaneTree.Edge {
      guard size.width > 0, size.height > 0 else { return .right }
      let x = p.x / size.width, y = p.y / size.height
      return [(PaneTree.Edge.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)].min { $0.1 < $1.1 }!.0
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { edge = nearest(info.location); return DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { edge = nil }
    func performDrop(info: DropInfo) -> Bool { onMove(nearest(info.location)); edge = nil; return true }
  }

  /// AppKit strip over a pane divider: resize cursor, and a drag that keeps going over the panes either side.
  private struct SplitHandle: NSViewRepresentable {
    let horizontal: Bool
    let ratio: Double
    let total: CGFloat
    let onRatio: (Double) -> Void

    final class Handle: NSView {
      var parent: SplitHandle!
      private var start: (point: NSPoint, ratio: Double)?
      override var mouseDownCanMoveWindow: Bool { false }
      override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
      override func resetCursorRects() { addCursorRect(bounds, cursor: parent.horizontal ? .resizeLeftRight : .resizeUpDown) }
      override func mouseDown(with event: NSEvent) { start = (event.locationInWindow, parent.ratio) }
      override func mouseDragged(with event: NSEvent) {
        guard let start, parent.total > 0 else { return }
        let p = event.locationInWindow
        let delta = parent.horizontal ? p.x - start.point.x : start.point.y - p.y  // window y grows upward
        parent.onRatio(start.ratio + Double(delta / parent.total))
      }
      override func mouseUp(with event: NSEvent) { start = nil }
    }

    func makeNSView(context: Context) -> Handle { let v = Handle(); v.parent = self; return v }
    func updateNSView(_ v: Handle, context: Context) {
      let flipped = v.parent?.horizontal != horizontal
      v.parent = self
      if flipped { v.window?.invalidateCursorRects(for: v) }
    }
  }

  /// Every pane closed: a quiet centre with the ways back in.
  private struct EmptyPanesView: View {
    let open: (String) -> Void

    var body: some View {
      VStack(spacing: 14) {
        Image(systemName: "square.dashed").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(.secondary)
        Text("開いているペインはありません").font(.headline)
        HStack(spacing: 10) {
          Button("ターミナルを開く") { open("terminal") }
          Button("エディタを開く") { open("editor") }
        }
        Text("⌘W でエディタを開けます").font(.caption).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(C.surface)
    }
  }


  private struct PaneView: View {
    let node: PaneTree.Node
    let focused: Int
    let launches: [Int: AgentLaunch]
    let project: String
    let onFocus: (Int) -> Void
    let onFacts: (Int, Int, Int?) -> Void
    let onRatio: (Int, Double) -> Void
    let editor: EditorPane
    let run: (String, CommandInput) -> Void
    /// Pane whose header handle is being dragged; other panes show edge drop zones meanwhile.
    @Binding var dragging: Int?

    /// The pane just before a divider names it (`PaneTree.setRatio`).
    private func lastLeaf(_ n: PaneTree.Node) -> Int {
      switch n {
      case .leaf(let id, _): return id
      case .split(_, _, _, let b): return lastLeaf(b)
      }
    }

    @ViewBuilder
    private func parts(_ axis: PaneTree.Axis, _ total: CGFloat, _ a: PaneTree.Node, _ b: PaneTree.Node, ratio: Double) -> some View {
      let h = axis == .horizontal
      PaneView(node: a, focused: focused, launches: launches, project: project, onFocus: onFocus, onFacts: onFacts, onRatio: onRatio, editor: editor, run: run, dragging: $dragging)
        .frame(width: h ? total * ratio : nil, height: h ? nil : total * ratio)
      Rectangle().fill(L.paneDivider).frame(width: h ? 1 : nil, height: h ? nil : 1)
      PaneView(node: b, focused: focused, launches: launches, project: project, onFocus: onFocus, onFacts: onFacts, onRatio: onRatio, editor: editor, run: run, dragging: $dragging)
    }

    var body: some View {
      switch node {
      case .leaf(let id, let kind):
        VStack(spacing: 0) {
          if kind != .editor {
            PaneHeaderView(
              id: id, label: "ターミナル", focused: id == focused,
              onSwap: { run("pane.swap", ["idA": .int($0), "idB": .int($1)]) },
              onDragStart: { dragging = id }, onDragEnd: { dragging = nil },
              onClose: { run("pane.focus", ["id": .int(id)]); run("pane.close", [:]) })
          }
          ZStack {
            C.surface
            if kind == .terminal { ClairGhosttySurface(launch: launches[id].map { ($0.command, $0.cwd) } ?? (project.hasPrefix("/") ? ("", project) : nil), pane: id, sessionKey: ClairWorkbenchStore.terminalKey(root: project, pane: id), focused: id == focused, onFocus: { if id != focused { onFocus(id) } }, onFacts: { onFacts(id, $0, $1) }) }  // one surface per terminal leaf, attached to the daemon shell keyed by project#pane
            else { editor }
            if let from = dragging, from != id {
              PaneDropZones { edge in
                run("pane.move", ["id": .int(from), "target": .int(id), "edge": .string(edge.rawValue)])
                dragging = nil
              } onCancel: { dragging = nil }
            }
          }
        }
        // Keep the editor fully legible even when another pane is focused.
        .opacity(kind == .editor || id == focused ? 1 : 0.75)
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
          let h = axis == .horizontal
          let total = h ? g.size.width : g.size.height
          ZStack(alignment: .topLeading) {
            if h {
              HStack(spacing: 0) { parts(axis, total, a, b, ratio: ratio) }
            } else {
              VStack(spacing: 0) { parts(axis, total, a, b, ratio: ratio) }
            }
            // Drawn after both panes so it sits above their terminal/editor NSViews, which otherwise take the drag.
            let at = total * ratio + 0.5
            SplitHandle(horizontal: h, ratio: ratio, total: total) { onRatio(lastLeaf(a), $0) }
              .frame(width: h ? 7 : g.size.width, height: h ? g.size.height : 7)
              .position(x: h ? at : g.size.width / 2, y: h ? g.size.height / 2 : at)
          }
        }
      }
    }
  }
#endif
