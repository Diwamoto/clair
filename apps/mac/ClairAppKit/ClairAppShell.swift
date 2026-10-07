#if os(macOS)
  import ClairShared
  import ClairDaemonKit
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
          // Pressed is a deeper wash plus a slight sink, so a click reads distinctly from a hover.
          .overlay(configuration.isPressed ? DesignTokens.Wash.strongest : (hovered && enabled) ? DesignTokens.Wash.selected : .clear, in: RoundedRectangle(cornerRadius: radius))
          .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
          .contentShape(Rectangle())
          .onHover { hovered = $0 }
          .animation(reduceMotion ? nil : .easeOut(duration: Motion.overlayDuration), value: hovered)
          .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
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
    public var state = WorkbenchState() {
      didSet { ClairLanguage.current = ClairLanguage(rawValue: state.choices["language"] ?? "") ?? .english }
    }
    public var pending: (id: String, input: CommandInput)?
    public var lastError: CommandError?
    public let registry = CommandRegistry.workbench
    /// U05: open editor buffers of the active Project, keyed by relative path.
    public let buffers = EditorBuffers()
    func editorSelectionChanged(_ path: String, _ selection: TextSelectionSet, in snapshot: TextSnapshot) {
      buffers.setCaret(path, selection, in: snapshot)
      guard state.active == path, let root = activeRoot, let first = selection.selections.first,
        let start = try? snapshot.position(at: first.range.lowerBound, columnUnit: UTF16Unit.self),
        let end = try? snapshot.position(at: first.range.upperBound, columnUnit: UTF16Unit.self)
      else { return }
      let length = first.range.upperBound.value - first.range.lowerBound.value
      let text = first.isEmpty || length > 16_384 ? nil : try? snapshot.text(in: first.range)
      state.editorContext = EditorContext(
        path: URL(fileURLWithPath: root).appending(path: path).standardizedFileURL.path,
        startLine: start.line.value + 1, startColumn: start.column.value,
        endLine: end.line.value + 1, endColumn: end.column.value, selectedText: text)
      broadcastSelection()
    }
    let reviews = ReviewStore()
    /// ADR-0022: the socket Claude Code connects to, and the proposed edits waiting for the user (by proposal path).
    let claudeIDE = ClaudeIDEServer()
    var proposals: [String: ClaudeProposal] = [:]
    var selectionBroadcast: Task<Void, Never>?
    /// V13: a managed worktree is a separate Project and keeps its own debug session.
    private var debugSessions: [String: ClairDebugSession] = [:]
    var debugSession: ClairDebugSession? { activeRoot.flatMap { debugSessions[$0] } }
    /// The registry's debug.* preflights read `state.debugPhase`; refresh it from the live session first.
    /// The IPC gate preflights on its own snapshot, so it calls this too (a stale phase refused `clair debug.continue`).
    func syncDebugPhase() {
      let phase = debugSession?.phaseName ?? "idle"
      if state.debugPhase != phase { state.debugPhase = phase }
    }
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
    /// Version whose bottom-right popup the user dismissed; a newer release shows it again.
    public var dismissedUpdate: String?
    public let updateConfig = ClairUpdateConfiguration.live()
    private var updateTask: Task<Void, Never>?
    private var sleepAssertion: IOPMAssertionID = 0
    private var persistenceTask: Task<Void, Never>?
    public private(set) var windowGeneration = 0

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

    /// The first window's store: Finder / `open -a` requests (the app as the default editor) land here.
    private static weak var main: ClairWorkbenchStore?
    private static var pendingOpens: [String] = []

    /// ADR-0022: Clair is quitting; Claude Code must stop finding it.
    public static func stopClaudeIDE() { main?.stopClaudeIDE() }

    /// `application(_:open:)`: each file opens like `clair open path`. Before the first window exists, queued.
    public static func open(files: [String]) {
      guard let main else { pendingOpens += files; return }
      for path in files { _ = main.run(WorkbenchProject.normalized(path) == nil ? "file.open" : "project.open", ["path": .string(path)]) }
    }

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
      if Self.main == nil {
        Self.main = self
        let queued = Self.pendingOpens
        Self.pendingOpens = []
        Self.open(files: queued)
        // ADR-0021: crashes of the app, daemon or CLI since the last look, once per app process.
        Task.detached(priority: .utility) {
          while true {
            ClairIssueReporter.reportNewCrashes()
            try? await Task.sleep(for: .seconds(3600))
          }
        }
      }
      let server = WorkbenchIPCServer { req in
        let req = req.callerAsParent()
        if req.via == .mcp || req.caller != nil || req.command == "file.preview" {
          return MCPGate.handle(
            req, registry: CommandRegistry.workbench,
            snapshot: {
              DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                  if req.command.hasPrefix("debug.") { store.syncDebugPhase() }
                  return store.state
                }
              }
            },
            approve: { store.approve($0, $1, $2, caller: req.caller) },
            run: { recheck, confirmed in
              DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                  if req.command.hasPrefix("debug.") { store.syncDebugPhase() }
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
      buffers.language.onWorkspaceEdit = { [weak self] in self?.applyWorkspaceEdit($0) ?? false }
      buffers.onAskAgent = { [weak self] in self?.askAgent($0) }
      buffers.onMarkResolved = { [weak self] path in
        guard let self else { return }
        Task {
          guard await self.saveFile(path) else { return }
          self.run("git.stage", ["path": .string(path)])
          self.gitRevision += 1
        }
      }
      state.dropProposalTabs()
      // Only the running app announces itself to Claude Code; a test's store must not write ~/.claude/ide.
      if Self.main === self, persistURL != nil, Bundle.main.bundleURL.pathExtension == "app" { startClaudeIDE() }
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
      } catch {
        update = .failed("\(error)")
        ClairIssueReporter.reportInBackground(
          "update: install failed (\(ClairIssueReporter.kind(of: error)))",
          "Installing \(u.version) over \(u.currentVersion) failed: \(error)\n\nArtifact: \(u.artifact.url)")
      }
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
      let previousEditor = (state.project, state.active)
      if id.hasPrefix("debug.") { syncDebugPhase() }
      // `file.save` from any caller (⌘S, CLI, MCP) writes the buffer first; a failed write keeps the dirty marker.
      if id == "file.save", let p = state.active, let root = activeRoot, buffers.isOpen(p) {
        let formatting = state.toggles["formatOnSave"] == true && !savingFormatted.contains(p)
        if formatting { formatBuffer(p) }
        do {
          try buffers.save(p, root: root)
        } catch {
          let e = CommandError(.preconditionFailed, tr("保存できません: %@", error.localizedDescription))
          lastError = e; return .failure(e)
        }
        buffers.language.save(root + "/" + p, root: root)
        // A language server formats asynchronously: save what it returns as a second write.
        if formatting, !DocumentFormatter.supports(p) { formatWithServer(p, root: root, thenSave: true) }
      }
      let closing =
        id == "pane.close" ? Self.terminalKey(root: activeRoot ?? state.project, pane: state.tree.focused)
        : { () -> String? in if id == "agent.close", case .string(let key)? = input["key"] { key } else { nil } }()
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
        if previousEditor.0 != state.project || previousEditor.1 != state.active { state.editorContext = nil }
        lastError = nil
        if id == "pane.focus", case .int(let pane)? = input["id"] {
          state.notices.markRead(project: state.project, pane: pane)
        }
        // `clair open` / Finder usually come while another app is in front: bring the file into view.
        if id == "file.open" || id == "file.preview" {
          NSApp?.activate(ignoringOtherApps: true)
          if let w = NSApp?.windows.first(where: { $0.isMiniaturized && $0.title != "Pair a device" }) { w.deminiaturize(nil) }
        }
        if id == "file.open", case .int(let line)? = input["line"], let p = state.active {
          let column: Int = if case .int(let c)? = input["column"] { c } else { 0 }
          buffers.reveal(p, line: line, column: column)
        }
        if id == "editor.definition" || id == "editor.references" { navigate(references: id == "editor.references") }
        if id == "editor.navigateBack" || id == "editor.navigateForward", let to = state.navigation.current, let p = state.active {
          buffers.reveal(p, line: to.line, column: to.column)
        }
        if id.hasPrefix("debug.") { runDebugCommand(id, input) }
        if ["cli.install", "skill.install", "cli.uninstall", "skill.uninstall", "claudeEditor.install", "claudeEditor.uninstall"].contains(id) {
          Self.install(String(id.prefix { $0 != "." }), remove: id.hasSuffix("uninstall"))
        }
        if let view = state.active.flatMap(buffers.view) {
          switch id {
          case "editor.fold": view.foldAtCaret()
          case "editor.unfold": view.unfoldAtCaret()
          case "editor.foldAll": view.foldAll()
          case "editor.unfoldAll": view.unfoldAll()
          default: break
          }
        }
        if id == "editor.format", let p = state.active {
          if DocumentFormatter.supports(p) { formatBuffer(p) } else if let root = activeRoot { formatWithServer(p, root: root, thenSave: false) }
        }
        if let p = state.active, let features = buffers.features(p) {
          switch id {
          case "editor.hover": features.hoverAtCaret()
          case "editor.rename": features.rename()
          case "editor.codeAction": features.codeActions()
          default: break
          }
        }
        if id == "editor.fileSymbols" { showFileSymbols() }
        if id == "editor.problems" { showProblems() }
        if id == "project.choose" { chooseProject() }
        if id == "agent.mention" { mentionSelectionToClaude() }
        if id == "agent.ask" { askAgentAboutSelection() }
        if id == "terminal.askAgent" { askAgentAboutTerminalSelection() }
        // Closing a proposal's tab answers Claude Code's waiting openDiff as rejected (ADR-0022).
        if id == "diff.close", case .string(let proposal)? = input["proposal"], proposals[proposal] != nil { closeProposal(proposal) }
        if id.hasPrefix("project.") { refreshClaudeLock() }
        if let closing { ClairDaemonLauncher.closeSession(key: closing); ClairGhosttySurfaceView.discard(key: closing) }  // T09: closing a pane ends its shell; closing a window does not
        if id == "agent.launch" || id == "pane.close" || id == "agent.close"
          || (id == "settings.set" && input["key"] == .string("preventSleepOnBattery"))
        { refreshSleepAssertion() }
        if id == "window.restart" { windowGeneration += 1 }
        if id == "app.restart" { restartApp() }
        watchProject()
        persistState()
      }
      // Agent-context commands: the registry validated the call; the answer comes from the GUI's live state.
      if case .success = r, let answer = answerAgentContext(id, input) {
        if case .failure(let e) = answer { lastError = e }
        return answer
      }
      return r
    }

    private func restartApp() {
      guard state.dirty.isEmpty, state.layouts.values.allSatisfy({ $0.dirty.isEmpty }) else {
        let alert = NSAlert()
        alert.messageText = tr("未保存の変更があります")
        alert.informativeText = tr("変更を保存してからアプリを再起動してください。")
        alert.runModal()
        return
      }
      guard let executable = Bundle.main.executableURL else { return }
      let launch: [String]
      if ProcessInfo.processInfo.environment["CLAIR_DEV_SUPERVISED"] != nil {
        launch = [executable.path]
      } else if Bundle.main.bundleURL.pathExtension == "app" {
        launch = ["/usr/bin/open", "-n", "-a", Bundle.main.bundleURL.path]
      } else {
        launch = [executable.path]
      }
      persistenceTask?.cancel()
      do {
        if let persistURL { try state.save(to: persistURL) }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; shift; exec \"$@\"", "clair-restart", String(ProcessInfo.processInfo.processIdentifier)] + launch
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        if let handoff = ProcessInfo.processInfo.environment["CLAIR_DEV_RESTART_PID_FILE"] {
          do {
            try String(helper.processIdentifier).write(toFile: handoff, atomically: true, encoding: .utf8)
          } catch {
            helper.terminate()
            throw error
          }
        }
        ClairDaemonLauncher.keepsSessionsOnQuit = true
        NSApp.terminate(nil)
      } catch {
        let alert = NSAlert()
        alert.messageText = tr("アプリを再起動できませんでした")
        alert.informativeText = error.localizedDescription
        alert.runModal()
      }
    }

    /// ⌘K install rows: the result is an alert because the palette has already closed (the settings rows show it inline).
    private static func install(_ kind: String, remove: Bool) {
      Task.detached {
        let what = kind == "cli" ? tr("clair コマンド") : kind == "skill" ? "Agent skill" : tr("Ctrl+G の editor 設定")
        let verb = remove ? tr("アンインストール") : tr("インストール")
        let message: String
        do {
          switch (kind, remove) {
          case ("cli", false): try ClairDaemonLauncher.installCommand()
          case ("cli", true): try ClairDaemonLauncher.uninstallCommand()
          case ("skill", false): try ClairSkills.install()
          case ("skill", true): try ClairSkills.uninstall()
          case (_, false): try ClairClaudeEditor.install()
          case (_, true): try ClairClaudeEditor.uninstall()
          }
          message = tr("%@を%@しました。", what, verb)
        } catch { message = tr("%@を%@できません: %@", what, verb, error.localizedDescription) }
        await MainActor.run {
          let alert = NSAlert()
          alert.messageText = message
          alert.runModal()
        }
      }
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
    var languageNotice: String?

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
      let at = try? m.buffer.snapshot.position(at: caret, columnUnit: UTF16Unit.self, rounding: .down)
      let from = EditorLocation(path: path, line: (at?.line.value ?? 0) + 1, column: at?.column.value ?? 0)
      guard EditorLanguageID.detect(path: rel)?.languageServer != nil else {
        languageNotice = tr("このファイルの言語サーバーはありません")
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
            ? tr("言語サーバーが応答しません") : (references ? tr("参照が見つかりません") : tr("定義が見つかりません"))
          return
        }
        // E17: several definitions are listed like references; the history records direct jumps only.
        // ponytail: a definition picked from that list is not added to ⌃- history; record it in file.open if missed.
        if references || found.count > 1 {
          languageItems = found.map { item($0, root: root) }
          run("palette.references")
        } else {
          let target = found[0]
          state.navigation.jump(from: from, to: EditorLocation(path: target.path, line: target.line + 1, column: target.character))
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
      if id == "pane.close", let target = state.activeDiff {
        var input: CommandInput = ["path": .string(target.path), "staged": .bool(target.staged), "untracked": .bool(target.untracked)]
        if let against = target.against { input["against"] = .string(against) }
        if let proposal = target.proposal { input["proposal"] = .string(proposal) }
        _ = run("diff.close", input)
        return
      }
      // Nothing but the empty editor (or the home screen) left: ⌘W quits like ⌘Q, confirmation included.
      if id == "pane.close", state.panesClosed || (state.active == nil && state.tree.leaves.map(\.kind) == [.editor]) {
        NSApp.terminate(nil); return
      }
      if id == "pane.close", state.tree.leaves.first?.id != state.tree.focused,
        state.tree.leaves.first(where: { $0.id == state.tree.focused })?.kind == .editor {
        _ = run("pane.close"); return  // a split editor: ⌘W closes the split, not the shared tab
      }
      if id == "pane.close", state.tree.leaves.first(where: { $0.id == state.tree.focused })?.kind == .editor {
        _ = run(state.active != nil ? "tab.close" : "pane.close")
        return
      }
      guard id == "file.save" else { _ = run(id, input, confirmed: id == "app.restart"); return }
      Task { await saveActiveFile() }
    }

    /// A click on a home-screen row: when the command opens a new pane, the empty editor makes way for it.
    func performFromHome(_ id: String) {
      let before = Set(state.tree.leaves.map(\.id))
      performFromUI(id)
      guard state.active == nil, !state.panesClosed, state.tree.leaves.contains(where: { !before.contains($0.id) }),
        let editor = state.tree.leaves.first(where: { $0.kind == .editor })?.id else { return }
      let opened = state.tree.focused
      _ = run("pane.focus", ["id": .int(editor)])
      _ = run("pane.close")
      _ = run("pane.focus", ["id": .int(opened)])
    }

    /// Runs Git commands through the same typed registry as CLI/MCP without blocking SwiftUI.
    /// A click on an explicitly labelled Pull/Push control is the native confirmation for its
    /// external risk; non-UI callers still have to pass the registry confirmation gate.
    func performGitFromUI(_ commands: [(String, CommandInput)], confirmed: Bool = false) async -> String? {
      guard let root = activeRoot else { return tr("Git Project ではありません。") }
      let project = state.project
      let snapshot = state
      let registry = registry
      let changesWorkingTree = commands.contains { $0.0 == "git.switch" || $0.0 == "git.pull" || $0.0 == "git.discard" }
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
      guard let path = state.active else { _ = run("file.save"); return }
      _ = await saveFile(path)
    }

    /// Save the file shown in a diff editor, which may differ from the active tab.
    func saveFile(_ path: String) async -> Bool {
      guard let root = activeRoot, case .ready(let manager)? = buffers.peek(path) else {
        lastError = CommandError(.preconditionFailed, tr("保存できません: ファイルを開けません。"))
        return false
      }
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
        return true
      case .failure(let error):
        lastError = CommandError(.preconditionFailed, tr("保存できません: %@", error.localizedDescription))
        return false
      }
    }

    /// Names the daemon shell behind one terminal pane. Keyed on the project path, not its name, so two
    /// projects with the same folder name never share a shell.
    static func terminalKey(root: String, pane: Int) -> String { "\(root)#\(pane)" }

    var activeRoot: String? { state.projects.first { $0.name == state.project }?.path }

    /// U05: called by the editor surface on every committed edit.
    func edited(_ path: String) {
      state.dirty.insert(path)
      if state.active == path { state.editorContext = nil }
    }  // the GUI owns dirty; never persisted (principle 8)

    /// `editor.format`, and ⌘S when 保存時に整形 is on. Reformats the buffer outside the live view's
    /// own edit path, the way `ClairMarkdownPreview`'s table commit does: `buffers.refresh` rebuilds
    /// the on-screen surface from the buffer afterward. No-op for an unsupported format, or one already
    /// formatted (so it never manufactures a no-op undo step or a spurious dirty mark).
    /// Paths whose server-formatted text is being saved, so that save does not format again.
    private var savingFormatted: Set<String> = []

    /// `textDocument/formatting` into the buffer as one undo unit (through the view when it is live, so the server and
    /// highlighting see it like typing). With `thenSave` (format on save) a changed buffer is saved again.
    private func formatWithServer(_ path: String, root: String, thenSave: Bool) {
      guard EditorLanguageID.detect(path: path)?.languageServer != nil else {
        if !thenSave { languageNotice = tr("このファイルの言語サーバーはありません") }
        return
      }
      let tab = Int(state.choices["tabWidth"] ?? "") ?? 4
      Task {
        guard let (edits, snapshot) = await buffers.language.format(root + "/" + path, root: root, tabSize: tab, insertSpaces: true) else {
          if !thenSave { languageNotice = tr("言語サーバーはこのファイルを整形できません") }
          return
        }
        guard !edits.isEmpty, activeRoot == root, case .ready(let m)? = buffers.peek(path), m.buffer.snapshot.revision == snapshot.revision
        else { return }
        commit(edits, to: path, manager: m, label: tr("ドキュメントの整形"))
        guard thenSave, state.active == path else { return }
        savingFormatted.insert(path)
        _ = run("file.save")
        savingFormatted.remove(path)
      }
    }

    /// One transaction on an open buffer: through its live view (undo, server, highlight, split mirrors), else straight
    /// into the buffer with the surface rebuilt from it.
    private func commit(_ edits: [TextEdit], to path: String, manager m: EditorTransactionManager, label: String? = nil) {
      if let view = buffers.view(path), view.snapshot.revision == m.buffer.snapshot.revision, let typed = view.onCommitEdits {
        typed(edits)
        return
      }
      guard (try? m.apply(edits, label: label)) != nil else { return }
      buffers.refresh(path)
      edited(path)
    }

    /// Applies a language server's workspace edit (rename, a code action): open buffers of the active Project take it
    /// as an unsaved transaction; every other file is rewritten on disk (the watcher then refreshes the tree).
    /// All-or-nothing per file; false when any file could not take its edits.
    func applyWorkspaceEdit(_ edit: LanguageServerWorkspaceEdit) -> Bool {
      guard !edit.unsupported else { return false }
      var ok = true
      for (absolute, changes) in edit.files where !changes.isEmpty {
        if let root = activeRoot, absolute.hasPrefix(root + "/") {
          let rel = String(absolute.dropFirst(root.count + 1))
          if case .ready(let m)? = buffers.peek(rel) {
            guard let edits = LanguageServerTextEdit.editorEdits(changes, in: m.buffer.snapshot) else { ok = false; continue }
            commit(edits, to: rel, manager: m)
            continue
          }
        }
        guard let text = try? String(contentsOfFile: absolute, encoding: .utf8),
          let updated = LanguageServerTextEdit.apply(changes, to: text),
          (try? updated.write(toFile: absolute, atomically: true, encoding: .utf8)) != nil
        else { ok = false; continue }
      }
      return ok
    }

    /// Types `text` into this Project's running agent terminal and focuses it. No Return: the user reviews and sends.
    /// Without a running agent the request goes to the clipboard instead.
    func askAgent(_ text: String, exceptPane: Int? = nil) {
      let agents = state.agentSessions.filter { $0.project == state.project && !$0.status.isExited }
      guard let agent = agents.first(where: { $0.pane != exceptPane }) ?? agents.first,
        ClairGhosttySurfaceView.send(text, toPane: agent.pane)
      else {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        languageNotice = tr("実行中の Agent がありません。依頼文をコピーしました")
        return
      }
      languageNotice = nil
      run("pane.focus", ["id": .int(agent.pane)])
    }

    /// `agent.ask`: the editor selection as an `@file#Lstart-end` reference (the whole file without a selection).
    private func askAgentAboutSelection() {
      guard let rel = state.active else { return }
      guard let c = state.editorContext, c.selectedText != nil else { return askAgent("@\(rel) ") }
      askAgent(c.startLine == c.endLine ? "@\(rel)#L\(c.startLine) " : "@\(rel)#L\(c.startLine)-\(c.endLine) ")
    }

    /// `terminal.askAgent`: the focused terminal's selected output, pasted (bracketed) into another agent.
    private func askAgentAboutTerminalSelection() {
      let pane = state.tree.focused
      guard let text = ClairGhosttySurfaceView.selectedText(inPane: pane) else {
        languageNotice = tr("ターミナルで範囲を選択してください")
        return
      }
      askAgent("\u{1b}[200~" + tr("次のターミナル出力について調べてください:") + "\n" + text + "\u{1b}[201~", exceptPane: pane)
    }

    /// ⌘⇧O: the active file's symbols in the list palette.
    private func showFileSymbols() {
      guard let rel = state.active, let root = activeRoot else { return }
      guard EditorLanguageID.detect(path: rel)?.languageServer != nil else {
        languageNotice = tr("このファイルの言語サーバーはありません")
        return
      }
      Task {
        let symbols = await buffers.language.documentSymbols(root + "/" + rel, root: root)
        guard activeRoot == root, state.active == rel else { return }
        guard !symbols.isEmpty else { languageNotice = tr("シンボルが見つかりません"); return }
        languageNotice = nil
        languageItems = symbols.map {
          PaletteItem(
            title: String(repeating: "  ", count: min($0.depth, 6)) + $0.name, hint: "\(rel):\($0.line + 1)", id: "file.open",
            input: ["path": .string(root + "/" + rel), "line": .int($0.line + 1), "column": .int($0.character)], detail: $0.detail ?? "")
        }
        run("palette.references")
      }
    }

    /// ⌘⇧N / the titlebar "+": pick any folder and open it as a Project.
    private func chooseProject() {
      let panel = NSOpenPanel()
      panel.canChooseFiles = false; panel.canChooseDirectories = true
      if panel.runModal() == .OK, let url = panel.url { run("project.open", ["path": .string(url.path)]) }
    }

    /// ⌘⇧M: every diagnostic of the active Project's open documents, errors first.
    private func showProblems() {
      guard let root = activeRoot else { return }
      let order = ["error": 0, "warning": 1, "information": 2, "hint": 3]
      let all = agentDiagnostics(in: root, path: nil).sorted {
        (order[$0.severity] ?? 4, $0.path, $0.line) < (order[$1.severity] ?? 4, $1.path, $1.line)
      }
      guard !all.isEmpty else { languageNotice = tr("問題はありません"); return }
      languageNotice = nil
      let mark = ["error": "✕", "warning": "⚠︎", "information": "ⓘ", "hint": "·"]
      languageItems = all.prefix(500).map { d in
        let rel = d.path.hasPrefix(root + "/") ? String(d.path.dropFirst(root.count + 1)) : d.path
        return PaletteItem(
          title: "\(mark[d.severity] ?? "·") \(d.message.split(separator: "\n").first.map(String.init) ?? d.message)",
          hint: "\(rel):\(d.line)", id: "file.open",
          input: ["path": .string(d.path), "line": .int(d.line), "column": .int(d.column)])
      }
      run("palette.references")
    }

    private func formatBuffer(_ path: String) {
      guard case .ready(let m)? = buffers.peek(path) else { return }
      let old = m.buffer.snapshot
      let text = old.string()
      guard let formatted = DocumentFormatter.format(path, text), formatted != text else { return }
      guard (try? m.apply([TextEdit(range: old.fullRange, replacement: formatted)], label: tr("ドキュメントの整形"))) != nil else { return }
      buffers.refresh(path)
      edited(path)
    }

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
      let project = state.projects.first { $0.name == state.project }
      let folders = project?.folders ?? []
      let key = ([state.project] + folders).joined(separator: "\0")  // adding/removing a folder re-watches
      guard watched != key else { return }
      let first = watched.isEmpty
      watched = key
      scanGeneration += 1
      let generation = scanGeneration
      guard let root = project?.path else { watcher = nil; return }
      watcher = FileWatcher(root: root, folders: folders) { [weak self] paths in
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
    /// Bumped when a watched `.git/` file changes, so the Git view reloads even when the file list is unchanged (a branch switch).
    private(set) var gitRevision = 0
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
      let folders = state.projects.first { $0.path == root }?.folders ?? []
      DispatchQueue.global(qos: .utility).async { [weak self] in
        let files = (self?.scanFiles(root) ?? []) + WorkbenchFiles.scanFolders(folders, from: root)
        DispatchQueue.main.async {
          guard let self else { return }
          self.scanning = false
          if generation == self.scanGeneration, root == self.activeRoot,
            self.gitFilesystemMutationRoot != root
          {
            let changed = preserveDirty ? paths.subtracting(self.state.dirty) : paths
            self.state.applyDiskChange(changed, files: files)
            if paths.contains(where: { FileWatcher.isGitState($0) }) { self.gitRevision += 1 }
            self.buffers.drop(changed)
            if let active = self.state.active, changed.contains(active) { self.state.editorContext = nil }
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

    public func title(pane: Int, _ title: String) {
      let key = NotificationLog.paneKey(state.project, pane)
      if state.paneTitles[key] != title { state.paneTitles[key] = title }
    }

    /// Only facts from an agent running in a Clair terminal can produce a macOS notification.
    private var lastAgentNotification: (key: String, body: String, at: Date)?

    public func facts(pane: Int, bells: Int, exit: Int?, notification: (title: String, body: String)?) {
      guard let agent = state.agentLaunch(in: state.project, pane: pane) else { return }
      // Agents may emit the same desktop notification over both OSC 9 and OSC 777.
      if exit == nil, let notification {
        let key = NotificationLog.paneKey(state.project, pane)
        if let last = lastAgentNotification, last.key == key, last.body == notification.body, Date().timeIntervalSince(last.at) < 2 { return }
        lastAgentNotification = (key, notification.body, Date())
      }
      let agentName = AgentProfile.named(agent.profile)?.title ?? agent.profile
      let oscTitle = state.paneTitles[NotificationLog.paneKey(state.project, pane)]
      let sessionTitle = oscTitle.flatMap { $0.isEmpty || $0 == (agent.cwd as NSString).lastPathComponent ? nil : $0 } ?? tr("%@ · ターミナル %@", agentName, pane)
      // Only this GUI writes facts (no command records them), so an agent cannot fabricate notifications.
      // History and badges always record; the toggles below only gate the macOS alert.
      var fresh: WorkbenchNotice?
      if bells > 0, let n = state.notices.record(project: state.project, pane: pane, kind: .bell, sourceTitle: notification?.title, sourceBody: notification?.body, sessionTitle: sessionTitle), state.toggles["notifyOnBell"] != false { fresh = n }
      if let exit, let n = state.notices.record(project: state.project, pane: pane, kind: .exited, exitCode: exit, sessionTitle: sessionTitle), state.toggles["notifyOnExit"] != false { fresh = n }
      refreshSleepAssertion()
      guard let n = fresh, state.toggles["notifyEnabled"] != false, !NSApp.isActive || state.toggles["notifyWhenActive"] == true else { return }
      deliverNotification(title: n.sessionTitle ?? agentName, subtitle: tr("%@ · %@ · ターミナル %@ · %@", n.project, agentName, n.pane, n.title), body: n.sourceBody ?? "", id: "clair-\(n.id)") { _ in }
    }

    /// Settings → 通知 → テスト. Ignores the enable/foreground toggles so the path can always be checked; `done(false)` = not allowed or not an app bundle.
    public func sendTestNotification(done: @escaping @MainActor (Bool) -> Void) {
      deliverNotification(title: "Clair", subtitle: tr("テスト通知"), body: tr("通知は正しく届いています。"), id: "clair-test-\(UUID().uuidString)", done: done)
    }

    private func deliverNotification(title: String, subtitle: String, body: String, id: String, done: @escaping @MainActor (Bool) -> Void) {
      guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil  // UNUserNotificationCenter traps outside an app bundle (swift run / XCTest)
      else { done(false); return }
      let sound = state.toggles["notifySound"] == true
      let c = UNUserNotificationCenter.current()
      c.delegate = ClairNotificationPresenter.shared  // without it a foreground app shows nothing
      c.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        guard granted else { DispatchQueue.main.async { MainActor.assumeIsolated { done(false) } }; return }
        let m = UNMutableNotificationContent()
        m.title = title; m.subtitle = subtitle; m.body = body
        if sound { m.sound = .default }
        c.add(UNNotificationRequest(identifier: id, content: m, trigger: nil)) { err in
          DispatchQueue.main.async { MainActor.assumeIsolated { done(err == nil) } }
        }
      }
    }

    /// V03: an AI call at write-or-above risk waits here (IPC thread, never main) for a native
    /// approval. No answer within `timeout` is a denial.
    public var mcpApproval: (id: String, input: CommandInput, risk: CommandRisk)?
    public private(set) var mcpApprovalDeadline = Date()
    private var mcpDecision: DispatchSemaphore?
    private var mcpApproved = false

    /// V16: approving an agent.launch from a terminal lets that same terminal fan out more agents for 10 minutes,
    /// so "3 parallel children" is one card, not three.
    // ponytail: the card does not say so yet; show the grant on the card when U07 reworks approval UI.
    private var fanOutGrants: [String: Date] = [:]
    nonisolated func approve(_ id: String, _ input: CommandInput, _ risk: CommandRisk, caller: String?) -> Bool {
      let fanOut = id == "agent.launch" ? caller : nil
      if let fanOut, DispatchQueue.main.sync(execute: { MainActor.assumeIsolated { fanOutGrants[fanOut].map { $0 > Date() } ?? false } }) {
        return true
      }
      let ok = requestMCPApproval(id, input, risk)
      if ok, let fanOut { DispatchQueue.main.sync { MainActor.assumeIsolated { fanOutGrants[fanOut] = Date().addingTimeInterval(600) } } }
      return ok
    }

    /// One card at a time: a concurrent request waits its turn (its 60 s starts when its card shows) instead of overwriting the visible card.
    private nonisolated let mcpSlot = DispatchSemaphore(value: 1)

    nonisolated func requestMCPApproval(_ id: String, _ input: CommandInput, _ risk: CommandRisk, timeout: TimeInterval = 60) -> Bool {
      mcpSlot.wait()
      defer { mcpSlot.signal() }
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
      CommandGroup(replacing: .appSettings) { items(.settings) }
      CommandGroup(after: .newItem) { items(.file) }
      CommandGroup(after: .textEditing) { items(.edit) }
      CommandGroup(after: .toolbar) { items(.view) }
      CommandMenu(tr("Pane")) {
        items(.go)
        // Ctrl-Tab is the conventional tab cycle; unclaimed, AppKit only walks the focus ring over the tab buttons.
        Button(tr("Next Tab")) { store?.performFromUI("tab.next") }
          .keyboardShortcut(.tab, modifiers: .control).disabled(store == nil)
        Button(tr("Previous Tab")) { store?.performFromUI("tab.previous") }
          .keyboardShortcut(.tab, modifiers: [.control, .shift]).disabled(store == nil)
      }
    }

    enum Menu { case settings, file, edit, view, go }

    /// Which standard menu a registry command lives in; anything unlisted falls into View.
    static func menu(_ id: String) -> Menu {
      if id == "settings.open" { return .settings }
      if id.hasPrefix("file.") || id.hasPrefix("project.")
        || ["window.restart", "app.restart", "tab.reopenClosed", "tab.close", "pane.close", "palette.recent", "palette.compare"].contains(id) { return .file }
      if id.hasPrefix("editor.fold") || id.hasPrefix("editor.unfold")
        || ["palette.find", "palette.search", "editor.format", "editor.codeAction", "editor.rename"].contains(id) { return .edit }
      if id.hasPrefix("editor.navigate") || id.hasPrefix("pane.focus")
        || ["editor.definition", "editor.references", "palette.files", "palette.symbols", "palette.references", "editor.fileSymbols", "editor.problems",
            "tab.next", "tab.previous", "tab.activate"].contains(id) { return .go }
      return .view
    }

    /// Menu-bar titles follow macOS English menus; the palette keeps the registry's titles.
    static let titles: [String: String] = [
      "settings.open": "Settings…", "file.save": "Save", "tab.reopenClosed": "Reopen Closed Tab",
      "project.choose": "Open Project…", "pane.close": "Close Tab or Pane", "palette.recent": "Open Recent…", "palette.compare": "Compare With…",
      "window.restart": "Restart Window", "editor.zoomIn": "Zoom In", "editor.zoomInAlt": "Zoom In", "editor.zoomOut": "Zoom Out", "app.restart": "Restart App",
      "palette.find": "Find", "palette.search": "Find in Project", "editor.format": "Format Document",
      "editor.fold": "Fold", "editor.unfold": "Unfold", "editor.foldAll": "Fold All", "editor.unfoldAll": "Unfold All",
      "sidebar.toggle": "Toggle Sidebar", "palette.commands": "Command Palette", "palette.commandsAlt": "Command Palette",
      "pane.splitRight": "Split Right", "pane.splitDown": "Split Down", "pane.maximize": "Maximize Pane",
      "pane.equalize": "Equalize Panes", "terminal.show": "Show Terminal", "editor.toggleWrap": "Toggle Word Wrap",
      "editor.markdownPreview": "Open Preview", "editor.definition": "Go to Definition",
      "editor.references": "Find References", "editor.navigateBack": "Go Back", "editor.navigateForward": "Go Forward",
      "palette.files": "Go to File…", "palette.symbols": "Go to Symbol…", "palette.references": "Find References…",
      "editor.codeAction": "Quick Fix…", "editor.rename": "Rename Symbol", "editor.fileSymbols": "Go to Symbol in File…",
      "editor.problems": "Show Problems", "editor.hover": "Show Hover", "agent.mention": "Send Selection to Claude Code",
      "tab.next": "Next Tab", "tab.previous": "Previous Tab", "pane.focusNext": "Focus Next Pane",
      "pane.focusPrevious": "Focus Previous Pane",
    ]

    @ViewBuilder private func items(_ m: Menu) -> some View {
      let state = store?.state ?? WorkbenchState()
      ForEach(CommandRegistry.workbench.commands.filter { Self.menu($0.id) == m && state.shortcut(for: $0) != nil }, id: \.id) { d in
        Button(tr(Self.titles[d.id] ?? d.title)) { store?.performFromUI(d.id) }
          .keyboardShortcut(Self.shortcut(state.shortcut(for: d)!))
          .disabled(store == nil)
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

  /// Keep the workbench owner alive while SwiftUI rebuilds this window's views.
  public struct ClairWindowRoot: View {
    @State private var store = ClairWorkbenchStore()

    public init() {}

    public var body: some View {
      ClairAppShell(store: store).id(store.windowGeneration)
    }
  }

  /// U04: AppShell chrome (checklist §3) — titlebar 48 + sidebar 286 + main +
  /// status 26. Built once; only sidebar panel and main are swapped. Pane
  /// contents other than the terminal are placeholders owned by U05/U06.
  public struct ClairAppShell: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var store: ClairWorkbenchStore
    @State private var draggingPane: Int?
    @State private var integrationNotes: [String: String] = [:]  // V16: last install result per row
    private var st: WorkbenchState { store.state }
    @State private var query = ""
    @FocusState private var paletteFocused: Bool
    @State private var selection = 0
    // U05: sidebar mode + source-control view. GUI-local (no command); the stage buttons go through git.stage/unstage.
    @State private var sidebarMode = "folder"
    @AppStorage("clair.sidebarWidth") private var sidebarWidth = 242.0
    @State private var debugMode = "debug"
    @State private var debugPID = ""
    struct AssociationDraft: Identifiable, Equatable { let id = UUID(); var ext: String; var lang: String }
    @State private var associationRows: [AssociationDraft] = []
    @State private var notificationTestResult: String?
    @State private var quota: [ProviderQuota] = []
    @State private var quotaHovered = false
    @State private var noticesOpen = false
    @State private var collapsedGroups: Set<String> = []
    @State private var groupDropTarget: String?
    @State private var hoveredGroup: String?
    @State private var rootFolded = false
    @State private var menus = ClairMenuController()
    @State private var changes: [GitChange] = []
    /// nil until the first `git status` for the active root lands; false when it failed.
    @State private var changesLoaded: Bool?
    @State private var branch: String?
    @State private var branches: [String] = []
    @State private var sync: (behind: Int, ahead: Int)?
    @State private var changesTask: Task<Void, Never>?
    @State private var gitOperation: String?
    @State private var gitMessage: String?
    @State private var gitFailed = false
    @State private var reviewError: String?
    @State private var diff: DiffTarget?
    @State private var chat: AgentHistory?
    @State private var loadedDiff: LoadedDiff?
    /// Left side of a two-file compare, picked from a file menu ("比較対象として選択").
    @State private var compareBase: String?
    @State private var diffTask: Task<Void, Never>?
    @State private var explorerRows: [ExplorerRow] = []
    @State private var visibleExplorerRows: [ExplorerRow] = []
    /// `changeRanks` cached per files/dirty change, not recomputed on every body render.
    @State private var explorerRanks: [String: Int] = [:]
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
    /// A Project without a picked colour cycles these by position.
    private let projectColors: [DesignTokens.GroupColor] = [.blue, .green, .amber]

    public init() { _store = State(initialValue: ClairWorkbenchStore()) }
    /// Snapshot tests inject a fixture store.
    init(store: ClairWorkbenchStore) { _store = State(initialValue: store) }

    @ViewBuilder private var pendingActions: some View {
      if store.pending?.id == "debug.restart" { Button(tr("再起動")) { store.confirm() } }
      else { Button(tr("破棄して続行"), role: .destructive) { store.confirm() } }
    }

    private var pendingTitle: String {
      store.pending?.id == "debug.restart" ? tr("デバッグを再起動しますか？") : tr("未保存の変更を破棄しますか？")
    }

    public var body: some View {
      VStack(spacing: 0) {
        // Mock `sheet` motion: settings comes over the top (scale 1.04 → 1 + fade).
        // Settings covers the workbench instead of replacing it: tearing the
        // workbench down destroyed every terminal surface and its scrollback.
        ZStack {
          VStack(spacing: 0) {
            titlebar
            HStack(spacing: 0) {
              activityBar
              if !st.sidebarHidden {
                sidebar
                Rectangle().fill(C.surfaceActive).frame(width: 1)
              }
              main
            }
          }
          .allowsHitTesting(!st.settingsOpen)
          .accessibilityHidden(st.settingsOpen)
          if st.settingsOpen {
            VStack(spacing: 0) {
              settingsHeader
              HStack(spacing: 0) {
                settingsPanel
                Rectangle().fill(L.hairline).frame(width: 1)
                settingsMain
              }
            }
            .background(C.canvas)
            .background(ResignWorkbenchFocus())
            .transition(.opacity.combined(with: .scale(scale: 1.04)))
            // A ZStack child being removed loses its place on top, so closing played behind the workbench (unseen).
            .zIndex(1)
          }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.screenDuration), value: st.settingsOpen)
        statusBar
      }
      .background(C.canvas)
      .frame(minWidth: 900, minHeight: 560)
      .clairMenuHost(menus)
      .overlay {
        if st.palette == .search { searchOverlay }
        else if let p = st.palette { paletteView(p) }
      }
      .animation(.easeOut(duration: 0.09), value: st.palette == nil)
      .overlay(alignment: .bottomTrailing) { updateToast.padding(.trailing, 16).padding(.bottom, ChromeBudget.statusBar + 12) }
      .animation(reduceMotion ? nil : .easeOut(duration: Motion.overlayDuration), value: store.update)
      .onChange(of: st.choices["appearance"], initial: true) { _, v in ColorSchemeChoice(setting: v).apply() }
      .onChange(of: st.fileAssociations, initial: true) { _, v in EditorLanguageID.associations = v }
      .onChange(of: terminalStyle, initial: true) { _, v in ClairGhosttySurfaceView.style = v }
      .onChange(of: st.palette) {
        query = ""; selection = 0
        if st.palette == .search { searchSelection = 0; runSearch() }
      }
      .onChange(of: st.debugNavigationGeneration) { sidebarMode = "ladybug" }
      // A file opened while the concierge chat covers the panes would land hidden behind it.
      .onChange(of: st.active) { if sidebarMode == "concierge" { leaveConcierge() } }
      .onChange(of: store.debugSession?.frames.first) { _, frame in
        if sidebarMode == "ladybug", let frame { openDebugFrame(frame) }
      }
      .onChange(of: st.project) {
        diff = st.activeDiff.map { DiffTarget(path: $0.path, staged: $0.staged, untracked: $0.untracked, against: $0.against, proposal: $0.proposal) }
        loadedDiff = nil; gitMessage = nil; gitFailed = false
        rebuildExplorer(); reloadChanges()
      }
      .onChange(of: st.files) { rebuildExplorer(); reloadChanges() }
      .onChange(of: st.expanded) { rebuildVisibleExplorer() }
      .onChange(of: st.activeDiff) {
        diff = st.activeDiff.map { DiffTarget(path: $0.path, staged: $0.staged, untracked: $0.untracked, against: $0.against, proposal: $0.proposal) }
      }
      .onChange(of: diff) { loadDiff() }
      .onAppear {
        diff = st.activeDiff.map { DiffTarget(path: $0.path, staged: $0.staged, untracked: $0.untracked, against: $0.against, proposal: $0.proposal) }
        rebuildExplorer(); reloadChanges()
      }
      .task {
        while !Task.isCancelled {
          await store.refreshDetectedAgents()
          try? await Task.sleep(for: .seconds(2))
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ClairCloseFocusedPaneShortcut"))) { _ in
        // An open history chat covers the panes, so ⌘W closes it first, like its ✕ button.
        if chat != nil { chat = nil; return }
        store.performFromUI("pane.close")
      }
      .focusedSceneValue(\.clairWorkbench, store)
      .confirmationDialog(
        Text(pendingTitle), isPresented: Binding(get: { store.pending != nil }, set: { if !$0 { store.pending = nil } })
      ) { pendingActions }
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
                projectGroup(p, colorKey: p.color.flatMap { DesignTokens.GroupColor.resolve($0) == nil ? nil : $0 } ?? projectColors[i % projectColors.count].rawValue)
              }
              Button { store.run("project.choose") } label: { Image(systemName: "plus").font(.system(size: 13)).foregroundStyle(C.chromeInk).frame(width: 30, height: 30) }
                .buttonStyle(.hoverWash).help(tr("フォルダを開く"))
            }
            .frame(minWidth: g.size.width, minHeight: g.size.height, alignment: .leading)
            .background(TitlebarArea())
          }
        }
        HStack(spacing: 4) {
          Button { store.run("palette.search") } label: {
            HStack(spacing: 4) {
              Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(C.textQuaternary)
              Text(tr("ファイル、シンボル")).font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
              Spacer(minLength: 0)
              Text("⌘⇧F").font(Typography.font(Typography.chrome)).foregroundStyle(C.textQuaternary)
            }
            .padding(.horizontal, 8).frame(width: 200, height: 28)
            .background(C.chrome, in: RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(L.hairlineFaint))
          }.buttonStyle(.hoverWash).help(tr("検索"))
          titlebarAction("command", tr("コマンドパレット"), on: st.palette == .commands) { store.run("palette.commands") }
          titlebarAction("gearshape", tr("設定"), on: st.settingsOpen) { store.run(st.settingsOpen ? "settings.close" : "settings.open") }
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

    private static func groupHelp(_ name: String, active: Bool, folded: Bool) -> String {
      guard active else { return tr("%@ に切り替え", name) }
      return folded ? tr("%@ タブグループを展開", name) : tr("%@ タブグループを折りたたむ", name)
    }

    /// An inactive group's chip switches to that Project (editor, terminals and sidebar follow `st.project`);
    /// the active group's chip toggles its tab strip (GUI-local).
    private func projectGroup(_ p: WorkbenchProject, colorKey: String) -> some View {
      let color = DesignTokens.GroupColor.resolve(colorKey) ?? DesignTokens.GroupColor.gray.color
      let active = st.project == p.name
      let tabs = active ? st.titlebarTabs : (st.layouts[p.name]?.titlebarTabs ?? [])
      let orderedTabs = tabs
      let selectedTab = active ? st.selectedTitlebarTab : nil
      let dirty = active ? st.dirty : (st.layouts[p.name]?.dirty ?? [])
      let folded = collapsedGroups.contains(p.name)
      let activate = {
        if !active { collapsedGroups.remove(p.name); store.run("project.switch", ["name": .string(p.name)]) }
        else {
          // Folding sucks the tabs back into the chip; unfolding pours them out of it.
          withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86)) {
            if folded { collapsedGroups.remove(p.name) } else { collapsedGroups.insert(p.name) }
          }
        }
      }
      return HStack(spacing: 0) {
        // Not a Button: a Button's press tracking swallows the drag, so the chip taps like a file tab does.
        Group {
          // The chip carries its group colour as its own fill/border (mock
          // review feedback: a small dot beside the label read as an
          // afterthought), not a separate dot — active groups get the
          // stronger alpha pair, matching the titlebar's active tab group.
          Text(p.displayName).font(.system(size: 12, weight: .semibold)).foregroundStyle(active ? C.textPrimary : C.textSecondary).lineLimit(1).fixedSize()
            .padding(.horizontal, 10).frame(height: 26)
            .background(color.opacity(active ? 0.22 : 0.1), in: RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(color.opacity(active ? 0.55 : 0.28)))
          .overlay(alignment: .topTrailing) {
            // Only agents waiting for input badge the chip; plain bells / exits stay in the notification popover.
            let waiting = st.agentSessions.filter { $0.project == p.name && $0.status == .attention }.count
            if waiting > 0 {
              Text("\(waiting)").font(.system(size: 9, weight: .bold)).foregroundStyle(C.textPrimary)
                .padding(.horizontal, 4).background(color, in: Capsule()).offset(x: 2, y: -4)
            }
          }
        }
        .overlay(hoveredGroup == p.name ? DesignTokens.Wash.selected : .clear, in: RoundedRectangle(cornerRadius: Radius.card))
        .contentShape(Rectangle())
        .onHover { hoveredGroup = $0 ? p.name : hoveredGroup == p.name ? nil : hoveredGroup }
        .onTapGesture(perform: activate)
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton).accessibilityAction(.default, activate)
        .help(Self.groupHelp(p.displayName, active: active, folded: folded))
        .background(NoWindowDrag())
        // Dropping a chip on another moves that Project's group into its place; the ring marks the drop target like a tab's.
        .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(groupDropTarget == p.name ? L.ring : .clear, lineWidth: 1))
        .onDrag { NSItemProvider(object: NSString(string: Self.groupDragPrefix + p.name)) }
        .onDrop(of: [.text], isTargeted: Binding(
          get: { groupDropTarget == p.name },
          set: { groupDropTarget = $0 ? p.name : groupDropTarget == p.name ? nil : groupDropTarget })) { providers in
          guard let provider = providers.first else { return false }
          provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = (object as? NSString).map({ $0 as String }), id.hasPrefix(Self.groupDragPrefix) else { return }
            Task { @MainActor in moveProject(String(id.dropFirst(Self.groupDragPrefix.count)), onto: p.name) }
          }
          return true
        }
        .clairContextMenu(menus) { projectMenu(p, colorKey: colorKey, folded: folded) }
        if !folded {
          HStack(spacing: 4) {
            ForEach(Array(orderedTabs.enumerated()), id: \.element) { i, tab in
              if i > 0 { Rectangle().fill(L.chromeSoft).frame(width: 1, height: 18) }
              switch tab {
              case .file(let path):
                fileTab(path, projectActive: active, project: p.name,
                  selected: selectedTab == tab, dirty: dirty.contains(path))
              case .terminal(let id), .graph(let id):
                let title = tab == .graph(id) ? tr("コミットグラフ") : terminalTabTitle(p.name, id)
                let agent = st.agentSessions.first { $0.project == p.name && $0.pane == id && !$0.status.isExited }
                FileTabButton(
                  path: tab.dragID, name: title, selected: selectedTab == tab, dirty: false,
                  onActivate: {
                    if !active { store.run("project.switch", ["name": .string(p.name)]) }
                    store.run("pane.focus", ["id": .int(id)])
                  },
                  onClose: {
                    if !active { store.run("project.switch", ["name": .string(p.name)]) }
                    store.run("pane.focus", ["id": .int(id)]); store.run("pane.close")
                  }, icon: tab == .graph(id) ? "point.3.connected.trianglepath.dotted" : "terminal",
                  providerIcon: tab == .graph(id) ? nil : agent?.title,
                  onMove: active ? { from in store.run("tab.reorder", ["source": .string(from), "target": .string(tab.dragID)]) } : nil)
                .help(title)
              case .diff(let target):
                FileTabButton(
                  path: tab.dragID,
                  name: target.proposal != nil ? tr("提案: %@", name(target.path))
                    : target.against.map { tr("比較: %@ ↔ %@", name($0), name(target.path)) } ?? tr("差分: %@", name(target.path)),
                  selected: selectedTab == tab, dirty: false,
                  onActivate: {
                    if !active { store.run("project.switch", ["name": .string(p.name)]) }
                    store.run("diff.activate", diffInput(target))
                  },
                  onClose: {
                    if !active { store.run("project.switch", ["name": .string(p.name)]) }
                    store.run("diff.close", diffInput(target))
                  }, icon: "square.split.2x1",
                  onMove: active ? { from in store.run("tab.reorder", ["source": .string(from), "target": .string(tab.dragID)]) } : nil)
                .help(target.path)
              }
            }
          }.padding(.leading, 4)
          .transition(reduceMotion ? .opacity : .scale(scale: 0.05, anchor: .leading).combined(with: .opacity))
        }
      }
    }

    /// Tabs drag their `dragID`; a group chip drags this prefix plus its Project name, so neither drop target takes the other.
    static let groupDragPrefix = "project-group:"

    /// Walks `project.move` one neighbour at a time until `name` sits where `target` was.
    private func moveProject(_ name: String, onto target: String) {
      guard let from = st.projects.firstIndex(where: { $0.name == name }),
        let to = st.projects.firstIndex(where: { $0.name == target }) else { return }
      for _ in 0..<abs(to - from) { store.run("project.move", ["name": .string(name), "offset": .int(to > from ? 1 : -1)]) }
    }

    private func diffInput(_ target: WorkbenchDiffTab) -> CommandInput {
      var input: CommandInput = ["path": .string(target.path), "staged": .bool(target.staged), "untracked": .bool(target.untracked)]
      if let against = target.against { input["against"] = .string(against) }
      if let proposal = target.proposal { input["proposal"] = .string(proposal) }
      return input
    }

    private func openDiff(_ target: DiffTarget) {
      store.run("diff.open", diffInput(WorkbenchDiffTab(path: target.path, staged: target.staged, untracked: target.untracked, against: target.against)))
    }

    private func closeDiff() {
      guard let target = st.activeDiff else { return }
      store.run("diff.close", diffInput(target))
    }

    /// The shell's OSC title; an agent whose title is just its folder name (Codex) shows its profile name instead.
    private func terminalTabTitle(_ project: String, _ pane: Int) -> String {
      let osc = st.paneTitles[NotificationLog.paneKey(project, pane)].flatMap { $0.isEmpty ? nil : $0 }
      guard let agent = st.agentSessions.first(where: { $0.project == project && $0.pane == pane }) else { return osc ?? "Terminal" }
      return osc.flatMap { $0 == (agent.cwd as NSString).lastPathComponent ? nil : $0 } ?? agent.title
    }

    private func fileTab(_ path: String, projectActive: Bool, project: String, selected: Bool, dirty: Bool) -> some View {
      FileTabButton(
        path: WorkbenchTab.file(path).dragID, name: name(path), selected: selected, dirty: dirty,
        onActivate: {
          if !projectActive { store.run("project.switch", ["name": .string(project)]) }
          store.run("tab.activate", ["path": .string(path)])
        },
        onClose: { store.run("tab.close", ["path": .string(path)]) },
        // Reorder within the active group only; other groups' tabs live in saved layouts.
        onMove: projectActive ? { from in store.run("tab.reorder", ["source": .string(from), "target": .string(WorkbenchTab.file(path).dragID)]) } : nil
      )
      .clairContextMenu(menus) { projectActive ? fileMenu(path, tab: true) : ClairMenuSpec(entries: []) }
    }

    /// Mock `projectMenu`: colour in place, switch/fold/rename, order, mute, close.
    private func projectMenu(_ p: WorkbenchProject, colorKey: String, folded: Bool) -> ClairMenuSpec {
      let name = CommandArg.string(p.name)
      let index = st.projects.firstIndex(of: p) ?? 0
      let muted = st.notices.mutedProjects.contains(p.name)
      return ClairMenuSpec(title: p.displayName, sub: p.path, entries: [
        .swatches(colorKey) { store.run("project.setColor", ["name": name, "color": .string($0)]) },
        .separator,
        .item(tr("このProjectに切り替え"), disabled: st.project == p.name) { store.run("project.switch", ["name": name]) },
        .item(folded ? tr("グループを展開") : tr("グループを折りたたむ")) {
          if folded { collapsedGroups.remove(p.name) } else { collapsedGroups.insert(p.name) }
        },
        .item(tr("フォルダを追加…")) { addFolder(to: p.name) },
        .item(tr("Project名を変更…")) {
          menus.ask(ClairDialog(title: tr("Project名を変更"), message: tr("空にするとフォルダ名に戻ります。"), initial: p.displayName) {
            store.run("project.rename", ["name": name, "label": .string($0)])
          })
        },
        .separator,
        .item(tr("左へ移動"), disabled: index == 0) { store.run("project.move", ["name": name, "offset": .int(-1)]) },
        .item(tr("右へ移動"), disabled: index >= st.projects.count - 1) { store.run("project.move", ["name": name, "offset": .int(1)]) },
        .separator,
        .item(muted ? tr("通知のミュートを解除") : tr("通知をミュート")) {
          store.run("notice.muteProject", ["name": name, "muted": .bool(!muted)])
        },
        .item(tr("Projectを閉じる"), disabled: st.projects.count < 2, destructive: true) {
          if case .failure(let e) = store.run("project.close", ["name": name]) {
            menus.ask(ClairDialog(title: tr("閉じられませんでした"), message: e.message) { _ in })
          }
        },
      ])
    }

    private var currentProject: WorkbenchProject? { st.projects.first { $0.name == st.project } }

    /// The absolute folder behind an explorer row that is an added folder's top row.
    private func addedFolder(_ id: String) -> String? {
      guard let p = currentProject, let i = p.folderPrefixes.firstIndex(of: id) else { return nil }
      return p.folders?[i]
    }

    private func addFolder(to project: String) {
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
      panel.prompt = tr("追加")
      guard panel.runModal() == .OK, let url = panel.url else { return }
      if case .failure(let e) = store.run("project.addFolder", ["name": .string(project), "path": .string(url.path)]) {
        menus.ask(ClairDialog(title: tr("追加できませんでした"), message: e.message) { _ in })
      } else if project == st.project {
        store.refreshProjectFiles()
      }
    }

    // MARK: activity bar + sidebar

    /// Left vertical nav strip, full-height, outside the sidebar panel.
    /// Was a horizontal row nested at the top of `sidebar` (see checklist
    /// §2.4, 2026-09-20 amendment): hover and selected now share one
    /// `washSelected` tint instead of the old `surfaceHover`/`surfaceActive`
    /// pair, and icons are bigger now that they own a whole column.
    private var activityBar: some View {
      VStack(spacing: 2) {
        ForEach(["folder", "shield", "terminal", "ladybug", "concierge"], id: \.self) { icon in
          activityBarButton(icon)
        }
        // ponytail: no overflow "…" menu — the Workbench shows it only when nav items overflow; four always fit here.
        Spacer(minLength: 0)
      }
      .padding(.vertical, 8)
      .frame(width: ChromeBudget.activityBarWidth).frame(maxHeight: .infinity)
      .background(C.chrome)
      .overlay(alignment: .trailing) { Rectangle().fill(C.surfaceActive).frame(width: 1) }
    }

    private func activityBarButton(_ icon: String) -> some View {
      return ActivityBarButton(icon: icon, on: sidebarMode == icon && !st.settingsOpen, enabled: true) {
        sidebarMode = icon
        if st.sidebarHidden { store.run("sidebar.toggle") }  // any activity-bar click brings the ⌘B-hidden sidebar back
        if icon != "terminal" { chat = nil }
        if icon == "folder", st.activeDiff != nil, let path = st.active {
          store.run("tab.activate", ["path": .string(path)])
        }
        if icon == "shield" { reloadChanges() }
        if icon == "ladybug" { store.run("debug.open") }
      }
    }

    private var sidebar: some View {
      VStack(spacing: 0) {
        // Lazy: a Project can list thousands of files, and an eager tree makes accessibility traversal (and layout) block the main thread.
        ScrollView { LazyVStack(alignment: .leading, spacing: 0) { sidebarMode == "shield" ? AnyView(changesList) : sidebarMode == "terminal" ? AnyView(sessionList) : sidebarMode == "ladybug" ? AnyView(debugPanel) : sidebarMode == "concierge" ? AnyView(conciergeSidebar) : AnyView(explorer) }.clairScroller() }
        Spacer(minLength: 0)
        if sidebarMode == "shield", st.isRepo {
          // Same filled control as the commit button, so it reads as a button and the whole box is the hit target.
          Button { store.run("git.graph") } label: {
            Label(tr("コミットグラフを開く"), systemImage: "point.3.connected.trianglepath.dotted")
              .foregroundStyle(C.textPrimary)
              .frame(maxWidth: .infinity).frame(height: 28)
              .background(C.surfaceActive, in: RoundedRectangle(cornerRadius: Radius.control))
              .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(L.strong))
          }
            .buttonStyle(.hoverWash)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
      }
      .frame(width: sidebarWidth)
      .font(Typography.font(Typography.sidebar))
      .background(C.chrome)
      // total 1 turns SplitHandle's ratio into a width in points.
      .overlay(alignment: .trailing) {
        SplitHandle(horizontal: true, ratio: sidebarWidth, total: 1) { sidebarWidth = min(max($0, 160), 600) }
          .frame(width: 6).offset(x: 3)
      }
    }

    /// Settings only covers the workbench, whose editor/terminal kept first responder: Esc (the ✕ button's
    /// cancelAction) and typing went to the hidden pane. Mounting this with settings takes the keyboard away.
    private struct ResignWorkbenchFocus: NSViewRepresentable {
      final class Probe: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.makeFirstResponder(nil) }
      }
      func makeNSView(context: Context) -> NSView { Probe() }
      func updateNSView(_ nsView: NSView, context: Context) {}
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
        Text(tr("設定")).font(.system(size: 16, weight: .semibold)).foregroundStyle(C.textPrimary)
        Spacer(minLength: 0)
        Button { store.run("settings.close") } label: {
          Image(systemName: "xmark").font(.system(size: 13, weight: .medium)).foregroundStyle(C.chromeInkMuted)
            .frame(width: 26, height: 26)
        }.buttonStyle(.hoverWash).keyboardShortcut(.cancelAction).padding(.trailing, 16).help(tr("設定を閉じる"))
      }
      .frame(height: ChromeBudget.titlebar)
      .background(TitlebarArea())
      .background(C.chrome)
      .overlay(alignment: .bottom) { Rectangle().fill(L.hairline).frame(height: 1) }
    }

    private var settingsPanel: some View {
      VStack(alignment: .leading, spacing: 12) {
        Text(tr("設定を検索")).font(.system(size: 15)).foregroundStyle(C.textQuaternary)
          .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
          .background(C.chrome, in: RoundedRectangle(cornerRadius: Radius.control))
          .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(L.hairline))
        VStack(alignment: .leading, spacing: 0) {
          ForEach(WorkbenchState.sections, id: \.self) { section in
            let selected = st.section == section
            Button { store.run("settings.open", ["section": .string(section)]) } label: {
              Text(tr(section))
                .font(.system(size: 15, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? C.textPrimary : C.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .padding(.horizontal, 8)
                .background(selected ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
            }
            .buttonStyle(.hoverWash)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8).padding(.vertical, 16)
      .frame(width: 240)
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
      searching = true; searchMessage = tr("検索中…")
      searchTask = Task {
        // ponytail: 250 ms debounce for typing; the cancel above is what keeps stale results out.
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        // Stream per-file hits so the first matches show while the rest of the Project is still scanned.
        let (batches, sink) = AsyncStream.makeStream(of: [SearchHit].self)
        let worker = Task.detached(priority: .userInitiated) {
          // ponytail: flush every 100 ms so a hit-heavy query doesn't re-render once per file.
          var pending: [SearchHit] = [], last = ContinuousClock.now
          defer { if !pending.isEmpty { sink.yield(pending) }; sink.finish() }
          return Result {
            try ProjectSearch.find(root: root, files: files, pattern) {
              pending += $0
              if last.duration(to: .now) > .milliseconds(100) { sink.yield(pending); pending = []; last = .now }
            }
          }
        }
        hits = []; searchSelection = 0
        await withTaskCancellationHandler(operation: {
          for await batch in batches where generation == searchGeneration {
            hits += batch
            searchMessage = tr("検索中… %@ 件", hits.count)
          }
        }, onCancel: { worker.cancel() })
        let result = await worker.value
        guard !Task.isCancelled, generation == searchGeneration else { return }
        searching = false
        switch result {
        case .success:
          searchMessage = hits.isEmpty ? tr("一致なし") : tr("%@ 件 / %@ ファイル", hits.count, Set(hits.map(\.path)).count)
        case .failure(let error) where error is CancellationError:
          break
        case .failure(let error):
          hits = []
          searchMessage = error is SearchError ? tr("正規表現が不正です") : tr("検索できません: %@", error)
        }
      }
    }

    private func runReplace() {
      guard !replacing, let root = store.activeRoot, !hits.isEmpty else { return }
      let (files, pattern, r) = (st.files, searchPattern, replaceText)
      searchTask?.cancel(); searching = false; replacing = true; searchMessage = tr("置換中…")
      replaceTask = Task {
        let result = await Task.detached(priority: .userInitiated) { Result { try ProjectSearch.replace(root: root, files: files, pattern, with: r) } }.value
        replacing = false
        switch result {
        case .success(let n): hits = []; searchMessage = tr("%@ 件を置換しました", n); runSearch()
        case .failure(let error): searchMessage = tr("置換できません: %@", error)
        }
      }
    }

    /// ADR-0009: an available release is offered, never applied on its own.
    @ViewBuilder private var updateToast: some View {
      let body: (title: String, note: String?, actions: Bool)? = switch store.update {
      case .available(let u) where store.dismissedUpdate != u.version: (tr("Clair %@ が利用できます", u.version), nil, true)
      case .installing: (tr("更新を適用しています"), tr("完了後に再起動します。"), false)
      default: nil
      }
      if let body {
        VStack(alignment: .leading, spacing: 10) {
          Text(body.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(C.textPrimary)
          if let note = body.note { Text(note).font(.system(size: 13)).foregroundStyle(C.textTertiary) }
          if body.actions, case .available(let u) = store.update {
            HStack(spacing: 8) {
              Button(tr("あとで")) { store.dismissedUpdate = u.version }
              Button(tr("適用して再起動")) { Task { await store.installUpdate() } }
            }
          }
        }
        .padding(14).frame(width: 300, alignment: .leading)
        .background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.overlay))
        .overlay(RoundedRectangle(cornerRadius: Radius.overlay).stroke(L.strong))
        .transition(.opacity)
      }
    }

    private func closeSearch() {
      store.run("palette.close")
      searchTask?.cancel(); searching = false; searchGeneration += 1
    }

    private var searchOverlay: some View {
      ZStack {
        Color(red: 8 / 255, green: 10 / 255, blue: 12 / 255).opacity(0.68).onTapGesture(perform: closeSearch)
        // Esc closes even when focus stayed in the terminal/editor (a key equivalent runs before keyDown).
        Button("", action: closeSearch).keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
        SearchPanel(
          query: $searchQuery, replacement: $replaceText, regex: $searchRegex, caseSensitive: $searchCase,
          selection: $searchSelection, hits: hits, message: searchMessage, searching: searching, replacing: replacing,
          search: runSearch, replaceAll: runReplace, close: closeSearch,
          open: {
            closeSearch(); store.run("tab.open", ["path": .string($0.path)])
            store.buffers.reveal($0.path, line: $0.line)
          })
          .frame(width: 560).background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.overlay))
          .overlay(RoundedRectangle(cornerRadius: Radius.overlay).stroke(L.strong))
          .transition(.scale(scale: 0.97).combined(with: .opacity))
      }
    }

    // MARK: concierge (ADR-0020)

    private var conciergeSidebar: some View {
      ConciergeSidebar(
        running: st.concierge(in: st.project) != nil,
        children: st.conciergeChildren(in: st.project), start: { startConcierge() },
        openTerminal: {
          if let c = st.concierge(in: st.project) { store.run("pane.focus", ["id": .int(c.pane)]) }
          leaveConcierge()
        },
        focus: focusConciergeChild, editInstructions: editConciergeInstructions)
    }

    private func startConcierge(_ message: String? = nil) {
      store.run("concierge.open", message.map { ["message": .string($0)] } ?? [:], confirmed: true)
    }

    /// Leaving the concierge for a pane or file hands the sidebar back to the file tree.
    private func leaveConcierge() { sidebarMode = "folder" }

    /// A child link shows the real terminal: leave the chat and focus that pane.
    private func focusConciergeChild(_ s: AgentSession) {
      if s.project != st.project { store.run("project.switch", ["name": .string(s.project)]) }
      store.run("pane.focus", ["id": .int(s.pane)])
      leaveConcierge()
    }

    private func editConciergeInstructions() {
      guard let root = store.activeRoot else { return }
      let url = URL(fileURLWithPath: root).appending(path: Concierge.instructionsPath)
      if !FileManager.default.fileExists(atPath: url.path) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(tr("# コンシェルジュへの指示\n\nこの Project で守ってほしいことを書きます。次回の起動から反映されます。\n").utf8).write(to: url, options: .withoutOverwriting)
      }
      leaveConcierge()
      store.refreshProjectFiles()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { store.run("tab.open", ["path": .string(Concierge.instructionsPath)]) }
    }

    private var sessionList: some View {
      SessionList(sessions: st.agentSessions, current: st.project) { s in
        if s.project != st.project { store.run("project.switch", ["name": .string(s.project)]) }
        store.run("pane.focus", ["id": .int(s.pane)])
        chat = nil
      } openHistory: { chat = $0 }
    }

    private var changesList: some View {
      VStack(alignment: .leading, spacing: 0) {
        if st.isRepo { ChangesList(
          changes: changes, loaded: changesLoaded, selected: diff, onSelect: { openDiff($0) },
          onToggle: { change, stage in
            runGit(
              [(stage ? "git.stage" : "git.unstage", ["path": .string(change.path)])],
              label: stage ? tr("ステージ") : tr("ステージ解除"))
          },
          onDiscard: discard,
          menus: menus,
          menu: { change, staged in
            ClairMenuSpec(title: (change.path as NSString).lastPathComponent, sub: change.path, entries: [
              .item(tr("変更を確認")) { openDiff(DiffTarget(path: change.path, staged: staged, untracked: change.untracked)) },
              .item(staged ? tr("ステージを取り消す") : tr("ステージに追加")) {
                runGit([(staged ? "git.unstage" : "git.stage", ["path": .string(change.path)])], label: staged ? tr("ステージ解除") : tr("ステージ"))
              },
              .separator,
              .item(change.untracked ? tr("ファイルを削除…") : tr("変更を元に戻す…"), destructive: true) { discard(change, staged) },
            ])
          },
          onBulk: { rows, stage in
            runGit(
              rows.map { (stage ? "git.stage" : "git.unstage", ["path": .string($0.path)]) },
              label: stage ? tr("一括ステージ") : tr("一括ステージ解除"))
          },
          onCommit: { message in
            runGit([("git.commit", ["message": .string(message)])], label: tr("コミット"))
          },
          busy: gitOperation != nil,
          operationMessage: gitOperation.map { tr("%@中…", $0) } ?? gitMessage)
        }
      }
    }

    /// "〜をレビュー ›" submenu: one item per agent profile; picking one launches the review.
    private func reviewMenu(_ title: String, _ target: AgentReviewRequest.Target, disabled: Bool) -> ClairMenuEntry {
      .item(title, disabled: disabled, submenu: AgentProfile.all.map { profile in
        .item(profile.title) { startReview(target, provider: profile.id) }
      })
    }

    private func resume(_ history: AgentHistory, in project: String) {
      guard let profile = AgentProfile.all.first(where: { $0.title == history.provider.rawValue }) else { return }
      // agent.launch runs in the active Project root, so open the chat's Project first.
      if project != st.project { store.run("project.switch", ["name": .string(project)]) }
      // The button is the user's approval, as with review launches.
      switch store.run("agent.launch", ["profile": .string(profile.id), "resume": .string(history.sessionID)], confirmed: true) {
      case .success(.pane(let pane)):
        reviewError = nil; chat = nil; sidebarMode = "terminal"
        store.run("pane.focus", ["id": .int(pane)])
      case .success: reviewError = nil; chat = nil; sidebarMode = "terminal"
      case .failure(let error): reviewError = error.message
      }
    }

    private func startReview(_ target: AgentReviewRequest.Target, provider: String) {
      guard store.activeRoot != nil, AgentProfile.named(provider) != nil else { return }
      switch target {
      case .file(let path):
        guard st.files.contains(where: { $0.path == path }), !st.dirty.contains(path) else { return }
      case .folder(let path):
        guard !st.dirty.contains(where: { $0.hasPrefix(path + "/") }) else { return }
      case .project:
        guard st.dirty.isEmpty else { return }
      }
      let input: CommandInput = [
        "profile": .string(provider), "prompt": .string(AgentReviewRequest.prompt(for: target)), "review": .bool(true),
      ]
      // The labelled button is the user's approval for launching this external tool.
      switch store.run("agent.launch", input, confirmed: true) {
      case .success(.pane(let pane)):
        reviewError = nil; diff = nil; sidebarMode = "terminal"
        store.run("pane.focus", ["id": .int(pane)])
      case .success:
        reviewError = nil; diff = nil; sidebarMode = "terminal"
      case .failure(let error): reviewError = error.message
      }
    }

    private func discard(_ change: GitChange, _ staged: Bool) {
      let name = (change.path as NSString).lastPathComponent
      menus.ask(ClairDialog(
        title: change.untracked ? tr("%@ を削除しますか？", name) : tr("%@ の変更を破棄しますか？", name),
        message: staged ? tr("ステージ済みと未ステージの変更をすべて HEAD の状態に戻します。取り消せません。") : tr("取り消せません。"),
        confirm: change.untracked ? tr("削除") : tr("破棄"), destructive: true
      ) { _ in
        runGit([("git.discard", ["path": .string(change.path), "staged": .bool(staged)])], label: tr("変更の破棄"), confirmed: true)
      })
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
        gitMessage = error ?? tr("%@が完了しました。", label)
        reloadChanges()
      }
    }

    private func reloadChanges() {
      changesTask?.cancel()
      guard let root = store.activeRoot else {
        changes = []; changesLoaded = nil; branch = nil; branches = []; sync = nil; diff = nil
        return
      }
      changesTask = Task {
        try? await Task.sleep(for: .milliseconds(40))
        guard !Task.isCancelled else { return }
        async let loadedChanges = Task.detached(priority: .utility) { WorkbenchGit.statusChanges(root) }.value
        async let loadedBranch = Task.detached(priority: .utility) { WorkbenchGit.currentBranch(root) }.value
        async let loadedBranches = Task.detached(priority: .utility) { WorkbenchGit.branches(root) }.value
        async let loadedSync = Task.detached(priority: .utility) { WorkbenchGit.aheadBehind(root) }.value
        let snapshot = await (loadedChanges, loadedBranch, loadedBranches, loadedSync)
        guard !Task.isCancelled, store.activeRoot == root else { return }
        changes = snapshot.0 ?? []; changesLoaded = snapshot.0 != nil; branch = snapshot.1; branches = snapshot.2; sync = snapshot.3
        store.buffers.conflictedPaths = Set(changes.filter(\.conflicted).map(\.path))
        // A proposal (ADR-0022) is about a file that need not have changed yet; it stays until answered.
        for target in st.diffTabs where target.proposal == nil && !changes.contains(where: { $0.path == target.path }) {
          store.run("diff.close", diffInput(target))
        }
        if diff != nil { loadDiff() }
      }
    }

    private var sections: some View {
      ForEach(WorkbenchState.sections, id: \.self) { s in
        row(tr(s), depth: 0, selected: st.section == s) { store.run("settings.open", ["section": .string(s)]) }
      }
    }

    /// Rows whose every ancestor folder is expanded. `files` is in tree order, so a folder's descendants follow it contiguously: one pass, no per-row scan of `expanded`.
    struct ExplorerRow: Identifiable, Sendable, Equatable {
      let id: String
      let label: String
      let depth: Int
      let file: WorkbenchFile?
    }

    nonisolated static func visibleExplorerRows(_ rows: [ExplorerRow], expanded: Set<String>) -> [ExplorerRow] {
      var hidden: String?
      return rows.filter { r in
        if let h = hidden { if r.id.hasPrefix(h) { return false }; hidden = nil }
        if r.file == nil, !expanded.contains(r.id) { hidden = r.id + "/" }
        return true
      }
    }

    /// Change rank per file and folder: 1 added, 2 modified, 3 deleted; a folder takes the highest rank inside it.
    nonisolated static func changeRanks(_ files: [WorkbenchFile], dirty: Set<String>) -> [String: Int] {
      var out: [String: Int] = [:]
      for f in files {
        var rank = switch f.status { case nil: 0; case "A", "U", "?": 1; case "D": 3; default: 2 }
        if dirty.contains(f.path) { rank = max(rank, 2) }
        guard rank > 0 else { continue }
        var path = f.path[...]
        while true {
          out[String(path)] = max(out[String(path)] ?? 0, rank)
          guard let slash = path.lastIndex(of: "/") else { break }
          path = path[..<slash]
        }
      }
      return out
    }

    nonisolated static func changeColor(_ rank: Int?) -> Color? {
      switch rank { case 1: C.success; case 2: C.attention; case 3: C.danger; default: nil }
    }

    /// Folders derived from the file paths; click toggles, files open a tab.
    private var explorer: some View {
      return LazyVStack(alignment: .leading, spacing: 0) {
        // Only the first scan blanks the tree; a rescan (every watcher event) swaps rows in place.
        if store.scanning && st.files.isEmpty {
          Text("Loading...").font(.system(size: 13)).foregroundStyle(C.textTertiary)
            .padding(.horizontal, 16).frame(height: 28)
        } else {
          // Project root: uppercase, branch glyph, no chevron — it reads as a
          // section label, not one more row in the same list as its children.
          // Folds the whole tree (GUI-local); click-to-collapse is unchanged.
          treeRow(depth: 0, selected: false, action: { rootFolded.toggle() }) {
            Text(st.project).font(.system(size: 13, weight: .semibold)).textCase(.uppercase).foregroundStyle(C.textPrimary)
            Spacer(minLength: 0)
          }
          .clairContextMenu(menus) {
            ClairMenuSpec(title: st.project, entries: [reviewMenu(tr("この Project をレビュー"), .project, disabled: !st.dirty.isEmpty)])
          }
          if !rootFolded {
            let ranks = explorerRanks
            ForEach(visibleExplorerRows) { r in
              if let f = r.file {
                let on = st.active == f.path && !st.settingsOpen
                treeRow(depth: r.depth, selected: on, action: { store.run("tab.open", ["path": .string(f.path)]) }) {
                  Color.clear.frame(width: 10)  // chevron slot: a file lines up with its sibling folders
                  FileIcon.forPath(f.path).image(size: 10, ink: on ? C.textSecondary : C.textTertiary).frame(width: 16)
                  Text(r.label).font(.system(size: 13, weight: on ? .semibold : .regular)).foregroundStyle(Self.changeColor(ranks[f.path]) ?? (on ? C.textPrimary : C.textSecondary)).lineLimit(1)
                  Spacer(minLength: 0)
                  if let tint = Self.changeColor(ranks[f.path]) {
                    Text(st.dirty.contains(f.path) ? "M" : f.status ?? "M").font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                  }
                }
                .clairContextMenu(menus) { fileMenu(f.path, tab: false) }
              } else {
                let open = st.expanded.contains(r.id)
                treeRow(depth: r.depth, selected: false, action: { store.run("explorer.toggle", ["path": .string(r.id)]) }) {
                  chevron(open: open)
                  FileIcon.folder(open: open).image(size: 11, ink: C.textTertiary).frame(width: 16)
                  Text(r.label).font(.system(size: 13)).foregroundStyle(Self.changeColor(ranks[r.id]) ?? C.textSecondary).lineLimit(1)
                  Spacer(minLength: 0)
                  if let tint = Self.changeColor(ranks[r.id]) { Circle().fill(tint).frame(width: 6, height: 6) }
                }
                .clairContextMenu(menus) {
                  if let folder = addedFolder(r.id) {
                    ClairMenuSpec(title: r.label, sub: folder, entries: [
                      .item(open ? tr("折りたたむ") : tr("開く")) { store.run("explorer.toggle", ["path": .string(r.id)]) },
                      .separator,
                      .item(tr("Project からフォルダを外す"), destructive: true) {
                        if case .failure(let e) = store.run("project.removeFolder", ["name": .string(st.project), "path": .string(folder)]) {
                          menus.ask(ClairDialog(title: tr("外せませんでした"), message: e.message) { _ in })
                        }
                      },
                    ])
                  } else {
                  ClairMenuSpec(title: r.label, sub: r.id, entries: [
                    .item(open ? tr("折りたたむ") : tr("開く")) { store.run("explorer.toggle", ["path": .string(r.id)]) },
                    reviewMenu(tr("このフォルダをレビュー"), .folder(r.id), disabled: st.dirty.contains(where: { $0.hasPrefix(r.id + "/") })),
                    .separator,
                  ] + pathItems(r.id) + [.separator] + fileOps(r.id, dir: true))
                  }
                }
              }
            }
          }
        }
      }.padding(.vertical, 4)
      .onChange(of: st.dirty) { explorerRanks = Self.changeRanks(st.files, dirty: st.dirty) }
      .alert(tr("レビューを開始できませんでした"), isPresented: Binding(get: { reviewError != nil }, set: { if !$0 { reviewError = nil } })) {
        Button("OK") {}
      } message: { Text(reviewError ?? "") }
    }

    private func rebuildExplorer() {
      explorerTask?.cancel()
      explorerRanks = Self.changeRanks(st.files, dirty: st.dirty)
      let files = st.files, project = st.project, roots = currentProject?.folderPrefixes ?? []
      explorerTask = Task {
        let rows = await Task.detached(priority: .utility) { Self.explorerRows(for: files, roots: roots) }.value
        guard !Task.isCancelled, st.project == project, st.files == files else { return }
        explorerRows = rows
        rebuildVisibleExplorer()
      }
    }

    private func rebuildVisibleExplorer() {
      explorerVisibilityTask?.cancel()
      let rows = explorerRows, expanded = st.expanded
      explorerVisibilityTask = Task {
        let visible = await Task.detached(priority: .utility) { Self.visibleExplorerRows(rows, expanded: expanded) }.value
        guard !Task.isCancelled, explorerRows == rows, st.expanded == expanded else { return }
        visibleExplorerRows = visible
      }
    }

    /// `roots`: added folders' relative prefixes (`../docs`); each is one top-level row named after the folder.
    nonisolated static func explorerRows(for files: [WorkbenchFile], roots: [String] = []) -> [ExplorerRow] {
      var out: [ExplorerRow] = []
      var seen = Set<String>()
      out.reserveCapacity(files.count * 2)
      for file in files where file.status != "D" {  // deleted files only tint their folders (changeRanks)
        guard !Task.isCancelled else { return [] }
        let root = roots.first { file.path.hasPrefix($0 + "/") }
        let parts = root.map { [$0] + file.path.dropFirst($0.count + 1).split(separator: "/").map(String.init) }
          ?? file.path.split(separator: "/").map(String.init)
        guard let name = parts.last else { continue }
        if parts.count > 1 {
          for depth in 0..<(parts.count - 1) {
            let id = parts[0...depth].joined(separator: "/")
            if seen.insert(id).inserted { out.append(ExplorerRow(id: id, label: (parts[depth] as NSString).lastPathComponent, depth: depth + 1, file: nil)) }
          }
        }
        out.append(ExplorerRow(id: file.path, label: name, depth: parts.count, file: file))
      }
      return out
    }

    private func row(_ title: String, depth: Int, selected: Bool, badge: Character? = nil, _ action: @escaping () -> Void) -> some View {
      treeRow(depth: depth, selected: selected, action: action) {
        Text(title).font(Typography.font(Typography.sidebar)).foregroundStyle(selected ? C.textPrimary : C.textSecondary)
        Spacer(minLength: 0)
        if let b = badge { Text(String(b)).font(Typography.font(Typography.sidebarMicro)).foregroundStyle(C.textTertiary) }
      }
    }

    private func chevron(open: Bool) -> some View {
      Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(C.textTertiary)
        .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10)
    }

    /// Explorer row: an inset, rounded 28px tab with 12px indent per level.
    private func treeRow<Content: View>(depth: Int, selected: Bool, action: @escaping () -> Void, @ViewBuilder _ content: () -> Content) -> some View {
      Button(action: action) {
        HStack(spacing: 10, content: content)
          .padding(.leading, 8 + CGFloat(depth) * 12).padding(.trailing, 8).frame(height: 28)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(selected ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.card))
          .contentShape(Rectangle())
      }.buttonStyle(.hoverWash).padding(.horizontal, 8)
    }

    // MARK: context menus (checklist §3.6), drawn by ClairContextMenu.swift.

    private func fileMenu(_ path: String, tab: Bool) -> ClairMenuSpec {
      var e: [ClairMenuEntry] = tab
        ? [.item(tr("タブを閉じる"), shortcut: "⌘W") { store.run("tab.close", ["path": .string(path)]) },
           .item(tr("分割して開く")) { store.run("tab.activate", ["path": .string(path)]); store.run("pane.splitRight") }]
        : [.item(tr("開く")) { store.run("tab.open", ["path": .string(path)]) }]
      let change = changes.first { $0.path == path }
      e.append(.item(tr("変更を確認"), disabled: change == nil) {
        if let c = change { openDiff(DiffTarget(path: c.path, staged: c.staged && !c.unstaged, untracked: c.untracked)) }
      })
      e.append(.item(tr("比較対象として選択")) { compareBase = path })
      if let base = compareBase, base != path {
        e.append(.item(tr("%@ と比較", name(base))) { openDiff(DiffTarget(path: path, staged: false, untracked: false, against: base)) })
      }
      e.append(reviewMenu(tr("このファイルをレビュー"), .file(path), disabled: st.dirty.contains(path)))
      e.append(.separator)
      e.append(agentItems(path))
      e += pathItems(path)
      if !tab { e += [.separator] + fileOps(path, dir: false) }
      return ClairMenuSpec(title: (path as NSString).lastPathComponent, sub: path, entries: e)
    }

    /// VS Code-style explorer file operations. The FSEvents watcher rescans the tree afterwards.
    private func fileOps(_ path: String, dir: Bool) -> [ClairMenuEntry] {
      let parent = dir ? path : (path as NSString).deletingLastPathComponent
      return [
        .item(tr("新しいファイル…")) { createItem(in: parent, folder: false) },
        .item(tr("新しいフォルダー…")) { createItem(in: parent, folder: true) },
        .separator,
        .item(tr("名前を変更…")) { renameItem(path) },
        .item(tr("削除"), destructive: true) { trashItem(path, dir: dir) },
      ]
    }

    private func absolute(_ path: String) -> URL? {
      store.activeRoot.map { URL(fileURLWithPath: ($0 as NSString).appendingPathComponent(path)) }
    }

    /// Name prompt. Rejects empty names and path separators so an item cannot escape its folder.
    private func promptName(_ title: String, initial: String, _ done: @escaping (String) -> Void) {
      menus.ask(ClairDialog(title: title, initial: initial) { raw in
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return }
        done(name)
      })
    }

    private func fileError(_ error: Error) {
      menus.ask(ClairDialog(title: tr("操作できませんでした"), message: error.localizedDescription) { _ in })
    }

    private func createItem(in folder: String, folder isFolder: Bool) {
      promptName(isFolder ? tr("新しいフォルダー") : tr("新しいファイル"), initial: "") { name in
        let rel = (folder as NSString).appendingPathComponent(name)
        guard let url = absolute(rel) else { return }
        guard !FileManager.default.fileExists(atPath: url.path) else {
          return fileError(CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path]))
        }
        do {
          if isFolder { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
          else { try Data().write(to: url, options: .withoutOverwriting) }
        } catch { return fileError(error) }
        store.refreshProjectFiles()
        if !isFolder { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { store.run("tab.open", ["path": .string(rel)]) } }
      }
    }

    private func renameItem(_ path: String) {
      let old = (path as NSString).lastPathComponent
      promptName(tr("名前を変更"), initial: old) { name in
        let rel = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
        guard name != old, let from = absolute(path), let to = absolute(rel) else { return }
        do { try FileManager.default.moveItem(at: from, to: to) } catch { return fileError(error) }
        closeTabs(under: path)
        store.refreshProjectFiles()
      }
    }

    private func trashItem(_ path: String, dir: Bool) {
      guard let url = absolute(path) else { return }
      menus.ask(ClairDialog(
        title: tr("“%@” を削除しますか?", (path as NSString).lastPathComponent),
        message: dir ? tr("フォルダーとその中身をゴミ箱に移動します。") : tr("ゴミ箱に移動します。"),
        confirm: tr("ゴミ箱に移動"), destructive: true
      ) { _ in
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { return fileError(error) }
        closeTabs(under: path)
        store.refreshProjectFiles()
      })
    }

    /// Tabs under a moved/trashed path would point at nothing; close them (unsaved ones stay for the user).
    private func closeTabs(under path: String) {
      for t in st.tabs where (t == path || t.hasPrefix(path + "/")) && !st.dirty.contains(t) {
        store.run("tab.close", ["path": .string(t)])
      }
    }

    /// "Agent に送る ›": types `@path ` into a running agent terminal of this Project. No Return; the user reviews and sends.
    private func agentItems(_ path: String) -> ClairMenuEntry {
      let agents = st.agentSessions.filter { $0.project == st.project && !$0.status.isExited }
      return .item(tr("Agent に送る"), disabled: agents.isEmpty, submenu: agents.map { a in
        .item("\(a.title) · pane \(a.pane)") {
          if ClairGhosttySurfaceView.send("@\(path) ", toPane: a.pane) { store.run("pane.focus", ["id": .int(a.pane)]) }
        }
      })
    }

    private func pathItems(_ path: String) -> [ClairMenuEntry] {
      let full = store.activeRoot.map { ($0 as NSString).appendingPathComponent(path) }
      return [
        .item(tr("パスをコピー")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) },
        .item(tr("Finder で表示"), disabled: full == nil) {
          full.map { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0)]) }
        },
      ]
    }
    // MARK: V13 Debug (Workbench Debug screen, with VS Code style run configuration)

    private var debugPanel: some View {
      VStack(alignment: .leading, spacing: 0) {
        Text(tr("実行とデバッグ")).font(.system(size: 12, weight: .semibold)).foregroundStyle(C.textTertiary)
          .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 8)
        HStack(spacing: 4) {
          Button { startDebugFromUI() } label: {
            Image(systemName: "play.fill")
              .font(.system(size: 12))
              .foregroundStyle(C.debugBlueText)
              .frame(width: 28, height: 28)
              .background(C.debugBlue.opacity(0.16), in: RoundedRectangle(cornerRadius: Radius.control))
          }
          .buttonStyle(.hoverWash).help(tr("デバッグを開始"))
          .disabled(debugMode == "attach" ? (Int(debugPID) ?? 0) <= 0 : !(st.active?.hasSuffix(".go") ?? false))
          Menu {
            Button(tr("Go: 現在のファイル")) { debugMode = "debug" }
            Button(tr("Go: 現在の package をテスト")) { debugMode = "test" }
            Button(tr("プロセスに attach")) { debugMode = "attach" }
          } label: {
            HStack(spacing: 6) {
              Text(debugMode == "test" ? tr("Go: package テスト") : debugMode == "attach" ? tr("プロセスに attach") : tr("Go: 現在のファイル"))
                .lineLimit(1)
              Spacer(minLength: 0)
              Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12))
            .foregroundStyle(C.textSecondary)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(C.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(L.strong))
          }
          .menuStyle(.borderlessButton)
          .accessibilityLabel(tr("デバッグ構成"))
        }.padding(.horizontal, 12)
        if debugMode == "attach" {
          TextField(tr("プロセス ID (PID)"), text: $debugPID)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(C.textPrimary)
            .padding(.horizontal, 8).frame(height: 28)
            .background(C.canvas, in: RoundedRectangle(cornerRadius: Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(L.strong))
            .padding(.horizontal, 12).padding(.top, 6)
        }
        Text(debugSetupMessage)
          .font(.system(size: 12)).foregroundStyle(C.textTertiary)
          .padding(.horizontal, 12).padding(.top, 8).fixedSize(horizontal: false, vertical: true)
        debugSection(tr("ブレークポイント"))
        if let session = store.debugSession, !session.breakpoints.isEmpty {
          ForEach(session.breakpoints.keys.sorted(), id: \.self) { path in
            ForEach((session.breakpoints[path] ?? []).sorted(), id: \.self) { line in
              let status = session.breakpointStatus[path]?[line]
              HStack(spacing: 0) {
                // The red dot removes the breakpoint; the rest of the row jumps to its line.
                Button { _ = store.run("debug.breakpoint", ["path": .string(path), "line": .int(line)]) } label: {
                  Image(systemName: "circle.fill").font(.system(size: 9)).foregroundStyle(C.danger)
                    .frame(width: 24, height: 28).contentShape(Rectangle())
                }.buttonStyle(.hoverWash).help(tr("ブレークポイントを削除"))
                Button {
                  let target = status?.line ?? line
                  _ = store.run("file.open", ["path": .string(path), "line": .int(target)])
                  if let rel = store.state.active { store.buffers.reveal(rel, line: target, column: -1) }  // select the line
                } label: {
                  Text("\(URL(fileURLWithPath: path).lastPathComponent):\(status?.line ?? line)")
                    .font(.system(size: 12)).foregroundStyle(status?.verified == false ? C.attention : C.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.hoverWash).help(status?.message ?? (status == nil ? tr("未検証") : tr("検証済み")))
              }.padding(.horizontal, 12).padding(.leading, 2)
            }
          }
        } else { debugEmpty(tr("設定されていません")) }
        debugSection(tr("スレッドとコールスタック"))
        if let session = store.debugSession, !session.threads.isEmpty {
          ForEach(session.threads) { thread in
            Button { _ = store.run("debug.selectThread", ["id": .int(thread.id)]) } label: {
              Label(thread.name, systemImage: session.selectedThread == thread.id ? "checkmark.circle.fill" : "circle.grid.2x2")
                .font(.system(size: 12)).foregroundStyle(session.selectedThread == thread.id ? C.textPrimary : C.textTertiary)
            }.buttonStyle(.hoverWash).padding(.horizontal, 12).frame(minHeight: 28)
          }
        }
        if let session = store.debugSession, !session.frames.isEmpty {
          ForEach(session.frames) { frame in
            Button { _ = store.run("debug.selectFrame", ["id": .int(frame.id)]); openDebugFrame(frame) } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(frame.name).foregroundStyle(C.textPrimary).lineLimit(1)
                Text(frame.path.map { "\(URL(fileURLWithPath: $0).lastPathComponent):\(frame.line)" } ?? tr("場所不明"))
                  .foregroundStyle(C.textQuaternary)
              }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.hoverWash).padding(.horizontal, 12).frame(minHeight: 34)
              .background(session.selectedFrame == frame.id ? C.debugBlue.opacity(0.08) : Color.clear)
              .overlay(alignment: .leading) {
                if session.selectedFrame == frame.id { C.debugBlue.frame(width: 2) }
              }
          }
        } else { debugEmpty(tr("停止すると表示されます")) }
        debugSection(tr("変数"))
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
              }.font(.system(size: 12)).padding(.leading, 12 + CGFloat(variable.depth * 12)).padding(.trailing, 12).padding(.vertical, 4)
            }.buttonStyle(.hoverWash).disabled(variable.reference == 0)
          }
        } else { debugEmpty(tr("停止すると表示されます")) }
        debugSection(tr("デバッグコンソール"))
        if let session = store.debugSession, !session.console.isEmpty {
          ForEach(Array(session.console.enumerated()), id: \.offset) { _, line in
            Text(line).font(.system(size: 12, design: .monospaced))
              .foregroundStyle(C.textTertiary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 12).padding(.vertical, 2)
              .textSelection(.enabled)
          }
        } else { debugEmpty(tr("出力はありません")) }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func debugSection(_ title: String) -> some View {
      Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(C.textTertiary)
        .padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 5)
    }
    private func debugEmpty(_ text: String) -> some View {
      Text(text).font(.system(size: 12)).foregroundStyle(C.textQuaternary).padding(.horizontal, 12)
    }

    private var debugSetupMessage: String {
      guard let session = store.debugSession else { return tr("Go ファイルを開き、構成を選んで開始してください。Delve (dlv) が必要です。") }
      switch session.phase {
      case .idle: return tr("構成を選んで開始してください。")
      case .starting: return tr("Delve に接続中…")
      case .configuring: return tr("ブレークポイントを設定中…")
      case .running: return tr("実行中 · %@", session.project.name)
      case .stopped: return tr("停止: %@", session.stoppedReason ?? tr("一時停止"))
      case .ended: return tr("デバッグセッションは終了しました")
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
          debugAction("play.fill", tr("続行"), "debug.continue", enabled: store.debugSession?.phase == .stopped)
          debugAction("pause.fill", tr("一時停止"), "debug.pause", enabled: store.debugSession?.phase == .running)
          debugAction("arrow.turn.down.right", tr("ステップオーバー"), "debug.stepOver", enabled: store.debugSession?.phase == .stopped)
          debugAction("arrow.down.right", tr("ステップイン"), "debug.stepInto", enabled: store.debugSession?.phase == .stopped)
          debugAction("arrow.up.right", tr("ステップアウト"), "debug.stepOut", enabled: store.debugSession?.phase == .stopped)
          Rectangle().fill(L.strong).frame(width: 1, height: 18).padding(.horizontal, 4)
          debugAction("arrow.clockwise", tr("再起動"), "debug.restart", enabled: store.debugSession != nil)
          debugAction("stop.fill", tr("終了"), "debug.stop", enabled: store.debugSession != nil)
        }
        .padding(.horizontal, 4).frame(height: 34)
        .background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(L.strong))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("デバッグ操作"))
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

    private func loadDiff(clear: Bool = true) {
      diffTask?.cancel(); if clear { loadedDiff = nil }
      guard let target = diff, let root = store.activeRoot else { return }
      diffTask = Task {
        async let rendered = Task.detached(priority: .userInitiated) {
          DiffView.model(
            target.proposal.map { WorkbenchGit.proposalDiff(root, target.path, proposal: $0) }
              ?? WorkbenchGit.diff(root, target.path, staged: target.staged, untracked: target.untracked, against: target.against, fullContext: true))
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
          if let proposal = d.proposal {
            ProposalBar(
              path: d.path, onAccept: { store.resolveProposal(proposal, accept: true) },
              onReject: { store.resolveProposal(proposal, accept: false) })
            DiffView(
              target: d, model: loaded.model, threads: [:], suggestions: [], onComment: { _, _, _ in }, onSuggest: { _, _ in },
              onResolve: { _ in }, onApply: { _ in nil }, onReject: { _ in }, onSend: nil, onClose: { closeDiff() }, editor: nil,
              onSave: nil, isDirty: false, label: tr("Claude の提案"), commentable: false)
            .id(d)
          } else {
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
              guard let m = buffer else { return tr("ファイルを開けません。") }
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
            onClose: { closeDiff() },
            editor: d.staged ? nil : EditorPane(
              buffers: store.buffers, root: root, path: d.path, focused: !st.settingsOpen,
              softWrap: st.toggles["softWrap"] == true, style: editorStyle,
              onEdit: { store.edited($0) },
              onCaret: { store.editorSelectionChanged($0, $1, in: $2) }),
            onSave: d.staged ? nil : {
              Task { if await store.saveFile(d.path) { loadDiff(clear: false) } }
            },
            isDirty: st.dirty.contains(d.path),
            onStageBlock: d.untracked || d.against != nil ? nil : { patch, reverse in
              if case .success(.text(let message)) = store.run("git.stagePatch", ["patch": .string(patch), "reverse": .bool(reverse)]) {
                store.languageNotice = message
              }
              reloadChanges()
            })
          .id(d)
          }
        } else if diff != nil {
          ProgressView { Text(tr("差分を読み込み中…")) }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if st.panesClosed {
          HomeView(shortcuts: homeShortcuts(st))
        } else {
        PaneView(
          node: st.tree.maximized.flatMap { id in st.tree.leaves.first { $0.id == id }.map { .leaf(id: $0.id, kind: $0.kind) } } ?? st.tree.root,
          // No pane is focused under settings, so a rebuilt editor/terminal cannot take the keyboard back; closing refocuses it.
          focused: st.settingsOpen ? -1 : st.tree.focused, launches: st.launches, project: store.activeRoot ?? st.project, onFocus: { store.run("pane.focus", ["id": .int($0)]) },
          onFacts: { store.facts(pane: $0, bells: $1, exit: $2, notification: $3) },
          onTitle: { store.title(pane: $0, $1) },
          title: { terminalTabTitle(st.project, $0) },
          onRatio: { store.run("pane.setRatio", ["id": .int($0), "ratio": .double($1)]) },
          editor: activeEditor,
          run: { _ = store.run($0, $1) }, dragging: $draggingPane)
        }
      }
      .overlay(alignment: .top) {
        if debugControlsVisible { debugToolbar.padding(.top, 12) }
      }
      // Chat history covers the panes instead of replacing them, so the
      // terminal surfaces stay mounted and keep their scrollback.
      .overlay {
        if let chat { AgentChatView(history: chat, onResume: st.projects.first(where: { $0.path == chat.project }).map { p in { resume(chat, in: p.name) } }) { self.chat = nil }.id(chat.id).background(C.canvas) }
        else if sidebarMode == "concierge" {
          let c = st.concierge(in: st.project)
          ConciergeChatView(session: c?.session, pane: c?.pane, children: st.conciergeChildren(in: st.project), focus: focusConciergeChild, start: { startConcierge($0) })
        }
      }
    }

    /// The active Project's editor pane; its own property keeps the `PaneView` call within the type checker's budget.
    private var activeEditor: EditorPane {
      EditorPane(buffers: store.buffers, root: store.activeRoot, path: st.active,
        softWrap: st.toggles["softWrap"] == true, style: editorStyle,
        debugLine: store.debugSession?.frames.first(where: { $0.id == store.debugSession?.selectedFrame }).flatMap {
          $0.path == store.activeRoot.map { $0 + "/" + (st.active ?? "") } ? $0.line : nil
        },
        // Requested breakpoints show before a session starts; the adapter's line wins once it answers.
        debugBreakpoints: activeBreakpoints,
        onToggleDebugBreakpoint: { line in
          guard let root = store.activeRoot, let path = st.active else { return }
          _ = store.run("debug.breakpoint", ["path": .string(root + "/" + path), "line": .int(line)])
        },
        onDefinition: { store.run("editor.definition") },
        onPreview: { store.run("editor.markdownPreview") },
        onEdit: { store.edited($0) }, onCaret: { store.editorSelectionChanged($0, $1, in: $2) }, previews: st.previews,
        home: homeShortcuts(st))
    }

    /// Requested breakpoints of the active file; the adapter's line wins once it answers.
    private var activeBreakpoints: Set<Int> {
      guard let s = store.debugSession else { return [] }
      let key = (store.activeRoot ?? "") + "/" + (st.active ?? "")
      return Set((s.breakpoints[key] ?? []).map { s.breakpointStatus[key]?[$0]?.line ?? $0 })
    }

    private static let sectionNotes = [
      "一般": "ワークスペースの基本動作とアプリ全体の表示を設定します。",
      "使用状況": "依頼・追記と推定費用の集計",
    ]

    /// Home screen rows (new Project, or every pane closed): commands with a bound key, in this order.
    private func homeShortcuts(_ st: WorkbenchState) -> [HomeView.Row] {
      ["terminal.show", "palette.files", "palette.commands", "sidebar.toggle", "pane.splitRight"].compactMap { id in
        CommandRegistry.workbench.commands.first { $0.id == id }.flatMap { d in
          st.shortcut(for: d).map { (tr(d.title), $0, { [store] in store.performFromHome(id) }) }
        }
      }
    }

    private var settingsMain: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          Text(tr(st.section)).font(.system(size: 25, weight: .semibold)).foregroundStyle(C.textPrimary)
          Text(Self.sectionNotes[st.section].map { tr($0) } ?? tr("%@ の設定です。", tr(st.section))).font(.system(size: 15)).foregroundStyle(C.textTertiary)
            .padding(.bottom, 16)
          switch st.section {
          case "使用状況":
            AgentUsageView(projects: st.projects, activeProject: st.project) { history in
              guard let project = st.projects.first(where: { $0.path == history.project }) else { return }
              store.run("settings.close")
              resume(history, in: project.name)
            }
          case "一般":
            SettingsCard(title: tr("ワークスペース")) {
              switchRow(tr("前回のレイアウトを復元"), "restoreLayout", note: tr("Projectごとのファイル、ターミナル、分割位置を再開します。"))
              switchRow(tr("閉じる前に確認"), "confirmClose", note: tr("実行中のターミナルや未保存のエディタを閉じる前に確認します。"))
            }
            SettingsCard(title: tr("インターフェース")) {
              choiceRow(tr("外観"), "appearance", note: tr("エディタ、ターミナル、サイドバーの配色をまとめて切り替えます。"))
              choiceRow(tr("言語"), "language")
              switchRow(tr("ステータスバーの利用枠を隠す"), "hideQuota")
            }
          case "通知":
            SettingsCard(title: tr("macOS 通知")) {
              switchRow(tr("通知を有効にする"), "notifyEnabled", note: tr("Clair の terminal で動く agent の通知要求と終了を macOS に送ります。"))
              switchRow(tr("入力待ち・通知要求で通知"), "notifyOnBell")
              switchRow(tr("終了で通知"), "notifyOnExit", note: tr("正常終了・異常終了のどちらも対象です。"))
              switchRow(tr("Clair が前面のときも通知"), "notifyWhenActive", note: tr("オフのときは他のアプリを使っている間だけ通知します。"))
              switchRow(tr("サウンドを鳴らす"), "notifySound")
            }
            SettingsCard(title: tr("テスト")) {
              SettingsRow(title: tr("テスト通知を送る"), note: notificationTestResult ?? tr("macOS の通知許可と表示を確認します。")) {
                Button(tr("送信")) {
                  store.sendTestNotification { notificationTestResult = $0 ? tr("送信しました。表示されない場合は システム設定 → 通知 → Clair を確認してください。") : tr("送信できませんでした。システム設定 → 通知 → Clair で許可してください（アプリ bundle 以外では動きません）。") }
                }
              }
            }
          case "AIプロバイダー":
            SettingsCard(title: "Agent") {
              defaultAgentRow
              choiceRow(tr("承認ポリシー"), "approvalPolicy", note: tr("ターミナル・Agent会話での変更提案を、どこまで自動で通すか。"))
            }
            integrationCard
          case "エディタ":
            SettingsCard(title: tr("表示")) {
              fontRow("editor")
              choiceRow(tr("文字サイズ"), "editorFontSize")
              switchRow(tr("行番号を表示"), "lineNumbers")
            }
            SettingsCard(title: tr("編集")) {
              switchRow(tr("保存時に整形"), "formatOnSave", note: tr("⌘S のタイミングでフォーマッタを実行します。"))
              choiceRow(tr("タブ幅"), "tabWidth")
              switchRow(tr("空白文字を表示"), "showWhitespace", note: tr("タブ・行末の空白を薄く可視化します。"))
              switchRow(tr("行の折り返し"), "softWrap", note: tr("長い行をエディタの幅に合わせて折り返します。⌥Z でも切り替えられます。"))
              // Full-width block: the rows sit under the title instead of squeezing into the trailing control slot.
              VStack(alignment: .leading, spacing: 8) {
                SettingsRow(title: tr("拡張子の言語"), note: tr("組み込みの判定より優先されます。開き直したファイルから反映されます。")) { EmptyView() }
                ForEach($associationRows) { $row in
                  HStack(spacing: 8) {
                    TextField("tpl", text: $row.ext).textFieldStyle(.plain)
                      .padding(.horizontal, 8).frame(width: 160, height: 28)
                      .background(RoundedRectangle(cornerRadius: 6).fill(C.surfaceActive))
                      .accessibilityLabel(tr("拡張子"))
                    Picker(tr("言語"), selection: $row.lang) {
                      ForEach(EditorLanguageID.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .labelsHidden().controlSize(.large).frame(width: 180)
                    Button { associationRows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                      .buttonStyle(.plain).foregroundStyle(C.textTertiary).accessibilityLabel(tr("削除"))
                  }
                }
                Button { associationRows.append(AssociationDraft(ext: "", lang: EditorLanguageID.terraform.rawValue)) } label: { Image(systemName: "plus") }
                  .accessibilityLabel(tr("追加"))
              }
              .padding(.bottom, 12)
                .onAppear {
                  associationRows = st.fileAssociations.sorted { $0.key < $1.key }.map { AssociationDraft(ext: $0.key, lang: $0.value) }
                }
                .onChange(of: associationRows) { _, rows in
                  let text = rows.map { "\($0.ext)=\($0.lang)" }.joined(separator: ",")
                  store.run("settings.fileAssociations", ["value": .string(text)])
                }
            }
          case "ターミナル":
            SettingsCard(title: tr("表示")) {
              fontRow("terminal")
              choiceRow(tr("文字サイズ"), "terminalFontSize")
              choiceRow(tr("カーソルの形"), "terminalCursorStyle")
              switchRow(tr("カーソルを点滅"), "terminalCursorBlink", note: tr("シェルやアプリが形・点滅を指定したときはそちらが優先されます。"))
            }
            SettingsCard(title: tr("シェルと承認")) {
              choiceRow(tr("デフォルトシェル"), "defaultShell")
              switchRow(tr("コマンド実行前に確認"), "terminalApprovals", note: tr("agentが実行するコマンドの承認プロンプト。"))
              choiceRow(tr("スクロールバック"), "scrollback")
            }
            SettingsCard(title: tr("電源")) {
              switchRow(tr("バッテリー駆動中もエージェント実行中はスリープさせない"), "preventSleepOnBattery")
            }
          case "アップデート":
            updateSection
          case "モバイル":
            SettingsCard(title: tr("モバイル")) {
              SettingsRow(title: tr("セッションの確認"), note: tr("同じネットワーク上の端末からセッションを確認します。")) { EmptyView() }
            }
          default:
            EmptyView()
          }
        }
        .font(.system(size: 15))
        .padding(.horizontal, 40).padding(.vertical, 40).frame(maxWidth: 880, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        // Destination change: short cross-fade on the screen token; SwiftUI retargets it mid-flight (interruptible), and reduce motion swaps instantly.
        .id(st.section).transition(.opacity)
      }
      .animation(reduceMotion ? nil : .easeOut(duration: Motion.screenDuration), value: st.section)
      .background(C.canvas)
    }

    /// V16: lets agents in Clair terminals drive Clair (`clair agent.launch` …) and know how (the clair-agents skill).
    private var integrationCard: some View {
      SettingsCard(title: tr("連携")) {
        SettingsRow(
          title: tr("clair コマンドをインストール"),
          note: integrationNotes["command"] ?? (ClairDaemonLauncher.isCommandInstalled
            ? tr("インストール済み(%@)。", ClairDaemonLauncher.commandLink.path)
            : tr("%@ にリンクし、ターミナルやAgentからClairを操作できるようにします。", ClairDaemonLauncher.commandLink.path))
        ) {
          Button(ClairDaemonLauncher.isCommandInstalled ? tr("再インストール") : tr("インストール")) {
            Task.detached {
              let note: String
              do { try ClairDaemonLauncher.installCommand(); note = tr("インストールしました(%@)。", ClairDaemonLauncher.commandLink.path) } catch {
                note = error.localizedDescription
              }
              await MainActor.run { integrationNotes["command"] = note }
            }
          }
        }
        SettingsRow(
          title: tr("Agent skill をインストール"),
          note: integrationNotes["skill"] ?? (ClairSkills.isInstalled()
            ? tr("インストール済み(~/.claude/skills, ~/.agents/skills)。")
            : tr("clair-agents / clair-preview skill を ~/.claude/skills と ~/.agents/skills に置きます。"))
        ) {
          Button(ClairSkills.isInstalled() ? tr("再インストール") : tr("インストール")) {
            do { try ClairSkills.install(); integrationNotes["skill"] = tr("インストールしました。") } catch {
              integrationNotes["skill"] = tr("インストールできません: %@", error.localizedDescription)
            }
          }
        }
        SettingsRow(
          title: tr("Claude Code の Ctrl+G で Clair を使う"),
          note: integrationNotes["editor"] ?? (ClairClaudeEditor.isInstalled()
            ? tr("設定済み(~/.claude/settings.json の env.VISUAL)。タブを閉じると Claude に戻ります。")
            : tr("~/.claude/settings.json の env.VISUAL に「%@」を設定します。", ClairClaudeEditor.command))
        ) {
          let installed = ClairClaudeEditor.isInstalled()
          Button(installed ? tr("アンインストール") : tr("インストール")) {
            do {
              if installed { try ClairClaudeEditor.uninstall() } else { try ClairClaudeEditor.install() }
              integrationNotes["editor"] = installed ? tr("アンインストールしました。") : tr("インストールしました。Claude Code を再起動すると有効になります。")
            } catch { integrationNotes["editor"] = tr("インストールできません: %@", error.localizedDescription) }
          }
        }
      }
    }

    @ViewBuilder private var updateSection: some View {
      let c = store.updateConfig
      SettingsCard(title: tr("バージョン")) {
        SettingsRow(title: tr("現在のバージョン"), note: "\(c.channel.displayName) \(c.currentVersion)") {
          if c.channel == .dev {
            Text(tr("Dev ビルドは更新フィードを持ちません。")).font(.system(size: 14)).foregroundStyle(C.textMuted)
          } else {
            switch store.update {
            case .idle: Text(tr("最新の状態です。")).font(.system(size: 14)).foregroundStyle(C.textTertiary)
            case .checking: Text(tr("確認中…")).font(.system(size: 14)).foregroundStyle(C.textTertiary)
            case .installing: Text(tr("更新を適用しています。完了後に再起動します。")).font(.system(size: 14)).foregroundStyle(C.textTertiary)
            case .failed(let m): Text(m).font(.system(size: 14)).foregroundStyle(C.textTertiary)
            case .available(let u):
              HStack(spacing: 8) {
                Text(tr("%@ が利用できます", u.version)).font(.system(size: 14)).foregroundStyle(C.textSecondary)
                Button(tr("適用して再起動")) { Task { await store.installUpdate() } }
              }
            }
          }
        }
        if c.channel != .dev {
          SettingsRow(title: tr("更新を確認")) { Button(tr("確認")) { Task { await store.checkForUpdate(manual: true) } } }
        }
        SettingsRow(title: tr("チェンジログ"), note: tr("GitHub の CHANGELOG.md をブラウザで開きます。")) {
          Button(tr("ブラウザで開く")) { NSWorkspace.shared.open(ClairUpdateConfiguration.changelogURL) }
        }
      }
    }

    private func switchRow(_ title: String, _ key: String, note: String? = nil) -> some View {
      SettingsRow(title: title, note: note) {
        SettingsSwitch(on: st.toggles[key] ?? false) { store.run("settings.set", ["key": .string(key), "value": .bool($0)]) }
      }
    }

    /// Installed fixed-pitch families, read once; the stored family stays listed even if it was uninstalled.
    private static let monospacedFamilies = NSFontManager.shared.availableFontFamilies.filter {
      NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: 12)?.isFixedPitch == true
    }

    private func fontRow(_ key: String) -> some View {
      let current = st.fonts[key] ?? ""
      let families = Self.monospacedFamilies + (current.isEmpty || Self.monospacedFamilies.contains(current) ? [] : [current])
      return SettingsRow(title: tr("フォント"), note: tr("インストール済みの等幅フォントから選びます。")) {
        Picker(tr("フォント"), selection: Binding(get: { current }, set: { store.run("settings.font", ["key": .string(key), "value": .string($0)]) })) {
          Text(tr("システム等幅")).tag("")
          ForEach(families, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden().controlSize(.large).frame(width: 220)
      }
    }

    private var editorStyle: EditorStyle {
      EditorStyle(family: st.fonts["editor"] ?? "", size: CGFloat(Double(st.choices["editorFontSize"] ?? "") ?? 12),
        lineNumbers: st.toggles["lineNumbers"] != false)
    }

    private var terminalStyle: ClairGhosttySurfaceView.Style {
      .init(family: st.fonts["terminal"] ?? "", size: Double(st.choices["terminalFontSize"] ?? "") ?? 13,
        cursor: ["バー": "bar", "下線": "underline"][st.choices["terminalCursorStyle"] ?? ""] ?? "block",
        blink: st.toggles["terminalCursorBlink"] != false)
    }

    private func choiceRow(_ title: String, _ key: String, note: String? = nil) -> some View {
      SettingsRow(title: title, note: note) {
        SettingsSegmented(options: WorkbenchState.choiceOptions[key] ?? [], value: st.choices[key] ?? "") {
          store.run("settings.choose", ["key": .string(key), "value": .string($0)])
        }
      }
    }

    // agent registry: a Menu, not SettingsSegmented, because the registry can list more agents
    // than a segmented control reads well; same picker idiom as the "〜をレビュー" submenu.
    private var defaultAgentRow: some View {
      SettingsRow(title: tr("既定のAgent"), note: tr("⌃⌘N で追加するときの初期選択。titlebarのタブは個別に選べます。")) {
        Menu {
          ForEach(AgentProfile.all, id: \.id) { profile in
            Button(profile.title) { store.run("settings.choose", ["key": .string("defaultAgent"), "value": .string(profile.id)]) }
          }
        } label: {
          Text(AgentProfile.named(st.choices["defaultAgent"] ?? "")?.title ?? "Agent")
            .font(.system(size: 14)).foregroundStyle(C.textSecondary)
        }
      }
    }

    /// U06/U05: facts only — branch, dirty count, agent state. The changed-file count lives in the Git panel, not here (owner, 2026-09-24).
    /// Mock `AppStatusBar`: branch, ahead/behind, caret, then the session count on the right. 26px, sans, `textTertiary`.
    /// Mock `QuotaMeter` (H11): the tightest window across providers; the tooltip lists every provider, unread ones included.
    private func quotaTint(_ usedPercent: Double) -> Color {
      if usedPercent <= 50 { return C.success }
      if usedPercent <= 90 { return C.attention }
      return C.danger
    }

    /// Vendor logos are fetched from each vendor's own site favicon at runtime rather than
    /// redistributed in this repository; offline or on failure the provider's initial stands in.
    @ViewBuilder private func quotaProviderIcon(_ provider: String, size: CGFloat = 15) -> some View {
      ProviderBrandIcon(provider: provider, size: size)
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
            .overlay(alignment: .leading) { Capsule().fill(tint).frame(width: 34 * min(max(1 - top.window.usedPercent / 100, 0), 1)) }
          Text(tr("残り%@%", top.window.remainingPercent)).fontWeight(.semibold).foregroundStyle(tint)
        } else {
          Text(quota.isEmpty ? tr("利用枠を取得中…") : tr("利用枠 —")).foregroundStyle(C.textQuaternary)
        }
      }
      .contentShape(Rectangle())
      .onHover { quotaHovered = $0 }
      .popover(isPresented: $quotaHovered, arrowEdge: .top) {
        VStack(alignment: .leading, spacing: 12) {
          if quota.isEmpty {
            Text(tr("利用枠を取得中…")).foregroundStyle(C.textTertiary)
          }
          ForEach(quota, id: \.provider) { provider in
            VStack(alignment: .leading, spacing: 7) {
              HStack {
                quotaProviderIcon(provider.provider, size: 20)
                Text(provider.provider).font(.system(size: 14, weight: .semibold))
                Spacer()
                if case .ok = provider.state {
                  Text(provider.isStale(now: now) ? tr("古い値 · %@ 取得", provider.fetchedAt.formatted(date: .omitted, time: .shortened)) : tr("%@ 取得", provider.fetchedAt.formatted(date: .omitted, time: .shortened)))
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
                      Text(tr("残り%@%", window.remainingPercent)).fontWeight(.semibold)
                    }
                    GeometryReader { geometry in
                      Capsule().fill(L.strong)
                        .overlay(alignment: .leading) {
                          Capsule().fill(provider.isStale(now: now) ? C.textQuaternary : quotaTint(window.usedPercent))
                            .frame(width: geometry.size.width * min(max(1 - window.usedPercent / 100, 0), 1))
                        }
                    }
                    .frame(height: 4)
                    .accessibilityHidden(true)
                  }
                  .accessibilityElement(children: .combine)
                }
              case .unavailable(let reason):
                Text(tr("取得できません — %@", reason)).foregroundStyle(C.textTertiary)
              case .unsupported(let reason):
                Text(tr("未対応 — %@", reason)).foregroundStyle(C.textTertiary)
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
          Text([errors > 0 ? tr("エラー %@", errors) : nil, warnings > 0 ? tr("警告 %@", warnings) : nil].compactMap { $0 }.joined(separator: " · "))
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
      .buttonStyle(.hoverWash).help(tr("通知")).accessibilityLabel(unread > 0 ? tr("通知 未読 %@ 件", unread) : tr("通知"))
      .popover(isPresented: $noticesOpen, arrowEdge: .top) {
        VStack(alignment: .leading, spacing: 0) {
          HStack {
            Text(tr("通知")).font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(tr("すべて既読")) { store.run("notice.markRead", [:]) }.disabled(unread == 0)
            Button(tr("消去")) { store.run("notice.clear", [:]) }.disabled(st.notices.items.isEmpty)
          }
          .buttonStyle(.borderless).padding(10)
          Divider()
          if st.notices.items.isEmpty {
            Text(tr("通知はありません")).foregroundStyle(C.textQuaternary).padding(12)
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
                        Text(n.sessionTitle ?? tr("ターミナル %@", n.pane))
                          .foregroundStyle(C.textPrimary)
                        Text(tr("%@ · ターミナル %@ · %@", n.project, n.pane, n.title)).foregroundStyle(n.kind == .exited && n.exitCode != 0 ? C.attention : C.textTertiary)
                        if let body = n.sourceBody, !body.isEmpty { Text(body).foregroundStyle(C.textSecondary).fixedSize(horizontal: false, vertical: true) }
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
          Text(tr("設定 · %@", tr(st.section)))
        } else {
          if let branch {
            Button { store.run("git.branches") } label: {
              HStack(spacing: 4) {
                GitBranchGlyph().stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                  .frame(width: 11, height: 11)
                Text(branch)
              }.padding(.horizontal, 6).frame(minHeight: 18)
            }
            .buttonStyle(.hoverWash).fixedSize().disabled(gitOperation != nil).help(tr("ブランチを切り替え / 作成"))
          }
          if st.isRepo {
            // VS Code-style sync: one button shows ↓behind ↑ahead and runs pull then push.
            Button { runGit([("git.pull", [:]), ("git.push", [:])], label: "Sync", confirmed: true) } label: {
              HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10))
                if let sync, sync.behind + sync.ahead > 0 { Text("\(sync.behind)↓ \(sync.ahead)↑") }
              }.frame(minHeight: 18)
            }.buttonStyle(.hoverWash).disabled(gitOperation != nil).help(sync.map { tr("%@ の同期: pull %@ 件 / push %@ 件\nクリックで Pull → Push", branch ?? "", $0.behind, $0.ahead) } ?? tr("同期 (Pull → Push)"))
            if let gitOperation { ProgressView().controlSize(.small).help(tr("%@中", gitOperation)) }
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
          if !st.dirty.isEmpty { Text(tr("未保存 %@", st.dirty.count)).foregroundStyle(C.attention) }
          if let caret { Text("Ln \(caret.line), Col \(caret.col)") }
          languageStatus
        }
        Spacer()
        ClairResourceMeter { terminalTabTitle($0, $1) }  // same name as the terminal's tab
        if st.toggles["hideQuota"] != true { quotaMeter }
        Button { sidebarMode = "terminal" } label: {
          HStack(spacing: 5) {
            if waiting > 0 { Circle().fill(C.attention).frame(width: 6, height: 6) }
            Text(tr("%@ セッション", agents.count) + (waiting > 0 ? tr(" · 入力待ち %@", waiting) : ""))
          }
        }.buttonStyle(.hoverWash)
        noticeButton
        Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"))
      }
      .font(Typography.font(Typography.chrome)).monospacedDigit().foregroundStyle(C.textTertiary)
      .padding(.horizontal, 12).frame(height: ChromeBudget.statusBar)
      .background(C.chrome.overlay(ClairChannel.current == .dev ? Color.orange.opacity(0.14) : .clear))  // Dev is told apart at a glance (owner, 2026-09-27)
      .overlay(alignment: .top) { Rectangle().fill(C.surfaceActive).frame(height: 1) }
      // Here, not on `body`: its modifier chain is at the type-checker's limit. The status bar is always mounted.
      .onChange(of: store.gitRevision) { reloadChanges() }
      // Off the main actor, every 5 min while the toggle is on; turning it off cancels the loop.
      .task(id: st.toggles["hideQuota"] != true) {
        guard st.toggles["hideQuota"] != true else { quota = []; return }
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
      case .branches:
        let q = query.trimmingCharacters(in: .whitespaces)
        let rows = branches.filter { q.isEmpty || $0.lowercased().contains(q.lowercased()) }.map {
          // The checked-out branch just closes the palette (switching to it would be a no-op that can still fail on dirty buffers).
          $0 == branch ? PaletteItem(title: $0, hint: tr("現在"), id: "palette.close", input: [:])
            : PaletteItem(title: $0, hint: "", id: "git.switch", input: ["name": .string($0)])
        }
        guard !q.isEmpty, !branches.contains(q) else { return rows }
        return rows + [PaletteItem(title: tr("新しいブランチを作成: %@", q), hint: "", id: "git.branchCreate", input: ["name": .string(q)])]
      case .references:  // references, file symbols and problems: match the location or the name
        let q = query.lowercased()
        return store.languageItems.filter { q.isEmpty || $0.hint.lowercased().contains(q) || $0.title.lowercased().contains(q) }
      default: return store.registry.paletteItems(p, query: query, state: st)
      }
    }

    private func paletteView(_ p: WorkbenchState.Palette) -> some View {
      let list = items(p)
      return ZStack {
        Color(red: 8 / 255, green: 10 / 255, blue: 12 / 255).opacity(0.68).onTapGesture { store.run("palette.close") }
        // Esc closes even when focus stayed in the terminal/editor (a key equivalent runs before keyDown).
        Button("") { store.run("palette.close") }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
        VStack(spacing: 0) {
          HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(C.textQuaternary)
            TextField("", text: $query)
              .focused($paletteFocused).task(id: p) { await focusField { paletteFocused = true } }
              .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(C.textPrimary)
              .onSubmit { run(list) }
              .onKeyPress(.downArrow) { selection = min(selection + 1, max(list.count - 1, 0)); return .handled }
              .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
              .onKeyPress(.escape) { store.run("palette.close"); return .handled }
              .onChange(of: query) { selection = 0 }
            Text(tr("%@ 件", list.count)).font(.system(size: 11)).foregroundStyle(C.textQuaternary)
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
          .contentShape(Rectangle()).onTapGesture { paletteFocused = true }
          .padding(12)
          ScrollViewReader { proxy in ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(Array(list.enumerated()), id: \.offset) { i, it in
                let on = i == selection
                HStack(spacing: 8) {
                  if p == .files || p == .compare || p == .recent { FileIcon.forPath(it.title).image(size: 11, ink: C.textTertiary).frame(width: 14) }
                  if p == .branches {
                    Group {
                      if it.id == "git.branchCreate" { Image(systemName: "plus").font(.system(size: 10)) }
                      else { GitBranchGlyph().stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)).frame(width: 11, height: 11) }
                    }.foregroundStyle(C.textTertiary).frame(width: 14)
                  }
                  Text(p == .files || p == .compare || p == .recent ? name(it.title) : it.title).font(.system(size: 12)).lineLimit(1)
                    .foregroundStyle(on ? C.textPrimary : C.textSecondary)
                  if !it.detail.isEmpty { Text(it.detail).font(.system(size: 11)).lineLimit(1).foregroundStyle(C.textQuaternary) }
                  Spacer(minLength: 0)
                  if p == .files || p == .compare || p == .recent {
                    Text(it.title).font(.system(size: 11)).lineLimit(1).truncationMode(.head).foregroundStyle(C.textQuaternary)
                  }
                  if p == .symbols || p == .references || p == .branches {
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
                .onHover { if $0 { selection = i } }
                .onTapGesture { selection = i; run(list) }
                .id(i)
              }
            }.padding(.horizontal, 8).padding(.bottom, 8)
          }.onChange(of: selection) { proxy.scrollTo(selection) } }.frame(minHeight: 322, maxHeight: 420)
          HStack(spacing: 8) {
            ForEach([(tr("コマンド"), WorkbenchState.Palette.commands), (tr("ファイルへ移動"), .files)], id: \.1) { label, mode in
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
        .transition(.scale(scale: 0.97).combined(with: .opacity))
      }
    }

    private func run(_ list: [PaletteItem]) {
      guard selection < list.count else { return }
      let it = list[selection]
      store.run("palette.close")
      switch it.id {
      case "git.switch": runGit([(it.id, it.input)], label: tr("ブランチ切替"))
      case "git.branchCreate": runGit([(it.id, it.input)], label: tr("ブランチ作成"))
      default: store.performFromUI(it.id, it.input)
      }
    }
  }

  /// Our SwiftUI titlebar covers AppKit's, so its empty areas re-implement the native titlebar: drag moves the window and
  /// a double-click does what System Settings › Desktop & Dock › "Double-click a window's title bar to" says.
  private struct TitlebarArea: NSViewRepresentable {
    final class Area: NSView {
      // Only this view's mouseDown should move the window; a tab above it owns its own drag.
      override var mouseDownCanMoveWindow: Bool { false }
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

  /// Sits behind titlebar tabs/group chips so a press on their empty parts reaches the item, not `TitlebarArea`'s
  /// performDrag underneath. The window server's own titlebar drag is stopped by AppDelegate's TitlebarDragShield.
  private struct NoWindowDrag: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
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

    var body: some View {
      Button(action: action) {
        Group {
          if icon == "concierge" {
            Image(systemName: "brain.head.profile").font(.system(size: 16))
          } else if icon == "shield" {
            GitBranchGlyph().stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
              .frame(width: 16, height: 16)
          } else {
            Image(systemName: icon).font(.system(size: 16))
          }
        }
          .foregroundStyle(on ? C.chromeInk : C.chromeInkMuted)
          .frame(width: ChromeBudget.cellControl, height: ChromeBudget.cellControl)
          .background(on ? W.selected : .clear, in: RoundedRectangle(cornerRadius: Radius.card))
          .opacity(enabled ? 1 : 0.35)
      }
      .buttonStyle(.hoverWash).disabled(!enabled).help(enabled ? "" : tr("準備中"))
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

  /// Shared by the status quota and terminal tabs, with the same offline fallback.
  struct ProviderBrandIcon: View {
    let provider: String
    let size: CGFloat
    // Claude's installed app ships a transparent menu-bar symbol. Read it once;
    // the web favicon below remains the fallback on other Macs.
    private static let claudeSymbol: NSImage? = {
      guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop"),
        let image = NSImage(contentsOf: app.appending(path: "Contents/Resources/TrayIconTemplate@3x.png"))
      else { return nil }
      image.isTemplate = true
      return image
    }()

    var body: some View {
      let domain: String? = switch provider {
      case "Codex": "chatgpt.com"
      case "Claude Code": "claude.ai"
      case "OpenCode": "opencode.ai"
      default: nil
      }
      if provider == "Claude Code", let claudeSymbol = Self.claudeSymbol {
        Image(nsImage: claudeSymbol).renderingMode(.template).resizable().scaledToFit()
          .foregroundStyle(Color(red: 217.0 / 255, green: 119.0 / 255, blue: 87.0 / 255))
          .frame(width: size, height: size).accessibilityHidden(true)
      } else if let domain {
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
  }

  private struct FileTabButton: View {
    let path: String
    let name: String
    let selected: Bool
    let dirty: Bool
    let onActivate: () -> Void
    let onClose: () -> Void
    var icon: String?
    var providerIcon: String?
    var onMove: (@MainActor @Sendable (String) -> Void)?

    @State private var isHovered = false
    @State private var isDropTarget = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
      let tint = selected ? C.chromeInk : C.textTertiary
      HStack(spacing: 4) {
        tabIcon(tint: tint)
        Text(name).font(.system(size: 11, weight: selected ? .semibold : .regular)).foregroundStyle(tint).lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 0)
        if dirty { Circle().fill(selected ? C.textTertiary : C.textQuaternary).frame(width: 6, height: 6) }
        Button(action: onClose) {
          Image(systemName: "xmark").font(.system(size: 9, weight: .medium)).foregroundStyle(C.textTertiary)
        }
        .buttonStyle(.hoverWash)
        .help(tr("閉じる"))
        .opacity((selected || isHovered) ? 1 : 0)
        .allowsHitTesting(selected || isHovered)
      }
      .padding(.horizontal, 8).frame(width: 200, height: ChromeBudget.cellControl)
      .background(selected ? W.selected : isHovered ? W.soft : .clear, in: RoundedRectangle(cornerRadius: Radius.card))
      .background(NoWindowDrag())
      .contentShape(Rectangle())
      // Same feel as the pane header drag: a card-shaped ghost of the tab and a ring on the drop target.
      .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(isDropTarget ? L.ring : .clear, lineWidth: 1))
      .onDrag({ NSItemProvider(object: NSString(string: path)) }, preview: {
        HStack(spacing: 4) {
          tabIcon(tint: C.chromeInk)
          Text(name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(C.chromeInk).padding(.horizontal, 10).frame(height: 30)
        .background(C.surface, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(L.ring, lineWidth: 1))
        .opacity(0.9)
      })
      .onDrop(of: [.text], isTargeted: $isDropTarget) { providers in
        guard let onMove, let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
          guard let from = (object as? NSString).map({ $0 as String }), !from.hasPrefix(ClairAppShell.groupDragPrefix) else { return }
          Task { @MainActor in onMove(from) }
        }
        return true
      }
      .onHover { isHovered = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: Motion.overlayDuration), value: isHovered)  // short fade, no flicker
      .onTapGesture(perform: onActivate)
      .help(path)
    }

    @ViewBuilder private func tabIcon(tint: Color) -> some View {
      if let providerIcon {
        ProviderBrandIcon(provider: providerIcon, size: 13)
      } else {
        if let icon {
          Image(systemName: icon).font(.system(size: 11)).foregroundStyle(tint)
        } else {
          FileIcon.forPath(path).image(size: 11, ink: tint)
        }
      }
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
        // Title top-left so a running agent's task stays readable; drag handle top-centre.
        Text(label).font(Typography.font(Typography.chrome)).foregroundStyle(focused ? C.textTertiary : C.textQuaternary)
          .lineLimit(1).truncationMode(.tail).padding(.leading, 6).frame(maxWidth: .infinity, alignment: .leading)
          .overlay {
            Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(C.textQuaternary)
              .opacity(isHovered ? 1 : 0).accessibilityHidden(true)
          }
        Button(action: onClose) {
          Image(systemName: "xmark").font(.system(size: 9, weight: .medium)).foregroundStyle(C.textQuaternary)
        }.buttonStyle(.hoverWash).help(tr("パネルを閉じる")).opacity((isHovered || focused) ? 1 : 0)
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
  private struct PaneView: View {
    let node: PaneTree.Node
    let focused: Int
    let launches: [Int: AgentLaunch]
    let project: String
    let onFocus: (Int) -> Void
    let onFacts: (Int, Int, Int?, (title: String, body: String)?) -> Void
    let onTitle: (Int, String) -> Void
    /// A terminal pane's live title (OSC 0/2, e.g. what `claude` is doing).
    let title: (Int) -> String
    let onRatio: (Int, Double) -> Void
    let editor: EditorPane
    let run: (String, CommandInput) -> Void
    /// Pane whose header handle is being dragged; other panes show edge drop zones meanwhile.
    @Binding var dragging: Int?
    /// Only first children all the way down: the anchored editor slot (`PaneTree.replaceFocusedEditor`).
    var leftmost = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

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
      PaneView(node: a, focused: focused, launches: launches, project: project, onFocus: onFocus, onFacts: onFacts, onTitle: onTitle, title: title, onRatio: onRatio, editor: editor, run: run, dragging: $dragging, leftmost: leftmost)
        .frame(width: h ? total * ratio : nil, height: h ? nil : total * ratio)
      Rectangle().fill(L.paneDivider).frame(width: h ? 1 : nil, height: h ? nil : 1)
      PaneView(node: b, focused: focused, launches: launches, project: project, onFocus: onFocus, onFacts: onFacts, onTitle: onTitle, title: title, onRatio: onRatio, editor: editor, run: run, dragging: $dragging, leftmost: false)
    }

    var body: some View {
      switch node {
      case .leaf(let id, let kind):
        VStack(spacing: 0) {
          if kind != .editor && kind != .graph {
            PaneHeaderView(
              id: id, label: kind == .preview ? (editor.previews[id].map { ($0 as NSString).lastPathComponent } ?? "") : kind == .graph ? tr("コミットグラフ") : title(id), focused: id == focused,
              onSwap: { run("pane.swap", ["idA": .int($0), "idB": .int($1)]) },
              onDragStart: { dragging = id }, onDragEnd: { dragging = nil },
              onClose: { run("pane.focus", ["id": .int(id)]); run("pane.close", [:]) })
          }
          ZStack {
            C.surface
            if kind == .terminal { ClairGhosttySurface(launch: launches[id].map { ($0.command, $0.cwd) } ?? (project.hasPrefix("/") ? ("", project) : nil), pane: id, sessionKey: ClairWorkbenchStore.terminalKey(root: project, pane: id), focused: id == focused, onFocus: { if id != focused { onFocus(id) } }, onFacts: { onFacts(id, $0, $1, $2) }, onTitle: { onTitle(id, $0) }).id(ClairWorkbenchStore.terminalKey(root: project, pane: id)) }  // one surface per terminal leaf, attached to the daemon shell keyed by project#pane; .id rebuilds it on a project switch (updateNSView never re-attaches)
            else if kind == .graph { CommitGraphPane(root: project) }
            else if kind == .preview, let path = editor.previews[id] ?? editor.path, TableFile.separator(path) != nil { TablePane(buffers: editor.buffers, path: path, onEdit: editor.onEdit) }
            else if kind == .preview, let path = editor.previews[id] ?? editor.path, path.lowercased().hasSuffix(".html") || path.lowercased().hasSuffix(".htm") { HTMLPreviewPane(buffers: editor.buffers, root: editor.root, path: path) }
            else if kind == .preview { MarkdownPreviewPane(buffers: editor.buffers, root: editor.root, path: editor.previews[id] ?? editor.path) }
            else { editor.inPane(focused: id == focused, onFocus: { if id != focused { onFocus(id) } },
              // Split editors have no pane header; the leftmost one is anchored (`pane.close` replaces it).
              onClose: leftmost ? nil : { run("pane.focus", ["id": .int(id)]); run("pane.close", [:]) }) }
            if let from = dragging, from != id {
              PaneDropZones { edge in
                run("pane.move", ["id": .int(from), "target": .int(id), "edge": .string(edge.rawValue)])
                dragging = nil
              } onCancel: { dragging = nil }
            }
          }
        }
        // Keep the editor and preview panes fully legible even when another pane is focused.
        .opacity(kind == .editor || kind == .preview || id == focused ? 1 : 0.75)
        // A split focuses the new pane, so the focused leaf fades in when it appears.
        // ponytail: the tree re-renders on split, so this keys off focus, not "is new".
        .opacity(shown || id != focused || reduceMotion ? 1 : 0)
        .onAppear { withAnimation(.easeOut(duration: Motion.screenDuration)) { shown = true } }
        .onTapGesture { onFocus(id) }
        // ponytail: the libghostty NSView may consume right-clicks, so terminal panes might not show this; copy/paste/clear items wait on U06 surface commands.
        .contextMenu {
          Button(tr("右に分割")) { run("pane.focus", ["id": .int(id)]); run("pane.splitRight", [:]) }
          Button(tr("下に分割")) { run("pane.focus", ["id": .int(id)]); run("pane.splitDown", [:]) }
          Button(tr("最大化")) { run("pane.focus", ["id": .int(id)]); run("pane.maximize", [:]) }
          Divider()
          Button(tr("ペインを閉じる"), role: .destructive) { run("pane.focus", ["id": .int(id)]); run("pane.close", [:]) }
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
  /// Lets banners show while Clair is frontmost (the "Clair が前面のときも通知" toggle and the test button).
  final class ClairNotificationPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = ClairNotificationPresenter()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
      done([.banner, .sound])
    }
  }
#endif
