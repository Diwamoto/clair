import ClairMobileKit
import ClairShared
import ClairWorkspace
import Foundation
import Testing

@testable import ClairTransport

// MARK: - Shared fixtures

/// A trivial async gate used to hold a mock reader call open until the test
/// explicitly releases it, so two concurrent controller calls can be proven
/// to genuinely overlap, mirroring N05's `N05Gate`.
private actor N06Gate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}

/// Builds a `ClairAuthenticatedConnection` directly from H03's internal
/// initializer (available via `@testable import ClairTransport`) so the
/// fast, mock-reader-backed tests below do not need a full pairing/reconnect
/// handshake just to have a connection value to pass around.
private func n06Connection() throws -> ClairAuthenticatedConnection {
  ClairAuthenticatedConnection(
    connectionID: try ClairConnectionID("n06-connection"),
    hostID: try ClairHostID("n06-host"),
    deviceID: try ClairDeviceID("n06-device"),
    generation: 1,
    negotiatedProtocol: try NegotiatedProtocol(
      version: .current,
      maximumFramePayloadBytes: FrameLimits.defaultMaximumPayloadBytes,
      capabilities: .empty
    )
  )
}

/// A minimal `ClairMobileWorkspaceReading` double that counts calls and can
/// be held open by a gate. It never touches H03/H07 authorization or a real
/// Git repository, so it isolates the controller's own de-duplication and
/// hunk-navigation logic from any real filesystem/Git behavior.
private actor N06MockReader: ClairMobileWorkspaceReading {
  private(set) var changedFileCallCount = 0
  private(set) var diffCallCountByKey: [String: Int] = [:]
  // Gated independently per operation: a test gating `diff` (for example)
  // must not also block an unrelated, ungated `changedFileSummary` warm-up
  // call made against the same reader instance.
  private let changedFilesReleaseGate: N06Gate?
  private let changedFilesStartedGate: N06Gate?
  private let diffReleaseGate: N06Gate?
  private let diffStartedGate: N06Gate?
  var changedFileSummaryToReturn: ClairChangedFileSummary
  var diffsByPath: [String: ClairGitDiff] = [:]
  var errorToThrow: Error?

  init(
    changedFileSummary: ClairChangedFileSummary,
    changedFilesReleaseGate: N06Gate? = nil,
    changedFilesStartedGate: N06Gate? = nil,
    diffReleaseGate: N06Gate? = nil,
    diffStartedGate: N06Gate? = nil
  ) {
    self.changedFileSummaryToReturn = changedFileSummary
    self.changedFilesReleaseGate = changedFilesReleaseGate
    self.changedFilesStartedGate = changedFilesStartedGate
    self.diffReleaseGate = diffReleaseGate
    self.diffStartedGate = diffStartedGate
  }

  func setDiff(_ diff: ClairGitDiff, forPath path: String) {
    diffsByPath[path] = diff
  }

  func setError(_ error: Error?) {
    errorToThrow = error
  }

  func changedFileSummary(
    for scope: ResourceScope,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairChangedFileSummary {
    changedFileCallCount += 1
    await changedFilesStartedGate?.open()
    await changedFilesReleaseGate?.wait()
    if let errorToThrow { throw errorToThrow }
    return changedFileSummaryToReturn
  }

  func diff(
    for scope: ResourceScope,
    path: ClairWorkspacePath,
    basis: ClairGitDiffBasis,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairGitDiff {
    diffCallCountByKey["\(basis.rawValue):\(path.rawValue)", default: 0] += 1
    await diffStartedGate?.open()
    await diffReleaseGate?.wait()
    if let errorToThrow { throw errorToThrow }
    guard let diff = diffsByPath[path.rawValue] else {
      throw ClairMobileDiffReviewError.fileNotFound(path)
    }
    return diff
  }
}

/// Polls (bounded, matching the codebase's existing race-test idiom) until
/// `predicate` is true, proving a duplicate call genuinely reached the
/// in-flight join point rather than racing real scheduler timing.
private func n06WaitUntil(_ predicate: @Sendable () async -> Bool) async {
  for _ in 0..<500 {
    if await predicate() { return }
    try? await Task.sleep(for: .milliseconds(1))
  }
}

private func n06ChangedFileSummary(
  files: [ClairChangedFile],
  isTruncated: Bool = false
) -> ClairChangedFileSummary {
  ClairChangedFileSummary(
    files: files,
    isTruncated: isTruncated,
    outputBytes: 128,
    maximumOutputBytes: 65_536,
    maximumFiles: 512
  )
}

private func n06TextDiff(
  path: String,
  hunks: [ClairGitDiffHunk],
  text: String = "diff",
  isTruncated: Bool = false
) throws -> ClairGitDiff {
  ClairGitDiff(
    path: try ClairWorkspacePath(path),
    basis: .workingTree,
    kind: .text,
    text: text,
    hunks: hunks,
    isTruncated: isTruncated,
    outputBytes: 128,
    maximumOutputBytes: 65_536
  )
}

// MARK: - Attachment and precondition tests

@Test
func diffReviewAttachmentRejectsSessionScope() throws {
  let scope = try ResourceScope(
    projectID: ProjectID("project-n06"), sessionID: SessionID("session-n06")
  )
  #expect(throws: ClairMobileDiffReviewError.invalidScope(scope)) {
    _ = try ClairMobileDiffReviewController.Attachment(
      scope: scope, connection: try n06Connection()
    )
  }
}

@Test
func diffReviewOperationsRequireAttachment() async throws {
  let controller = ClairMobileDiffReviewController()
  #expect(await controller.isAttached == false)

  await #expect(throws: ClairMobileDiffReviewError.notAttached) {
    _ = try await controller.refreshChangedFiles()
  }
  await #expect(throws: ClairMobileDiffReviewError.notAttached) {
    _ = try await controller.selectFile(try ClairWorkspacePath("tracked.txt"))
  }
}

@Test
func diffReviewSelectFileRejectsUnknownPath() async throws {
  let projectID = try ProjectID("project-n06-unknown-path")
  let trackedPath = try ClairWorkspacePath("tracked.txt")
  let reader = N06MockReader(
    changedFileSummary: n06ChangedFileSummary(
      files: [
        ClairChangedFile(
          path: trackedPath, kind: .modified, indexStatus: ".", worktreeStatus: "M"
        )
      ]
    )
  )
  let controller = ClairMobileDiffReviewController(reader: reader)
  let scope = try ResourceScope(projectID: projectID)
  try await controller.attach(.init(scope: scope, connection: n06Connection()))
  _ = try await controller.refreshChangedFiles()

  let unknownPath = try ClairWorkspacePath("unknown.txt")
  await #expect(throws: ClairMobileDiffReviewError.fileNotFound(unknownPath)) {
    _ = try await controller.selectFile(unknownPath)
  }
  #expect(await reader.diffCallCountByKey.isEmpty)
}

// MARK: - De-duplication tests

@Test
func diffReviewDuplicateRefreshChangedFilesJoinsInFlightRequest() async throws {
  let projectID = try ProjectID("project-n06-refresh-dedupe")
  let gate = N06Gate()
  let startedGate = N06Gate()
  let reader = N06MockReader(
    changedFileSummary: n06ChangedFileSummary(files: []),
    changedFilesReleaseGate: gate,
    changedFilesStartedGate: startedGate
  )
  let controller = ClairMobileDiffReviewController(reader: reader)
  try await controller.attach(
    .init(scope: try ResourceScope(projectID: projectID), connection: n06Connection())
  )

  async let first = controller.refreshChangedFiles()
  await startedGate.wait()
  async let second = controller.refreshChangedFiles()
  await n06WaitUntil { await reader.changedFileCallCount >= 1 }
  await gate.open()
  _ = try await (first, second)

  #expect(await reader.changedFileCallCount == 1)
}

@Test
func diffReviewDuplicateSelectFileJoinsInFlightRequest() async throws {
  let projectID = try ProjectID("project-n06-select-dedupe")
  let trackedPath = try ClairWorkspacePath("tracked.txt")
  let gate = N06Gate()
  let startedGate = N06Gate()
  let reader = N06MockReader(
    changedFileSummary: n06ChangedFileSummary(
      files: [
        ClairChangedFile(
          path: trackedPath, kind: .modified, indexStatus: ".", worktreeStatus: "M"
        )
      ]
    ),
    diffReleaseGate: gate,
    diffStartedGate: startedGate
  )
  await reader.setDiff(
    try n06TextDiff(path: "tracked.txt", hunks: []), forPath: "tracked.txt"
  )
  let controller = ClairMobileDiffReviewController(reader: reader)
  try await controller.attach(
    .init(scope: try ResourceScope(projectID: projectID), connection: n06Connection())
  )
  _ = try await controller.refreshChangedFiles()

  async let first = controller.selectFile(trackedPath)
  await startedGate.wait()
  async let second = controller.selectFile(trackedPath)
  await n06WaitUntil { await (reader.diffCallCountByKey["working_tree:tracked.txt"] ?? 0) >= 1 }
  await gate.open()
  _ = try await (first, second)

  #expect(await reader.diffCallCountByKey["working_tree:tracked.txt"] == 1)
}

// MARK: - Hunk navigation safety

@Test
func diffReviewHunkNavigationClampsAndIgnoresDuplicateInput() async throws {
  let projectID = try ProjectID("project-n06-hunk-nav")
  let trackedPath = try ClairWorkspacePath("tracked.txt")
  let hunks = [
    ClairGitDiffHunk(
      id: "h1", header: "@@ -1,1 +1,1 @@", oldStart: 1, oldCount: 1, newStart: 1, newCount: 1),
    ClairGitDiffHunk(
      id: "h2", header: "@@ -5,1 +5,1 @@", oldStart: 5, oldCount: 1, newStart: 5, newCount: 1),
    ClairGitDiffHunk(
      id: "h3", header: "@@ -9,1 +9,1 @@", oldStart: 9, oldCount: 1, newStart: 9, newCount: 1),
  ]
  let reader = N06MockReader(
    changedFileSummary: n06ChangedFileSummary(
      files: [
        ClairChangedFile(
          path: trackedPath, kind: .modified, indexStatus: ".", worktreeStatus: "M"
        )
      ]
    )
  )
  await reader.setDiff(try n06TextDiff(path: "tracked.txt", hunks: hunks), forPath: "tracked.txt")
  let controller = ClairMobileDiffReviewController(reader: reader)
  try await controller.attach(
    .init(scope: try ResourceScope(projectID: projectID), connection: n06Connection())
  )
  _ = try await controller.refreshChangedFiles()
  _ = try await controller.selectFile(trackedPath)

  #expect(await controller.state.currentHunk?.id == "h1")

  // Rapid-repeat/duplicate "next" input well past the end must clamp, not
  // crash or wrap.
  for _ in 0..<10 { _ = await controller.nextHunk() }
  #expect(await controller.state.currentHunk?.id == "h3")
  #expect(await controller.nextHunk() == false)

  // Rapid-repeat/duplicate "previous" input well past the start must clamp
  // the same way.
  for _ in 0..<10 { _ = await controller.previousHunk() }
  #expect(await controller.state.currentHunk?.id == "h1")
  #expect(await controller.previousHunk() == false)

  #expect(await controller.selectHunk(id: "h2"))
  #expect(await controller.state.currentHunk?.id == "h2")
  // An unknown/stale hunk id is safely ignored rather than corrupting the
  // cursor.
  #expect(await controller.selectHunk(id: "does-not-exist") == false)
  #expect(await controller.state.currentHunk?.id == "h2")
}

@Test
func diffReviewHunkNavigationIsSafeOnAHunklessBinaryDiff() async throws {
  let projectID = try ProjectID("project-n06-binary-nav")
  let binaryPath = try ClairWorkspacePath("binary.dat")
  let reader = N06MockReader(
    changedFileSummary: n06ChangedFileSummary(
      files: [
        ClairChangedFile(
          path: binaryPath, kind: .untracked, indexStatus: "?", worktreeStatus: "?"
        )
      ]
    )
  )
  await reader.setDiff(
    ClairGitDiff(
      path: binaryPath,
      basis: .workingTree,
      kind: .binary,
      text: nil,
      hunks: [],
      isTruncated: false,
      outputBytes: 0,
      maximumOutputBytes: 65_536
    ),
    forPath: "binary.dat"
  )
  let controller = ClairMobileDiffReviewController(reader: reader)
  try await controller.attach(
    .init(scope: try ResourceScope(projectID: projectID), connection: n06Connection())
  )
  _ = try await controller.refreshChangedFiles()
  _ = try await controller.selectFile(binaryPath)

  #expect(await controller.state.isBinary)
  #expect(await controller.state.currentHunk == nil)
  #expect(await controller.nextHunk() == false)
  #expect(await controller.previousHunk() == false)
  #expect(await controller.selectHunk(id: "anything") == false)
  #expect(await controller.state.currentHunk == nil)
}

@Test
func diffReviewFollowUpPromptSeedReflectsSelection() async throws {
  let projectID = try ProjectID("project-n06-follow-up")
  let trackedPath = try ClairWorkspacePath("tracked.txt")
  let hunk = ClairGitDiffHunk(
    id: "h1", header: "@@ -1,1 +1,1 @@", oldStart: 1, oldCount: 1, newStart: 1, newCount: 1
  )
  let reader = N06MockReader(
    changedFileSummary: n06ChangedFileSummary(
      files: [
        ClairChangedFile(
          path: trackedPath, kind: .modified, indexStatus: ".", worktreeStatus: "M"
        )
      ]
    )
  )
  await reader.setDiff(
    try n06TextDiff(path: "tracked.txt", hunks: [hunk]), forPath: "tracked.txt"
  )
  let controller = ClairMobileDiffReviewController(reader: reader)
  try await controller.attach(
    .init(scope: try ResourceScope(projectID: projectID), connection: n06Connection())
  )
  #expect(await controller.state.followUpPromptSeed == nil)

  _ = try await controller.refreshChangedFiles()
  _ = try await controller.selectFile(trackedPath)
  let seed = try #require(await controller.state.followUpPromptSeed)
  #expect(seed.contains("tracked.txt"))
  #expect(seed.contains(hunk.header))
}

// MARK: - Reattach resets state

@Test
func diffReviewReattachResetsPriorDiffAndHunkSelection() async throws {
  let firstProjectID = try ProjectID("project-n06-reattach-first")
  let secondProjectID = try ProjectID("project-n06-reattach-second")
  let trackedPath = try ClairWorkspacePath("tracked.txt")
  let reader = N06MockReader(
    changedFileSummary: n06ChangedFileSummary(
      files: [
        ClairChangedFile(
          path: trackedPath, kind: .modified, indexStatus: ".", worktreeStatus: "M"
        )
      ]
    )
  )
  await reader.setDiff(
    try n06TextDiff(
      path: "tracked.txt",
      hunks: [
        ClairGitDiffHunk(
          id: "h1", header: "@@ -1,1 +1,1 @@", oldStart: 1, oldCount: 1, newStart: 1, newCount: 1
        )
      ]
    ),
    forPath: "tracked.txt"
  )
  let controller = ClairMobileDiffReviewController(reader: reader)
  try await controller.attach(
    .init(scope: try ResourceScope(projectID: firstProjectID), connection: n06Connection())
  )
  _ = try await controller.refreshChangedFiles()
  _ = try await controller.selectFile(trackedPath)
  #expect(await controller.state.selectedPath == trackedPath)
  #expect(await controller.state.currentHunk != nil)

  try await controller.attach(
    .init(scope: try ResourceScope(projectID: secondProjectID), connection: n06Connection())
  )
  #expect(await controller.state.selectedPath == nil)
  #expect(await controller.state.diff == nil)
  #expect(await controller.state.currentHunk == nil)
  #expect(await controller.state.changedFiles == nil)
}

// MARK: - Real H07 workspace + H03 authorization integration

#if os(macOS)

  private struct N06WorkspaceBridge: ClairMobileWorkspaceReading {
    let authority: ClairPairingAuthority
    let runtime: ClairWorkspaceRuntime

    func changedFileSummary(
      for scope: ResourceScope,
      on connection: ClairAuthenticatedConnection
    ) async throws -> ClairChangedFileSummary {
      try await authority.authorizeRead(scope: scope, on: connection)
      return try runtime.changedFileSummary(
        projectID: scope.projectID, worktreeID: scope.worktreeID
      )
    }

    func diff(
      for scope: ResourceScope,
      path: ClairWorkspacePath,
      basis: ClairGitDiffBasis,
      on connection: ClairAuthenticatedConnection
    ) async throws -> ClairGitDiff {
      try await authority.authorizeRead(scope: scope, on: connection)
      return try runtime.gitDiff(
        projectID: scope.projectID, worktreeID: scope.worktreeID, path: path, basis: basis
      )
    }
  }

  private struct N06HostFixture {
    let authority: ClairPairingAuthority
    let connection: ClairAuthenticatedConnection
    let scope: ResourceScope
    let runtime: ClairWorkspaceRuntime

    static func make(
      projectID: ProjectID,
      rootURL: URL,
      limits: ClairWorkspaceLimits = .standard
    ) async throws -> Self {
      let scope = try ResourceScope(projectID: projectID)
      let authority = try ClairPairingAuthority(
        hostID: ClairHostID("host-n06"),
        endpoint: ClairTransportEndpoint("wss://n06.example.test"),
        defaultVisibleScopes: [scope]
      )
      let client = ClairNativeClientTransport(deviceKey: ClairDeviceKey())
      let link = try await authority.issuePairingLink(lifetime: 60)
      let paired = try await client.pair(
        using: link, with: authority, displayName: "N06 fixture", confirmHostFingerprint: true
      )
      _ = try await authority.updateGrant(
        deviceID: paired.credential.grant.deviceID,
        capabilities: CapabilitySet([.view]),
        visibleScopes: [scope]
      )
      let connection = try await client.reconnect(to: authority.presentation(), using: authority)
      let project = try ClairProjectRoot(id: projectID, rootURL: rootURL)
      let runtime = try ClairWorkspaceRuntime(projects: [project], limits: limits)
      return Self(authority: authority, connection: connection, scope: scope, runtime: runtime)
    }

    var reader: N06WorkspaceBridge {
      N06WorkspaceBridge(authority: authority, runtime: runtime)
    }

    func makeController() -> ClairMobileDiffReviewController {
      ClairMobileDiffReviewController(reader: reader)
    }

    func attachment() throws -> ClairMobileDiffReviewController.Attachment {
      try .init(scope: scope, connection: connection)
    }
  }

  private final class N06GitFixture {
    let rootURL: URL

    init() throws {
      rootURL = URL(fileURLWithPath: "/private/tmp")
        .appendingPathComponent("clair-n06-fixture-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(
        at: rootURL,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      try runGit(["init", "--quiet"])
      try runGit(["config", "user.email", "clair-n06@example.invalid"])
      try runGit(["config", "user.name", "Clair N06"])
      try writeText("tracked.txt", "one\ntwo\nthree\n")
      try runGit(["add", "tracked.txt"])
      try runGit(["commit", "--quiet", "-m", "initial"])
    }

    func writeText(_ relativePath: String, _ value: String) throws {
      try writeData(relativePath, Data(value.utf8))
    }

    func writeData(_ relativePath: String, _ data: Data) throws {
      let url = rootURL.appendingPathComponent(relativePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: url)
    }

    @discardableResult
    func runGit(_ arguments: [String]) throws -> String {
      let candidates = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
      guard
        let path = candidates.first(where: {
          FileManager.default.isExecutableFile(atPath: $0)
        })
      else {
        throw N06FixtureError.commandFailed
      }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: path)
      process.arguments = arguments
      process.currentDirectoryURL = rootURL
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = Pipe()
      process.standardError = FileHandle.nullDevice
      try process.run()
      let output =
        (process.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw N06FixtureError.commandFailed
      }
      return String(data: output, encoding: .utf8) ?? ""
    }

    func fileBytes(_ relativePath: String) throws -> Data {
      try Data(contentsOf: rootURL.appendingPathComponent(relativePath))
    }

    func remove() {
      try? FileManager.default.removeItem(at: rootURL)
    }
  }

  private enum N06FixtureError: Error {
    case commandFailed
  }

  @Test
  func diffReviewSurfacesBinaryFileExplicitly() async throws {
    let git = try N06GitFixture()
    defer { git.remove() }
    try git.writeData("binary.dat", Data([0, 1, 2, 3, 255]))

    let projectID = try ProjectID("project-n06-binary")
    let fixture = try await N06HostFixture.make(projectID: projectID, rootURL: git.rootURL)
    let controller = fixture.makeController()
    try await controller.attach(fixture.attachment())

    _ = try await controller.refreshChangedFiles()
    let diff = try await controller.selectFile(try ClairWorkspacePath("binary.dat"))

    #expect(diff.kind == .binary)
    #expect(diff.text == nil)
    #expect(diff.hunks.isEmpty)
    #expect(await controller.state.isBinary)
    // A binary diff has no hunks to navigate; this must stay a safe no-op.
    #expect(await controller.nextHunk() == false)
    #expect(await controller.previousHunk() == false)
  }

  @Test
  func diffReviewSurfacesTruncatedLargeDiffExplicitly() async throws {
    let git = try N06GitFixture()
    defer { git.remove() }
    try git.writeText("large.txt", String(repeating: "large line\n", count: 80))

    let projectID = try ProjectID("project-n06-truncated")
    let boundedLimits = try ClairWorkspaceLimits(
      maximumFileReadBytes: 1_024,
      maximumTreeEntries: 256,
      maximumTreeDepth: 4,
      maximumChangedFiles: 32,
      maximumChangedOutputBytes: 96,
      maximumGitOutputBytes: 1_024
    )
    let fixture = try await N06HostFixture.make(
      projectID: projectID, rootURL: git.rootURL, limits: boundedLimits
    )
    let controller = fixture.makeController()
    try await controller.attach(fixture.attachment())

    _ = try await controller.refreshChangedFiles()
    let diff = try await controller.selectFile(try ClairWorkspacePath("large.txt"))

    #expect(diff.isTruncated)
    #expect(diff.outputBytes <= diff.maximumOutputBytes)
    #expect(await controller.state.isTruncated)
  }

  /// The task's central safety requirement: a full render/navigation pass —
  /// listing changed files (tracked, untracked, binary, and a bounded/large
  /// diff), selecting each one, and navigating hunks including duplicate and
  /// out-of-bounds input — must never write to, stage, or otherwise mutate
  /// the Git repository or working tree. This drives the real H07
  /// `ClairWorkspaceRuntime` (not a mock) through H03's real
  /// `authorizeRead`, and proves the repository is byte-identical before and
  /// after.
  @Test
  func diffReviewFullSessionProducesZeroGitMutations() async throws {
    let git = try N06GitFixture()
    defer { git.remove() }
    try git.writeText("tracked.txt", "one\nCHANGED\nthree\n")
    try git.writeText("untracked.txt", "brand new\n")
    try git.writeData("binary.dat", Data([0, 1, 2, 3, 255]))
    try git.writeText("large.txt", String(repeating: "large line\n", count: 80))

    let projectID = try ProjectID("project-n06-zero-mutation")
    let boundedLimits = try ClairWorkspaceLimits(
      maximumFileReadBytes: 4_096,
      maximumTreeEntries: 256,
      maximumTreeDepth: 4,
      maximumChangedFiles: 32,
      maximumChangedOutputBytes: 96,
      maximumGitOutputBytes: 1_024
    )
    let fixture = try await N06HostFixture.make(
      projectID: projectID, rootURL: git.rootURL, limits: boundedLimits
    )
    let controller = fixture.makeController()
    try await controller.attach(fixture.attachment())

    let statusBefore = try git.runGit(["status", "--porcelain=2", "-z"])
    let headBefore = try git.runGit(["rev-parse", "HEAD"])
    let trackedBefore = try git.fileBytes("tracked.txt")
    let untrackedBefore = try git.fileBytes("untracked.txt")
    let binaryBefore = try git.fileBytes("binary.dat")
    let largeBefore = try git.fileBytes("large.txt")

    let summary = try await controller.refreshChangedFiles()
    #expect(summary.files.contains { $0.path.rawValue == "tracked.txt" })
    #expect(summary.files.contains { $0.path.rawValue == "untracked.txt" })
    #expect(summary.files.contains { $0.path.rawValue == "binary.dat" })
    #expect(summary.files.contains { $0.path.rawValue == "large.txt" })

    _ = try await controller.selectFile(try ClairWorkspacePath("tracked.txt"))
    // Duplicate/rapid-repeat hunk navigation, including past both ends, must
    // stay safe and must never touch the filesystem.
    for _ in 0..<5 { _ = await controller.nextHunk() }
    for _ in 0..<8 { _ = await controller.previousHunk() }
    _ = await controller.nextHunk()

    let binaryDiff = try await controller.selectFile(try ClairWorkspacePath("binary.dat"))
    #expect(binaryDiff.kind == .binary)
    #expect(await controller.state.isBinary)
    _ = await controller.nextHunk()
    _ = await controller.previousHunk()

    let largeDiff = try await controller.selectFile(try ClairWorkspacePath("large.txt"))
    #expect(largeDiff.isTruncated)

    _ = try await controller.selectFile(try ClairWorkspacePath("untracked.txt"))

    // A duplicate/rapid-repeat re-selection of the same file must join the
    // same in-flight read rather than issuing (or racing) a second one.
    async let first = controller.selectFile(try ClairWorkspacePath("tracked.txt"))
    async let second = controller.selectFile(try ClairWorkspacePath("tracked.txt"))
    _ = try await (first, second)

    // Re-attaching (as when the user picks a different destination) must
    // reset to a clean state without touching the filesystem.
    try await controller.attach(fixture.attachment())
    #expect(await controller.state.selectedPath == nil)

    let statusAfter = try git.runGit(["status", "--porcelain=2", "-z"])
    let headAfter = try git.runGit(["rev-parse", "HEAD"])
    let trackedAfter = try git.fileBytes("tracked.txt")
    let untrackedAfter = try git.fileBytes("untracked.txt")
    let binaryAfter = try git.fileBytes("binary.dat")
    let largeAfter = try git.fileBytes("large.txt")

    #expect(statusBefore == statusAfter)
    #expect(headBefore == headAfter)
    #expect(trackedBefore == trackedAfter)
    #expect(untrackedBefore == untrackedAfter)
    #expect(binaryBefore == binaryAfter)
    #expect(largeBefore == largeAfter)
  }

#endif
