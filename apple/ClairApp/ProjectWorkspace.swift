import Foundation
import SwiftUI

@MainActor
final class ProjectWorkspaceModel: ObservableObject {
  let store: ProjectStore
  let rootChecker: any ProjectRootChecking
  let commandRegistry: CommandRegistry
  let historyStore: ProjectLocalHistoryStore

  @Published private(set) var projects: [Project] = []
  @Published private(set) var activeProjectID: UUID?
  @Published private(set) var activeSurface: ProjectSurfaceModel?
  @Published private(set) var lastErrorMessage: String?

  private var records: [ProjectRecord] = []
  private var surfaces: [UUID: ProjectSurfaceModel] = [:]
  private var surfaceSnapshots: [UUID: ProjectSurfaceSnapshot] = [:]

  init(
    store: ProjectStore,
    rootChecker: any ProjectRootChecking = FileSystemProjectRootChecker(),
    commandRegistry: CommandRegistry = CommandRegistry(),
    historyStore: ProjectLocalHistoryStore? = nil
  ) {
    self.store = store
    self.rootChecker = rootChecker
    self.commandRegistry = commandRegistry
    self.historyStore = historyStore ?? .makeDefault(for: .current)

    do {
      let snapshot = try store.load()
      records = Self.normalizedRecords(snapshot.projects)
      activeProjectID = snapshot.activeProjectID
    } catch let error as ProjectError {
      lastErrorMessage = error.localizedDescription
    } catch {
      lastErrorMessage = error.localizedDescription
    }

    do {
      let snapshot = try store.loadWorkspace()
      var recoveredSurface = false
      for surface in snapshot.surfaces {
        guard let validSurface = surface.validated(for: surface.projectID) else {
          recoveredSurface = true
          continue
        }
        surfaceSnapshots[validSurface.projectID] = validSurface
      }
      if recoveredSurface {
        lastErrorMessage = "Some Project workspace surfaces were invalid and were reset."
      }
    } catch let error as ProjectError {
      lastErrorMessage = error.localizedDescription
    } catch {
      lastErrorMessage = error.localizedDescription
    }

    refreshPublishedState()
  }

  var activeProject: Project? {
    guard let activeProjectID else {
      return nil
    }
    return projects.first { $0.id == activeProjectID }
  }

  /// Returns the already-restored surface for a Project, when it has been
  /// materialized. Non-active Projects are created lazily when first opened.
  func surface(for projectID: UUID) -> ProjectSurfaceModel? {
    surfaces[projectID]
  }

  /// Materializes a non-active Project surface for control-plane consumers.
  /// The normal UI path remains lazy, while agent discovery can inspect and
  /// reattach every persisted agent tab without depending on the visible pane.
  func materializeSurface(for projectID: UUID) -> ProjectSurfaceModel? {
    guard let project = projects.first(where: { $0.id == projectID }) else {
      return nil
    }
    if let surface = surfaces[projectID] {
      return surface
    }

    let surface = ProjectSurfaceModel(
      projectID: project.id,
      rootURL: project.rootURL,
      rootChecker: rootChecker,
      historyStore: historyStore,
      snapshot: surfaceSnapshots[project.id],
      onSnapshotChange: { [weak self] snapshot in
        self?.persistSurfaceSnapshot(snapshot)
      }
    )
    surfaces[project.id] = surface
    return surface
  }

  func dismissError() {
    lastErrorMessage = nil
  }

  func reattachRuntimeSessions() {
    for surface in surfaces.values {
      surface.reattachRuntimeSessions()
    }
  }

  func terminateAllTerminalSessions() {
    for surface in surfaces.values {
      surface.terminateAllTerminalSessions()
    }
  }

  func preflight(_ command: ClairCommand) -> CommandPreflight {
    commandRegistry.preflight(command, state: commandState)
  }

  @discardableResult
  func execute(_ command: ClairCommand) -> Result<ClairCommandResult, CommandError> {
    let preflight = preflight(command)
    guard preflight.availability.isAvailable else {
      let reason = preflight.availability.reason ?? "The command is not available."
      let error = CommandError.unavailable(commandID: command.id, reason: reason)
      lastErrorMessage = error.localizedDescription
      return .failure(error)
    }

    do {
      let result = try apply(command)
      lastErrorMessage = nil
      return .success(result)
    } catch let error as CommandError {
      lastErrorMessage = error.localizedDescription
      return .failure(error)
    } catch let error as ProjectError {
      lastErrorMessage = error.localizedDescription
      return .failure(.project(error))
    } catch let error as ProjectGitError {
      lastErrorMessage = error.localizedDescription
      return .failure(.git(error))
    } catch {
      let projectError = ProjectError.storeIO(error.localizedDescription)
      lastErrorMessage = projectError.localizedDescription
      return .failure(.project(projectError))
    }
  }

  func moveProject(id: UUID, by offset: Int) {
    guard let currentIndex = projects.firstIndex(where: { $0.id == id }) else {
      return
    }
    let targetIndex = currentIndex + offset
    _ = execute(
      .reorderProject(
        ReorderProjectCommand(projectID: id, targetIndex: targetIndex)
      )
    )
  }

  func revealTerminal(projectID: UUID, tabID: String) {
    guard projects.contains(where: { $0.id == projectID }) else {
      return
    }
    if activeProjectID != projectID {
      _ = execute(.switchProject(SwitchProjectCommand(projectID: projectID)))
    }
    guard let surface = surfaces[projectID] else {
      return
    }
    surface.activateTab(id: tabID)
    activeSurface = surface
  }

  private var commandState: ProjectCommandState {
    ProjectCommandState(
      openProjectIDs: Set(projects.map(\.id)),
      activeProjectID: activeProjectID
    )
  }

  private func apply(_ command: ClairCommand) throws -> ClairCommandResult {
    switch command {
    case .openProject(let input):
      return .project(try openProject(at: input.rootURL))
    case .switchProject(let input):
      try switchProject(to: input.projectID)
      return .none
    case .renameProject(let input):
      return .project(try renameProject(id: input.projectID, name: input.name))
    case .setProjectColor(let input):
      return .project(try setProjectColor(id: input.projectID, color: input.color))
    case .reorderProject(let input):
      try reorderProject(id: input.projectID, targetIndex: input.targetIndex)
      return .none
    case .closeProject(let input):
      try closeProject(id: input.projectID)
      return .none
    case .gitRefresh(let input):
      return .gitStatus(try activeGitSurface(for: input.projectID).refreshGitStatusThrowing())
    case .gitShowDiff(let input):
      return .gitDiff(
        try activeGitSurface(for: input.projectID).showGitDiff(
          relativePath: input.relativePath,
          basis: input.basis
        )
      )
    case .gitStage(let input):
      return .gitStatus(
        try activeGitSurface(for: input.projectID).stageGitChange(relativePath: input.relativePath)
      )
    case .gitUnstage(let input):
      return .gitStatus(
        try activeGitSurface(for: input.projectID).unstageGitChange(
          relativePath: input.relativePath
        )
      )
    case .gitCommit(let input):
      return .gitStatus(
        try activeGitSurface(for: input.projectID).commitGitChanges(message: input.message)
      )
    case .gitSwitchBranch(let input):
      return .gitStatus(
        try activeGitSurface(for: input.projectID).switchGitBranch(input.branch)
      )
    default:
      throw CommandError.adapter(
        "The command is routed through the CLI/MCP adapter rather than the Project workspace."
      )
    }
  }

  private func activeGitSurface(for projectID: UUID) throws -> ProjectSurfaceModel {
    guard activeProjectID == projectID, let activeSurface else {
      throw ProjectError.projectNotOpen(projectID)
    }
    return activeSurface
  }

  private func openProject(at rootURL: URL) throws -> Project {
    let canonicalURL = try rootChecker.validate(rootURL)

    if let existingIndex = records.firstIndex(where: {
      rootChecker.canonicalURL(for: URL(fileURLWithPath: $0.rootPath, isDirectory: true))
        == canonicalURL
    }) {
      if records[existingIndex].isOpen {
        throw ProjectError.duplicateRoot(existingProjectID: records[existingIndex].id)
      }

      var nextRecords = records
      nextRecords[existingIndex].isOpen = true
      nextRecords[existingIndex].rootPath = canonicalURL.path
      nextRecords[existingIndex].order = openRecords.count
      try commit(nextRecords, activeID: nextRecords[existingIndex].id)
      return try project(id: nextRecords[existingIndex].id)
    }

    let name =
      canonicalURL.lastPathComponent.isEmpty
      ? canonicalURL.path
      : canonicalURL.lastPathComponent
    let record = ProjectRecord(
      id: UUID(),
      rootPath: canonicalURL.path,
      name: name,
      color: .blue,
      isOpen: true,
      order: openRecords.count
    )
    var nextRecords = records
    nextRecords.append(record)
    try commit(nextRecords, activeID: record.id)
    return try project(id: record.id)
  }

  private func switchProject(to projectID: UUID) throws {
    guard records.contains(where: { $0.id == projectID && $0.isOpen }) else {
      throw ProjectError.projectNotOpen(projectID)
    }
    try commit(records, activeID: projectID)
  }

  private func renameProject(id projectID: UUID, name: String) throws -> Project {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else {
      throw ProjectError.invalidName
    }
    guard let index = records.firstIndex(where: { $0.id == projectID && $0.isOpen }) else {
      throw ProjectError.projectNotOpen(projectID)
    }

    var nextRecords = records
    nextRecords[index].name = normalizedName
    try commit(nextRecords, activeID: activeProjectID)
    return try project(id: projectID)
  }

  private func setProjectColor(id projectID: UUID, color: ProjectColor) throws -> Project {
    guard let index = records.firstIndex(where: { $0.id == projectID && $0.isOpen }) else {
      throw ProjectError.projectNotOpen(projectID)
    }

    var nextRecords = records
    nextRecords[index].color = color
    try commit(nextRecords, activeID: activeProjectID)
    return try project(id: projectID)
  }

  private func reorderProject(id projectID: UUID, targetIndex: Int) throws {
    guard records.contains(where: { $0.id == projectID && $0.isOpen }) else {
      throw ProjectError.projectNotOpen(projectID)
    }
    guard openRecords.indices.contains(targetIndex) else {
      throw ProjectError.invalidOrder(targetIndex)
    }

    var ordered = openRecords
    guard let currentIndex = ordered.firstIndex(where: { $0.id == projectID }) else {
      throw ProjectError.projectNotFound(projectID)
    }
    let moved = ordered.remove(at: currentIndex)
    ordered.insert(moved, at: targetIndex)

    var nextRecords = records
    for (order, record) in ordered.enumerated() {
      guard let index = nextRecords.firstIndex(where: { $0.id == record.id }) else {
        throw ProjectError.projectNotFound(record.id)
      }
      nextRecords[index].order = order
    }
    try commit(nextRecords, activeID: activeProjectID)
  }

  private func closeProject(id projectID: UUID) throws {
    guard let index = records.firstIndex(where: { $0.id == projectID && $0.isOpen }) else {
      throw ProjectError.projectNotOpen(projectID)
    }

    var nextRecords = records
    nextRecords[index].isOpen = false
    let nextActiveID: UUID?
    if activeProjectID == projectID {
      nextActiveID = openRecords.first { $0.id != projectID }?.id
    } else {
      nextActiveID = activeProjectID
    }
    try commit(nextRecords, activeID: nextActiveID)
  }

  private var openRecords: [ProjectRecord] {
    records.filter(\.isOpen).sorted {
      if $0.order == $1.order {
        return $0.id.uuidString < $1.id.uuidString
      }
      return $0.order < $1.order
    }
  }

  private func project(id projectID: UUID) throws -> Project {
    guard let record = records.first(where: { $0.id == projectID && $0.isOpen }) else {
      throw ProjectError.projectNotOpen(projectID)
    }
    return makeProject(from: record)
  }

  private func commit(_ nextRecords: [ProjectRecord], activeID: UUID?) throws {
    let previousRecords = records
    let previousActiveID = activeProjectID
    records = Self.normalizedRecords(nextRecords)
    activeProjectID = activeID
    refreshPublishedState()

    let snapshot = ProjectStoreSnapshot(
      schemaVersion: ProjectStoreSnapshot.currentSchemaVersion,
      projects: records,
      activeProjectID: activeProjectID
    )
    do {
      try store.save(snapshot)
    } catch {
      records = previousRecords
      activeProjectID = previousActiveID
      refreshPublishedState()
      throw error
    }
  }

  private func refreshPublishedState() {
    projects = openRecords.map(makeProject(from:))
    if let activeProjectID, projects.contains(where: { $0.id == activeProjectID }) {
      reconcileSurfaces()
      return
    }
    activeProjectID = projects.first?.id
    reconcileSurfaces()
  }

  private func reconcileSurfaces() {
    let openProjectIDs = Set(projects.map(\.id))
    let closedProjectIDs = surfaces.keys.filter { !openProjectIDs.contains($0) }
    for projectID in closedProjectIDs {
      surfaces[projectID] = nil
    }

    guard let activeProjectID else {
      activeSurface = nil
      return
    }

    guard let project = projects.first(where: { $0.id == activeProjectID }) else {
      activeSurface = nil
      return
    }

    if let surface = surfaces[project.id] {
      activeSurface = surface
      return
    }

    let surface = ProjectSurfaceModel(
      projectID: project.id,
      rootURL: project.rootURL,
      rootChecker: rootChecker,
      historyStore: historyStore,
      snapshot: surfaceSnapshots[project.id],
      onSnapshotChange: { [weak self] snapshot in
        self?.persistSurfaceSnapshot(snapshot)
      }
    )
    surfaces[project.id] = surface
    activeSurface = surface
  }

  private func persistSurfaceSnapshot(_ snapshot: ProjectSurfaceSnapshot) {
    surfaceSnapshots[snapshot.projectID] = snapshot
    let workspaceSnapshot = ProjectWorkspaceStoreSnapshot(
      schemaVersion: ProjectWorkspaceStoreSnapshot.currentSchemaVersion,
      surfaces: surfaceSnapshots.values.sorted {
        $0.projectID.uuidString < $1.projectID.uuidString
      }
    )
    do {
      try store.saveWorkspace(workspaceSnapshot)
      lastErrorMessage = nil
    } catch let error as ProjectError {
      lastErrorMessage = error.localizedDescription
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  private func makeProject(from record: ProjectRecord) -> Project {
    let rootURL = URL(fileURLWithPath: record.rootPath, isDirectory: true)
    return Project(
      id: record.id,
      rootURL: rootURL,
      name: record.name,
      color: record.color,
      availability: rootChecker.availability(for: rootURL)
    )
  }

  private static func normalizedRecords(_ records: [ProjectRecord]) -> [ProjectRecord] {
    var normalized = records
    let openIDs =
      normalized
      .filter(\.isOpen)
      .sorted {
        if $0.order == $1.order {
          return $0.id.uuidString < $1.id.uuidString
        }
        return $0.order < $1.order
      }
      .map(\.id)

    for (order, id) in openIDs.enumerated() {
      guard let index = normalized.firstIndex(where: { $0.id == id }) else {
        continue
      }
      normalized[index].order = order
    }
    return normalized
  }
}

@MainActor
final class ProjectSurfaceModel: ObservableObject {
  let projectID: UUID
  let rootURL: URL
  let historyStore: ProjectLocalHistoryStore

  @Published private(set) var fileTree: ProjectFileTreeSnapshot
  @Published private(set) var layout: ProjectPaneNode
  @Published private(set) var focusedPaneID: UUID
  @Published private(set) var maximizedPaneID: UUID?
  @Published private(set) var selectedNodeID: String?
  @Published private(set) var lastEditorErrorMessage: String?
  @Published private(set) var historyEntries: [ProjectLocalHistoryEntry] = []
  @Published private(set) var searchResults: [ProjectSearchMatch] = []
  @Published private(set) var quickOpenResults: [ProjectQuickOpenItem] = []
  @Published private(set) var quickOpenIsLoading = false
  @Published private(set) var searchIsLoading = false
  @Published private(set) var replacementIsLoading = false
  @Published private(set) var replacementPreview: ProjectSearchReplacementPreview?
  @Published private(set) var lastNavigationErrorMessage: String?
  @Published private(set) var lastNavigationStatusMessage: String?
  @Published private(set) var gitStatus: ProjectGitSnapshot?
  @Published private(set) var selectedGitDiff: ProjectGitDiff?
  @Published private(set) var lastGitErrorMessage: String?
  @Published var workspaceActivityRawValue: String

  private let rootChecker: any ProjectRootChecking
  private let fileManager: FileManager
  private let gitService: ProjectGitService
  private let onSnapshotChange: ((ProjectSurfaceSnapshot) -> Void)?
  private var activeSearchQuery = ""
  private var expandedNodeIDs: Set<String> = []
  private var loadedDirectoryPaths: Set<String> = []
  private var directoryEntryLimits: [String: Int] = [:]
  private var editorDocuments: [String: ProjectEditorTab] = [:]
  private var terminalSessions: [String: TerminalSession] = [:]
  private var watcher: ProjectFileSystemWatcher?
  private var treeLoadTask: Task<Void, Never>?
  private var quickOpenTask: Task<Void, Never>?
  private var searchTask: Task<Void, Never>?
  private var replacementTask: Task<Void, Never>?
  private var treeLoadGeneration = 0
  private var quickOpenGeneration = 0
  private var searchGeneration = 0
  private var replacementGeneration = 0

  init(
    projectID: UUID,
    rootURL: URL,
    rootChecker: any ProjectRootChecking = FileSystemProjectRootChecker(),
    fileManager: FileManager = .default,
    historyStore: ProjectLocalHistoryStore = .makeDefault(for: .current),
    snapshot: ProjectSurfaceSnapshot? = nil,
    onSnapshotChange: ((ProjectSurfaceSnapshot) -> Void)? = nil
  ) {
    self.projectID = projectID
    self.rootURL = rootURL
    self.rootChecker = rootChecker
    self.fileManager = fileManager
    self.gitService = ProjectGitService(rootURL: rootURL, fileManager: fileManager)
    self.historyStore = historyStore
    self.onSnapshotChange = onSnapshotChange

    let initialSnapshot =
      snapshot?.validated(for: projectID)
      ?? ProjectSurfaceSnapshot.empty(for: projectID)
    self.layout = initialSnapshot.root
    self.focusedPaneID = initialSnapshot.focusedPaneID
    self.maximizedPaneID = initialSnapshot.maximizedPaneID
    self.selectedNodeID = initialSnapshot.selectedNodeID
    self.expandedNodeIDs = Set(initialSnapshot.expandedNodeIDs)
    self.workspaceActivityRawValue =
      initialSnapshot.workspaceActivity ?? WorkspaceActivity.files.rawValue
    let canonicalRootURL = rootChecker.canonicalURL(for: rootURL)
    self.loadedDirectoryPaths = [canonicalRootURL.path]
    self.fileTree = ProjectFileTreeSnapshot.empty(
      for: rootChecker.availability(for: rootURL),
      isLoading: true
    )

    restoreRuntimeTabs()
    refreshHistoryEntries()

    if rootChecker.availability(for: rootURL) == .available {
      let initialTree = ProjectFileTreeScanner.scanLoaded(
        rootURL: canonicalRootURL,
        loadedDirectoryPaths: loadedDirectoryPaths,
        directoryEntryLimits: directoryEntryLimits,
        fileManager: fileManager
      )
      applyTreeSnapshot(initialTree)
    } else {
      fileTree = ProjectFileTreeSnapshot.empty(
        for: rootChecker.availability(for: rootURL)
      )
    }

    watcher = ProjectFileSystemWatcher(
      rootURL: rootURL,
      fileManager: fileManager
    ) { [weak self] in
      Task { @MainActor [weak self] in
        self?.reload()
      }
    }
    watcher?.updateWatchedDirectories(loadedDirectoryURLs())
    watcher?.start()
  }

  deinit {
    treeLoadTask?.cancel()
    quickOpenTask?.cancel()
    searchTask?.cancel()
    replacementTask?.cancel()
    watcher?.stop()
  }

  var activeTab: ProjectEditorTab? {
    guard let descriptor = activeTabDescriptor, descriptor.kind == .editor else {
      return nil
    }
    return editorDocuments[descriptor.id]
  }

  var editorTabs: [ProjectEditorTab] {
    layout.leaves.flatMap { leaf in
      leaf.tabs.compactMap { tab in
        guard tab.kind == .editor else {
          return nil
        }
        return editorDocuments[tab.id]
      }
    }
  }

  var activeTabID: String? {
    activeTabDescriptor?.id
  }

  var terminalSession: TerminalSession? {
    guard let descriptor = activeTabDescriptor, descriptor.kind == .terminal else {
      return nil
    }
    return terminalSessions[descriptor.id]
  }

  var isTerminalVisible: Bool {
    activeTabDescriptor?.kind == .terminal
  }

  var paneIDs: [UUID] {
    layout.leafIDs
  }

  /// All tabs in document order, retaining their owning pane for the global
  /// workspace tab strip.
  var workspaceTabs: [ProjectWorkspaceTab] {
    layout.leaves.flatMap { leaf in
      leaf.tabs.map { ProjectWorkspaceTab(paneID: leaf.id, tab: $0) }
    }
  }

  /// A maximized pane hides the other panes, so its tabs are the only tabs
  /// shown in the titlebar until the layout is restored.
  var visibleWorkspaceTabs: [ProjectWorkspaceTab] {
    guard let maximizedPaneID,
      let leaf = layout.leaf(withID: maximizedPaneID)
    else {
      return workspaceTabs
    }
    return leaf.tabs.map { ProjectWorkspaceTab(paneID: leaf.id, tab: $0) }
  }

  var visibleLayout: ProjectPaneNode {
    guard let maximizedPaneID, let leaf = layout.leaf(withID: maximizedPaneID) else {
      return layout
    }
    return .leaf(leaf)
  }

  var isFocusedPaneMaximized: Bool {
    maximizedPaneID == focusedPaneID
  }

  var workspaceSnapshot: ProjectSurfaceSnapshot {
    ProjectSurfaceSnapshot(
      schemaVersion: ProjectSurfaceSnapshot.currentSchemaVersion,
      projectID: projectID,
      root: layout,
      focusedPaneID: focusedPaneID,
      maximizedPaneID: maximizedPaneID,
      selectedNodeID: selectedNodeID,
      expandedNodeIDs: expandedNodeIDs.sorted(),
      workspaceActivity: workspaceActivityRawValue
    )
  }

  func tabs(in paneID: UUID) -> [ProjectPaneTab] {
    layout.leaf(withID: paneID)?.tabs ?? []
  }

  func activeTab(in paneID: UUID) -> ProjectPaneTab? {
    guard let leaf = layout.leaf(withID: paneID), let activeTabID = leaf.activeTabID else {
      return nil
    }
    return leaf.tabs.first { $0.id == activeTabID }
  }

  func editorDocument(tabID: String) -> ProjectEditorTab? {
    editorDocuments[tabID]
  }

  func terminalSession(tabID: String) -> TerminalSession? {
    terminalSessions[tabID]
  }

  func sessionIDsInUse(for worktreeID: WorktreeID) -> Set<UUID> {
    Set(
      layout.leaves.flatMap(\.tabs).compactMap { tab in
        guard
          tab.kind == .terminal,
          tab.worktreeID == worktreeID,
          let sessionID = tab.sessionID,
          let session = terminalSessions[tab.id]
        else {
          return nil
        }
        switch session.state {
        case .idle, .starting, .running, .stopping:
          return sessionID
        case .exited, .missing, .failed:
          return nil
        }
      }
    )
  }

  func isFocusedPane(_ paneID: UUID) -> Bool {
    focusedPaneID == paneID
  }

  func focusPane(id paneID: UUID) {
    guard layout.leafIDs.contains(paneID), focusedPaneID != paneID else {
      return
    }
    focusedPaneID = paneID
    notifySnapshotChanged()
  }

  func splitFocusedPane(orientation: ProjectPaneOrientation) {
    guard let currentLeaf = layout.leaf(withID: focusedPaneID) else {
      return
    }
    let newLeaf = ProjectPaneLeaf()
    let replacement = ProjectPaneNode.split(
      id: UUID(),
      orientation: orientation,
      ratio: 0.5,
      first: .leaf(currentLeaf),
      second: .leaf(newLeaf)
    )
    layout = replacingLeaf(
      in: layout,
      leafID: focusedPaneID,
      with: replacement
    )
    focusedPaneID = newLeaf.id
    maximizedPaneID = nil
    notifySnapshotChanged()
  }

  func moveActiveTab(to paneID: UUID) {
    guard paneID != focusedPaneID,
      layout.leafIDs.contains(paneID),
      let source = layout.leaf(withID: focusedPaneID),
      let activeTabID = source.activeTabID,
      let tab = source.tabs.first(where: { $0.id == activeTabID })
    else {
      return
    }
    guard layout.leaf(withID: paneID)?.tabs.contains(where: { $0.id == tab.id }) != true else {
      return
    }

    layout = updatingLeaf(in: layout, leafID: focusedPaneID) { leaf in
      var next = leaf
      next.tabs.removeAll { $0.id == tab.id }
      next.activeTabID = next.tabs.last?.id
      return next
    }
    layout = updatingLeaf(in: layout, leafID: paneID) { leaf in
      var next = leaf
      next.tabs.append(tab)
      next.activeTabID = tab.id
      return next
    }
    focusedPaneID = paneID
    notifySnapshotChanged()
  }

  func closePane(id paneID: UUID) {
    guard paneIDs.count > 1, paneIDs.contains(paneID) else {
      return
    }

    if let leaf = layout.leaf(withID: paneID) {
      stopTerminalSessions(in: leaf)
      for tab in leaf.tabs where tab.kind == .editor {
        editorDocuments[tab.id] = nil
      }
    }
    guard let nextLayout = removingLeaf(in: layout, leafID: paneID) else {
      return
    }
    layout = nextLayout
    if focusedPaneID == paneID || !layout.leafIDs.contains(focusedPaneID) {
      focusedPaneID = layout.leafIDs[0]
    }
    if let maximizedPane = maximizedPaneID, !layout.leafIDs.contains(maximizedPane) {
      maximizedPaneID = nil
    }
    notifySnapshotChanged()
  }

  func toggleMaximizeFocusedPane() {
    maximizedPaneID = isFocusedPaneMaximized ? nil : focusedPaneID
    notifySnapshotChanged()
  }

  func equalizeSplits() {
    let equalized = equalizingSplits(in: layout)
    guard equalized != layout else {
      return
    }
    layout = equalized
    notifySnapshotChanged()
  }

  func showTerminal() {
    showTerminal(in: focusedPaneID)
  }

  @discardableResult
  func openNewTerminal(
    title: String = "ターミナル",
    agentProfileID: String? = nil,
    executionRootURL: URL? = nil,
    worktreeID: WorktreeID? = nil,
    in paneID: UUID? = nil
  ) -> String? {
    let targetPaneID = paneID ?? focusedPaneID
    guard layout.leaf(withID: targetPaneID) != nil else {
      return nil
    }
    let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let newTab = ProjectPaneTab.terminal(
      title: normalizedTitle.isEmpty ? "ターミナル" : normalizedTitle,
      agentProfileID: agentProfileID,
      executionRootURL: executionRootURL,
      worktreeID: worktreeID
    )
    layout = updatingLeaf(in: layout, leafID: targetPaneID) { leaf in
      var next = leaf
      next.tabs.append(newTab)
      next.activeTabID = newTab.id
      return next
    }
    focusedPaneID = targetPaneID
    startTerminal(tabID: newTab.id)
    return newTab.id
  }

  func showTerminal(in paneID: UUID) {
    guard let leaf = layout.leaf(withID: paneID) else {
      return
    }
    focusedPaneID = paneID
    let terminalTab = leaf.tabs.first { $0.kind == .terminal }
    let tabID: String
    if let terminalTab {
      tabID = terminalTab.id
    } else {
      let newTab = ProjectPaneTab.terminal()
      tabID = newTab.id
      layout = updatingLeaf(in: layout, leafID: paneID) { leaf in
        var next = leaf
        next.tabs.append(newTab)
        next.activeTabID = newTab.id
        return next
      }
    }
    setActiveTab(tabID, in: paneID, revealEditor: false)
    startTerminal(tabID: tabID)
  }

  func startTerminal(tabID: String) {
    guard let location = tabLocation(for: tabID), location.tab.kind == .terminal else {
      return
    }
    focusedPaneID = location.paneID
    setActiveTab(tabID, in: location.paneID, revealEditor: false)
    if terminalSessions[tabID] == nil {
      let session = TerminalSession(
        projectRootURL: location.tab.executionRootURL ?? rootURL,
        sessionID: location.tab.sessionID ?? UUID(),
        startMode: .create
      )
      terminalSessions[tabID] = session
      session.start()
    }
    notifySnapshotChanged()
  }

  func recoverTerminal(tabID: String) {
    guard let session = terminalSessions[tabID] else {
      startTerminal(tabID: tabID)
      return
    }
    session.startNewSession()
  }

  func hideTerminal() {
    guard let leaf = layout.leaf(withID: focusedPaneID) else {
      return
    }
    let fallback = leaf.tabs.last { $0.kind != .terminal }
    if let fallback {
      setActiveTab(fallback.id, in: focusedPaneID, revealEditor: fallback.kind == .editor)
    } else if leaf.activeTabID != nil {
      layout = updatingLeaf(in: layout, leafID: focusedPaneID) { leaf in
        var next = leaf
        next.activeTabID = nil
        return next
      }
      notifySnapshotChanged()
    }
  }

  func endTerminal() {
    guard let descriptor = activeTabDescriptor, descriptor.kind == .terminal else {
      return
    }
    closeTab(id: descriptor.id)
  }

  func openDiff() {
    openDiff(in: focusedPaneID)
  }

  func openDiff(in paneID: UUID) {
    guard layout.leafIDs.contains(paneID) else {
      return
    }
    let tab = ProjectPaneTab.diff()
    layout = updatingLeaf(in: layout, leafID: paneID) { leaf in
      var next = leaf
      next.tabs.append(tab)
      next.activeTabID = tab.id
      return next
    }
    focusedPaneID = paneID
    notifySnapshotChanged()
  }

  func dismissEditorError() {
    lastEditorErrorMessage = nil
  }

  func dismissNavigationError() {
    lastNavigationErrorMessage = nil
  }

  func dismissGitError() {
    lastGitErrorMessage = nil
  }

  func refreshGitStatus() {
    _ = try? refreshGitStatusThrowing()
  }

  @discardableResult
  func refreshGitStatusThrowing() throws -> ProjectGitSnapshot {
    do {
      let snapshot = try gitService.status()
      gitStatus = snapshot
      lastGitErrorMessage = nil
      if let selectedGitDiff,
        !snapshot.changes.contains(where: { $0.id == selectedGitDiff.change.id })
      {
        self.selectedGitDiff = nil
      }
      return snapshot
    } catch {
      lastGitErrorMessage = error.localizedDescription
      throw error
    }
  }

  @discardableResult
  func showGitDiff(
    relativePath: String,
    basis: ProjectGitDiffBasis
  ) throws -> ProjectGitDiff {
    do {
      let change = try currentGitChange(relativePath: relativePath)
      let diff = try gitService.diff(for: change, basis: basis)
      selectedGitDiff = diff
      lastGitErrorMessage = nil
      openDiff()
      return diff
    } catch {
      lastGitErrorMessage = error.localizedDescription
      throw error
    }
  }

  @discardableResult
  func stageGitChange(relativePath: String) throws -> ProjectGitSnapshot {
    do {
      _ = try currentGitChange(relativePath: relativePath)
      let snapshot = try gitService.stage(path: relativePath)
      gitStatus = snapshot
      selectedGitDiff = nil
      lastGitErrorMessage = nil
      return snapshot
    } catch {
      lastGitErrorMessage = error.localizedDescription
      throw error
    }
  }

  @discardableResult
  func unstageGitChange(relativePath: String) throws -> ProjectGitSnapshot {
    do {
      _ = try currentGitChange(relativePath: relativePath)
      let snapshot = try gitService.unstage(path: relativePath)
      gitStatus = snapshot
      selectedGitDiff = nil
      lastGitErrorMessage = nil
      return snapshot
    } catch {
      lastGitErrorMessage = error.localizedDescription
      throw error
    }
  }

  @discardableResult
  func commitGitChanges(message: String) throws -> ProjectGitSnapshot {
    do {
      let snapshot = try gitService.commit(message: message)
      gitStatus = snapshot
      selectedGitDiff = nil
      lastGitErrorMessage = nil
      return snapshot
    } catch {
      lastGitErrorMessage = error.localizedDescription
      throw error
    }
  }

  @discardableResult
  func switchGitBranch(_ branch: String) throws -> ProjectGitSnapshot {
    do {
      let snapshot = try gitService.switchBranch(branch)
      gitStatus = snapshot
      selectedGitDiff = nil
      lastGitErrorMessage = nil
      reload()
      return snapshot
    } catch {
      lastGitErrorMessage = error.localizedDescription
      throw error
    }
  }

  func revealGitChange(relativePath: String) {
    guard
      let fileURL = ProjectNavigation.fileURL(for: relativePath, rootURL: rootURL),
      isRegularFile(fileURL)
    else {
      lastNavigationErrorMessage =
        "The changed file is unavailable in the Project tree: \(relativePath)"
      return
    }
    lastNavigationErrorMessage = nil
    if let node = fileTree.node(withID: fileURL.path) {
      select(nodeID: node.id)
      return
    }

    revealPathWithoutOpening(fileURL)
    selectedNodeID = fileURL.path
    _ = openEditorTab(for: fileURL, title: fileURL.lastPathComponent)
    notifySnapshotChanged()
  }

  private func currentGitChange(relativePath: String) throws -> ProjectGitChange {
    let snapshot: ProjectGitSnapshot
    if let gitStatus, gitStatus.isRepository {
      snapshot = gitStatus
    } else {
      snapshot = try refreshGitStatusThrowing()
    }
    guard snapshot.isRepository else {
      throw ProjectGitError.notRepository(path: rootURL.path)
    }
    guard let change = snapshot.changes.first(where: { $0.path == relativePath }) else {
      throw ProjectGitError.changeNotFound(relativePath)
    }
    return change
  }

  func quickOpenItems(matching query: String) -> [ProjectQuickOpenItem] {
    return ProjectNavigation.quickOpenItems(
      query: query,
      rootURL: rootURL,
      fileManager: fileManager
    )
  }

  func requestQuickOpenItems(matching query: String) {
    quickOpenGeneration += 1
    let generation = quickOpenGeneration
    quickOpenTask?.cancel()
    quickOpenIsLoading = true

    let rootURL = self.rootURL
    quickOpenTask = Task { [weak self] in
      let items = await ProjectNavigation.quickOpenItemsAsync(
        query: query,
        rootURL: rootURL
      )
      guard !Task.isCancelled, let self, generation == self.quickOpenGeneration else {
        return
      }
      self.quickOpenResults = items
      self.quickOpenIsLoading = false
      self.quickOpenTask = nil
    }
  }

  func openQuickOpenItem(_ item: ProjectQuickOpenItem) {
    guard
      let fileURL = ProjectNavigation.fileURL(for: item.relativePath, rootURL: rootURL),
      fileURL.path == item.filePath,
      isRegularFile(fileURL)
    else {
      lastNavigationErrorMessage = "The Quick Open result is no longer available."
      return
    }
    lastNavigationErrorMessage = nil
    if let node = fileTree.node(withID: item.filePath) {
      select(nodeID: node.id)
      return
    }

    revealPathWithoutOpening(fileURL)
    selectedNodeID = fileURL.path
    _ = openEditorTab(for: fileURL, title: item.title)
    notifySnapshotChanged()
  }

  func search(query: String) {
    searchGeneration += 1
    searchTask?.cancel()
    searchIsLoading = false
    replacementGeneration += 1
    replacementTask?.cancel()
    replacementIsLoading = false
    activeSearchQuery = query
    replacementPreview = nil
    lastNavigationErrorMessage = nil
    lastNavigationStatusMessage = nil
    searchResults = ProjectNavigation.search(
      query: query,
      rootURL: rootURL,
      fileManager: fileManager
    )
  }

  func requestSearch(query: String) {
    replacementGeneration += 1
    replacementTask?.cancel()
    replacementIsLoading = false
    activeSearchQuery = query
    replacementPreview = nil
    lastNavigationErrorMessage = nil
    lastNavigationStatusMessage = nil
    requestSearchRefresh()
  }

  private func requestSearchRefresh() {
    searchGeneration += 1
    let generation = searchGeneration
    searchTask?.cancel()

    guard !activeSearchQuery.isEmpty else {
      searchResults = []
      searchIsLoading = false
      return
    }

    searchIsLoading = true
    let query = activeSearchQuery
    let rootURL = self.rootURL
    searchTask = Task { [weak self] in
      let results = await ProjectNavigation.searchAsync(
        query: query,
        rootURL: rootURL
      )
      guard !Task.isCancelled, let self, generation == self.searchGeneration else {
        return
      }
      self.searchResults = results
      self.searchIsLoading = false
      self.searchTask = nil
    }
  }

  func previewReplacement(query: String, replacement: String) {
    replacementGeneration += 1
    replacementTask?.cancel()
    replacementIsLoading = false
    searchGeneration += 1
    searchTask?.cancel()
    searchIsLoading = false
    activeSearchQuery = query
    lastNavigationErrorMessage = nil
    lastNavigationStatusMessage = nil
    do {
      let preview = try ProjectNavigation.previewReplacement(
        query: query,
        replacement: replacement,
        rootURL: rootURL,
        fileManager: fileManager
      )
      replacementPreview = preview
      searchResults = preview.matches
    } catch {
      replacementPreview = nil
      lastNavigationErrorMessage = error.localizedDescription
    }
  }

  func requestReplacementPreview(query: String, replacement: String) {
    replacementGeneration += 1
    let generation = replacementGeneration
    replacementTask?.cancel()
    searchGeneration += 1
    searchTask?.cancel()
    searchIsLoading = false
    activeSearchQuery = query
    lastNavigationErrorMessage = nil
    lastNavigationStatusMessage = nil
    replacementIsLoading = true
    let rootURL = self.rootURL
    replacementTask = Task { [weak self] in
      do {
        let preview = try await ProjectNavigation.previewReplacementAsync(
          query: query,
          replacement: replacement,
          rootURL: rootURL
        )
        guard !Task.isCancelled, let self, generation == self.replacementGeneration else {
          return
        }
        self.replacementPreview = preview
        self.searchResults = preview.matches
        self.replacementIsLoading = false
        self.replacementTask = nil
      } catch {
        guard !Task.isCancelled, let self, generation == self.replacementGeneration else {
          return
        }
        self.replacementPreview = nil
        self.replacementIsLoading = false
        self.replacementTask = nil
        self.lastNavigationErrorMessage = error.localizedDescription
      }
    }
  }

  func applyReplacement(_ preview: ProjectSearchReplacementPreview) {
    struct ReplacementTarget {
      let fileURL: URL
      let content: String
    }

    var targets: [ReplacementTarget] = []
    for file in preview.files {
      guard
        let fileURL = ProjectNavigation.fileURL(
          for: file.relativePath,
          rootURL: rootURL
        ),
        let currentData = try? Data(contentsOf: fileURL),
        currentData == file.originalData,
        let replacementContent = String(data: file.replacementData, encoding: .utf8)
      else {
        lastNavigationErrorMessage =
          "\(file.relativePath) の置換プレビューが古くなっています。もう一度プレビューしてください。"
        return
      }
      targets.append(
        ReplacementTarget(
          fileURL: fileURL,
          content: replacementContent
        )
      )
    }

    var changedFiles = 0
    for target in targets {
      guard
        let document = openEditorTab(
          for: target.fileURL,
          title: target.fileURL.lastPathComponent
        )
      else {
        lastNavigationErrorMessage =
          "置換対象が利用できなくなりました: \(target.fileURL.lastPathComponent)"
        return
      }
      document.replaceContent(target.content, actionName: "全て置換")
      changedFiles += 1
    }

    activeSearchQuery = preview.query
    replacementPreview = nil
    searchResults = []
    lastNavigationErrorMessage = nil
    lastNavigationStatusMessage =
      "エディタバッファ\(changedFiles)件に置換を適用しました。ディスクに書き込むにはタブを保存してください。"
  }

  func openSearchMatch(_ match: ProjectSearchMatch) {
    guard
      let fileURL = ProjectNavigation.fileURL(for: match.relativePath, rootURL: rootURL),
      fileURL.path == match.filePath,
      isRegularFile(fileURL)
    else {
      lastNavigationErrorMessage = "検索結果は利用できなくなりました。"
      return
    }
    lastNavigationErrorMessage = nil
    if let node = fileTree.node(withID: match.filePath) {
      select(nodeID: node.id)
    } else {
      revealPathWithoutOpening(fileURL)
      selectedNodeID = fileURL.path
      _ = openEditorTab(for: fileURL, title: fileURL.lastPathComponent)
      notifySnapshotChanged()
    }
    editorDocuments[match.filePath]?.requestSelection(
      line: match.line,
      column: match.column,
      length: match.matchLength
    )
  }

  func refreshHistoryEntries() {
    do {
      historyEntries = try historyStore.entries(for: projectID)
    } catch {
      historyEntries = []
      lastNavigationErrorMessage = error.localizedDescription
    }
  }

  func restoreHistoryEntry(_ entry: ProjectLocalHistoryEntry) {
    guard entry.projectID == projectID else {
      lastNavigationErrorMessage = "この履歴エントリは別のProjectに属しています。"
      return
    }
    guard
      let fileURL = ProjectNavigation.fileURL(for: entry.filePath, rootURL: rootURL),
      let document = openEditorTab(for: fileURL, title: fileURL.lastPathComponent)
    else {
      lastNavigationErrorMessage =
        "履歴ファイルは利用できなくなりました: \(entry.filePath)"
      return
    }

    do {
      try document.restoreHistoryEntry(id: entry.id)
      lastNavigationErrorMessage = nil
      lastNavigationStatusMessage =
        "\(entry.filePath) をエディタバッファに復元しました。ディスクに書き込むにはタブを保存してください。"
    } catch {
      lastNavigationErrorMessage = error.localizedDescription
    }
  }

  func save(tabID: String? = nil) {
    guard let tab = editorTab(withID: tabID) else {
      return
    }

    do {
      try tab.save()
      lastEditorErrorMessage = nil
      refreshHistoryEntries()
    } catch {
      lastEditorErrorMessage = error.localizedDescription
    }
  }

  func undoActiveTab() {
    activeTab?.undo()
  }

  func redoActiveTab() {
    activeTab?.redo()
  }

  func restoreHistoryEntry(_ entryID: UUID, tabID: String? = nil) {
    guard let tab = editorTab(withID: tabID) else {
      return
    }

    do {
      try tab.restoreHistoryEntry(id: entryID)
      lastEditorErrorMessage = nil
      refreshHistoryEntries()
    } catch {
      lastEditorErrorMessage = error.localizedDescription
    }
  }

  func reload() {
    refreshEditorDocumentsFromDisk()
    scheduleTreeReload()

    if activeSearchQuery.isEmpty {
      searchTask?.cancel()
      searchResults = []
      searchIsLoading = false
    } else {
      requestSearchRefresh()
    }
    replacementPreview = nil
    replacementGeneration += 1
    replacementTask?.cancel()
    replacementIsLoading = false
    refreshHistoryEntries()
    refreshGitStatus()
  }

  private func scheduleTreeReload() {
    treeLoadGeneration += 1
    let generation = treeLoadGeneration
    treeLoadTask?.cancel()

    let rootURL = rootChecker.canonicalURL(for: self.rootURL)
    let loadedDirectoryPaths = self.loadedDirectoryPaths
    let directoryEntryLimits = self.directoryEntryLimits
    fileTree = ProjectFileTreeSnapshot(
      root: fileTree.root,
      availability: fileTree.availability,
      isLoading: true
    )

    treeLoadTask = Task { [weak self] in
      let scanTask = Task.detached(priority: .utility) {
        ProjectFileTreeScanner.scanLoaded(
          rootURL: rootURL,
          loadedDirectoryPaths: loadedDirectoryPaths,
          directoryEntryLimits: directoryEntryLimits
        )
      }
      let snapshot = await withTaskCancellationHandler(
        operation: {
          await scanTask.value
        },
        onCancel: {
          scanTask.cancel()
        })
      guard !Task.isCancelled, let self, generation == self.treeLoadGeneration else {
        return
      }
      self.applyTreeSnapshot(snapshot)
    }
  }

  private func loadedDirectoryURLs() -> [URL] {
    loadedDirectoryPaths.sorted().map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }
  }

  private func applyTreeSnapshot(_ snapshot: ProjectFileTreeSnapshot) {
    treeLoadTask = nil
    fileTree = ProjectFileTreeSnapshot(
      root: snapshot.root,
      availability: snapshot.availability,
      isLoading: false
    )

    guard let root = snapshot.root else {
      expandedNodeIDs.removeAll()
      selectedNodeID = nil
      watcher?.updateWatchedDirectories(loadedDirectoryURLs())
      return
    }

    expandedNodeIDs.formIntersection(root.allNodeIDs)
    expandedNodeIDs.insert(root.id)

    let availableNodeIDs = root.allNodeIDs
    if let selectedNodeID, !availableNodeIDs.contains(selectedNodeID) {
      var isDirectory = ObjCBool(false)
      if !fileManager.fileExists(atPath: selectedNodeID, isDirectory: &isDirectory) {
        self.selectedNodeID = nil
      }
    }

    let rootPath = rootURL.standardizedFileURL.path
    loadedDirectoryPaths = Set(
      loadedDirectoryPaths.filter { path in
        path == rootPath || root.node(withID: path)?.isDirectory == true
      }
    )
    directoryEntryLimits = directoryEntryLimits.filter { loadedDirectoryPaths.contains($0.key) }
    watcher?.updateWatchedDirectories(loadedDirectoryURLs())

    let nextLayout = filteringUnavailableEditorTabs(in: layout)
    if nextLayout != layout {
      layout = nextLayout
      if !layout.leafIDs.contains(focusedPaneID) {
        focusedPaneID = layout.leafIDs[0]
      }
    }
  }

  func isExpanded(_ nodeID: String) -> Bool {
    expandedNodeIDs.contains(nodeID)
  }

  func toggleExpansion(for nodeID: String) {
    guard let node = fileTree.node(withID: nodeID), node.isDirectory else {
      return
    }
    if isExpanded(nodeID) {
      expandedNodeIDs.remove(nodeID)
    } else {
      expandedNodeIDs.insert(nodeID)
      if node.children == nil {
        loadedDirectoryPaths.insert(node.id)
        directoryEntryLimits[node.id] = max(
          directoryEntryLimits[node.id] ?? 0,
          ProjectFileTreeScanner.maxChildrenPerDirectory
        )
        scheduleTreeReload()
      }
    }
    notifySnapshotChanged()
  }

  func loadMoreChildren(for nodeID: String) {
    guard let node = fileTree.node(withID: nodeID), node.isDirectory, node.hasMoreChildren else {
      return
    }
    loadedDirectoryPaths.insert(nodeID)
    let currentLimit =
      directoryEntryLimits[nodeID] ?? ProjectFileTreeScanner.maxChildrenPerDirectory
    directoryEntryLimits[nodeID] = min(
      currentLimit + ProjectFileTreeScanner.maxChildrenPerDirectory,
      ProjectFileTreeScanner.maxDirectoryEntriesPerRefresh
    )
    scheduleTreeReload()
  }

  func select(nodeID: String) {
    guard let node = fileTree.node(withID: nodeID) else {
      return
    }
    selectedNodeID = node.id
    if !node.isDirectory {
      openEditorTab(for: node)
    }
    notifySnapshotChanged()
  }

  func reveal(nodeID: String) {
    guard let node = fileTree.node(withID: nodeID) else {
      return
    }

    revealNodeWithoutOpening(node)
    select(nodeID: nodeID)
  }

  func activateTab(id: String) {
    guard let location = tabLocation(for: id) else {
      return
    }
    if maximizedPaneID != nil, maximizedPaneID != location.paneID {
      maximizedPaneID = nil
    }
    focusedPaneID = location.paneID
    setActiveTab(
      id,
      in: location.paneID,
      revealEditor: location.tab.kind == .editor
    )
  }

  func closeTab(id: String) {
    guard let location = tabLocation(for: id) else {
      return
    }
    if location.tab.kind == .terminal {
      terminalSessions[id]?.stop()
      terminalSessions[id] = nil
    } else if location.tab.kind == .editor {
      editorDocuments[id] = nil
    }
    layout = updatingLeaf(in: layout, leafID: location.paneID) { leaf in
      var next = leaf
      next.tabs.removeAll { $0.id == id }
      if next.activeTabID == id {
        next.activeTabID = next.tabs.last?.id
      }
      return next
    }
    if let activeEditorPath = activeTabDescriptor?.filePath {
      selectedNodeID = activeEditorPath
    } else if activeTabDescriptor == nil {
      selectedNodeID = nil
    }
    notifySnapshotChanged()
  }

  @discardableResult
  private func openEditorTab(for node: ProjectFileTreeNode) -> ProjectEditorTab? {
    guard !node.isDirectory else {
      return nil
    }

    return openEditorTab(for: node.url, title: node.name)
  }

  @discardableResult
  private func openEditorTab(for fileURL: URL, title: String) -> ProjectEditorTab? {
    let fileURL = fileURL.standardizedFileURL
    guard isRegularFile(fileURL) else {
      return nil
    }

    if editorDocuments[fileURL.path] == nil {
      editorDocuments[fileURL.path] = ProjectEditorTab(
        projectID: projectID,
        rootURL: rootURL,
        url: fileURL,
        historyStore: historyStore,
        fileManager: fileManager
      )
    }
    if let existingLocation = tabLocation(for: fileURL.path) {
      setActiveTab(fileURL.path, in: existingLocation.paneID, revealEditor: false)
      return editorDocuments[fileURL.path]
    }
    let tab = ProjectPaneTab.editor(path: fileURL.path, title: title)
    layout = updatingLeaf(in: layout, leafID: focusedPaneID) { leaf in
      var next = leaf
      next.tabs.append(tab)
      next.activeTabID = tab.id
      return next
    }
    return editorDocuments[fileURL.path]
  }

  private func isRegularFile(_ fileURL: URL) -> Bool {
    var isDirectory = ObjCBool(false)
    guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      return false
    }
    let values = try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
    return values?.isSymbolicLink != true && values?.isRegularFile == true
  }

  private func editorTab(withID tabID: String?) -> ProjectEditorTab? {
    if let tabID {
      return editorDocuments[tabID]
    }
    return activeTab
  }

  private func refreshEditorDocumentsFromDisk() {
    for tab in editorDocuments.values {
      do {
        _ = try tab.refreshFromDisk()
      } catch {
        lastEditorErrorMessage = error.localizedDescription
      }
    }
  }

  private var activeTabDescriptor: ProjectPaneTab? {
    activeTab(in: focusedPaneID)
  }

  private func notifySnapshotChanged() {
    onSnapshotChange?(workspaceSnapshot)
  }

  func notifyWorkspaceActivityChanged() {
    notifySnapshotChanged()
  }

  private func restoreRuntimeTabs() {
    layout = mappingLeaves(in: layout) { [self] leaf in
      var restoredTabs: [ProjectPaneTab] = []
      for tab in leaf.tabs {
        switch tab.kind {
        case .editor:
          guard
            let filePath = tab.filePath,
            let fileURL = restorableFileURL(for: filePath),
            editorDocuments[tab.id] == nil
          else {
            continue
          }
          let document = ProjectEditorTab(
            projectID: projectID,
            rootURL: rootURL,
            url: fileURL,
            historyStore: historyStore,
            fileManager: fileManager
          )
          editorDocuments[tab.id] = document
          restoredTabs.append(tab)
        case .terminal:
          let session = TerminalSession(
            projectRootURL: tab.executionRootURL ?? rootURL,
            sessionID: tab.sessionID ?? UUID(),
            startMode: .reattach
          )
          terminalSessions[tab.id] = session
          restoredTabs.append(tab)
        case .diff:
          restoredTabs.append(tab)
        }
      }
      let activeTabID =
        leaf.activeTabID.flatMap { activeID in
          restoredTabs.contains(where: { $0.id == activeID }) ? activeID : nil
        } ?? restoredTabs.last?.id
      return ProjectPaneLeaf(
        id: leaf.id,
        tabs: restoredTabs,
        activeTabID: activeTabID
      )
    }
    if !layout.leafIDs.contains(focusedPaneID) {
      focusedPaneID = layout.leafIDs[0]
    }
    if let maximizedPaneID, !layout.leafIDs.contains(maximizedPaneID) {
      self.maximizedPaneID = nil
    }
  }

  private func restorableFileURL(for path: String) -> URL? {
    let fileURL = URL(fileURLWithPath: path).standardizedFileURL
    let rootPath = rootURL.standardizedFileURL.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    guard fileURL.path.hasPrefix(prefix) else {
      return nil
    }
    var isDirectory = ObjCBool(false)
    guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      return nil
    }
    return fileURL
  }

  private func filteringUnavailableEditorTabs(in node: ProjectPaneNode) -> ProjectPaneNode {
    mappingLeaves(in: node) { leaf in
      let tabs = leaf.tabs.filter { tab in
        tab.kind != .editor || editorDocuments[tab.id] != nil
      }
      let activeTabID = leaf.activeTabID.flatMap { activeID in
        tabs.contains(where: { $0.id == activeID }) ? activeID : tabs.last?.id
      }
      return ProjectPaneLeaf(id: leaf.id, tabs: tabs, activeTabID: activeTabID)
    }
  }

  private func revealNodeWithoutOpening(_ node: ProjectFileTreeNode) {
    revealPathWithoutOpening(node.url)
  }

  private func revealPathWithoutOpening(_ fileURL: URL) {
    var directory = fileURL.standardizedFileURL.deletingLastPathComponent()
    let rootPath = rootURL.standardizedFileURL.path
    var changed = false
    while directory.standardizedFileURL.path != rootPath {
      let path = directory.standardizedFileURL.path
      expandedNodeIDs.insert(path)
      if loadedDirectoryPaths.insert(path).inserted {
        directoryEntryLimits[path] = ProjectFileTreeScanner.maxChildrenPerDirectory
        changed = true
      }
      let parent = directory.deletingLastPathComponent()
      guard parent.path != directory.path else {
        break
      }
      directory = parent
    }
    expandedNodeIDs.insert(rootPath)
    if changed {
      scheduleTreeReload()
    }
  }

  private func setActiveTab(
    _ tabID: String,
    in paneID: UUID,
    revealEditor: Bool
  ) {
    guard let tab = layout.leaf(withID: paneID)?.tabs.first(where: { $0.id == tabID }) else {
      return
    }
    focusedPaneID = paneID
    layout = updatingLeaf(in: layout, leafID: paneID) { leaf in
      var next = leaf
      next.activeTabID = tabID
      return next
    }
    if revealEditor, let filePath = tab.filePath {
      let fileURL = URL(fileURLWithPath: filePath).standardizedFileURL
      guard isRegularFile(fileURL) else {
        notifySnapshotChanged()
        return
      }
      selectedNodeID = fileURL.path
      revealPathWithoutOpening(fileURL)
    }
    notifySnapshotChanged()
  }

  private func tabLocation(for tabID: String) -> (paneID: UUID, tab: ProjectPaneTab)? {
    for leaf in layout.leaves {
      if let tab = leaf.tabs.first(where: { $0.id == tabID }) {
        return (leaf.id, tab)
      }
    }
    return nil
  }

  func reattachRuntimeSessions() {
    for session in terminalSessions.values {
      session.start()
    }
  }

  func terminateAllTerminalSessions() {
    for session in terminalSessions.values {
      session.stop()
    }
    terminalSessions.removeAll()
  }

  private func stopTerminalSessions(in leaf: ProjectPaneLeaf) {
    for tab in leaf.tabs where tab.kind == .terminal {
      terminalSessions[tab.id]?.stop()
      terminalSessions[tab.id] = nil
    }
  }

  private func mappingLeaves(
    in node: ProjectPaneNode,
    transform: (ProjectPaneLeaf) -> ProjectPaneLeaf
  ) -> ProjectPaneNode {
    switch node {
    case .leaf(let leaf):
      return .leaf(transform(leaf))
    case .split(let id, let orientation, let ratio, let first, let second):
      return .split(
        id: id,
        orientation: orientation,
        ratio: ratio,
        first: mappingLeaves(in: first, transform: transform),
        second: mappingLeaves(in: second, transform: transform)
      )
    }
  }

  private func updatingLeaf(
    in node: ProjectPaneNode,
    leafID: UUID,
    transform: (ProjectPaneLeaf) -> ProjectPaneLeaf
  ) -> ProjectPaneNode {
    mappingLeaves(in: node) { leaf in
      leaf.id == leafID ? transform(leaf) : leaf
    }
  }

  private func replacingLeaf(
    in node: ProjectPaneNode,
    leafID: UUID,
    with replacement: ProjectPaneNode
  ) -> ProjectPaneNode {
    switch node {
    case .leaf(let leaf):
      return leaf.id == leafID ? replacement : node
    case .split(let id, let orientation, let ratio, let first, let second):
      return .split(
        id: id,
        orientation: orientation,
        ratio: ratio,
        first: replacingLeaf(in: first, leafID: leafID, with: replacement),
        second: replacingLeaf(in: second, leafID: leafID, with: replacement)
      )
    }
  }

  private func removingLeaf(
    in node: ProjectPaneNode,
    leafID: UUID
  ) -> ProjectPaneNode? {
    switch node {
    case .leaf(let leaf):
      return leaf.id == leafID ? nil : node
    case .split(let id, let orientation, let ratio, let first, let second):
      if first.isLeaf, first.id == leafID {
        return second
      }
      if second.isLeaf, second.id == leafID {
        return first
      }
      let nextFirst = removingLeaf(in: first, leafID: leafID)
      let nextSecond = removingLeaf(in: second, leafID: leafID)
      if nextFirst == first, nextSecond == second {
        return node
      }
      if nextFirst == nil {
        return nextSecond ?? second
      }
      if nextSecond == nil {
        return nextFirst ?? first
      }
      return .split(
        id: id,
        orientation: orientation,
        ratio: ratio,
        first: nextFirst!,
        second: nextSecond!
      )
    }
  }

  private func equalizingSplits(in node: ProjectPaneNode) -> ProjectPaneNode {
    switch node {
    case .leaf:
      return node
    case .split(let id, let orientation, _, let first, let second):
      return .split(
        id: id,
        orientation: orientation,
        ratio: 0.5,
        first: equalizingSplits(in: first),
        second: equalizingSplits(in: second)
      )
    }
  }
}

extension ProjectSurfaceModel {
  /// Live session of the focused pane active tab, used by the status bar.
  var focusedPaneSession: TerminalSession? {
    guard let leaf = layout.leaf(withID: focusedPaneID), let activeTabID = leaf.activeTabID else {
      return nil
    }
    guard let tab = leaf.tabs.first(where: { $0.id == activeTabID }), tab.kind == .terminal else {
      return nil
    }
    return terminalSessions[tab.id]
  }

  /// Compact ownership summary displayed inside the active Project group.
  var activeTabSummary: String? {
    guard let tab = activeTab(in: focusedPaneID) else {
      return nil
    }
    switch tab.kind {
    case .editor:
      return "エディタ · \(tab.title)"
    case .terminal:
      return "ターミナル · \(tab.title)"
    case .diff:
      return "差分"
    }
  }
}
