import ClairShared
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

/// Transient editor context exposed to agents. Text is present only for an explicit selection.
public struct EditorContext: Sendable, Codable, Equatable {
  public let path: String
  public let startLine: Int
  public let startColumn: Int
  public let endLine: Int
  public let endColumn: Int
  public let selectedText: String?

  public init(path: String, startLine: Int, startColumn: Int, endLine: Int, endColumn: Int, selectedText: String?) {
    self.path = path; self.startLine = startLine; self.startColumn = startColumn
    self.endLine = endLine; self.endColumn = endColumn; self.selectedText = selectedText
  }
}

public struct WorkbenchState: Sendable, Codable, Equatable {
  public enum Palette: String, Sendable, Codable { case commands, files, search, symbols, references, branches, compare, recent }

  public static let sections = ["一般", "AIプロバイダー", "使用状況", "エディタ", "ターミナル", "通知", "モバイル", "アップデート"]
  public static let toggleKeys = ["restoreLayout", "confirmClose", "hideQuota", "preventSleepOnBattery", "formatOnSave", "showWhitespace", "softWrap", "terminalApprovals", "lineNumbers", "terminalCursorBlink", "notifyEnabled", "notifyOnBell", "notifyOnExit", "notifyWhenActive", "notifySound"]
  /// Closed-set settings (the mock's segmented controls). The first option is the default.
  /// Palette titles of `toggleKeys` / `choiceOptions`, matching the settings rows, so every setting is reachable from ⌘K.
  public static let settingTitles = [
    "restoreLayout": "前回のレイアウトを復元", "confirmClose": "閉じる前に確認", "hideQuota": "ステータスバーの利用枠を隠す",
    "preventSleepOnBattery": "バッテリー駆動中もエージェント実行中はスリープさせない", "formatOnSave": "保存時に整形",
    "showWhitespace": "空白文字を表示", "softWrap": "行の折り返し", "terminalApprovals": "コマンド実行前に確認",
    "defaultAgent": "既定のAgent", "approvalPolicy": "承認ポリシー", "tabWidth": "タブ幅", "defaultShell": "デフォルトシェル",
    "scrollback": "スクロールバック", "appearance": "外観",
    "lineNumbers": "行番号を表示", "terminalCursorBlink": "ターミナルのカーソルを点滅", "editorFontSize": "エディタの文字サイズ",
    "terminalFontSize": "ターミナルの文字サイズ", "terminalCursorStyle": "ターミナルのカーソルの形",
    "notifyEnabled": "通知を有効にする", "notifyOnBell": "入力待ち・通知要求で通知", "notifyOnExit": "終了で通知",
    "notifyWhenActive": "Clair が前面のときも通知", "notifySound": "通知のサウンド", "language": "言語",
  ]
  // agent registry: `defaultAgent` reads its choices from the `AgentProfile` registry instead of
  // a literal list, so switching to a newly registered agent needs no change here.
  public static let choiceOptions: [String: [String]] = [
    "defaultAgent": AgentProfile.all.map(\.id),
    "approvalPolicy": ["毎回確認", "セッション中は許可", "自動承認"],
    "tabWidth": ["2", "4", "8"],
    "defaultShell": ["/bin/zsh", "/bin/bash"],
    "scrollback": ["1000", "5000", "10000"],
    "appearance": ["ダーク", "ライト", "システム"],  // E18; mirrors ClairDesignSystem.ColorSchemeChoice
    "editorFontSize": ["11", "12", "13", "14", "16", "18"],
    "terminalFontSize": ["11", "12", "13", "14", "16", "18"],
    "terminalCursorStyle": ["ブロック", "バー", "下線"],
    "language": ClairLanguage.allCases.map(\.rawValue),  // English is the default
  ]
  /// Font family per surface (`editor`, `terminal`); "" is the system monospaced font.
  public static let fontKeys = ["editor", "terminal"]
  /// A family name the settings can store: short, no control characters (the terminal's goes into a Ghostty config line).
  public static func isValidFontFamily(_ name: String) -> Bool {
    name.count <= 100 && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }

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
  public var tree = PaneTree(single: .editor)
  /// Every pane was closed (⌘W on the last one): the shell shows the empty panel instead of `tree`. Transient.
  public var panesClosed = false
  public var tabs: [String] = ["apple/ClairApp/ContentView.swift"]
  public var active: String? = "apple/ClairApp/ContentView.swift" {
    didSet {  // every path that makes a file active counts as opening it
      guard let active, active != oldValue else { return }
      recent = [active] + recent.filter { $0 != active }.prefix(49)
    }
  }
  /// Recently opened files in this Project, newest first; persisted with the layout.
  public var recent: [String] = []
  /// Current editor selection; never written to WorkspaceSnapshot.
  public var editorContext: EditorContext?
  public var diffTabs: [WorkbenchDiffTab] = []
  public var activeDiff: WorkbenchDiffTab?
  public var tabOrder: [WorkbenchTab] = []
  public var dirty: Set<String> = []
  /// Explorer folders the user opened; every other folder starts closed, including ones that appear later.
  public var expanded: Set<String> = []
  public var launches: [Int: AgentLaunch] = [:]
  /// ⌘⇧T history, newest last, capped at `closedLimit`. Terminals reopen as fresh shells. Transient.
  public struct ClosedTab: Sendable, Codable, Equatable { public let project: String, tab: WorkbenchTab }
  public var closedTabs: [ClosedTab] = []
  static let closedLimit = 10
  mutating func recordClosed(_ tab: WorkbenchTab) {
    closedTabs.append(ClosedTab(project: project, tab: tab))
    if closedTabs.count > Self.closedLimit { closedTabs.removeFirst() }
  }
  /// Preview pane id → the file it was opened for (Markdown rendered, CSV/TSV as a table).
  public var previews: [Int: String] = [:]
  /// CLI agents started by hand in Clair terminals. Refreshed from live process facts, never saved.
  public var detectedLaunches: [String: [Int: AgentLaunch]] = [:]
  /// Latest OSC 0/2 window title per `NotificationLog.paneKey`, as Ghostty shows in its tab. Transient.
  public var paneTitles: [String: String] = [:]
  public var notices = NotificationLog()
  public var settingsOpen = false
  /// Transient UI navigation request. The sidebar selection itself belongs to the app shell.
  public var debugNavigationGeneration = 0
  /// ⌘B hides the sidebar panel (activity bar stays). Transient.
  public var sidebarHidden = false
  public var debugPhase = "idle"  // transient; refreshed by the GUI before a debugger command
  public var section = "一般"
  public var palette: Palette?
  /// E17: definition-jump history for ⌃- / ⌃⇧-. Transient (not in `WorkspaceSnapshot`).
  public var navigation = NavigationHistory()
  public var toggles = ["restoreLayout": true, "confirmClose": true, "hideQuota": false, "preventSleepOnBattery": false, "formatOnSave": false, "showWhitespace": false, "softWrap": false, "terminalApprovals": true, "lineNumbers": true, "terminalCursorBlink": true, "notifyEnabled": true, "notifyOnBell": true, "notifyOnExit": true, "notifyWhenActive": false, "notifySound": false]
  // Font sizes default to what Clair shipped with (mock editor 12px, terminal 13pt), not the smallest option.
  public var choices = WorkbenchState.choiceOptions.mapValues { $0[0] }.merging(["editorFontSize": "12", "terminalFontSize": "13"]) { $1 }
  public var fonts = ["editor": "", "terminal": ""]
  /// V11: user shortcut assignments over the registry defaults. An empty string unassigns a default.
  public var shortcuts: [String: String] = [:]
  /// File extension (lowercased, no dot) → editor language id. Overrides the built-in detection.
  public var fileAssociations = ["tpl": "terraform"]
  /// `"tpl=terraform,j2=python"` ⇄ the map (the settings list sends this). Malformed or empty pairs are dropped.
  public static func parseAssociations(_ text: String) -> [String: String] {
    var map: [String: String] = [:]
    for pair in text.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
      let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
      guard kv.count == 2, !kv[1].isEmpty else { continue }
      let ext = kv[0].hasPrefix(".") ? String(kv[0].dropFirst()) : kv[0]
      if !ext.isEmpty { map[ext] = kv[1] }
    }
    return map
  }
  public static func formatAssociations(_ map: [String: String]) -> String {
    map.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
  }

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
  public var label: String { [tr("読み取り"), tr("追加"), tr("書き込み"), tr("破壊的"), tr("外部")][rawValue] }
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
  case editorContext(EditorContext)
  case review(GitReview)
  case diagnostics([WorkbenchDiagnostic])
  case reviewThreads([WorkbenchReviewThread])
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
  /// Secondary label shown after the title (the Japanese title when `title` is the English command name).
  public let detail: String

  public init(title: String, hint: String, id: String, input: CommandInput, detail: String = "") {
    self.title = title; self.hint = hint; self.id = id; self.input = input; self.detail = detail
  }

  /// Every whitespace-separated query token appears in the title or the detail (case-insensitive).
  func matches(_ query: String) -> Bool {
    let hay = (title + " " + detail).lowercased()
    return query.lowercased().split(whereSeparator: \.isWhitespace).allSatisfy { hay.contains($0) }
  }
}

extension CommandDescriptor {
  /// English command name derived from the id: `pane.splitRight` → `Pane: Split Right`.
  // ponytail: derived, not authored; add an explicit English title to `cmd(...)` when a derived name reads badly.
  public var englishName: String {
    func words(_ s: Substring) -> String {
      var out = ""
      for c in s { if c.isUppercase, !out.isEmpty { out += " " }; out.append(out.isEmpty || out.last == " " ? Character(c.uppercased()) : c) }
      return out
    }
    let parts = id.split(separator: ".")
    return parts.count > 1 ? "\(words(parts[0])): \(parts.dropFirst().map(words).joined(separator: " "))" : words(parts[0])
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
      return commands.filter { $0.inPalette && (state.isRepo || !($0.id.hasPrefix("git.") || $0.id.hasPrefix("worktree."))) }
        .map { PaletteItem(title: $0.englishName, hint: state.shortcut(for: $0) ?? "", id: $0.id, input: [:], detail: tr($0.title)) }
        .filter { $0.matches(q) }
        + AgentProfile.all.map { PaletteItem(title: tr("%@ を起動", $0.title), hint: "", id: "agent.launch", input: ["profile": .string($0.id)]) }
          .filter { $0.matches(q) }
        + settingItems(state).filter { $0.matches(q) }
    case .files:
      return QuickOpen.rank(query, state.files.filter { $0.status != "D" })
        .map { PaletteItem(title: $0.path, hint: "", id: "tab.open", input: ["path": .string($0.path)]) }
    case .recent:
      // Reopen a recently opened file, newest first; files gone from the tree drop out.
      let live = Set(state.files.filter { $0.status != "D" }.map(\.path))
      return QuickOpen.rank(query, state.recent.filter { live.contains($0) && $0 != state.active }.map { WorkbenchFile(path: $0, status: nil) })
        .map { PaletteItem(title: $0.path, hint: "", id: "tab.open", input: ["path": .string($0.path)]) }
    case .compare:
      // VS Code's "Compare Active File With…": the picked file is the left side, the active file the right.
      guard let active = state.active else { return [] }
      // Recently opened files first (newest first), then the rest in tree order; rank keeps that order on ties.
      let candidates = state.files.filter { $0.status != "D" && $0.path != active }
      let order = Dictionary(state.recent.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
      let byRecency = candidates.enumerated().sorted {
        (order[$0.element.path] ?? .max, $0.offset) < (order[$1.element.path] ?? .max, $1.offset)
      }.map(\.element)
      return QuickOpen.rank(query, byRecency)
        .map { PaletteItem(title: $0.path, hint: "", id: "diff.open",
                           input: ["path": .string(active), "staged": .bool(false), "untracked": .bool(false), "against": .string($0.path)]) }
    case .search, .symbols, .references, .branches:
      return []  // search runs in the GUI; symbols/references come from the language server; branches load off the main thread
    }
  }

  /// One row per settings value: flip each toggle, pick each other choice, open each section.
  private func settingItems(_ state: WorkbenchState) -> [PaletteItem] {
    let t = WorkbenchState.settingTitles
    return WorkbenchState.toggleKeys.map { k in
      let on = state.toggles[k] == true
      return PaletteItem(title: tr("設定: %@を%@にする", tr(t[k] ?? k), on ? tr("オフ") : tr("オン")), hint: "", id: "settings.set", input: ["key": .string(k), "value": .bool(!on)])
    }
      + WorkbenchState.choiceOptions.keys.sorted().flatMap { k in
        WorkbenchState.choiceOptions[k]!.filter { $0 != state.choices[k] }.map {
          PaletteItem(title: tr("設定: %@を %@ にする", tr(t[k] ?? k), tr($0)), hint: "", id: "settings.choose", input: ["key": .string(k), "value": .string($0)])
        }
      }
      + WorkbenchState.sections.map { PaletteItem(title: tr("設定を開く: %@", tr($0)), hint: "", id: "settings.open", input: ["section": .string($0)]) }
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
        }) { s, i in
      s.tree.focus(i["id"]!.int!)
      s.activeDiff = nil
      return .ok
    },
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
    // With no file open and other panes beside it, the empty editor is removed; opening a file brings it back.
    cmd("pane.close", "ペインを閉じる", .write, shortcut: "⌘W",
        preflight: { s, _ throws(CommandError) in
          try require(!s.panesClosed, "no pane to close")
          return .write
        }) { s, _ in
      switch s.tree.leaves.first(where: { $0.id == s.tree.focused })?.kind {
      case .terminal: s.recordClosed(.terminal(s.tree.focused))
      case .graph: s.recordClosed(.graph(s.tree.focused))
      default: break
      }
      if s.tree.leaves.first?.id == s.tree.focused, s.tree.leaves.first?.kind == .editor, s.active != nil || s.tree.leaves.count == 1 {
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
          CommandParam("parent", .string, required: false), CommandParam("resume", .string, required: false),
          CommandParam("review", .bool, required: false),
        ], palette: false,
        preflight: { s, i throws(CommandError) in
          try require(i["resume"]?.string.map(AgentProfile.isSessionID) ?? true, "invalid session id")
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
        parent: i["parent"]?.string, resume: i["resume"]?.string, review: i["review"]?.bool == true)
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
    // ADR-0020: focus the Project's concierge, starting it if needed. GUI-only (ai: false): an agent
    // must not spawn a concierge; it launches children through agent.launch instead.
    cmd("concierge.open", "コンシェルジュを開く", .external, ai: false,
        params: [CommandParam("message", .string, required: false)],
        preflight: { s, _ throws(CommandError) in
          _ = try s.launchHome(nil)
          return .external
        }) { s, i in
      if let c = s.concierge(in: s.project) { s.tree.focus(c.pane); return .pane(c.pane) }
      let home = try! s.launchHome(nil)
      s.tree.splitFocused(.horizontal, kind: .terminal)
      let pane = s.tree.focused
      s.launches[pane] = AgentLaunch(
        profile: "claude", cwd: home.project.path, concierge: UUID().uuidString.lowercased(),
        opening: i["message"]?.string.flatMap { $0.isEmpty ? nil : $0 })
      s.panesClosed = false
      return .pane(pane)
    },
    cmd("tab.open", "ファイルを開く", .read, params: [CommandParam("path", .string)],
        preflight: { s, i throws(CommandError) in
          try require(s.files.contains { $0.path == i["path"]?.string && $0.status != "D" }, "no file \(i["path"]!)"); return .read
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
    cmd("diff.open", "差分を開く", .read,
        params: [CommandParam("path", .string), CommandParam("staged", .bool), CommandParam("untracked", .bool),
                 CommandParam("against", .string, required: false), CommandParam("proposal", .string, required: false)],
        palette: false,
        preflight: { s, i throws(CommandError) in
          for path in [i["path"]!.string!] + [i["against"]?.string].compactMap({ $0 }) {
            try require(!path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains(".."), "invalid diff path")
          }
          // A proposal's text only ever lives in Clair's own proposal folder (ADR-0022).
          if let proposal = i["proposal"]?.string { try require(ClaudeIDE.isProposal(proposal), "invalid proposal path") }
          try require(s.projects.contains { $0.name == s.project }, "no active Project")
          return .read
        }) { s, i in
      s.openDiff(WorkbenchDiffTab.from(i))
      return .ok
    },
    cmd("diff.activate", "差分タブを切り替え", .read,
        params: [CommandParam("path", .string), CommandParam("staged", .bool), CommandParam("untracked", .bool),
                 CommandParam("against", .string, required: false), CommandParam("proposal", .string, required: false)],
        palette: false) { s, i in
      s.selectTab(.diff(WorkbenchDiffTab.from(i)))
      return .ok
    },
    cmd("diff.close", "差分タブを閉じる", .write,
        params: [CommandParam("path", .string), CommandParam("staged", .bool), CommandParam("untracked", .bool),
                 CommandParam("against", .string, required: false), CommandParam("proposal", .string, required: false)],
        palette: false) { s, i in
      let target = WorkbenchDiffTab.from(i)
      if s.diffTabs.contains(target) { s.recordClosed(.diff(target)) }
      s.closeDiff(target)
      return .ok
    },
    // Pops this Project's newest closed tab; entries whose file is gone are dropped on the way.
    cmd("tab.reopenClosed", "閉じたタブを再度開く", .additive, shortcut: "⌘⇧T",
        preflight: { s, _ throws(CommandError) in
          try require(s.closedTabs.contains { $0.project == s.project }, "no closed tab"); return .additive
        }) { s, _ in
      while let i = s.closedTabs.lastIndex(where: { $0.project == s.project }) {
        let tab = s.closedTabs.remove(at: i).tab
        s.panesClosed = false
        switch tab {
        case .file(let path):
          guard s.files.contains(where: { $0.path == path && $0.status != "D" }) else { continue }
          s.openTab(path)
        case .diff(let target): s.openDiff(target)
        case .terminal: s.tree.splitFocused(.horizontal, kind: .terminal)
        case .graph: s.tree.splitFocused(.horizontal, kind: .graph)
        }
        return .ok
      }
      return .ok
    },
    cmd("tab.reorder", "タブを並べ替え", .read,
        params: [CommandParam("source", .string), CommandParam("target", .string)], palette: false,
        preflight: { s, i throws(CommandError) in
          try require(s.titlebarTabs.contains { $0.dragID == i["source"]!.string! }, "no source tab")
          try require(s.titlebarTabs.contains { $0.dragID == i["target"]!.string! }, "no target tab")
          return .read
        }) { s, i in
      let tabs = s.titlebarTabs
      s.moveTab(tabs.first { $0.dragID == i["source"]!.string! }!, to: tabs.first { $0.dragID == i["target"]!.string! }!)
      return .ok
    },
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
      s.tabs.remove(at: idx); s.dirty.remove(p); s.recordClosed(.file(p))
      s.tabOrder.removeAll { $0 == .file(p) }
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
    // Removes a Project from the workspace. Its terminals stay in the daemon, so reopening the same
    // folder reattaches them by `project#pane`. ponytail: shells of a never-reopened Project live until `clair daemon stop`.
    cmd("project.close", "プロジェクトを閉じる", .write, ai: false, params: [CommandParam("name", .string)],
        preflight: { s, i throws(CommandError) in
          let name = i["name"]!.string!
          try require(s.projects.contains { $0.name == name }, "no project \(name)")
          try require(s.projects.count > 1, tr("最後の Project は閉じられません"))
          let dirty = name == s.project ? s.dirty : s.layouts[name]?.dirty ?? []
          try require(dirty.isEmpty, tr("%@ に未保存の変更があります", name))
          return .write
        }) { s, i in
      let name = i["name"]!.string!
      if name == s.project { s.switchProject(to: s.projects.first { $0.name != name }!, scanFiles: false) }
      s.projects.removeAll { $0.name == name }
      s.layouts[name] = nil
      s.filesCache[name] = nil
      return .ok
    },
    // Tab-group chrome: shown name and colour, persisted with the Project. Empty label restores the folder name.
    cmd("project.rename", "プロジェクト名を変更", .write, ai: false, params: [CommandParam("name", .string), CommandParam("label", .string)],
        palette: false,
        preflight: { s, i throws(CommandError) in
          try require(s.projects.contains { $0.name == i["name"]!.string! }, "no project \(i["name"]!)"); return .write
        }) { s, i in
      let label = i["label"]!.string!.trimmingCharacters(in: .whitespacesAndNewlines)
      let idx = s.projects.firstIndex { $0.name == i["name"]!.string! }!
      s.projects[idx].label = label.isEmpty || label == s.projects[idx].name ? nil : label
      return .ok
    },
    cmd("project.setColor", "タブグループの色を変更", .write, ai: false, params: [CommandParam("name", .string), CommandParam("color", .string)],
        palette: false,
        preflight: { s, i throws(CommandError) in
          try require(s.projects.contains { $0.name == i["name"]!.string! }, "no project \(i["name"]!)")
          let color = i["color"]!.string!
          try require(["blue", "green", "amber", "red", "purple", "gray"].contains(color) || color.wholeMatch(of: /#[0-9a-fA-F]{6}/) != nil,
                      "unknown color \(i["color"]!)")
          return .write
        }) { s, i in
      s.projects[s.projects.firstIndex { $0.name == i["name"]!.string! }!].color = i["color"]!.string!
      return .ok
    },
    // ai: false — like project.open, an agent must not widen the readable file system on its own.
    cmd("project.addFolder", "プロジェクトにフォルダを追加", .additive, ai: false,
        params: [CommandParam("name", .string), CommandParam("path", .string)], palette: false,
        preflight: { s, i throws(CommandError) in
          guard let p = s.projects.first(where: { $0.name == i["name"]!.string! }) else { throw CommandError(.preconditionFailed, "no project \(i["name"]!)") }
          guard let path = WorkbenchProject.normalized(i["path"]!.string!) else { throw CommandError(.preconditionFailed, "not a directory \(i["path"]!)") }
          // Nested either way would list the same files twice.
          for other in [p.path] + (p.folders ?? []) {
            try require(path != other && !path.hasPrefix(other + "/") && !other.hasPrefix(path + "/"), tr("%@ は既にこの Project に含まれています", path))
          }
          return .additive
        }) { s, i in
      let idx = s.projects.firstIndex { $0.name == i["name"]!.string! }!
      s.projects[idx].folders = (s.projects[idx].folders ?? []) + [WorkbenchProject.normalized(i["path"]!.string!)!]
      s.filesCache[s.projects[idx].name] = nil
      return .ok
    },
    cmd("project.removeFolder", "プロジェクトからフォルダを外す", .write, ai: false,
        params: [CommandParam("name", .string), CommandParam("path", .string)], palette: false,
        preflight: { s, i throws(CommandError) in
          let p = s.projects.first { $0.name == i["name"]!.string! }
          try require(p?.folders?.contains(i["path"]!.string!) == true, "not an added folder \(i["path"]!)")
          let prefix = WorkbenchFiles.relative(i["path"]!.string!, from: p!.path) + "/"
          let dirty = p!.name == s.project ? s.dirty : s.layouts[p!.name]?.dirty ?? []
          try require(!dirty.contains { $0.hasPrefix(prefix) }, tr("未保存の変更があります"))
          return .write
        }) { s, i in
      let idx = s.projects.firstIndex { $0.name == i["name"]!.string! }!
      let p = s.projects[idx], prefix = WorkbenchFiles.relative(i["path"]!.string!, from: p.path) + "/"
      s.projects[idx].folders?.removeAll { $0 == i["path"]!.string! }
      s.filesCache[p.name] = nil
      if p.name == s.project {
        s.files.removeAll { $0.path.hasPrefix(prefix) }
        for tab in s.tabs where tab.hasPrefix(prefix) { s.tabOrder.removeAll { $0 == .file(tab) } }
        s.tabs.removeAll { $0.hasPrefix(prefix) }
        if s.active.map({ $0.hasPrefix(prefix) }) == true { s.active = s.tabs.last }
      }
      return .ok
    },
    cmd("project.move", "タブグループを移動", .write, ai: false, params: [CommandParam("name", .string), CommandParam("offset", .int)],
        palette: false,
        preflight: { s, i throws(CommandError) in
          let from = s.projects.firstIndex { $0.name == i["name"]!.string! }
          try require(from != nil, "no project \(i["name"]!)")
          try require(s.projects.indices.contains(from! + i["offset"]!.int!), "cannot move further"); return .write
        }) { s, i in
      let from = s.projects.firstIndex { $0.name == i["name"]!.string! }!
      s.projects.swapAt(from, from + i["offset"]!.int!)
      return .ok
    },
    // ai: false — an agent must not widen the readable file system on its own.
    cmd("project.open", "フォルダをプロジェクトとして開く", .additive, ai: false, params: [CommandParam("path", .string)],
        preflight: { _, i throws(CommandError) in
          try require(WorkbenchProject.normalized(i["path"]!.string!) != nil, "not a directory \(i["path"]!)"); return .additive
        }) { s, i in
      let path = WorkbenchProject.normalized(i["path"]!.string!)!
      s.openProject(WorkbenchProject(name: URL(fileURLWithPath: path).lastPathComponent, path: path)); return .ok
    },
    // MCP may navigate only within a Project already open in Clair. The user's CLI keeps its wider file-open behavior.
    cmd("file.open", "パスからファイルを開く", .additive,
        params: [CommandParam("path", .string), CommandParam("line", .int, required: false), CommandParam("column", .int, required: false)],
        palette: false,
        preflight: { _, i throws(CommandError) in
          let path = i["path"]!.string!
          guard let file = WorkbenchProject.normalizedFile(path) else { throw CommandError(.preconditionFailed, "not a file \(path)") }
          try require(i["line"]?.int.map { $0 >= 1 } ?? true, "line must be 1 or more")
          try require(i["column"]?.int.map { $0 >= 0 } ?? true, "column must be 0 or more")
          return .additive
        }) { s, i in
      s.openFile(WorkbenchProject.normalizedFile(i["path"]!.string!)!)
      return .ok
    },
    cmd("file.isOpen", "ファイルがタブで開いているか", .read, params: [CommandParam("path", .string)], palette: false) { s, i in
      .text(WorkbenchProject.normalizedFile(i["path"]!.string!).map { s.isOpen($0) ? "open" : "closed" } ?? "closed")
    },
    // Terminal agents may request this with `clair preview`; the CLI gate asks before executing HTML/JS.
    cmd("file.preview", "HTML をプレビュー", .additive, ai: false,
        params: [CommandParam("path", .string)], palette: false,
        preflight: { _, i throws(CommandError) in
          let path = i["path"]!.string!
          guard let file = WorkbenchProject.normalizedFile(path) else { throw CommandError(.preconditionFailed, "not a file \(path)") }
          try require(file.lowercased().hasSuffix(".html") || file.lowercased().hasSuffix(".htm"), tr("HTML ファイルを指定してください"))
          return .additive
        }) { s, i in
      let path = WorkbenchProject.normalizedFile(i["path"]!.string!)!
      s.openFile(path)
      guard let active = s.active, let editor = s.tree.leaves.first(where: { $0.kind == .editor }) else { return .ok }
      if let preview = s.tree.leaves.first(where: { $0.kind == .preview && s.previews[$0.id] == active }) {
        if s.tree.maximized != nil { s.tree.toggleMaximize() }
        s.tree.focus(preview.id)
        return .pane(preview.id)
      }
      let id = s.tree.split(editor.id, .horizontal, kind: .preview)
      s.previews[id] = active
      s.tree.focus(id)
      return .pane(id)
    },
    cmd("editor.context", "現在のファイルと選択範囲を取得", .read, palette: false,
        preflight: { s, _ throws(CommandError) in
          guard let context = s.editorContext, let active = s.active,
            let root = s.projects.first(where: { $0.name == s.project })?.path
          else { throw CommandError(.preconditionFailed, "no active editor context") }
          let current = URL(fileURLWithPath: root).appending(path: active).standardizedFileURL.path
          try require(context.path == current, "editor context is stale")
          return .read
        }) { s, _ in .editorContext(s.editorContext!) },
    // E17: the GUI reveals `navigation.current` after these succeed (the caret belongs to the editor).
    cmd("editor.navigateBack", "前の位置に戻る", .read, ai: false, shortcut: "⌃-",
        preflight: { s, _ throws(CommandError) in try require(s.navigation.canGoBack, tr("戻る位置がありません")); return .read }) { s, _ in
      if let to = s.navigation.back(), let file = WorkbenchProject.normalizedFile(to.path) { s.openFile(file) }
      return .ok
    },
    cmd("editor.navigateForward", "次の位置に進む", .read, ai: false, shortcut: "⌃⇧-",
        preflight: { s, _ throws(CommandError) in try require(s.navigation.canGoForward, tr("進む位置がありません")); return .read }) { s, _ in
      if let to = s.navigation.forward(), let file = WorkbenchProject.normalizedFile(to.path) { s.openFile(file) }
      return .ok
    },
    cmd("explorer.toggle", "フォルダを開閉", .read, params: [CommandParam("path", .string)]) { s, i in
      let p = i["path"]!.string!
      if !s.expanded.insert(p).inserted { s.expanded.remove(p) }
      return .ok
    },
    cmd("settings.open", "設定を開く", .read, params: [CommandParam("section", .string, required: false, allowed: WorkbenchState.sections)],
        shortcut: "⌘,") { s, i in
      s.settingsOpen = true; s.palette = nil
      if let sec = i["section"]?.string { s.section = sec }
      return .ok
    },
    // The GUI performs these after success (they touch the file system outside any Project); state is unchanged here.
    cmd("cli.install", "clair コマンドをインストール", .write, ai: false) { _, _ in .ok },
    cmd("skill.install", "Agent skill をインストール", .write, ai: false) { _, _ in .ok },
    cmd("cli.uninstall", "clair コマンドをアンインストール", .write, ai: false) { _, _ in .ok },
    cmd("skill.uninstall", "Agent skill をアンインストール", .write, ai: false) { _, _ in .ok },
    cmd("settings.close", "設定を閉じる", .read) { s, _ in s.settingsOpen = false; return .ok },
    cmd("settings.set", "設定を変更", .write, ai: false,
        params: [CommandParam("key", .string, allowed: WorkbenchState.toggleKeys), CommandParam("value", .bool)]) { s, i in
      s.toggles[i["key"]!.string!] = i["value"]!.bool!; return .ok
    },
    cmd("settings.choose", "設定の選択肢を変更", .write, ai: false,
        params: [CommandParam("key", .string, allowed: WorkbenchState.choiceOptions.keys.sorted()), CommandParam("value", .string)],
        preflight: { _, i throws(CommandError) in
          let key = i["key"]?.string ?? "", v = i["value"]?.string ?? ""
          try require(WorkbenchState.choiceOptions[key]?.contains(v) == true, tr("%@ に %@ は選べません", key, v))
          return .write
        }) { s, i in
      s.choices[i["key"]!.string!] = i["value"]!.string!; return .ok
    },
    cmd("settings.font", "フォントを変更", .write, ai: false,
        params: [CommandParam("key", .string, allowed: WorkbenchState.fontKeys), CommandParam("value", .string)],
        preflight: { _, i throws(CommandError) in
          try require(WorkbenchState.isValidFontFamily(i["value"]?.string ?? ""), tr("フォント名が不正です"))
          return .write
        }) { s, i in
      s.fonts[i["key"]!.string!] = i["value"]!.string!; return .ok
    },
    cmd("settings.fileAssociations", "拡張子の言語を設定", .write, ai: false,
        params: [CommandParam("value", .string)]) { s, i in
      s.fileAssociations = WorkbenchState.parseAssociations(i["value"]!.string!); return .ok
    },
    cmd("sidebar.toggle", "サイドバーの表示切替", .read, ai: false, shortcut: "⌘B") { s, _ in s.sidebarHidden.toggle(); return .ok },
    cmd("window.restart", "ウインドウを再起動", .write, ai: false) { s, _ in s.palette = nil; return .ok },
    cmd("app.restart", "アプリを再起動", .external, ai: false) { s, _ in s.palette = nil; return .ok },
    cmd("palette.commands", "コマンドパレット", .read, ai: false, shortcut: "⌘K", palette: false) { s, _ in s.palette = .commands; return .ok },
    // VS Code habit: ⌘⇧P opens the same command palette as ⌘K.
    cmd("palette.commandsAlt", "コマンドパレット", .read, ai: false, shortcut: "⌘⇧P", palette: false) { s, _ in s.palette = .commands; return .ok },
    cmd("palette.files", "ファイルへ移動", .read, ai: false, shortcut: "⌘P", palette: false) { s, _ in s.palette = .files; return .ok },
    cmd("palette.search", "Project を検索", .read, ai: false, shortcut: "⌘⇧F", palette: false) { s, _ in s.palette = .search; return .ok },
    // ponytail: ⌘F opens the same search panel; a per-file find bar replaces this when the editor grows one.
    cmd("palette.find", "検索", .read, ai: false, shortcut: "⌘F", palette: false) { s, _ in s.palette = .search; return .ok },
    cmd("palette.compare", "Compare With…（アクティブファイルと比較）", .read, ai: false,
        preflight: { s, _ throws(CommandError) in try require(s.active != nil, "no active file"); return .read }) { s, _ in
      s.palette = .compare; return .ok
    },
    cmd("palette.recent", "Open Recent…（最近開いたファイル）", .read, ai: false) { s, _ in s.palette = .recent; return .ok },
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
        preflight: { s, _ throws(CommandError) in try require(s.active != nil, tr("ファイルが開かれていません")); return .read }) { _, _ in .ok },
    cmd("editor.unfold", "展開する", .read, ai: false, shortcut: "⌥⌘]",
        preflight: { s, _ throws(CommandError) in try require(s.active != nil, tr("ファイルが開かれていません")); return .read }) { _, _ in .ok },
    cmd("editor.foldAll", "すべて折りたたむ", .read, ai: false, shortcut: "⌃⌥[",
        preflight: { s, _ throws(CommandError) in try require(s.active != nil, tr("ファイルが開かれていません")); return .read }) { _, _ in .ok },
    cmd("editor.unfoldAll", "すべて展開する", .read, ai: false, shortcut: "⌃⌥]",
        preflight: { s, _ throws(CommandError) in try require(s.active != nil, tr("ファイルが開かれていません")); return .read }) { _, _ in .ok },
    cmd("editor.definition", "定義へ移動", .read, ai: false, shortcut: "⌃⌘J",
        preflight: { s, _ throws(CommandError) in try require(s.active != nil, tr("ファイルが開かれていません")); return .read }) { _, _ in .ok },
    // E15: each preview pane is bound to the file it was opened for (Markdown rendered, CSV/TSV as an editable
    // table) and keeps showing it when the editor switches files; asking again for the same file just focuses it.
    cmd("editor.markdownPreview", "プレビュー / 表で開く", .additive, ai: false, shortcut: "⌘⇧V",
        preflight: { s, _ throws(CommandError) in
          try require(s.active.map { MarkdownPreview.isMarkdown($0) || TableFile.separator($0) != nil || $0.lowercased().hasSuffix(".html") || $0.lowercased().hasSuffix(".htm") } == true, tr("Markdown / CSV / HTML ファイルが開かれていません")); return .additive
        }) { s, _ in
      guard let path = s.active else { return .ok }
      s.panesClosed = false
      if let preview = s.tree.leaves.first(where: { $0.kind == .preview && s.previews[$0.id] == path }) {
        if s.tree.maximized != nil { s.tree.toggleMaximize() }
        return .pane(preview.id)
      }
      guard let editor = s.tree.leaves.first(where: { $0.kind == .editor }) else { return .ok }
      let id = s.tree.split(editor.id, .horizontal, kind: .preview)
      s.previews[id] = path
      return .pane(id)
    },
    cmd("editor.references", "参照を検索", .read, ai: false, shortcut: "⌃⌘R",
        preflight: { s, _ throws(CommandError) in try require(s.active != nil, tr("ファイルが開かれていません")); return .read }) { _, _ in .ok },
    // The language server's `textDocument/formatting`, else a server-free formatter (JSON via `DocumentFormatter`).
    // The GUI performs the actual buffer edit, like editor.fold.
    cmd("editor.format", "ドキュメントを整形", .write, ai: false, shortcut: "⌃⌥F",
        preflight: { s, _ throws(CommandError) in
          try require(s.active.map(DocumentFormatter.mayFormat) == true, tr("対応していないファイル形式です")); return .write
        }) { _, _ in .ok },
    // Language features at the active editor's caret; like editor.definition the registry validates and the GUI asks
    // the language server and shows the result on the view.
    cmd("editor.hover", "ホバー情報を表示", .read, ai: false,
        preflight: { s, _ throws(CommandError) in try require(s.active != nil, tr("ファイルが開かれていません")); return .read }) { _, _ in .ok },
    cmd("editor.rename", "シンボルの名前を変更", .read, ai: false,
        preflight: { s, _ throws(CommandError) in try require(s.active != nil, tr("ファイルが開かれていません")); return .read }) { _, _ in .ok },
    cmd("editor.codeAction", "クイックフィックス…", .read, ai: false, shortcut: "⌘.",
        preflight: { s, _ throws(CommandError) in try require(s.active != nil, tr("ファイルが開かれていません")); return .read }) { _, _ in .ok },
    cmd("editor.fileSymbols", "ファイル内のシンボルへ移動", .read, ai: false, shortcut: "⌘⇧O",
        preflight: { s, _ throws(CommandError) in try require(s.active != nil, tr("ファイルが開かれていません")); return .read }) { _, _ in .ok },
    cmd("editor.problems", "問題の一覧", .read, ai: false, shortcut: "⌘⇧M") { _, _ in .ok },
    // ADR-0022: puts the selection (or the file) into every connected Claude Code's prompt. The GUI sends it.
    cmd("agent.mention", "選択範囲を Claude Code に送る", .read, ai: false, shortcut: "⌥⌘K",
        preflight: { s, _ throws(CommandError) in try require(s.active != nil, tr("ファイルが開かれていません")); return .read }) { _, _ in .ok },
    // Typed into the Project's running agent terminal without Return; the user reviews and sends.
    cmd("agent.ask", "選択範囲を Agent に送る", .read, ai: false,
        preflight: { s, _ throws(CommandError) in try require(s.active != nil, tr("ファイルが開かれていません")); return .read }) { _, _ in .ok },
    cmd("terminal.askAgent", "ターミナルの選択範囲を Agent に聞く", .read, ai: false,
        preflight: { s, _ throws(CommandError) in
          try require(s.tree.leaves.first { $0.id == s.tree.focused }?.kind == .terminal, tr("ターミナルを選択してください")); return .read
        }) { _, _ in .ok },
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
          guard let root = s.projects.first(where: { $0.name == s.project })?.path else { throw CommandError(.preconditionFailed, tr("Project が開かれていません")) }
          let path = URL(fileURLWithPath: i["program"]!.string!, relativeTo: URL(fileURLWithPath: root)).standardizedFileURL.resolvingSymlinksInPath().path
          try require(path == root || path.hasPrefix(root + "/"), tr("起動対象は Project 内にしてください"))
          try require(FileManager.default.fileExists(atPath: path), tr("起動対象がありません: %@", path))
          try require(["idle", "ended", "failed"].contains(s.debugPhase), tr("デバッグセッションが既に実行中です"))
          return .external
        }) { _, _ in .ok },
    cmd("debug.attach", "Go プロセスに接続", .external, ai: false, params: [CommandParam("pid", .int)], palette: false,
        preflight: { s, i throws(CommandError) in
          try require(s.projects.contains { $0.name == s.project }, tr("Project が開かれていません"))
          try require(i["pid"]!.int! > 0, tr("PID は正の整数にしてください"))
          try require(["idle", "ended", "failed"].contains(s.debugPhase), tr("デバッグセッションが既に実行中です"))
          return .external
        }) { _, _ in .ok },
    cmd("debug.breakpoint", "ブレークポイントを切り替え", .write, ai: false,
        params: [CommandParam("path", .string), CommandParam("line", .int)], palette: false,
        preflight: { s, i throws(CommandError) in
          guard let root = s.projects.first(where: { $0.name == s.project })?.path else { throw CommandError(.preconditionFailed, tr("Project が開かれていません")) }
          let path = URL(fileURLWithPath: i["path"]!.string!).standardizedFileURL.resolvingSymlinksInPath().path
          try require(path.hasPrefix(root + "/"), tr("ファイルが Project 外です"))
          try require(FileManager.default.fileExists(atPath: path), tr("ファイルがありません: %@", path))
          try require(i["line"]!.int! > 0, tr("行は 1 以上にしてください"))
          return .write
        }) { _, _ in .ok },
    cmd("debug.selectThread", "デバッグスレッドを選択", .read, ai: false,
        params: [CommandParam("id", .int)], palette: false,
        preflight: { s, _ throws(CommandError) in try require(s.debugPhase == "stopped", tr("停止中の session がありません")); return .read }) { _, _ in .ok },
    cmd("debug.selectFrame", "スタックフレームを選択", .read, ai: false,
        params: [CommandParam("id", .int)], palette: false,
        preflight: { s, _ throws(CommandError) in try require(s.debugPhase == "stopped", tr("停止中の session がありません")); return .read }) { _, _ in .ok },
    cmd("debug.expandVariable", "変数を展開", .read, ai: false,
        params: [CommandParam("id", .string)], palette: false,
        preflight: { s, _ throws(CommandError) in try require(s.debugPhase == "stopped", tr("停止中の session がありません")); return .read }) { _, _ in .ok },
    cmd("debug.continue", "デバッグを続行", .write, ai: false,
        preflight: { s, _ throws(CommandError) in try require(s.debugPhase == "stopped", tr("停止中の session がありません")); return .write }) { _, _ in .ok },
    cmd("debug.pause", "デバッグを一時停止", .write, ai: false,
        preflight: { s, _ throws(CommandError) in try require(s.debugPhase == "running", tr("実行中の session がありません")); return .write }) { _, _ in .ok },
    cmd("debug.stepOver", "ステップオーバー", .write, ai: false,
        preflight: { s, _ throws(CommandError) in try require(s.debugPhase == "stopped", tr("停止中の session がありません")); return .write }) { _, _ in .ok },
    cmd("debug.stepInto", "ステップイン", .write, ai: false,
        preflight: { s, _ throws(CommandError) in try require(s.debugPhase == "stopped", tr("停止中の session がありません")); return .write }) { _, _ in .ok },
    cmd("debug.stepOut", "ステップアウト", .write, ai: false,
        preflight: { s, _ throws(CommandError) in try require(s.debugPhase == "stopped", tr("停止中の session がありません")); return .write }) { _, _ in .ok },
    cmd("debug.restart", "デバッグを再起動", .external, ai: false,
        preflight: { s, _ throws(CommandError) in try require(!["idle", "ended"].contains(s.debugPhase), tr("再起動する session がありません")); return .external }) { _, _ in .ok },
    cmd("debug.stop", "デバッグを終了", .write, ai: false,
        preflight: { s, _ throws(CommandError) in try require(!["idle", "ended"].contains(s.debugPhase), tr("終了する session がありません")); return .write }) { _, _ in .ok },
    cmd("state.snapshot", "状態を取得", .read, palette: false) { s, _ in .snapshot(s) },
  ] + gitCommands + agentContextCommands + mergeCommands

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

/// A place in a file: absolute path, 1-based line, 0-based UTF-16 column (the `file.open` inputs).
public struct EditorLocation: Sendable, Codable, Equatable {
  public let path: String
  public let line: Int
  public let column: Int
  public init(path: String, line: Int, column: Int) { self.path = path; self.line = line; self.column = column }
}

/// E17: browser-style back/forward list. A jump drops the forward entries, records where it left from
/// (the caret may have moved since the last visit) and where it landed.
public struct NavigationHistory: Sendable, Codable, Equatable {
  public private(set) var entries: [EditorLocation] = []
  public private(set) var index = -1
  static let limit = 50

  public init() {}

  public var current: EditorLocation? { entries.indices.contains(index) ? entries[index] : nil }
  public var canGoBack: Bool { index > 0 }
  public var canGoForward: Bool { index + 1 < entries.count }

  public mutating func jump(from: EditorLocation, to: EditorLocation) {
    entries = Array(entries.prefix(max(index, 0))) + [from, to]
    if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    index = entries.count - 1
  }

  public mutating func back() -> EditorLocation? { guard canGoBack else { return nil }; index -= 1; return current }
  public mutating func forward() -> EditorLocation? { guard canGoForward else { return nil }; index += 1; return current }
}
