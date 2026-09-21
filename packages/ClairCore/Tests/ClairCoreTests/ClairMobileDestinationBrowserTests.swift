import ClairMobileKit
import ClairShared
import ClairWorkspace
import Foundation
import Testing

private struct N04Fixture {
  let firstProjectID = try! ProjectID("n04-first-project")
  let secondProjectID = try! ProjectID("n04-second-project")
  let firstWorktreeID = try! WorktreeID("n04-first-worktree")
  let secondWorktreeID = try! WorktreeID("n04-second-worktree")
  let firstSessionID = try! SessionID("n04-first-session")
  let secondSessionID = try! SessionID("n04-second-session")

  func catalog(
    firstState: ClairWorkspaceRootState = .available,
    firstWorktreeState: ClairWorkspaceRootState = .available
  ) -> ClairWorkspaceCatalog {
    let firstWorktree = ClairWorktreeCatalogEntry(
      id: firstWorktreeID,
      projectID: firstProjectID,
      repositoryRootURL: URL(fileURLWithPath: "/n04/first"),
      rootURL: URL(fileURLWithPath: "/n04/first/worktree"),
      branch: "n04-first",
      state: firstWorktreeState
    )
    let secondWorktree = ClairWorktreeCatalogEntry(
      id: secondWorktreeID,
      projectID: secondProjectID,
      repositoryRootURL: URL(fileURLWithPath: "/n04/second"),
      rootURL: URL(fileURLWithPath: "/n04/second/worktree"),
      branch: "n04-second",
      state: .available
    )
    return ClairWorkspaceCatalog(projects: [
      ClairProjectCatalogEntry(
        id: firstProjectID,
        rootURL: URL(fileURLWithPath: "/n04/first"),
        state: firstState,
        worktrees: [firstWorktree]
      ),
      ClairProjectCatalogEntry(
        id: secondProjectID,
        rootURL: URL(fileURLWithPath: "/n04/second"),
        state: .available,
        worktrees: [secondWorktree]
      ),
    ])
  }

  func sessions() throws -> [ClairMobileSessionCatalogEntry] {
    [
      try ClairMobileSessionCatalogEntry(
        scope: ResourceScope(
          projectID: firstProjectID,
          worktreeID: firstWorktreeID,
          sessionID: firstSessionID
        ),
        displayName: "First worktree session",
        status: "running"
      ),
      try ClairMobileSessionCatalogEntry(
        scope: ResourceScope(projectID: secondProjectID, sessionID: secondSessionID),
        displayName: "Second project session",
        status: "stopped"
      ),
    ]
  }
}

@Test
func n04BrowserSelectsProjectWorktreeAndExactSessionScope() throws {
  let fixture = N04Fixture()
  var browser = ClairMobileDestinationBrowserState(
    catalog: fixture.catalog(),
    sessions: try fixture.sessions()
  )

  let projectScope = try ResourceScope(projectID: fixture.firstProjectID)
  let worktreeScope = try ResourceScope(
    projectID: fixture.firstProjectID,
    worktreeID: fixture.firstWorktreeID
  )
  let sessionScope = try ResourceScope(
    projectID: fixture.firstProjectID,
    worktreeID: fixture.firstWorktreeID,
    sessionID: fixture.firstSessionID
  )
  let selectedProject = browser.selectProject(fixture.firstProjectID)
  #expect(selectedProject)
  #expect(browser.selectedScope == projectScope)

  let selectedWorktree = browser.selectWorktree(
    projectID: fixture.firstProjectID,
    worktreeID: fixture.firstWorktreeID
  )
  #expect(selectedWorktree)
  #expect(browser.selectedScope == worktreeScope)

  let selectedSession = browser.selectSession(fixture.firstSessionID)
  #expect(selectedSession)
  #expect(browser.selectedScope == sessionScope)
}

@Test
func n04RecentDestinationRoundTripsAndCanBeCleared() throws {
  let fixture = N04Fixture()
  var browser = ClairMobileDestinationBrowserState(
    catalog: fixture.catalog(),
    sessions: try fixture.sessions()
  )

  let selected = browser.selectSession(fixture.firstSessionID)
  #expect(selected)
  let saved = try #require(browser.recentDestination)
  let roundTrip = try JSONDecoder().decode(
    ClairMobileRecentDestination.self,
    from: JSONEncoder().encode(saved)
  )

  var restored = ClairMobileDestinationBrowserState(
    catalog: fixture.catalog(),
    sessions: try fixture.sessions(),
    recentDestination: roundTrip
  )
  #expect(restored.selectedScope == saved.scope)
  #expect(restored.recentDestination == saved)

  restored.clearRecentDestination()
  #expect(restored.recentDestination == nil)
  #expect(restored.selectedScope == saved.scope)
}

@Test
func n04BrowserDoesNotMixProjectsOrAcceptForeignWorktrees() throws {
  let fixture = N04Fixture()
  var browser = ClairMobileDestinationBrowserState(
    catalog: fixture.catalog(),
    sessions: try fixture.sessions()
  )

  let selectedForeignWorktree = browser.selectWorktree(
    projectID: fixture.firstProjectID,
    worktreeID: fixture.secondWorktreeID
  )
  #expect(!selectedForeignWorktree)
  #expect(
    browser.lastError
      == .worktreeNotFound(projectID: fixture.firstProjectID, worktreeID: fixture.secondWorktreeID))
  let firstProjectScope = try ResourceScope(projectID: fixture.firstProjectID)
  #expect(browser.sessions(for: firstProjectScope).map(\.id) == [fixture.firstSessionID])

  let selectedSecondSession = browser.selectSession(fixture.secondSessionID)
  #expect(selectedSecondSession)
  #expect(browser.selectedScope?.projectID == fixture.secondProjectID)
  #expect(browser.selectedScope?.worktreeID == nil)

  let staleSessionID = try SessionID("n04-stale-session")
  let selectedStaleSession = browser.selectSession(staleSessionID)
  #expect(!selectedStaleSession)
  #expect(browser.lastError == .sessionNotFound(staleSessionID))
}

@Test
func n04BrowserExplicitlyReportsMissingAndPermissionDeniedRoots() throws {
  let fixture = N04Fixture()
  var missing = ClairMobileDestinationBrowserState(
    catalog: fixture.catalog(firstState: .missing),
    sessions: try fixture.sessions()
  )
  let selectedMissingProject = missing.selectProject(fixture.firstProjectID)
  #expect(!selectedMissingProject)
  #expect(missing.lastError == .projectRootUnavailable(fixture.firstProjectID, .missing))

  var permissionDenied = ClairMobileDestinationBrowserState(
    catalog: fixture.catalog(firstWorktreeState: .permissionDenied),
    sessions: try fixture.sessions()
  )
  let selectedDeniedWorktree = permissionDenied.selectWorktree(
    projectID: fixture.firstProjectID,
    worktreeID: fixture.firstWorktreeID
  )
  #expect(!selectedDeniedWorktree)
  #expect(
    permissionDenied.lastError
      == .worktreeRootUnavailable(fixture.firstWorktreeID, .permissionDenied))
}

@Test
func n04BrowserClearsStaleRecentAndFiltersStaleSessionEntries() throws {
  let fixture = N04Fixture()
  let recent = ClairMobileRecentDestination(
    scope: try ResourceScope(projectID: fixture.firstProjectID, sessionID: fixture.firstSessionID)
  )
  var browser = ClairMobileDestinationBrowserState(
    catalog: fixture.catalog(),
    sessions: try fixture.sessions(),
    recentDestination: recent
  )
  #expect(browser.recentDestination == nil)
  #expect(browser.lastError == .staleDestination(recent.scope))

  let selectedFirstSession = browser.selectSession(fixture.firstSessionID)
  #expect(selectedFirstSession)
  browser.replaceSnapshot(
    catalog: fixture.catalog(firstState: .missing), sessions: try fixture.sessions())
  #expect(browser.selectedScope == nil)
  #expect(browser.recentDestination == nil)
  #expect(browser.sessions.map(\.id) == [fixture.secondSessionID])
}

@Test
func n04BrowserSelectionHasNoTransportSideEffects() throws {
  let fixture = N04Fixture()
  var browser = ClairMobileDestinationBrowserState(
    catalog: fixture.catalog(),
    sessions: try fixture.sessions()
  )
  let initialCatalog = browser.catalog
  let initialSessions = browser.sessions

  let selectedProject = browser.selectProject(fixture.firstProjectID)
  let selectedWorktree = browser.selectWorktree(
    projectID: fixture.firstProjectID,
    worktreeID: fixture.firstWorktreeID
  )
  let selectedSession = browser.selectSession(fixture.firstSessionID)
  #expect(selectedProject)
  #expect(selectedWorktree)
  #expect(selectedSession)
  #expect(browser.catalog == initialCatalog)
  #expect(browser.sessions == initialSessions)
}
