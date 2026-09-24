import Foundation

// V01: ADR-0007 typed Command Registry. Every Mac workbench operation is a
// command here; palette, menu and shortcuts are projections of `commands`,
// and a test/CLI caller runs the exact same `execute`. State owner is the GUI
// process (ADR-0007 "State owner" addendum); this file is UI-free so the same
// registry can later be served over IPC (V02) and MCP (V03).
// Invariants/test matrix: docs/plans/clair-v01-command-registry.md.

public struct WorkbenchFile: Sendable, Codable, Equatable {
  public let path: String
  public let status: String?
}

public struct WorkbenchState: Sendable, Codable, Equatable {
  public enum Palette: String, Sendable, Codable { case commands, files, search, symbols, references }

  public static let sections = ["一般", "AIプロバイダー", "使用状況", "エディタ", "ターミナル", "モバイル", "アップデート"]
  public static let toggleKeys = ["restoreLayout", "confirmClose", "showQuota", "preventSleepOnBattery", "formatOnSave", "showWhitespace", "softWrap", "terminalApprovals"]
  /// Closed-set settings (the mock's segmented controls). The first option is the default.
  public static let choiceOptions: [String: [String]] = [
    "defaultAgent": ["claude", "codex"],
    "approvalPolicy": ["毎回確認", "セッション中は許可", "自動承認"],
    "tabWidth": ["2", "4", "8"],
    "defaultShell": ["/bin/zsh", "/bin/bash"],
    "scrollback": ["1000", "5000", "10000"],
  ]

  // Sample tree only until a Project is opened (`project.open` replaces it with the real file system).
  public var files = [
    WorkbenchFile(path: "apple/ClairApp/ContentView.swift", status: "M"),
    WorkbenchFile(path: "apple/ClairApp/ProjectWorkspace.swift", status: "M"),
    WorkbenchFile(path: "apple/ClairApp/PaneSplit.swift", status: "A"),
    WorkbenchFile(path: "apple/ClairApp/SessionRail.swift", status: "A"),
    WorkbenchFile(path: "docs/architecture/pane-layout.md", status: nil),
  ]
  public var projects: [WorkbenchProject] = []
  public var project = ""
  /// Layouts of inactive Projects (V04); the active one lives in the fields below.
  public var layouts: [String: ProjectLayout] = [:]
  /// Last scanned tree per Project; not persisted, only makes switching back instant.
  var filesCache: [String: [WorkbenchFile]] = [:]
  public var tree = PaneTree()
  /// Every pane was closed (⌘W on the last one): the shell shows the empty panel instead of `tree`. Transient.
  public var panesClosed = false
  public var tabs: [String] = ["apple/ClairApp/ContentView.swift"]
  public var active: String? = "apple/ClairApp/ContentView.swift"
  public var dirty: Set<String> = []
  public var collapsed: Set<String> = []
  public var launches: [Int: AgentLaunch] = [:]
  /// CLI agents started by hand in Clair terminals. Refreshed from live process facts, never saved.
  public var detectedLaunches: [String: [Int: AgentLaunch]] = [:]
  /// Latest OSC 0/2 window title per `NotificationLog.paneKey`, as Ghostty shows in its tab. Transient.
  public var paneTitles: [String: String] = [:]
  public var notices = NotificationLog()
  public var settingsOpen = false
  /// Transient UI navigation request. The sidebar selection itself belongs to the app shell.
  public var debugNavigationGeneration = 0
  public var debugPhase = "idle"  // transient; refreshed by the GUI before a debugger command
  public var section = "一般"
  public var palette: Palette?
  public var toggles = ["restoreLayout": true, "confirmClose": true, "showQuota": false, "preventSleepOnBattery": false, "formatOnSave": false, "showWhitespace": false, "softWrap": false, "terminalApprovals": true]
  public var choices = WorkbenchState.choiceOptions.mapValues { $0[0] }
  /// V11: user shortcut assignments over the registry defaults. An empty string unassigns a default.
  public var shortcuts: [String: String] = [:]

  public init() {}

  /// The shortcut a command answers to now: the user's assignment, else its default.
  public func shortcut(for d: CommandDescriptor) -> String? {
    guard let s = shortcuts[d.id] else { return d.shortcut }
    return s.isEmpty ? nil : s
  }
}

extension WorkbenchState {
  static let shortcutModifiers = ["⌃", "⌥", "⌘", "⇧"]  // canonical order; matches the registry defaults
  static let shortcutKeys = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789,./;'[]-=`\\→←↑↓")

  /// `⇧⌘d` → `⌘⇧D`. nil unless it is one key plus at least one of ⌃⌥⌘ (a bare or shift-only key would eat typing).
  public static func canonicalShortcut(_ raw: String) -> String? {
    guard let key = raw.last.map({ Character($0.uppercased()) }), shortcutKeys.contains(key) else { return nil }
    let mods = raw.dropLast()
    guard Set(mods).count == mods.count, mods.allSatisfy({ shortcutModifiers.contains(String($0)) }) else { return nil }
    let ordered = shortcutModifiers.filter { mods.contains(Character($0)) }
    return ordered.contains { $0 != "⇧" } ? ordered.joined() + String(key) : nil
  }
}

/// Fixed risk class. Preflight may only raise it (ADR-0007).
public enum CommandRisk: Int, Sendable, Codable, Comparable {
  case read, additive, write, destructive, external
  public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
  public var label: String { ["読み取り", "追加", "書き込み", "破壊的", "外部"][rawValue] }
}

public enum CommandArg: Sendable, Codable, Equatable {
  case string(String), int(Int), double(Double), bool(Bool)

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if let v = try? c.decode(Bool.self) { self = .bool(v) }
    else if let v = try? c.decode(Int.self) { self = .int(v) }
    else if let v = try? c.decode(Double.self) { self = .double(v) }
    else { self = .string(try c.decode(String.self)) }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .string(let v): try c.encode(v)
    case .int(let v): try c.encode(v)
    case .double(let v): try c.encode(v)
    case .bool(let v): try c.encode(v)
    }
  }

  var string: String? { if case .string(let v) = self { v } else { nil } }
  var int: Int? { if case .int(let v) = self { v } else { nil } }
  var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
  var double: Double? {
    switch self { case .double(let v): v; case .int(let v): Double(v); default: nil }
  }
}

public typealias CommandInput = [String: CommandArg]

public struct CommandParam: Sendable, Codable, Equatable {
  public enum Kind: String, Sendable, Codable { case string, int, double, bool }
  public let name: String
  public let kind: Kind
  public let required: Bool
  public let allowed: [String]?

  public init(_ name: String, _ kind: Kind, required: Bool = true, allowed: [String]? = nil) {
    self.name = name; self.kind = kind; self.required = required; self.allowed = allowed
  }
}

public enum CommandResult: Sendable, Codable, Equatable {
  case ok
  case pane(Int)
  case snapshot(WorkbenchState)
  case text(String)
  case review(GitReview)
}

public struct CommandError: Error, Sendable, Codable, Equatable {
  public enum Code: String, Sendable, Codable { case unknownCommand, invalidInput, preconditionFailed, confirmationRequired, notAvailableToAI, denied }
  public let code: Code
  public let message: String
  public init(_ code: Code, _ message: String) { self.code = code; self.message = message }
}

public struct CommandDescriptor: Sendable, Codable, Equatable {
  public let id: String
  public let title: String
  public let risk: CommandRisk
  public let aiAvailable: Bool
  public let params: [CommandParam]
  /// Default shortcut as display string, e.g. `⌃⌘⇧D`. Last character is the key.
  public let shortcut: String?
  /// Listed in the ⌘K palette (UI-only commands and ones needing arguments are not).
  public let inPalette: Bool
}

public struct PaletteItem: Sendable, Equatable {
  public let title: String
  public let hint: String
  public let id: String
  public let input: CommandInput

  public init(title: String, hint: String, id: String, input: CommandInput) {
    self.title = title; self.hint = hint; self.id = id; self.input = input
  }
}

public struct CommandRegistry: Sendable {
  struct Command: Sendable {
    let descriptor: CommandDescriptor
    /// Throws for unmet preconditions; returns the effective risk.
    let preflight: @Sendable (WorkbenchState, CommandInput) throws(CommandError) -> CommandRisk
    let run: @Sendable (inout WorkbenchState, CommandInput) -> CommandResult
  }

  private let table: [String: Command]
  public let commands: [CommandDescriptor]

  init(_ list: [Command]) {
    commands = list.map(\.descriptor)
    table = Dictionary(uniqueKeysWithValues: list.map { ($0.descriptor.id, $0) })
  }

  /// Validates input against the schema and returns the effective risk (never below the fixed one).
  public func preflight(_ id: String, _ input: CommandInput = [:], _ state: WorkbenchState) -> Result<CommandRisk, CommandError> {
    guard let c = table[id] else { return .failure(CommandError(.unknownCommand, id)) }
    do {
      try Self.validate(input, c.descriptor.params)
      return .success(max(c.descriptor.risk, try c.preflight(state, input)))
    } catch { return .failure(error) }
  }

  /// Runs a command. `destructive`/`external` effective risk requires `confirmed` (native UI approval).
  @discardableResult
  public func execute(_ id: String, _ input: CommandInput = [:], confirmed: Bool = false, state: inout WorkbenchState) -> Result<CommandResult, CommandError> {
    switch preflight(id, input, state) {
    case .failure(let e): return .failure(e)
    case .success(let risk) where risk >= .destructive && !confirmed:
      return .failure(CommandError(.confirmationRequired, "\(id) is \(risk.label)"))
    case .success: return .success(table[id]!.run(&state, input))
    }
  }

  public func paletteItems(_ kind: WorkbenchState.Palette, query: String, state: WorkbenchState) -> [PaletteItem] {
    let q = query.lowercased()
    switch kind {
    case .commands:
      return commands.filter { $0.inPalette && (state.isRepo || !($0.id.hasPrefix("git.") || $0.id.hasPrefix("worktree."))) && (q.isEmpty || $0.title.lowercased().contains(q)) }
        .map { PaletteItem(title: $0.title, hint: state.shortcut(for: $0) ?? "", id: $0.id, input: [:]) }
        + AgentProfile.all.map { PaletteItem(title: "\($0.title) を起動", hint: "", id: "agent.launch", input: ["profile": .string($0.id)]) }
          .filter { q.isEmpty || $0.title.lowercased().contains(q) }
    case .files:
      return QuickOpen.rank(query, state.files)
        .map { PaletteItem(title: $0.path, hint: "", id: "tab.open", input: ["path": .string($0.path)]) }
    case .search, .symbols, .references:
      return []  // search runs in the GUI; symbols/references come from the language server
    }
  }

  private static func validate(_ input: CommandInput, _ params: [CommandParam]) throws(CommandError) {
    for key in input.keys where !params.contains(where: { $0.name == key }) {
      throw CommandError(.invalidInput, "unknown argument \(key)")
    }
    for p in params {
      guard let v = input[p.name] else {
        if p.required { throw CommandError(.invalidInput, "missing \(p.name)") }
        continue
      }
      let ok: Bool
      switch p.kind {
      case .string: ok = v.string.map { p.allowed?.contains($0) ?? true } ?? false
      case .int: ok = v.int != nil
      case .double: ok = v.double != nil
      case .bool: ok = v.bool != nil
      }
      if !ok { throw CommandError(.invalidInput, "\(p.name) must be \(p.kind.rawValue)\(p.allowed.map { " in \($0)" } ?? "")") }
    }
  }
}

// MARK: - Workbench commands

extension CommandRegistry {
  static func cmd(
    _ id: String, _ title: String, _ risk: CommandRisk, ai: Bool = true, params: [CommandParam] = [],
    shortcut: String? = nil, palette: Bool? = nil,
    preflight: @escaping @Sendable (WorkbenchState, CommandInput) throws(CommandError) -> CommandRisk = { _, _ in .read },
    _ run: @escaping @Sendable (inout WorkbenchState, CommandInput) -> CommandResult
  ) -> Command {
    Command(
      descriptor: CommandDescriptor(
        id: id, title: title, risk: risk, aiAvailable: ai, params: params, shortcut: shortcut,
        inPalette: palette ?? !params.contains(where: \.required)),
      preflight: preflight, run: run)
  }

  private static func require(_ ok: Bool, _ message: @autoclosure () -> String) throws(CommandError) {
    if !ok { throw CommandError(.preconditionFailed, message()) }
  }

  public static let workbench = CommandRegistry(core + [shortcutSet(core.map(\.descriptor))])

  private static let core: [Command] = [
    cmd("pane.splitRight", "ペインを右に分割", .additive, shortcut: "⌘D") { s, _ in
      s.tree.splitFocused(.horizontal, kind: s.active == nil ? .terminal : nil); return .pane(s.tree.focused)
    },
    cmd("pane.splitDown", "ペインを下に分割", .additive, shortcut: "⌘⇧D") { s, _ in
      s.tree.splitFocused(.vertical, kind: s.active == nil ? .terminal : nil); return .pane(s.tree.focused)
    },
    cmd("terminal.show", "ターミナルを開く", .additive, shortcut: "⌘J") { s, _ in
      s.panesClosed = false
      if let terminal = s.tree.leaves.first(where: { $0.kind == .terminal }) {
        if s.tree.maximized != nil, s.tree.maximized != terminal.id { s.tree.toggleMaximize() }
        s.tree.focus(terminal.id)
      } else {
        s.tree.splitFocused(.horizontal, kind: .terminal)
      }
      return .pane(s.tree.focused)
    },
    cmd("pane.focusNext", "ペインのフォーカスを右へ", .read) { s, _ in s.tree.focusNext(); return .ok },
    cmd("pane.focusPrevious", "ペインのフォーカスを左へ", .read) { s, _ in s.tree.focusPrevious(); return .ok },
    cmd("pane.focus", "ペインにフォーカス", .read, params: [CommandParam("id", .int)],
        preflight: { s, i throws(CommandError) in
          try require(s.tree.leaves.contains { $0.id == i["id"]?.int }, "no pane \(i["id"]!)"); return .read
        }) { s, i in s.tree.focus(i["id"]!.int!); return .ok },
    cmd("pane.maximize", "ペインを最大化", .read, shortcut: "⌃⌘M") { s, _ in s.tree.toggleMaximize(); return .ok },
    cmd("pane.equalize", "分割を均等化", .read, shortcut: "⌃⌘=") { s, _ in s.tree.equalize(); return .ok },
    cmd("pane.setRatio", "分割比を変更", .read, params: [CommandParam("id", .int), CommandParam("ratio", .double)]) { s, i in
      s.tree.setRatio(splitContaining: i["id"]!.int!, i["ratio"]!.double!); return .ok
    },
    // Dropping a header handle on another pane's edge moves the pane there.
    cmd("pane.move", "ペインを移動", .write, params: [CommandParam("id", .int), CommandParam("target", .int), CommandParam("edge", .string)],
        preflight: { s, i throws(CommandError) in
          let a = i["id"]?.int, b = i["target"]?.int
          try require(a != nil && b != nil && a != b, "need two different pane ids")
          try require(s.tree.leaves.contains { $0.id == a } && s.tree.leaves.contains { $0.id == b }, "no such pane")
          try require(i["edge"]?.string.flatMap(PaneTree.Edge.init(rawValue:)) != nil, "edge must be left/right/top/bottom")
          var moved = s.tree
          moved.moveLeaf(a!, to: b!, PaneTree.Edge(rawValue: i["edge"]!.string!)!)
          try require(moved != s.tree, "the leftmost pane must remain an editor")
          return .write
        }) { s, i in
      s.tree.moveLeaf(i["id"]!.int!, to: i["target"]!.int!, PaneTree.Edge(rawValue: i["edge"]!.string!)!)
      return .ok
    },
    // Header drag handle drop target swaps what two panes show; tree shape/ratios/focus stay put.
    cmd("pane.swap", "ペインの表示を入れ替え", .write, params: [CommandParam("idA", .int), CommandParam("idB", .int)],
        preflight: { s, i throws(CommandError) in
          let a = i["idA"]?.int, b = i["idB"]?.int
          try require(a != nil && b != nil, "missing pane ids")
          try require(a != b, "cannot swap a pane with itself")
          try require(s.tree.leaves.contains { $0.id == a }, "no pane \(a!)")
          try require(s.tree.leaves.contains { $0.id == b }, "no pane \(b!)")
          var swapped = s.tree
          swapped.swapLeaves(a!, b!)
          try require(swapped != s.tree || s.tree.leaves.first { $0.id == a }?.kind == s.tree.leaves.first { $0.id == b }?.kind,
            "the leftmost pane must remain an editor")
          return .write
        }) { s, i in
      let a = i["idA"]!.int!, b = i["idB"]!.int!
      s.tree.swapLeaves(a, b)
      (s.launches[a], s.launches[b]) = (s.launches[b], s.launches[a])
      return .ok
    },
    // The leftmost editor is replaced on close; open buffers remain available.
    cmd("pane.close", "ペインを閉じる", .write, shortcut: "⌘W",
        preflight: { s, _ throws(CommandError) in
          try require(!s.panesClosed, "no pane to close")
          return .write
        }) { s, _ in
      if s.tree.leaves.first?.id == s.tree.focused, s.tree.leaves.first?.kind == .editor {
        s.tree.replaceFocusedEditor()
        return .ok
      }
      // The tree cannot be empty, so closing the last pane hides it behind the empty panel.
      if s.tree.leaves.count == 1 {
        s.tree.ensureEditorAtLeft()
        s.launches = s.launches.filter { id, _ in s.tree.leaves.contains { $0.id == id } }
        return .ok
      }
      s.tree.closeFocused()
      s.launches = s.launches.filter { id, _ in s.tree.leaves.contains { $0.id == id } }
      return .ok
    },
    cmd("pane.open", "ペインを開く", .additive, params: [CommandParam("kind", .string, allowed: ["editor", "terminal"])]) { s, i in
      s.tree = PaneTree(single: .editor)
      if i["kind"]!.string! == "terminal" { s.tree.splitFocused(.horizontal, kind: .terminal) }
      s.panesClosed = false
      return .pane(s.tree.focused)
    },
    // External: spawns a user-configured executable, so every launch is approved in the GUI (MCPGate).
    // V16: AI-available (owner decision 2026-09-24, spec §9): an agent in a Clair terminal fans out
    // children next to its own pane (`parent`, injected by the GUI from the caller's terminal, never trusted
    // from the client), optionally in a new Clair-managed worktree (`branch`), with a delegated `prompt`.
    // The client still cannot choose cwd or command: cwd is the Project root or the worktree Clair creates.
    cmd("agent.launch", "エージェントを起動", .external,
        params: [
          CommandParam("profile", .string, allowed: AgentProfile.all.map(\.id)),
          CommandParam("prompt", .string, required: false), CommandParam("branch", .string, required: false),
          CommandParam("direction", .string, required: false, allowed: ["right", "down"]),
          CommandParam("parent", .string, required: false),
        ], palette: false,
        preflight: { s, i throws(CommandError) in
          let home = try s.launchHome(i["parent"]?.string)
          if let b = i["branch"]?.string {
            try require(FileManager.default.fileExists(atPath: home.project.path + "/.git"), "not a Git project")
            try require(WorkbenchGit.validBranch(b), "invalid branch name")
            try require(!WorkbenchGit.branchExists(home.project.path, b), "branch \(b) exists")
          }
          return .external
        }) { s, i in
      let home = try! s.launchHome(i["parent"]?.string)
      var cwd = home.project.path
      if let b = i["branch"]?.string {
        guard case .success(let wt) = WorkbenchGit.createWorktree(home.project, branch: b) else { return .text("worktree add failed") }
        s.projects.append(wt); cwd = wt.path
      }
      let launch = AgentLaunch(
        profile: i["profile"]!.string!, cwd: cwd, prompt: i["prompt"]?.string.flatMap { $0.isEmpty ? nil : $0 },
        parent: i["parent"]?.string)
      let axis: PaneTree.Axis = i["direction"]?.string == "down" ? .vertical : .horizontal
      let pane = s.withLayout(home.project.name) { l in
        let id = home.pane.map { l.tree.split($0, axis, kind: .terminal) } ?? { l.tree.splitFocused(.vertical, kind: .terminal); return l.tree.focused }()
        l.launches[id] = launch
        return id
      }
      if home.project.name == s.project { s.panesClosed = false }
      return home.pane == nil ? .pane(pane) : .text(WorkbenchState.terminalKey(home.project.path, pane))
    },
    // V16: fan-in. `key` is the `root#pane` terminal key agent.launch returned.
    cmd("agent.status", "エージェントの状態", .read, params: [CommandParam("key", .string)], palette: false,
        preflight: { s, i throws(CommandError) in _ = try s.delegated(i["key"]!.string!); return .read }) { s, i in
      let l = try! s.delegated(i["key"]!.string!)
      return .text(AgentRun(id: l.run!).exitCode.map { "exited \($0)" } ?? "running")
    },
    cmd("agent.output", "エージェントの出力", .read,
        params: [CommandParam("key", .string), CommandParam("lines", .int, required: false)], palette: false,
        preflight: { s, i throws(CommandError) in _ = try s.delegated(i["key"]!.string!); return .read }) { s, i in
      let l = try! s.delegated(i["key"]!.string!)
      return .text(AgentRun(id: l.run!).output(lines: max(1, i["lines"]?.int ?? 200)))
    },
    // Closing your own finished child is housekeeping; anything else ends someone's session and needs approval.
    cmd("agent.close", "エージェントのペインを閉じる", .read,
        params: [CommandParam("key", .string), CommandParam("parent", .string, required: false)], palette: false,
        preflight: { s, i throws(CommandError) in
          let l = try s.delegated(i["key"]!.string!)
          let own = l.parent != nil && l.parent == i["parent"]?.string && AgentRun(id: l.run!).exitCode != nil
          return own ? .read : .write
        }) { s, i in
      let t = s.terminal(i["key"]!.string!)!
      s.withLayout(t.project) { l in l.tree.close(t.pane); l.launches[t.pane] = nil }
      return .ok
    },
    cmd("tab.open", "ファイルを開く", .read, params: [CommandParam("path", .string)],
        preflight: { s, i throws(CommandError) in
          try require(s.files.contains { $0.path == i["path"]?.string }, "no file \(i["path"]!)"); return .read
        }) { s, i in
      s.openTab(i["path"]!.string!); return .ok
    },
    cmd("tab.activate", "タブを切り替え", .read, params: [CommandParam("path", .string)],
        preflight: { s, i throws(CommandError) in
          try require(s.tabs.contains(i["path"]!.string!), "no tab \(i["path"]!)"); return .read
        }) { s, i in
      s.selectTab(.file(i["path"]!.string!))
      return .ok
    },
    cmd("tab.next", "次のタブ", .read, shortcut: "⌃⌘→") { s, _ in s.cycleTab(1); return .ok },
    cmd("tab.previous", "前のタブ", .read, shortcut: "⌃⌘←") { s, _ in s.cycleTab(-1); return .ok },
    // Drag-reorder: moves `path` into `target`'s slot.
    cmd("tab.move", "タブを移動", .read, params: [CommandParam("path", .string), CommandParam("target", .string)],
        preflight: { s, i throws(CommandError) in
          try require(s.tabs.contains(i["path"]!.string!) && s.tabs.contains(i["target"]!.string!), "no tab"); return .read
        }) { s, i in
      let from = s.tabs.firstIndex(of: i["path"]!.string!)!, to = s.tabs.firstIndex(of: i["target"]!.string!)!
      s.tabs.insert(s.tabs.remove(at: from), at: to); return .ok
    },
    // Omitted `path` means the active tab. A dirty tab discards its buffer → destructive.
    cmd("tab.close", "タブを閉じる", .write, params: [CommandParam("path", .string, required: false)],
        preflight: { s, i throws(CommandError) in
          let p = i["path"]?.string ?? s.active
          try require(p.map(s.tabs.contains) ?? false, "no tab to close")
          return s.dirty.contains(p!) ? .destructive : .write
        }) { s, i in
      let p = i["path"]?.string ?? s.active!
      let idx = s.tabs.firstIndex(of: p)!
      s.tabs.remove(at: idx); s.dirty.remove(p)
      if s.active == p { s.active = s.tabs.isEmpty ? nil : s.tabs[max(idx - 1, 0)] }
      if s.active == nil { s.tree.closeExtraEditors() }  // at most one empty editor
      return .ok
    },
    cmd("file.save", "保存", .write, shortcut: "⌘S",
        preflight: { s, _ throws(CommandError) in try require(s.active != nil, "no active file"); return .write }) { s, _ in
      s.dirty.remove(s.active!); return .ok  // ponytail: dirty flag only; real buffer write lands with V04/V05 file binding.
    },
    cmd("project.switch", "プロジェクトを切り替え", .read, params: [CommandParam("name", .string)],
        preflight: { s, i throws(CommandError) in
          try require(s.projects.contains { $0.name == i["name"]!.string! }, "no project \(i["name"]!)"); return .read
        }) { s, i in s.switchProject(to: s.projects.first { $0.name == i["name"]!.string! }!, scanFiles: false); return .ok },
    // ai: false — an agent must not widen the readable file system on its own.
    cmd("project.open", "フォルダをプロジェクトとして開く", .additive, ai: false, params: [CommandParam("path", .string)],
        preflight: { _, i throws(CommandError) in
          try require(WorkbenchProject.normalized(i["path"]!.string!) != nil, "not a directory \(i["path"]!)"); return .additive
        }) { s, i in
      let path = WorkbenchProject.normalized(i["path"]!.string!)!
      s.openProject(WorkbenchProject(name: URL(fileURLWithPath: path).lastPathComponent, path: path)); return .ok
    },
    // V11 `clair open path:line`: the open Project that owns the file, else a new Project for its repository (or folder).
    // ai: false — like project.open, an agent must not widen the readable file system on its own.
    cmd("file.open", "パスからファイルを開く", .additive, ai: false,
        params: [CommandParam("path", .string), CommandParam("line", .int, required: false), CommandParam("column", .int, required: false)],
        palette: false,
        preflight: { _, i throws(CommandError) in
          let path = i["path"]!.string!
          guard let file = WorkbenchProject.normalizedFile(path) else { throw CommandError(.preconditionFailed, "not a file \(path)") }
          try require(i["line"]?.int.map { $0 >= 1 } ?? true, "line must be 1 or more")
          try require(i["column"]?.int.map { $0 >= 0 } ?? true, "column must be 0 or more")
          return .additive
        }) { s, i in
      let file = WorkbenchProject.normalizedFile(i["path"]!.string!)!
      let owner = s.owner(of: file) ?? WorkbenchProject.root(containing: file)
      // The requested file can be opened immediately; the GUI fills the rest of a newly discovered
      // Project in the background instead of blocking this command on a full walk + `git status`.
      s.openProject(owner, scanFiles: false)
      let rel = String(file.dropFirst(owner.path.count + 1))
      if !s.files.contains(where: { $0.path == rel }) { s.files.append(WorkbenchFile(path: rel, status: nil)) }  // outside the scan (skipped dir / over the cap)
      s.openTab(rel)
      return .ok
    },
    cmd("explorer.toggle", "フォルダを開閉", .read, params: [CommandParam("path", .string)]) { s, i in
      let p = i["path"]!.string!
      if !s.collapsed.insert(p).inserted { s.collapsed.remove(p) }
      return .ok
    },
    cmd("settings.open", "設定を開く", .read, params: [CommandParam("section", .string, required: false, allowed: WorkbenchState.sections)],
        shortcut: "⌘,") { s, i in
      s.settingsOpen = true; s.palette = nil
      if let sec = i["section"]?.string { s.section = sec }
      return .ok
    },
    cmd("settings.close", "設定を閉じる", .read) { s, _ in s.settingsOpen = false; return .ok },
    cmd("settings.set", "設定を変更", .write, ai: false,
        params: [CommandParam("key", .string, allowed: WorkbenchState.toggleKeys), CommandParam("value", .bool)]) { s, i in
      s.toggles[i["key"]!.string!] = i["value"]!.bool!; return .ok
    },
    cmd("settings.choose", "設定の選択肢を変更", .write, ai: false,
        params: [CommandParam("key", .string, allowed: WorkbenchState.choiceOptions.keys.sorted()), CommandParam("value", .string)],
        preflight: { _, i throws(CommandError) in
          let key = i["key"]?.string ?? "", v = i["value"]?.string ?? ""
          try require(WorkbenchState.choiceOptions[key]?.contains(v) == true, "\(key) に \(v) は選べません")
          return .write
        }) { s, i in
      s.choices[i["key"]!.string!] = i["value"]!.string!; return .ok
    },
    cmd("palette.commands", "コマンドパレット", .read, ai: false, shortcut: "⌘K", palette: false) { s, _ in s.palette = .commands; return .ok },
    cmd("palette.files", "ファイルへ移動", .read, ai: false, shortcut: "⌘P", palette: false) { s, _ in s.palette = .files; return .ok },
    cmd("palette.search", "Project を検索", .read, ai: false, shortcut: "⌘⇧F", palette: false) { s, _ in s.palette = .search; return .ok },
    // ponytail: ⌘F opens the same search panel; a per-file find bar replaces this when the editor grows one.
    cmd("palette.find", "検索", .read, ai: false, shortcut: "⌘F", palette: false) { s, _ in s.palette = .search; return .ok },
    cmd("palette.close", "パレットを閉じる", .read, ai: false, palette: false) { s, _ in s.palette = nil; return .ok },
    // E12: language-server navigation. The registry only validates and opens the palette; the GUI asks the
    // server for the active file's caret (the answer is async and belongs to the editor, not to this state).
    cmd("palette.symbols", "シンボルへ移動", .read, ai: false, shortcut: "⌘T", palette: false) { s, _ in s.palette = .symbols; return .ok },
    cmd("palette.references", "参照一覧", .read, ai: false, palette: false) { s, _ in s.palette = .references; return .ok },
    // E13: soft wrap is a persisted setting (ccedit: 設定 › エディタ「行の折り返し」, ⌥Z). Folding acts on the active
    // editor's caret, so like editor.definition the registry validates and the GUI performs it on the view.
    cmd("editor.toggleWrap", "行の折り返しを切り替え", .write, ai: false, shortcut: "⌥Z") { s, _ in
      s.toggles["softWrap"] = !(s.toggles["softWrap"] ?? false); return .ok
    },
    cmd("editor.fold", "折りたたむ", .read, ai: false, shortcut: "⌥⌘[",
        preflight: { s, _ throws(CommandError) in try require(s.active != nil, "ファイルが開かれていません"); return .read }) { _, _ in .ok },
    cmd("editor.unfold", "展開する", .read, ai: false, shortcut: "⌥⌘]",
        preflight: { s, _ throws(CommandError) in try require(s.active != nil, "ファイルが開かれていません"); return .read }) { _, _ in .ok },
    cmd("editor.foldAll", "すべて折りたたむ", .read, ai: false, shortcut: "⌃⌥[",
        preflight: { s, _ throws(CommandError) in try require(s.active != nil, "ファイルが開かれていません"); return .read }) { _, _ in .ok },
    cmd("editor.unfoldAll", "すべて展開する", .read, ai: false, shortcut: "⌃⌥]",
        preflight: { s, _ throws(CommandError) in try require(s.active != nil, "ファイルが開かれていません"); return .read }) { _, _ in .ok },
    cmd("editor.definition", "定義へ移動", .read, ai: false, shortcut: "⌃⌘J",
        preflight: { s, _ throws(CommandError) in try require(s.active != nil, "ファイルが開かれていません"); return .read }) { _, _ in .ok },
    cmd("editor.references", "参照を検索", .read, ai: false, shortcut: "⌃⌘R",
        preflight: { s, _ throws(CommandError) in try require(s.active != nil, "ファイルが開かれていません"); return .read }) { _, _ in .ok },
    // V08. Reading history is `state.snapshot`; mute changes what the user is told, so ai: false.
    cmd("notice.markRead", "通知を既読にする", .write, params: [CommandParam("project", .string, required: false)]) { s, i in
      s.notices.markRead(project: i["project"]?.string); return .ok
    },
    cmd("notice.clear", "通知履歴を消去", .write, ai: false) { s, _ in s.notices.clear(); return .ok },
    cmd("notice.muteProject", "Project の通知をミュート", .write, ai: false,
        params: [CommandParam("name", .string), CommandParam("muted", .bool)],
        preflight: { s, i throws(CommandError) in
          try require(s.projects.contains { $0.name == i["name"]!.string! }, "no project \(i["name"]!)"); return .write
        }) { s, i in
      let n = i["name"]!.string!
      if i["muted"]!.bool! { s.notices.mutedProjects.insert(n) } else { s.notices.mutedProjects.remove(n) }
      return .ok
    },
    cmd("notice.mutePane", "ターミナルの通知をミュート", .write, ai: false,
        params: [CommandParam("id", .int), CommandParam("muted", .bool)],
        preflight: { s, i throws(CommandError) in
          try require(s.tree.leaves.contains { $0.id == i["id"]!.int! }, "no pane \(i["id"]!)"); return .write
        }) { s, i in
      let k = NotificationLog.paneKey(s.project, i["id"]!.int!)
      if i["muted"]!.bool! { s.notices.mutedPanes.insert(k) } else { s.notices.mutedPanes.remove(k) }
      return .ok
    },
    // V13: all debugger controls share the typed command boundary. The GUI owns
    // the live adapter; these commands validate targets before it performs I/O.
    cmd("debug.open", "実行とデバッグ", .read, ai: false) { s, _ in
      s.debugNavigationGeneration += 1; return .ok
    },
    cmd("debug.launch", "Go をデバッグ起動", .external, ai: false,
        params: [CommandParam("program", .string), CommandParam("mode", .string, required: false, allowed: ["debug", "test", "exec"])], palette: false,
        preflight: { s, i throws(CommandError) in
          guard let root = s.projects.first(where: { $0.name == s.project })?.path else { throw CommandError(.preconditionFailed, "Project が開かれていません") }
          let path = URL(fileURLWithPath: i["program"]!.string!, relativeTo: URL(fileURLWithPath: root)).standardizedFileURL.resolvingSymlinksInPath().path
          try require(path == root || path.hasPrefix(root + "/"), "起動対象は Project 内にしてください")
          try require(FileManager.default.fileExists(atPath: path), "起動対象がありません: \(path)")
          try require(["idle", "ended", "failed"].contains(s.debugPhase), "デバッグセッションが既に実行中です")
          return .external
        }) { _, _ in .ok },
    cmd("debug.attach", "Go プロセスに接続", .external, ai: false, params: [CommandParam("pid", .int)], palette: false,
        preflight: { s, i throws(CommandError) in
          try require(s.projects.contains { $0.name == s.project }, "Project が開かれていません")
          try require(i["pid"]!.int! > 0, "PID は正の整数にしてください")
          try require(["idle", "ended", "failed"].contains(s.debugPhase), "デバッグセッションが既に実行中です")
          return .external
        }) { _, _ in .ok },
    cmd("debug.breakpoint", "ブレークポイントを切り替え", .write, ai: false,
        params: [CommandParam("path", .string), CommandParam("line", .int)], palette: false,
        preflight: { s, i throws(CommandError) in
          guard let root = s.projects.first(where: { $0.name == s.project })?.path else { throw CommandError(.preconditionFailed, "Project が開かれていません") }
          let path = URL(fileURLWithPath: i["path"]!.string!).standardizedFileURL.resolvingSymlinksInPath().path
          try require(path.hasPrefix(root + "/"), "ファイルが Project 外です")
          try require(FileManager.default.fileExists(atPath: path), "ファイルがありません: \(path)")
          try require(i["line"]!.int! > 0, "行は 1 以上にしてください")
          return .write
        }) { _, _ in .ok },
    cmd("debug.selectThread", "デバッグスレッドを選択", .read, ai: false,
        params: [CommandParam("id", .int)], palette: false,
        preflight: { s, _ throws(CommandError) in try require(s.debugPhase == "stopped", "停止中の session がありません"); return .read }) { _, _ in .ok },
    cmd("debug.selectFrame", "スタックフレームを選択", .read, ai: false,
        params: [CommandParam("id", .int)], palette: false,
        preflight: { s, _ throws(CommandError) in try require(s.debugPhase == "stopped", "停止中の session がありません"); return .read }) { _, _ in .ok },
    cmd("debug.expandVariable", "変数を展開", .read, ai: false,
        params: [CommandParam("id", .string)], palette: false,
        preflight: { s, _ throws(CommandError) in try require(s.debugPhase == "stopped", "停止中の session がありません"); return .read }) { _, _ in .ok },
    cmd("debug.continue", "デバッグを続行", .write, ai: false,
        preflight: { s, _ throws(CommandError) in try require(s.debugPhase == "stopped", "停止中の session がありません"); return .write }) { _, _ in .ok },
    cmd("debug.pause", "デバッグを一時停止", .write, ai: false,
        preflight: { s, _ throws(CommandError) in try require(s.debugPhase == "running", "実行中の session がありません"); return .write }) { _, _ in .ok },
    cmd("debug.stepOver", "ステップオーバー", .write, ai: false,
        preflight: { s, _ throws(CommandError) in try require(s.debugPhase == "stopped", "停止中の session がありません"); return .write }) { _, _ in .ok },
    cmd("debug.stepInto", "ステップイン", .write, ai: false,
        preflight: { s, _ throws(CommandError) in try require(s.debugPhase == "stopped", "停止中の session がありません"); return .write }) { _, _ in .ok },
    cmd("debug.stepOut", "ステップアウト", .write, ai: false,
        preflight: { s, _ throws(CommandError) in try require(s.debugPhase == "stopped", "停止中の session がありません"); return .write }) { _, _ in .ok },
    cmd("debug.restart", "デバッグを再起動", .external, ai: false,
        preflight: { s, _ throws(CommandError) in try require(!["idle", "ended"].contains(s.debugPhase), "再起動する session がありません"); return .external }) { _, _ in .ok },
    cmd("debug.stop", "デバッグを終了", .write, ai: false,
        preflight: { s, _ throws(CommandError) in try require(!["idle", "ended"].contains(s.debugPhase), "終了する session がありません"); return .write }) { _, _ in .ok },
    cmd("state.snapshot", "状態を取得", .read, palette: false) { s, _ in .snapshot(s) },
  ] + gitCommands

  private static func shortcutSet(_ known: [CommandDescriptor]) -> Command {
    // V11. Only commands runnable without arguments can hold a shortcut. "" unassigns. ai: false — keys are the user's.
    cmd("shortcut.set", "ショートカットを割り当て", .write, ai: false,
        params: [CommandParam("command", .string), CommandParam("shortcut", .string)], palette: false,
        preflight: { s, i throws(CommandError) in
          let id = i["command"]!.string!, raw = i["shortcut"]!.string!
          guard let d = known.first(where: { $0.id == id }) else { throw CommandError(.invalidInput, "unknown command \(id)") }
          try require(!d.params.contains(where: \.required), "\(id) needs arguments, so a key cannot run it")
          if raw.isEmpty { return .write }
          guard let key = WorkbenchState.canonicalShortcut(raw) else { throw CommandError(.invalidInput, "\(raw) is not a shortcut (modifiers ⌃⌥⌘⇧ + one key, at least one of ⌃⌥⌘)") }
          let taken = known.first { $0.id != id && s.shortcut(for: $0) == key }
          try require(taken == nil, "\(key) is already \(taken!.id)")
          return .write
        }) { s, i in
      let raw = i["shortcut"]!.string!
      s.shortcuts[i["command"]!.string!] = WorkbenchState.canonicalShortcut(raw) ?? ""
      return .ok
    }
  }
}
