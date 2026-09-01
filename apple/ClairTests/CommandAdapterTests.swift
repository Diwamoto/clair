import Foundation
import XCTest

@testable import ClairApp

@MainActor
private final class CommandAdapterApprovalSpy: CommandApprovalHandler {
  let decision: Bool
  private(set) var approvedCommandIDs: [ClairCommandID] = []

  init(decision: Bool) {
    self.decision = decision
  }

  func approve(
    commandID: ClairCommandID,
    title: String,
    risk: CommandRisk,
    reason: String
  ) -> Bool {
    approvedCommandIDs.append(commandID)
    return decision
  }
}

@MainActor
final class CommandAdapterTests: XCTestCase {
  func testRegistryCoversAllTypedCommandsAndCodecPreservesID() throws {
    let registry = CommandRegistry()
    XCTAssertEqual(
      Set(registry.descriptors.map(\.id)),
      Set(ClairCommandID.allCases)
    )

    let command = try ClairCommandCodec.makeCommand(
      id: .navigationOpenFile,
      parameters: .object([
        "path": .string("/tmp/example.swift"),
        "line": .number(12),
        "column": .number(4),
      ])
    )
    XCTAssertEqual(command.id, .navigationOpenFile)

    let optionalCommand = try ClairCommandCodec.makeCommand(
      id: .editorSave,
      parameters: .object([
        "projectID": .string(UUID().uuidString),
        "tabID": .null,
      ])
    )
    XCTAssertEqual(optionalCommand.id, .editorSave)
    XCTAssertEqual(CommandRegistry().descriptor(for: .navigationOpenFile)?.risk, .additive)
  }

  func testLongestPrefixRoutingChoosesNestedProject() {
    let parent = URL(fileURLWithPath: "/tmp/clair-routing-parent", isDirectory: true)
    let child = parent.appendingPathComponent("nested", isDirectory: true)
    let projects = [
      Project(
        id: UUID(),
        rootURL: parent,
        name: "Parent",
        color: .blue,
        availability: .available
      ),
      Project(
        id: UUID(),
        rootURL: child,
        name: "Nested",
        color: .green,
        availability: .available
      ),
    ]

    let selected = CommandProjectRouter.longestPrefixProject(
      path: child.appendingPathComponent("Sources/App.swift"),
      projects: projects
    )
    XCTAssertEqual(selected?.name, "Nested")
  }

  func testMCPListFiltersCommandsAndCallReturnsStructuredError() {
    let workspace = ProjectWorkspaceModel(store: ProjectStore(fileURL: nil))
    let router = CommandAdapterRouter(workspace: workspace)

    let listResponse = router.handle(
      CommandIPCRequest(operation: .list, source: .mcp)
    )
    XCTAssertTrue(listResponse.ok)
    guard
      case .object(let list)? = listResponse.result,
      case .array(let commands)? = list["commands"]
    else {
      return XCTFail("MCP list did not return a command array.")
    }
    let names = commands.compactMap { value -> String? in
      guard case .object(let command) = value, case .string(let name) = command["name"] else {
        return nil
      }
      return name
    }
    XCTAssertTrue(names.contains(ClairCommandID.navigationOpenFile.rawValue))
    XCTAssertFalse(names.contains(ClairCommandID.gitCommit.rawValue))

    let deniedResponse = router.handle(
      CommandIPCRequest(
        operation: .call,
        commandID: ClairCommandID.gitCommit.rawValue,
        params: .object([:]),
        source: .mcp
      )
    )
    XCTAssertFalse(deniedResponse.ok)
    XCTAssertEqual(deniedResponse.error?.code, "not_ai_available")
    XCTAssertEqual(deniedResponse.error?.commandID, ClairCommandID.gitCommit.rawValue)
    XCTAssertNotNil(deniedResponse.error?.risk)
    XCTAssertNotNil(deniedResponse.error?.reason)
  }

  func testCLIWriteCommandUsesGUIApprovalGate() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("clair-command-adapter-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: false
    )
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    let storeURL = rootURL.appendingPathComponent("store.json")
    let workspace = ProjectWorkspaceModel(
      store: ProjectStore(fileURL: storeURL)
    )
    let approvals = CommandAdapterApprovalSpy(decision: true)
    let router = CommandAdapterRouter(
      workspace: workspace,
      approvalHandler: approvals
    )
    let response = router.handle(
      CommandIPCRequest(
        operation: .call,
        commandID: ClairCommandID.openProject.rawValue,
        params: .object(["rootPath": .string(rootURL.path)]),
        source: .cli
      )
    )

    XCTAssertTrue(response.ok)
    XCTAssertEqual(approvals.approvedCommandIDs, [.openProject])
    XCTAssertEqual(workspace.projects.count, 1)
  }

  func testCLIWriteCommandCanBeDeniedBeforeDispatch() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("clair-command-adapter-deny-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: false
    )
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    let workspace = ProjectWorkspaceModel(
      store: ProjectStore(
        fileURL: rootURL.appendingPathComponent("store.json")
      )
    )
    let approvals = CommandAdapterApprovalSpy(decision: false)
    let router = CommandAdapterRouter(
      workspace: workspace,
      approvalHandler: approvals
    )
    let response = router.handle(
      CommandIPCRequest(
        operation: .call,
        commandID: ClairCommandID.openProject.rawValue,
        params: .object(["rootPath": .string(rootURL.path)]),
        source: .cli
      )
    )

    XCTAssertFalse(response.ok)
    XCTAssertEqual(response.error?.code, "approval_denied")
    XCTAssertEqual(workspace.projects.count, 0)
  }
}
