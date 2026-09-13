import AppKit
import Combine
import SwiftUI

enum CommandSurfaceSource: String, Codable, CaseIterable, Sendable {
  case commandWindow
  case menu
  case shortcut
}

enum CommandSurfaceOutcome: Equatable, Sendable {
  case success(String)
  case failure(String)

  var message: String {
    switch self {
    case .success(let message), .failure(let message):
      message
    }
  }

  var isSuccess: Bool {
    if case .success = self {
      return true
    }
    return false
  }
}

struct CommandSurfaceExecution: Equatable, Sendable {
  let commandID: ClairCommandID
  let source: CommandSurfaceSource
  let outcome: CommandSurfaceOutcome
}

struct CommandShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
  let rawValue: Int

  static let command = Self(rawValue: 1 << 0)
  static let shift = Self(rawValue: 1 << 1)
  static let option = Self(rawValue: 1 << 2)
  static let control = Self(rawValue: 1 << 3)

  var eventModifiers: EventModifiers {
    var result: EventModifiers = []
    if contains(.command) {
      result.insert(.command)
    }
    if contains(.shift) {
      result.insert(.shift)
    }
    if contains(.option) {
      result.insert(.option)
    }
    if contains(.control) {
      result.insert(.control)
    }
    return result
  }

  var displayPrefix: String {
    var result = ""
    if contains(.control) {
      result += "⌃"
    }
    if contains(.option) {
      result += "⌥"
    }
    if contains(.shift) {
      result += "⇧"
    }
    if contains(.command) {
      result += "⌘"
    }
    return result
  }
}

struct CommandShortcut: Codable, Equatable, Hashable, Sendable {
  let key: String
  let modifiers: CommandShortcutModifiers

  init(key: String, modifiers: CommandShortcutModifiers = [.command]) {
    self.key = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    self.modifiers = modifiers
  }

  var displayName: String {
    "\(modifiers.displayPrefix)\(key.uppercased())"
  }

  var keyEquivalent: KeyEquivalent? {
    guard let character = key.first, key.count == 1 else {
      return nil
    }
    return KeyEquivalent(character)
  }

  static func normalizedKey(_ rawKey: String) -> String? {
    let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count == 1, let character = trimmed.first, !character.isWhitespace else {
      return nil
    }
    let normalized = String(character).lowercased()
    guard normalized.count == 1 else {
      return nil
    }
    return normalized
  }
}

enum CommandShortcutValidationError: Error, Equatable, LocalizedError, Sendable {
  case unknownCommand(ClairCommandID)
  case invalidKey
  case reserved(CommandShortcut)
  case conflict(existing: ClairCommandID, requested: ClairCommandID, shortcut: CommandShortcut)
  case malformedStore

  var errorDescription: String? {
    switch self {
    case .unknownCommand(let commandID):
      "The command \(commandID.rawValue) is not registered."
    case .invalidKey:
      "Shortcut keys must contain exactly one non-whitespace character."
    case .reserved(let shortcut):
      "The shortcut \(shortcut.displayName) is reserved by Clair or text editing."
    case .conflict(let existing, let requested, let shortcut):
      "The shortcut \(shortcut.displayName) is already assigned to \(existing.rawValue); it cannot also be assigned to \(requested.rawValue)."
    case .malformedStore:
      "Saved command shortcuts were invalid and were reset to defaults."
    }
  }
}

private struct CommandShortcutStoreSnapshot: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 2
  static let supportedSchemaVersions: Set<Int> = [1, currentSchemaVersion]

  let schemaVersion: Int
  let bindings: [Binding]

  struct Binding: Codable, Equatable, Sendable {
    let commandID: ClairCommandID
    let shortcut: CommandShortcut
  }
}

final class CommandShortcutStore {
  static let defaultsKey = "clair.command-keymap.v1"
  static let commandWindowShortcut = CommandShortcut(
    key: "k",
    modifiers: [.command, .shift]
  )
  static let closeTabShortcut = CommandShortcut(
    key: "w",
    modifiers: [.command]
  )
  static let quitApplicationShortcut = CommandShortcut(
    key: "q",
    modifiers: [.command]
  )
  static let quickOpenShortcut = CommandShortcut(
    key: "p",
    modifiers: [.command]
  )
  static let commandPaletteShortcut = CommandShortcut(
    key: "p",
    modifiers: [.command, .shift]
  )
  static let findShortcut = CommandShortcut(
    key: "f",
    modifiers: [.command]
  )
  static let replaceShortcut = CommandShortcut(
    key: "f",
    modifiers: [.command, .option]
  )
  static let goToLineShortcut = CommandShortcut(
    key: "g",
    modifiers: [.control]
  )
  static let toggleSidebarShortcut = CommandShortcut(
    key: "b",
    modifiers: [.command]
  )
  static let toggleTerminalShortcut = CommandShortcut(
    key: "`",
    modifiers: [.control]
  )
  /// Opens the existing terminal in the focused pane, or focuses it when it
  /// is already present. This is intentionally distinct from the legacy
  /// terminal visibility toggle above.
  static let terminalOpenShortcut = CommandShortcut(
    key: "j",
    modifiers: [.command]
  )
  /// Splits the focused pane horizontally. Git diff keeps its Cmd+Shift+D
  /// binding, so this command does not share a key chord with Git operations.
  static let paneSplitShortcut = CommandShortcut(
    key: "d",
    modifiers: [.command]
  )
  static let splitEditorShortcut = CommandShortcut(
    key: "\\",
    modifiers: [.command]
  )
  static let previousTabShortcut = CommandShortcut(
    key: "[",
    modifiers: [.command, .shift]
  )
  static let nextTabShortcut = CommandShortcut(
    key: "]",
    modifiers: [.command, .shift]
  )
  static let showExplorerShortcut = CommandShortcut(
    key: "e",
    modifiers: [.command, .shift]
  )
  static let showSearchShortcut = CommandShortcut(
    key: "f",
    modifiers: [.command, .shift]
  )
  static let showSourceControlShortcut = CommandShortcut(
    key: "g",
    modifiers: [.control, .shift]
  )
  static let toggleWordWrapShortcut = CommandShortcut(
    key: "z",
    modifiers: [.option]
  )
  static let saveAllShortcut = CommandShortcut(
    key: "s",
    modifiers: [.command, .option]
  )
  static let zoomInShortcut = CommandShortcut(
    key: "=",
    modifiers: [.command]
  )
  static let zoomOutShortcut = CommandShortcut(
    key: "-",
    modifiers: [.command]
  )
  static let resetZoomShortcut = CommandShortcut(
    key: "0",
    modifiers: [.command]
  )
  static let openSettingsShortcut = CommandShortcut(
    key: ",",
    modifiers: [.command]
  )
  static let copyActiveFilePathShortcut = CommandShortcut(
    key: "p",
    modifiers: [.command, .option]
  )
  static let revealActiveFileShortcut = CommandShortcut(
    key: "r",
    modifiers: [.command, .option]
  )
  static let selectLineShortcut = CommandShortcut(
    key: "l",
    modifiers: [.command]
  )
  static let toggleLineCommentShortcut = CommandShortcut(
    key: "/",
    modifiers: [.command]
  )
  static let indentLineShortcut = CommandShortcut(
    key: "]",
    modifiers: [.command]
  )
  static let outdentLineShortcut = CommandShortcut(
    key: "[",
    modifiers: [.command]
  )
  static let blockedWindowCloseShortcut = CommandShortcut(
    key: "w",
    modifiers: [.command, .shift]
  )
  static let reservedShortcuts: Set<CommandShortcut> = [
    CommandShortcut(key: "s", modifiers: [.command]),
    commandWindowShortcut,
    closeTabShortcut,
    quitApplicationShortcut,
    quickOpenShortcut,
    commandPaletteShortcut,
    findShortcut,
    replaceShortcut,
    goToLineShortcut,
    toggleSidebarShortcut,
    toggleTerminalShortcut,
    splitEditorShortcut,
    previousTabShortcut,
    nextTabShortcut,
    showExplorerShortcut,
    showSearchShortcut,
    showSourceControlShortcut,
    toggleWordWrapShortcut,
    saveAllShortcut,
    zoomInShortcut,
    zoomOutShortcut,
    resetZoomShortcut,
    openSettingsShortcut,
    copyActiveFilePathShortcut,
    revealActiveFileShortcut,
    selectLineShortcut,
    toggleLineCommentShortcut,
    indentLineShortcut,
    outdentLineShortcut,
    blockedWindowCloseShortcut,
  ]

  static let defaultShortcuts: [ClairCommandID: CommandShortcut] = [
    .openProject: CommandShortcut(key: "o", modifiers: [.command]),
    .terminalOpen: terminalOpenShortcut,
    .paneSplit: paneSplitShortcut,
    .gitRefresh: CommandShortcut(key: "r", modifiers: [.command, .shift]),
    .gitShowDiff: CommandShortcut(key: "d", modifiers: [.command, .shift]),
  ]
  static let schemaV2AddedShortcuts: [ClairCommandID: CommandShortcut] = [
    .terminalOpen: terminalOpenShortcut,
    .paneSplit: paneSplitShortcut,
  ]

  private let defaults: UserDefaults
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    self.encoder = encoder
    self.decoder = JSONDecoder()
  }

  func load() -> [ClairCommandID: CommandShortcut] {
    guard
      let data = defaults.data(forKey: Self.defaultsKey),
      let snapshot = try? decoder.decode(CommandShortcutStoreSnapshot.self, from: data),
      CommandShortcutStoreSnapshot.supportedSchemaVersions.contains(snapshot.schemaVersion),
      let bindings = try? validatedBindings(snapshot.bindings)
    else {
      return Self.defaultShortcuts
    }

    var loaded = Dictionary(uniqueKeysWithValues: bindings.map { ($0.commandID, $0.shortcut) })
    guard snapshot.schemaVersion < CommandShortcutStoreSnapshot.currentSchemaVersion else {
      return loaded
    }

    // v1 did not include the keyboard-first terminal and pane commands. Add
    // only those new defaults; an absent v1 binding can mean that the user
    // intentionally cleared an older shortcut, so older defaults must not be
    // restored during migration. Existing bindings remain authoritative and
    // an explicitly occupied chord is never overwritten.
    var occupied = Set(loaded.values)
    for (commandID, shortcut) in Self.schemaV2AddedShortcuts where loaded[commandID] == nil {
      guard occupied.insert(shortcut).inserted else {
        continue
      }
      loaded[commandID] = shortcut
    }
    // Keep the migration durable. Otherwise every launch would reinterpret
    // the old payload, and a later save could accidentally be based on a
    // stale v1 snapshot again.
    try? save(loaded)
    return loaded
  }

  func save(_ shortcuts: [ClairCommandID: CommandShortcut]) throws {
    let bindings = try validatedBindings(
      shortcuts.map {
        CommandShortcutStoreSnapshot.Binding(commandID: $0.key, shortcut: $0.value)
      }
    )
    let snapshot = CommandShortcutStoreSnapshot(
      schemaVersion: CommandShortcutStoreSnapshot.currentSchemaVersion,
      bindings: bindings.sorted { $0.commandID.rawValue < $1.commandID.rawValue }
    )
    defaults.set(try encoder.encode(snapshot), forKey: Self.defaultsKey)
  }

  private func validatedBindings(
    _ bindings: [CommandShortcutStoreSnapshot.Binding]
  ) throws -> [CommandShortcutStoreSnapshot.Binding] {
    var commandIDs = Set<ClairCommandID>()
    var shortcuts = [CommandShortcut: ClairCommandID]()
    let allowedModifiers = CommandShortcutModifiers([.command, .shift, .option, .control])
    var normalizedBindings = [CommandShortcutStoreSnapshot.Binding]()
    for binding in bindings {
      guard ClairCommandID.allCases.contains(binding.commandID) else {
        throw CommandShortcutValidationError.malformedStore
      }
      guard commandIDs.insert(binding.commandID).inserted else {
        throw CommandShortcutValidationError.malformedStore
      }
      guard CommandShortcut.normalizedKey(binding.shortcut.key) != nil else {
        throw CommandShortcutValidationError.malformedStore
      }
      guard binding.shortcut.modifiers.rawValue & ~allowedModifiers.rawValue == 0 else {
        throw CommandShortcutValidationError.malformedStore
      }
      let normalized = CommandShortcut(
        key: binding.shortcut.key,
        modifiers: binding.shortcut.modifiers
      )
      guard !Self.reservedShortcuts.contains(normalized) else {
        throw CommandShortcutValidationError.malformedStore
      }
      guard shortcuts[normalized] == nil else {
        throw CommandShortcutValidationError.malformedStore
      }
      shortcuts[normalized] = binding.commandID
      normalizedBindings.append(
        CommandShortcutStoreSnapshot.Binding(
          commandID: binding.commandID,
          shortcut: normalized
        )
      )
    }
    return normalizedBindings
  }
}

struct CommandSurfaceMatch: Identifiable, Equatable, Sendable {
  let descriptor: CommandDescriptor
  let availability: CommandAvailability
  let shortcut: CommandShortcut?

  var id: ClairCommandID {
    descriptor.id
  }

  var statusText: String {
    availability.reason ?? "利用可能"
  }
}

@MainActor
final class CommandSurfaceModel: ObservableObject {
  let workspace: ProjectWorkspaceModel
  let registry: CommandRegistry
  let shortcutStore: CommandShortcutStore

  @Published private(set) var shortcuts: [ClairCommandID: CommandShortcut]
  @Published private(set) var lastExecution: CommandSurfaceExecution?
  @Published private(set) var lastShortcutErrorMessage: String?

  private var workspaceObservation: AnyCancellable?
  private var surfaceObservation: AnyCancellable?

  init(
    workspace: ProjectWorkspaceModel,
    registry: CommandRegistry? = nil,
    shortcutStore: CommandShortcutStore = CommandShortcutStore()
  ) {
    self.workspace = workspace
    self.registry = registry ?? workspace.commandRegistry
    self.shortcutStore = shortcutStore
    self.shortcuts = shortcutStore.load()
    observeWorkspace()
  }

  var menuMatches: [CommandSurfaceMatch] {
    matches(for: "")
  }

  func matches(for query: String) -> [CommandSurfaceMatch] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return registry.descriptors
      .filter { descriptor in
        normalizedQuery.isEmpty
          || descriptor.title.lowercased().contains(normalizedQuery)
          || descriptor.id.rawValue.lowercased().contains(normalizedQuery)
      }
      .map { descriptor in
        CommandSurfaceMatch(
          descriptor: descriptor,
          availability: availability(for: descriptor.id),
          shortcut: shortcuts[descriptor.id]
        )
      }
      .sorted {
        if $0.availability.isAvailable != $1.availability.isAvailable {
          return $0.availability.isAvailable
        }
        return $0.descriptor.title.localizedStandardCompare($1.descriptor.title)
          == .orderedAscending
      }
  }

  func availability(for commandID: ClairCommandID) -> CommandAvailability {
    switch resolvedAction(for: commandID) {
    case .openProject:
      return workspace.preflight(
        .openProject(OpenProjectCommand(rootURL: URL(fileURLWithPath: "/")))
      ).availability
    case .command(let command):
      return workspace.preflight(command).availability
    case .surface:
      return .available
    case .unavailable(let reason):
      return .unavailable(reason)
    }
  }

  @discardableResult
  func invoke(
    commandID: ClairCommandID,
    source: CommandSurfaceSource
  ) -> Result<ClairCommandResult, CommandError> {
    switch resolvedAction(for: commandID) {
    case .openProject:
      let panel = NSOpenPanel()
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.allowsMultipleSelection = false
      panel.prompt = "Projectを開く"
      guard panel.runModal() == .OK, let url = panel.url else {
        return recordCancellation(commandID: commandID, source: source)
      }
      return dispatch(
        .openProject(OpenProjectCommand(rootURL: url)),
        source: source
      )
    case .command(let command):
      return dispatch(command, source: source)
    case .surface(let action):
      return execute(action, commandID: commandID, source: source)
    case .unavailable(let reason):
      return recordUnavailable(commandID: commandID, source: source, reason: reason)
    }
  }

  @discardableResult
  func dispatch(
    _ command: ClairCommand,
    source: CommandSurfaceSource
  ) -> Result<ClairCommandResult, CommandError> {
    let result = workspace.execute(command)
    lastExecution = CommandSurfaceExecution(
      commandID: command.id,
      source: source,
      outcome: outcome(for: result)
    )
    return result
  }

  @discardableResult
  func setShortcut(
    _ shortcut: CommandShortcut?,
    for commandID: ClairCommandID
  ) -> Result<Void, CommandShortcutValidationError> {
    guard registry.descriptor(for: commandID) != nil else {
      let error = CommandShortcutValidationError.unknownCommand(commandID)
      lastShortcutErrorMessage = error.localizedDescription
      return .failure(error)
    }

    var candidate = shortcuts
    if let shortcut {
      guard CommandShortcut.normalizedKey(shortcut.key) != nil else {
        let error = CommandShortcutValidationError.invalidKey
        lastShortcutErrorMessage = error.localizedDescription
        return .failure(error)
      }
      let normalizedShortcut = CommandShortcut(
        key: shortcut.key,
        modifiers: shortcut.modifiers
      )
      if CommandShortcutStore.reservedShortcuts.contains(normalizedShortcut) {
        let error = CommandShortcutValidationError.reserved(normalizedShortcut)
        lastShortcutErrorMessage = error.localizedDescription
        return .failure(error)
      }
      if let conflict = candidate.first(where: {
        $0.key != commandID && $0.value == normalizedShortcut
      }) {
        let error = CommandShortcutValidationError.conflict(
          existing: conflict.key,
          requested: commandID,
          shortcut: normalizedShortcut
        )
        lastShortcutErrorMessage = error.localizedDescription
        return .failure(error)
      }
      candidate[commandID] = normalizedShortcut
    } else {
      candidate.removeValue(forKey: commandID)
    }

    do {
      try shortcutStore.save(candidate)
    } catch let error as CommandShortcutValidationError {
      lastShortcutErrorMessage = error.localizedDescription
      return .failure(error)
    } catch {
      let validationError = CommandShortcutValidationError.malformedStore
      lastShortcutErrorMessage = validationError.localizedDescription
      return .failure(validationError)
    }
    shortcuts = candidate
    lastShortcutErrorMessage = nil
    return .success(())
  }

  func clearShortcutError() {
    lastShortcutErrorMessage = nil
  }

  private func observeWorkspace() {
    workspaceObservation = workspace.objectWillChange.sink { [weak self] _ in
      self?.observeActiveSurface()
      self?.objectWillChange.send()
    }
    observeActiveSurface()
  }

  private func observeActiveSurface() {
    surfaceObservation = workspace.activeSurface?.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
  }

  private enum ResolvedAction {
    case openProject
    case command(ClairCommand)
    case surface(SurfaceCommand)
    case unavailable(String)
  }

  private enum SurfaceCommand {
    case openTerminal
    case splitPane
    case stopTerminal(tabID: String)
    case recoverTerminal(tabID: String)
  }

  private func resolvedAction(for commandID: ClairCommandID) -> ResolvedAction {
    let activeProjectID = workspace.activeProjectID

    switch commandID {
    case .openProject:
      return .openProject
    case .switchProject:
      guard
        let nextProject = workspace.projects.first(where: { $0.id != activeProjectID })
      else {
        let unavailableCommand = ClairCommand.switchProject(
          SwitchProjectCommand(projectID: UUID())
        )
        return .unavailable(unavailableReason(for: unavailableCommand))
      }
      return .command(.switchProject(SwitchProjectCommand(projectID: nextProject.id)))
    case .paneSplit:
      guard activeProjectID != nil else {
        return .unavailable("Open a Project before splitting a pane.")
      }
      guard workspace.activeSurface != nil else {
        return .unavailable("The active Project surface is not ready to split.")
      }
      return .surface(.splitPane)
    case .terminalOpen:
      guard activeProjectID != nil else {
        return .unavailable("Open a Project before opening a terminal.")
      }
      guard workspace.activeSurface != nil else {
        return .unavailable("The active Project surface is not ready to open a terminal.")
      }
      return .surface(.openTerminal)
    case .terminalStop:
      guard let surface = workspace.activeSurface, surface.isTerminalVisible,
        let tabID = surface.activeTabID
      else {
        return .unavailable("Focus a terminal before stopping it.")
      }
      return .surface(.stopTerminal(tabID: tabID))
    case .terminalRecover:
      guard let surface = workspace.activeSurface,
        let tab = surface.activeTab(in: surface.focusedPaneID),
        tab.kind == .terminal
      else {
        return .unavailable("Focus a terminal before recovering its session.")
      }
      return .surface(.recoverTerminal(tabID: tab.id))
    case .renameProject, .setProjectColor, .reorderProject, .closeProject:
      guard workspace.activeProject != nil else {
        return .unavailable("Open a Project before using this command.")
      }
      switch commandID {
      case .renameProject:
        return .unavailable("Rename Project needs a name and is available from the Project menu.")
      case .setProjectColor:
        return .unavailable(
          "Set Project Color needs a color and is available from the Project menu.")
      case .reorderProject:
        return .unavailable(
          "Reorder Project needs a target position and is available from the Project list."
        )
      case .closeProject:
        return .unavailable(
          "Close Project requires confirmation and is available from the Project menu.")
      default:
        assertionFailure("Unexpected Project command")
        return .unavailable("This Project command is not available from the command surface.")
      }
    case .gitRefresh:
      guard let activeProjectID else {
        return .unavailable("Open a Project before refreshing Git status.")
      }
      return .command(.gitRefresh(GitRefreshCommand(projectID: activeProjectID)))
    case .gitShowDiff, .gitStage, .gitUnstage:
      guard let activeProjectID, let change = selectedGitChange() else {
        return .unavailable("Refresh Git status and select a Git change first.")
      }
      switch commandID {
      case .gitShowDiff:
        return .command(
          .gitShowDiff(
            GitShowDiffCommand(
              projectID: activeProjectID,
              relativePath: change.path,
              basis: change.isStaged && !change.isUnstaged ? .staged : .workingTree
            )
          )
        )
      case .gitStage:
        guard change.isUnstaged else {
          return .unavailable("Select an unstaged Git change first.")
        }
        return .command(
          .gitStage(GitStageCommand(projectID: activeProjectID, relativePath: change.path))
        )
      case .gitUnstage:
        guard change.isStaged else {
          return .unavailable("Select a staged Git change first.")
        }
        return .command(
          .gitUnstage(GitUnstageCommand(projectID: activeProjectID, relativePath: change.path))
        )
      default:
        assertionFailure("Unexpected Git change command")
        return .unavailable("This Git command is not available from the command surface.")
      }
    case .gitCommit:
      guard let status = workspace.activeSurface?.gitStatus else {
        return .unavailable("Refresh Git status before committing Git changes.")
      }
      guard status.isRepository, status.stagedCount > 0 else {
        return .unavailable("Stage at least one Git change before committing.")
      }
      return .unavailable("Commit Git Changes needs a message and is available from the Git view.")
    case .gitSwitchBranch:
      guard let status = workspace.activeSurface?.gitStatus, status.isRepository else {
        return .unavailable("Refresh Git status for an active Git Project first.")
      }
      return .unavailable(
        status.branches.count > 1
          ? "Switch Git Branch needs a branch and is available from the Git view."
          : "No alternate Git branch is available."
      )
    default:
      return .unavailable(
        "This command is available through the typed CLI/MCP adapter or a contextual surface."
      )
    }
  }

  private func selectedGitChange() -> ProjectGitChange? {
    guard let status = workspace.activeSurface?.gitStatus else {
      return nil
    }
    guard let selectedNodeID = workspace.activeSurface?.selectedNodeID else {
      return nil
    }
    let rootPath = workspace.activeSurface?.rootURL.path ?? ""
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    let relativePath =
      selectedNodeID.hasPrefix(prefix)
      ? String(selectedNodeID.dropFirst(prefix.count))
      : selectedNodeID
    return status.changes.first(where: { $0.path == relativePath })
  }

  private func unavailableReason(for command: ClairCommand) -> String {
    workspace.preflight(command).availability.reason ?? "The command is not available."
  }

  @discardableResult
  private func execute(
    _ action: SurfaceCommand,
    commandID: ClairCommandID,
    source: CommandSurfaceSource
  ) -> Result<ClairCommandResult, CommandError> {
    guard let surface = workspace.activeSurface else {
      return recordUnavailable(
        commandID: commandID,
        source: source,
        reason: "The active Project surface is not ready."
      )
    }

    let result: Result<ClairCommandResult, CommandError>
    switch action {
    case .openTerminal:
      guard !surface.paneIDs.isEmpty else {
        return recordUnavailable(
          commandID: commandID,
          source: source,
          reason: "The active Project has no pane available for a terminal."
        )
      }
      surface.showTerminal()
      guard surface.isTerminalVisible, let tabID = surface.activeTabID else {
        return recordUnavailable(
          commandID: commandID,
          source: source,
          reason: "Clair could not open or focus a terminal in the active pane."
        )
      }
      result = .success(
        .adapter(.terminal(projectID: surface.projectID, tabID: tabID))
      )
    case .splitPane:
      let paneCount = surface.paneIDs.count
      surface.splitFocusedPane(orientation: .horizontal)
      guard surface.paneIDs.count == paneCount + 1 else {
        return recordUnavailable(
          commandID: commandID,
          source: source,
          reason: "Clair could not split the focused pane."
        )
      }
      result = .success(
        .adapter(
          .pane(
            projectID: surface.projectID,
            focusedPaneID: surface.focusedPaneID,
            paneCount: surface.paneIDs.count
          )
        )
      )
    case .stopTerminal(let tabID):
      guard surface.isTerminalVisible, surface.activeTabID == tabID else {
        return recordUnavailable(
          commandID: commandID,
          source: source,
          reason: "The terminal to stop is no longer focused."
        )
      }
      surface.endTerminal()
      guard !surface.tabStore.contains(where: { $0.id == tabID }) else {
        return recordUnavailable(
          commandID: commandID,
          source: source,
          reason: "Clair could not stop the focused terminal."
        )
      }
      result = .success(
        .adapter(.terminal(projectID: surface.projectID, tabID: tabID))
      )
    case .recoverTerminal(let tabID):
      guard surface.tabStore.contains(where: { $0.id == tabID && $0.kind == .terminal }) else {
        return recordUnavailable(
          commandID: commandID,
          source: source,
          reason: "The terminal session is no longer available to recover."
        )
      }
      surface.recoverTerminal(tabID: tabID)
      result = .success(
        .adapter(.terminal(projectID: surface.projectID, tabID: tabID))
      )
    }

    lastExecution = CommandSurfaceExecution(
      commandID: commandID,
      source: source,
      outcome: outcome(for: result)
    )
    return result
  }

  private func outcome(
    for result: Result<ClairCommandResult, CommandError>
  ) -> CommandSurfaceOutcome {
    switch result {
    case .success(let result):
      return .success(Self.successMessage(for: result))
    case .failure(let error):
      return .failure(error.localizedDescription)
    }
  }

  private static func successMessage(for result: ClairCommandResult) -> String {
    switch result {
    case .project(let project):
      "Project ready: \(project.name)"
    case .gitStatus(let status):
      status.message ?? "Git status refreshed."
    case .gitDiff(let diff):
      "Showing \(diff.change.displayPath)."
    case .adapter(let result):
      switch result {
      case .status(let message):
        message
      case .pane(_, _, let paneCount):
        "Pane split complete (\(paneCount) panes)."
      case .terminal(_, _):
        "Terminal ready."
      default:
        "Command completed."
      }
    case .none:
      "Command completed."
    }
  }

  private func recordUnavailable(
    commandID: ClairCommandID,
    source: CommandSurfaceSource,
    reason: String
  ) -> Result<ClairCommandResult, CommandError> {
    let error = CommandError.unavailable(commandID: commandID, reason: reason)
    lastExecution = CommandSurfaceExecution(
      commandID: commandID,
      source: source,
      outcome: .failure(error.localizedDescription)
    )
    return .failure(error)
  }

  private func recordCancellation(
    commandID: ClairCommandID,
    source: CommandSurfaceSource
  ) -> Result<ClairCommandResult, CommandError> {
    let reason = "The command was cancelled."
    lastExecution = CommandSurfaceExecution(
      commandID: commandID,
      source: source,
      outcome: .failure(reason)
    )
    return .failure(.unavailable(commandID: commandID, reason: reason))
  }
}

struct CommandWindowView: View {
  @ObservedObject var surface: CommandSurfaceModel

  @State private var query = ""
  @State private var selectedCommandID: ClairCommandID?
  @State private var shortcutKey = ""
  @State private var shortcutModifiers: CommandShortcutModifiers = [.command]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "command")
          .foregroundStyle(.secondary)
        TextField("Search commands or stable IDs…", text: $query)
          .textFieldStyle(.roundedBorder)
          .onSubmit {
            runFirstAvailableMatch()
          }
      }
      .padding(16)

      Divider()

      List(selection: $selectedCommandID) {
        ForEach(surface.matches(for: query)) { match in
          Button {
            selectedCommandID = match.id
            run(match)
          } label: {
            HStack(spacing: 10) {
              VStack(alignment: .leading, spacing: 3) {
                Text(match.descriptor.title)
                  .foregroundStyle(.primary)
                Text(match.descriptor.id.rawValue)
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                Text(match.statusText)
                  .font(.caption)
                  .foregroundStyle(match.availability.isAvailable ? .green : .orange)
              }
              Spacer(minLength: 8)
              if let shortcut = match.shortcut {
                Text(shortcut.displayName)
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
              }
              Text(match.descriptor.risk.rawValue)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
          }
          .buttonStyle(.tactile)
          .disabled(!match.availability.isAvailable)
          .tag(match.id)
        }
      }
      .listStyle(.inset)

      Divider()

      shortcutEditor

      if let execution = surface.lastExecution {
        Divider()
        HStack(alignment: .top, spacing: 8) {
          Image(
            systemName: execution.outcome.isSuccess ? "checkmark.circle.fill" : "xmark.octagon.fill"
          )
          .foregroundStyle(execution.outcome.isSuccess ? .green : .red)
          VStack(alignment: .leading, spacing: 2) {
            Text("\(execution.source.rawValue) · \(execution.commandID.rawValue)")
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
            Text(execution.outcome.message)
              .font(.callout)
              .textSelection(.enabled)
          }
          Spacer()
        }
        .padding(12)
      }
    }
    .frame(minWidth: 680, minHeight: 560)
    .background {
      ThinScrollbarsInstaller()
    }
    .onChange(of: selectedCommandID) { _, commandID in
      guard let commandID else { return }
      let shortcut = surface.shortcuts[commandID]
      shortcutKey = shortcut?.key ?? ""
      shortcutModifiers = shortcut?.modifiers ?? [.command]
    }
  }

  private var shortcutEditor: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Configurable shortcut")
          .font(.headline)
        Spacer()
        if let selectedCommandID {
          Text(selectedCommandID.rawValue)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
      }

      if selectedCommandID == nil {
        Text("Select a command to assign or clear its shortcut.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        HStack(spacing: 8) {
          TextField("Key", text: $shortcutKey)
            .frame(width: 72)
            .textFieldStyle(.roundedBorder)
          Toggle("⌘", isOn: modifierBinding(.command))
          Toggle("⇧", isOn: modifierBinding(.shift))
          Toggle("⌥", isOn: modifierBinding(.option))
          Toggle("⌃", isOn: modifierBinding(.control))
          Button("Save") {
            saveShortcut()
          }
          .buttonStyle(.borderedProminent)
          Button("Clear") {
            clearShortcut()
          }
          .buttonStyle(.bordered)
        }
        if let error = surface.lastShortcutErrorMessage {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }
    }
    .padding(12)
  }

  private func modifierBinding(_ modifier: CommandShortcutModifiers) -> Binding<Bool> {
    Binding(
      get: { shortcutModifiers.contains(modifier) },
      set: { isSelected in
        if isSelected {
          shortcutModifiers.insert(modifier)
        } else {
          shortcutModifiers.remove(modifier)
        }
      }
    )
  }

  private func runFirstAvailableMatch() {
    guard let match = surface.matches(for: query).first(where: { $0.availability.isAvailable })
    else {
      return
    }
    selectedCommandID = match.id
    run(match)
  }

  private func run(_ match: CommandSurfaceMatch) {
    guard match.availability.isAvailable else { return }
    _ = surface.invoke(commandID: match.id, source: .commandWindow)
  }

  private func saveShortcut() {
    guard let selectedCommandID else { return }
    _ = surface.setShortcut(
      CommandShortcut(key: shortcutKey, modifiers: shortcutModifiers),
      for: selectedCommandID
    )
  }

  private func clearShortcut() {
    guard let selectedCommandID else { return }
    _ = surface.setShortcut(nil, for: selectedCommandID)
  }
}

struct ClairCommandMenu: Commands {
  @ObservedObject var surface: CommandSurfaceModel
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandMenu("Commands") {
      Button("Command Window") {
        openWindow(id: "command-window")
      }
      .keyboardShortcut(
        CommandShortcutStore.commandWindowShortcut.keyEquivalent!,
        modifiers: CommandShortcutStore.commandWindowShortcut.modifiers.eventModifiers
      )

      Button("コマンドパレット") {
        post(.commandPalette)
      }
      .keyboardShortcut(
        CommandShortcutStore.commandPaletteShortcut.keyEquivalent!,
        modifiers: CommandShortcutStore.commandPaletteShortcut.modifiers.eventModifiers
      )

      Button("ファイルをクイックオープン") {
        post(.quickOpen)
      }
      .keyboardShortcut(
        CommandShortcutStore.quickOpenShortcut.keyEquivalent!,
        modifiers: CommandShortcutStore.quickOpenShortcut.modifiers.eventModifiers
      )

      Button("検索") {
        post(.find)
      }
      .keyboardShortcut(
        CommandShortcutStore.findShortcut.keyEquivalent!,
        modifiers: CommandShortcutStore.findShortcut.modifiers.eventModifiers
      )

      Button("置換") {
        post(.replace)
      }
      .keyboardShortcut(
        CommandShortcutStore.replaceShortcut.keyEquivalent!,
        modifiers: CommandShortcutStore.replaceShortcut.modifiers.eventModifiers
      )

      Button("行へ移動") {
        post(.goToLine)
      }
      .keyboardShortcut(
        CommandShortcutStore.goToLineShortcut.keyEquivalent!,
        modifiers: CommandShortcutStore.goToLineShortcut.modifiers.eventModifiers
      )

      Divider()

      Button("タブを閉じる") {
        surface.workspace.requestCloseActiveTab()
      }

      Button("エディタを分割") {
        post(.splitEditor)
      }
      .keyboardShortcut(
        CommandShortcutStore.splitEditorShortcut.keyEquivalent!,
        modifiers: CommandShortcutStore.splitEditorShortcut.modifiers.eventModifiers
      )

      Button("ターミナル表示を切り替え") {
        post(.toggleTerminal)
      }
      .keyboardShortcut(
        CommandShortcutStore.toggleTerminalShortcut.keyEquivalent!,
        modifiers: CommandShortcutStore.toggleTerminalShortcut.modifiers.eventModifiers
      )

      Button("サイドバー表示を切り替え") {
        post(.toggleSidebar)
      }
      .keyboardShortcut(
        CommandShortcutStore.toggleSidebarShortcut.keyEquivalent!,
        modifiers: CommandShortcutStore.toggleSidebarShortcut.modifiers.eventModifiers
      )

      Button("設定") {
        post(.openSettings)
      }
      .keyboardShortcut(
        CommandShortcutStore.openSettingsShortcut.keyEquivalent!,
        modifiers: CommandShortcutStore.openSettingsShortcut.modifiers.eventModifiers
      )

      Divider()

      Button("Text Surface Harness") {
        _ = TextSurfaceHarnessWindowController.present()
      }
      .disabled(!TextSurfaceHarness.availability.isAvailable)
      .help(
        TextSurfaceHarness.availability.reason
          ?? "Open the shared text surface diagnostics window."
      )

      Divider()

      ForEach(surface.menuMatches) { match in
        commandButton(for: match)
      }
    }
  }

  private func post(_ action: ClairKeyboardShortcutAction) {
    NotificationCenter.default.post(
      name: .clairKeyboardShortcut,
      object: nil,
      userInfo: ["action": action.rawValue]
    )
  }

  @ViewBuilder
  private func commandButton(for match: CommandSurfaceMatch) -> some View {
    if let shortcut = match.shortcut, let keyEquivalent = shortcut.keyEquivalent {
      Button(match.descriptor.title) {
        _ = surface.invoke(commandID: match.id, source: .menu)
      }
      .disabled(!match.availability.isAvailable)
      .keyboardShortcut(keyEquivalent, modifiers: shortcut.modifiers.eventModifiers)
      .help(match.availability.reason ?? match.descriptor.id.rawValue)
    } else {
      Button(match.descriptor.title) {
        _ = surface.invoke(commandID: match.id, source: .menu)
      }
      .disabled(!match.availability.isAvailable)
      .help(match.availability.reason ?? match.descriptor.id.rawValue)
    }
  }
}
