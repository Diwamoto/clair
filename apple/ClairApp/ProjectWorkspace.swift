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
    historyStore: ProjectLocalHistoryStore = .makeDefault(for: .current)
  ) {
    self.store = store
    self.rootChecker = rootChecker
    self.commandRegistry = commandRegistry
    self.historyStore = historyStore

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

  func dismissError() {
    lastErrorMessage = nil
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
    } catch let error as ProjectError {
      lastErrorMessage = error.localizedDescription
      return .failure(.project(error))
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
    }
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

  private let rootChecker: any ProjectRootChecking
  private let fileManager: FileManager
  private let onSnapshotChange: ((ProjectSurfaceSnapshot) -> Void)?
  private var expandedNodeIDs: Set<String> = []
  private var editorDocuments: [String: ProjectEditorTab] = [:]
  private var terminalSessions: [String: TerminalSession] = [:]
  private var watcher: ProjectFileSystemWatcher?

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
    self.fileTree = ProjectFileTreeSnapshot.empty(
      for: rootChecker.availability(for: rootURL)
    )

    restoreRuntimeTabs()

    watcher = ProjectFileSystemWatcher(
      rootURL: rootURL,
      fileManager: fileManager
    ) { [weak self] in
      Task { @MainActor [weak self] in
        self?.reload()
      }
    }
    reload()
    watcher?.start()
  }

  deinit {
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
      expandedNodeIDs: expandedNodeIDs.sorted()
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
      let session = TerminalSession(projectRootURL: rootURL)
      terminalSessions[tabID] = session
      session.start()
    }
    notifySnapshotChanged()
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

  func save(tabID: String? = nil) {
    guard let tab = editorTab(withID: tabID) else {
      return
    }

    do {
      try tab.save()
      lastEditorErrorMessage = nil
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
    } catch {
      lastEditorErrorMessage = error.localizedDescription
    }
  }

  func reload() {
    refreshEditorDocumentsFromDisk()

    let nextTree = ProjectFileTreeScanner.scan(
      rootURL: rootURL,
      rootChecker: rootChecker,
      fileManager: fileManager
    )
    fileTree = nextTree

    guard let root = nextTree.root else {
      expandedNodeIDs.removeAll()
      selectedNodeID = nil
      return
    }

    expandedNodeIDs.formIntersection(root.allNodeIDs)
    expandedNodeIDs.insert(root.id)

    let availableNodeIDs = root.allNodeIDs
    if let selectedNodeID, !availableNodeIDs.contains(selectedNodeID) {
      self.selectedNodeID = nil
    }

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
    }
    notifySnapshotChanged()
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

  private func openEditorTab(for node: ProjectFileTreeNode) {
    guard !node.isDirectory else {
      return
    }

    if editorDocuments[node.id] == nil {
      do {
        editorDocuments[node.id] = try ProjectEditorTab(
          projectID: projectID,
          rootURL: rootURL,
          url: node.url,
          historyStore: historyStore,
          fileManager: fileManager
        )
      } catch {
        lastEditorErrorMessage = error.localizedDescription
        return
      }
    }
    if let existingLocation = tabLocation(for: node.id) {
      setActiveTab(node.id, in: existingLocation.paneID, revealEditor: false)
      return
    }
    let tab = ProjectPaneTab.editor(path: node.id, title: node.name)
    layout = updatingLeaf(in: layout, leafID: focusedPaneID) { leaf in
      var next = leaf
      next.tabs.append(tab)
      next.activeTabID = tab.id
      return next
    }
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

  private func restoreRuntimeTabs() {
    layout = mappingLeaves(in: layout) { [self] leaf in
      var restoredTabs: [ProjectPaneTab] = []
      for tab in leaf.tabs {
        switch tab.kind {
        case .editor:
          guard
            let filePath = tab.filePath,
            let fileURL = restorableFileURL(for: filePath),
            editorDocuments[tab.id] == nil,
            let document = try? ProjectEditorTab(
              projectID: projectID,
              rootURL: rootURL,
              url: fileURL,
              historyStore: historyStore,
              fileManager: fileManager
            )
          else {
            continue
          }
          editorDocuments[tab.id] = document
          restoredTabs.append(tab)
        case .terminal, .diff:
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
    var directory = node.url.deletingLastPathComponent()
    let rootPath = rootURL.standardizedFileURL.path
    while directory.standardizedFileURL.path != rootPath {
      expandedNodeIDs.insert(directory.standardizedFileURL.path)
      let parent = directory.deletingLastPathComponent()
      guard parent.path != directory.path else {
        break
      }
      directory = parent
    }
    expandedNodeIDs.insert(rootPath)
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
    if revealEditor, let filePath = tab.filePath, let node = fileTree.node(withID: filePath) {
      selectedNodeID = node.id
      revealNodeWithoutOpening(node)
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
