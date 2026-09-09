import AppKit
import Foundation

enum CommandAdapterResult: Equatable, Sendable {
  case openedFile(projectID: UUID, filePath: String, line: Int?, column: Int?)
  case quickOpen(projectID: UUID, query: String, items: [ProjectQuickOpenItem])
  case search(projectID: UUID, query: String, matches: [ProjectSearchMatch])
  case pane(projectID: UUID, focusedPaneID: UUID, paneCount: Int)
  case terminal(projectID: UUID, tabID: String?)
  case agent(AgentWorkflowSession)
  case agents([AgentControlSnapshot])
  case agentStatus(AgentControlSnapshot)
  case agentControl(AgentControlReceipt)
  case worktrees(projectID: UUID, worktrees: [ManagedWorktree])
  case cleanupPlan(ManagedWorktreeCleanupPlan)
  case review(ProjectBranchReviewSnapshot)
  case adoptionPlan(ProjectBranchAdoptionPlan)
  case adoption(ProjectBranchAdoptionResult)
  case notifications(projectID: UUID, activities: [AgentActivity])
  case status(String)
}

enum CommandJSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([CommandJSONValue])
  case object([String: CommandJSONValue])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
      return
    }
    if let value = try? container.decode(Bool.self) {
      self = .bool(value)
      return
    }
    if let value = try? container.decode(Double.self) {
      self = .number(value)
      return
    }
    if let value = try? container.decode(String.self) {
      self = .string(value)
      return
    }
    if let value = try? container.decode([CommandJSONValue].self) {
      self = .array(value)
      return
    }
    if let value = try? container.decode([String: CommandJSONValue].self) {
      self = .object(value)
      return
    }
    throw DecodingError.dataCorruptedError(
      in: container,
      debugDescription: "The value is not valid JSON."
    )
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .number(let value):
      guard value.isFinite else {
        throw EncodingError.invalidValue(
          value,
          EncodingError.Context(
            codingPath: encoder.codingPath,
            debugDescription: "JSON numbers must be finite."
          )
        )
      }
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }

  var objectValue: [String: CommandJSONValue]? {
    guard case .object(let value) = self else {
      return nil
    }
    return value
  }
}

enum CommandIPCOperation: String, Codable, Sendable {
  case list
  case call
}

enum CommandIPCSource: String, Codable, Sendable {
  case cli
  case mcp
  case mobile
}

struct CommandIPCRequest: Codable, Sendable {
  let requestID: String
  let operation: CommandIPCOperation
  let commandID: String?
  let params: CommandJSONValue?
  let source: CommandIPCSource
  let confirmed: Bool

  init(
    requestID: String = UUID().uuidString,
    operation: CommandIPCOperation,
    commandID: String? = nil,
    params: CommandJSONValue? = nil,
    source: CommandIPCSource = .cli,
    confirmed: Bool = false
  ) {
    self.requestID = requestID
    self.operation = operation
    self.commandID = commandID
    self.params = params
    self.source = source
    self.confirmed = confirmed
  }

  private enum CodingKeys: String, CodingKey {
    case requestID
    case operation
    case commandID
    case params
    case source
    case confirmed
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    requestID = try container.decode(String.self, forKey: .requestID)
    operation = try container.decode(CommandIPCOperation.self, forKey: .operation)
    commandID = try container.decodeIfPresent(String.self, forKey: .commandID)
    params = try container.decodeIfPresent(CommandJSONValue.self, forKey: .params)
    source = try container.decodeIfPresent(CommandIPCSource.self, forKey: .source) ?? .cli
    confirmed = try container.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
  }
}

struct CommandIPCError: Codable, Equatable, Sendable {
  let code: String
  let message: String
  let commandID: String?
  let risk: String?
  let reason: String?
}

struct CommandIPCResponse: Codable, Sendable {
  let requestID: String
  let ok: Bool
  let result: CommandJSONValue?
  let error: CommandIPCError?

  static func success(
    requestID: String,
    result: CommandJSONValue
  ) -> CommandIPCResponse {
    CommandIPCResponse(
      requestID: requestID,
      ok: true,
      result: result,
      error: nil
    )
  }

  static func failure(
    requestID: String,
    error: CommandIPCError
  ) -> CommandIPCResponse {
    CommandIPCResponse(
      requestID: requestID,
      ok: false,
      result: nil,
      error: error
    )
  }
}

enum CommandAdapterCodecError: Error, Equatable, LocalizedError, Sendable {
  case invalidParameters(String)
  case unknownCommand(String)

  var errorDescription: String? {
    switch self {
    case .invalidParameters(let message):
      message
    case .unknownCommand(let commandID):
      "Unknown Clair command: \(commandID)"
    }
  }
}

private struct CommandParameterReader {
  let values: [String: CommandJSONValue]

  init(_ value: CommandJSONValue?) throws {
    guard case .object(let values) = value ?? .object([:]) else {
      throw CommandAdapterCodecError.invalidParameters(
        "Command parameters must be a JSON object."
      )
    }
    self.values = values
  }

  func string(_ key: String, required: Bool = true) throws -> String? {
    guard let value = value(for: key) else {
      if required {
        throw missing(key)
      }
      return nil
    }
    if case .null = value {
      guard !required else {
        throw invalid(key, expected: "a non-null string")
      }
      return nil
    }
    guard case .string(let string) = value else {
      throw invalid(key, expected: "a string")
    }
    if required, string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw invalid(key, expected: "a non-empty string")
    }
    return string
  }

  func uuid(_ key: String, required: Bool = true) throws -> UUID? {
    guard let string = try string(key, required: required) else {
      return nil
    }
    guard let value = UUID(uuidString: string) else {
      throw invalid(key, expected: "a UUID")
    }
    return value
  }

  func integer(_ key: String, required: Bool = true) throws -> Int? {
    guard let value = value(for: key) else {
      if required {
        throw missing(key)
      }
      return nil
    }
    guard case .number(let number) = value, let integer = Int(exactly: number) else {
      throw invalid(key, expected: "an integer")
    }
    return integer
  }

  func boolean(_ key: String, required: Bool = true) throws -> Bool? {
    guard let value = value(for: key) else {
      if required {
        throw missing(key)
      }
      return nil
    }
    guard case .bool(let boolean) = value else {
      throw invalid(key, expected: "a Boolean")
    }
    return boolean
  }

  private func value(for key: String) -> CommandJSONValue? {
    values[key] ?? values[Self.snakeCase(key)]
  }

  private func missing(_ key: String) -> CommandAdapterCodecError {
    .invalidParameters("Missing required parameter: \(key).")
  }

  private func invalid(_ key: String, expected: String) -> CommandAdapterCodecError {
    .invalidParameters("Parameter \(key) must be \(expected).")
  }

  private static func snakeCase(_ value: String) -> String {
    value.reduce(into: "") { result, character in
      if character.isUppercase {
        result.append("_")
        result.append(contentsOf: character.lowercased())
      } else {
        result.append(character)
      }
    }
  }
}

enum ClairCommandCodec {
  static func makeCommand(
    id: ClairCommandID,
    parameters: CommandJSONValue?
  ) throws -> ClairCommand {
    let reader = try CommandParameterReader(parameters)
    switch id {
    case .openProject:
      let path = try reader.string("rootPath") ?? ""
      return .openProject(
        OpenProjectCommand(rootURL: URL(fileURLWithPath: path, isDirectory: true))
      )
    case .switchProject:
      return .switchProject(
        SwitchProjectCommand(projectID: try reader.uuid("projectID") ?? UUID())
      )
    case .renameProject:
      return .renameProject(
        RenameProjectCommand(
          projectID: try reader.uuid("projectID") ?? UUID(),
          name: try reader.string("name") ?? ""
        )
      )
    case .setProjectColor:
      let rawValue = try reader.string("color") ?? ""
      guard let color = ProjectColor(rawValue: rawValue) else {
        throw CommandAdapterCodecError.invalidParameters(
          "Parameter color is not a supported Project color."
        )
      }
      return .setProjectColor(
        SetProjectColorCommand(
          projectID: try reader.uuid("projectID") ?? UUID(),
          color: color
        )
      )
    case .reorderProject:
      return .reorderProject(
        ReorderProjectCommand(
          projectID: try reader.uuid("projectID") ?? UUID(),
          targetIndex: try reader.integer("targetIndex") ?? 0
        )
      )
    case .closeProject:
      return .closeProject(
        CloseProjectCommand(projectID: try reader.uuid("projectID") ?? UUID())
      )
    case .navigationOpenFile:
      let line = try reader.integer("line", required: false)
      let column = try reader.integer("column", required: false)
      if let line, line < 1 {
        throw CommandAdapterCodecError.invalidParameters("Parameter line must be positive.")
      }
      if let column, column < 1 {
        throw CommandAdapterCodecError.invalidParameters("Parameter column must be positive.")
      }
      return .navigationOpenFile(
        NavigationOpenFileCommand(
          path: try reader.string("path") ?? "",
          line: line,
          column: column
        )
      )
    case .navigationQuickOpen:
      return .navigationQuickOpen(
        NavigationQuickOpenCommand(
          projectID: try reader.uuid("projectID") ?? UUID(),
          query: try reader.string("query") ?? ""
        )
      )
    case .navigationSearch:
      return .navigationSearch(
        NavigationSearchCommand(
          projectID: try reader.uuid("projectID") ?? UUID(),
          query: try reader.string("query") ?? ""
        )
      )
    case .editorSave, .editorUndo, .editorRedo:
      let input = EditorCommand(
        projectID: try reader.uuid("projectID") ?? UUID(),
        tabID: try reader.string("tabID", required: false)
      )
      switch id {
      case .editorSave:
        return .editorSave(input)
      case .editorUndo:
        return .editorUndo(input)
      case .editorRedo:
        return .editorRedo(input)
      default:
        throw CommandAdapterCodecError.unknownCommand(id.rawValue)
      }
    case .paneSplit:
      let rawOrientation = try reader.string("orientation") ?? ""
      guard let orientation = ProjectPaneOrientation(rawValue: rawOrientation) else {
        throw CommandAdapterCodecError.invalidParameters(
          "Parameter orientation must be horizontal or vertical."
        )
      }
      return .paneSplit(
        PaneSplitCommand(
          projectID: try reader.uuid("projectID") ?? UUID(),
          orientation: orientation
        )
      )
    case .paneFocus, .paneMoveTab, .paneClose:
      let input = PaneTargetCommand(
        projectID: try reader.uuid("projectID") ?? UUID(),
        paneID: try reader.uuid("paneID") ?? UUID()
      )
      switch id {
      case .paneFocus:
        return .paneFocus(input)
      case .paneMoveTab:
        return .paneMoveTab(input)
      case .paneClose:
        return .paneClose(input)
      default:
        throw CommandAdapterCodecError.unknownCommand(id.rawValue)
      }
    case .paneToggleMaximize, .paneEqualize, .terminalOpen:
      let input = ProjectTargetCommand(
        projectID: try reader.uuid("projectID") ?? UUID()
      )
      switch id {
      case .paneToggleMaximize:
        return .paneToggleMaximize(input)
      case .paneEqualize:
        return .paneEqualize(input)
      case .terminalOpen:
        return .terminalOpen(input)
      default:
        throw CommandAdapterCodecError.unknownCommand(id.rawValue)
      }
    case .terminalStop, .terminalRecover:
      let input = TerminalCommand(
        projectID: try reader.uuid("projectID") ?? UUID(),
        tabID: try reader.string("tabID", required: false)
      )
      return id == .terminalStop ? .terminalStop(input) : .terminalRecover(input)
    case .agentList:
      return .agentList(
        ListAgentsCommand(projectID: try reader.uuid("projectID", required: false))
      )
    case .agentStatus:
      return .agentStatus(
        AgentSessionCommand(sessionID: try reader.uuid("sessionID") ?? UUID())
      )
    case .agentLaunch:
      return .agentLaunch(
        LaunchAgentCommand(
          projectID: try reader.uuid("projectID") ?? UUID(),
          profileID: try reader.string("profileID") ?? "",
          modelID: try reader.string("modelID", required: false),
          worktreeID: try reader.uuid("worktreeID", required: false)
        )
      )
    case .agentReveal:
      return .agentReveal(
        RevealAgentCommand(
          projectID: try reader.uuid("projectID") ?? UUID(),
          sessionID: try reader.uuid("sessionID") ?? UUID()
        )
      )
    case .agentInput:
      return .agentInput(
        AgentInputCommand(
          sessionID: try reader.uuid("sessionID") ?? UUID(),
          text: try reader.string("text") ?? ""
        )
      )
    case .agentInterrupt:
      return .agentInterrupt(
        AgentSessionCommand(sessionID: try reader.uuid("sessionID") ?? UUID())
      )
    case .agentStop:
      return .agentStop(
        AgentSessionCommand(sessionID: try reader.uuid("sessionID") ?? UUID())
      )
    case .worktreeList:
      return .worktreeList(
        WorktreeListCommand(projectID: try reader.uuid("projectID") ?? UUID())
      )
    case .worktreeCreate:
      return .worktreeCreate(
        WorktreeCreateCommand(
          projectID: try reader.uuid("projectID") ?? UUID(),
          branch: try reader.string("branch") ?? "",
          baseRevision: try reader.string("baseRevision", required: false) ?? "HEAD",
          targetName: try reader.string("targetName") ?? ""
        )
      )
    case .worktreePrepareCleanup:
      return .worktreePrepareCleanup(
        WorktreeCleanupCommand(
          projectID: try reader.uuid("projectID") ?? UUID(),
          worktreeID: try reader.uuid("worktreeID") ?? UUID()
        )
      )
    case .gitRefresh:
      return .gitRefresh(
        GitRefreshCommand(projectID: try reader.uuid("projectID") ?? UUID())
      )
    case .gitShowDiff:
      return .gitShowDiff(
        GitShowDiffCommand(
          projectID: try reader.uuid("projectID") ?? UUID(),
          relativePath: try reader.string("relativePath") ?? "",
          basis: try diffBasis(from: reader)
        )
      )
    case .gitStage:
      return .gitStage(
        GitStageCommand(
          projectID: try reader.uuid("projectID") ?? UUID(),
          relativePath: try reader.string("relativePath") ?? ""
        )
      )
    case .gitUnstage:
      return .gitUnstage(
        GitUnstageCommand(
          projectID: try reader.uuid("projectID") ?? UUID(),
          relativePath: try reader.string("relativePath") ?? ""
        )
      )
    case .gitCommit:
      return .gitCommit(
        GitCommitCommand(
          projectID: try reader.uuid("projectID") ?? UUID(),
          message: try reader.string("message") ?? ""
        )
      )
    case .gitSwitchBranch:
      return .gitSwitchBranch(
        GitSwitchBranchCommand(
          projectID: try reader.uuid("projectID") ?? UUID(),
          branch: try reader.string("branch") ?? ""
        )
      )
    case .gitReview, .gitPrepareAdoption:
      let input = GitReviewCommand(
        projectID: try reader.uuid("projectID") ?? UUID(),
        worktreeID: try reader.uuid("worktreeID") ?? UUID()
      )
      return id == .gitReview ? .gitReview(input) : .gitPrepareAdoption(input)
    case .gitAdopt:
      return .gitAdopt(
        GitAdoptCommand(
          projectID: try reader.uuid("projectID") ?? UUID(),
          worktreeID: try reader.uuid("worktreeID") ?? UUID(),
          confirmationID: try reader.uuid("confirmationID") ?? UUID()
        )
      )
    case .notificationList:
      return .notificationList(
        NotificationListCommand(
          projectID: try reader.uuid("projectID") ?? UUID(),
          sessionID: try reader.uuid("sessionID", required: false)
        )
      )
    case .notificationSetMute:
      return .notificationSetMute(
        NotificationMuteCommand(
          projectID: try reader.uuid("projectID") ?? UUID(),
          sessionID: try reader.uuid("sessionID", required: false),
          muted: try reader.boolean("muted") ?? false
        )
      )
    }
  }

  static func schema(for id: ClairCommandID) -> CommandJSONValue {
    let projectID: CommandJSONValue = .object([
      "type": .string("string"),
      "format": .string("uuid"),
    ])
    let optionalString: CommandJSONValue = .object([
      "type": .array([.string("string"), .string("null")])
    ])
    let optionalUUID: CommandJSONValue = .object([
      "type": .array([.string("string"), .string("null")]),
      "format": .string("uuid"),
    ])
    switch id {
    case .openProject:
      return objectSchema(properties: ["rootPath": stringSchema()], required: ["rootPath"])
    case .switchProject, .closeProject:
      return objectSchema(properties: ["projectID": projectID], required: ["projectID"])
    case .renameProject:
      return objectSchema(
        properties: ["projectID": projectID, "name": stringSchema()],
        required: ["projectID", "name"]
      )
    case .setProjectColor:
      return objectSchema(
        properties: [
          "projectID": projectID,
          "color": enumSchema(ProjectColor.allCases.map(\.rawValue)),
        ],
        required: ["projectID", "color"]
      )
    case .reorderProject:
      return objectSchema(
        properties: ["projectID": projectID, "targetIndex": integerSchema()],
        required: ["projectID", "targetIndex"]
      )
    case .navigationOpenFile:
      return objectSchema(
        properties: [
          "path": stringSchema(),
          "line": integerSchema(minimum: 1),
          "column": integerSchema(minimum: 1),
        ],
        required: ["path"]
      )
    case .navigationQuickOpen, .navigationSearch:
      return objectSchema(
        properties: ["projectID": projectID, "query": stringSchema()],
        required: ["projectID", "query"]
      )
    case .editorSave, .editorUndo, .editorRedo:
      return objectSchema(
        properties: ["projectID": projectID, "tabID": optionalString],
        required: ["projectID"]
      )
    case .paneSplit:
      return objectSchema(
        properties: [
          "projectID": projectID,
          "orientation": enumSchema(ProjectPaneOrientation.allCases.map(\.rawValue)),
        ],
        required: ["projectID", "orientation"]
      )
    case .paneFocus, .paneMoveTab, .paneClose:
      return objectSchema(
        properties: ["projectID": projectID, "paneID": projectID],
        required: ["projectID", "paneID"]
      )
    case .paneToggleMaximize, .paneEqualize, .terminalOpen:
      return objectSchema(properties: ["projectID": projectID], required: ["projectID"])
    case .terminalStop, .terminalRecover:
      return objectSchema(
        properties: ["projectID": projectID, "tabID": optionalString],
        required: ["projectID"]
      )
    case .agentList:
      return objectSchema(
        properties: ["projectID": optionalUUID],
        required: []
      )
    case .agentStatus, .agentInterrupt, .agentStop:
      return objectSchema(
        properties: ["sessionID": projectID],
        required: ["sessionID"]
      )
    case .agentLaunch:
      return objectSchema(
        properties: [
          "projectID": projectID,
          "profileID": stringSchema(),
          "worktreeID": optionalUUID,
        ],
        required: ["projectID", "profileID"]
      )
    case .agentReveal:
      return objectSchema(
        properties: ["projectID": projectID, "sessionID": projectID],
        required: ["projectID", "sessionID"]
      )
    case .agentInput:
      return objectSchema(
        properties: ["sessionID": projectID, "text": stringSchema()],
        required: ["sessionID", "text"]
      )
    case .worktreeList:
      return objectSchema(properties: ["projectID": projectID], required: ["projectID"])
    case .worktreeCreate:
      return objectSchema(
        properties: [
          "projectID": projectID,
          "branch": stringSchema(),
          "baseRevision": stringSchema(),
          "targetName": stringSchema(),
        ],
        required: ["projectID", "branch", "targetName"]
      )
    case .worktreePrepareCleanup:
      return objectSchema(
        properties: ["projectID": projectID, "worktreeID": projectID],
        required: ["projectID", "worktreeID"]
      )
    case .gitRefresh:
      return objectSchema(properties: ["projectID": projectID], required: ["projectID"])
    case .gitShowDiff:
      return objectSchema(
        properties: [
          "projectID": projectID,
          "relativePath": stringSchema(),
          "basis": enumSchema(ProjectGitDiffBasis.allCases.map(\.rawValue)),
        ],
        required: ["projectID", "relativePath", "basis"]
      )
    case .gitStage, .gitUnstage:
      return objectSchema(
        properties: ["projectID": projectID, "relativePath": stringSchema()],
        required: ["projectID", "relativePath"]
      )
    case .gitCommit:
      return objectSchema(
        properties: ["projectID": projectID, "message": stringSchema()],
        required: ["projectID", "message"]
      )
    case .gitSwitchBranch:
      return objectSchema(
        properties: ["projectID": projectID, "branch": stringSchema()],
        required: ["projectID", "branch"]
      )
    case .gitReview, .gitPrepareAdoption:
      return objectSchema(
        properties: ["projectID": projectID, "worktreeID": projectID],
        required: ["projectID", "worktreeID"]
      )
    case .gitAdopt:
      return objectSchema(
        properties: [
          "projectID": projectID,
          "worktreeID": projectID,
          "confirmationID": projectID,
        ],
        required: ["projectID", "worktreeID", "confirmationID"]
      )
    case .notificationList:
      return objectSchema(
        properties: ["projectID": projectID, "sessionID": optionalUUID],
        required: ["projectID"]
      )
    case .notificationSetMute:
      return objectSchema(
        properties: [
          "projectID": projectID,
          "sessionID": optionalUUID,
          "muted": .object(["type": .string("boolean")]),
        ],
        required: ["projectID", "muted"]
      )
    }
  }

  private static func diffBasis(from reader: CommandParameterReader) throws -> ProjectGitDiffBasis {
    let rawValue = try reader.string("basis") ?? ""
    guard let basis = ProjectGitDiffBasis(rawValue: rawValue) else {
      throw CommandAdapterCodecError.invalidParameters(
        "Parameter basis must be workingTree or staged."
      )
    }
    return basis
  }

  private static func objectSchema(
    properties: [String: CommandJSONValue],
    required: [String]
  ) -> CommandJSONValue {
    .object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "properties": .object(properties),
      "required": .array(required.map(CommandJSONValue.string)),
    ])
  }

  private static func stringSchema() -> CommandJSONValue {
    .object(["type": .string("string")])
  }

  private static func integerSchema(minimum: Int? = nil) -> CommandJSONValue {
    var result: [String: CommandJSONValue] = ["type": .string("integer")]
    if let minimum {
      result["minimum"] = .number(Double(minimum))
    }
    return .object(result)
  }

  private static func enumSchema(_ values: [String]) -> CommandJSONValue {
    .object([
      "type": .string("string"),
      "enum": .array(values.map(CommandJSONValue.string)),
    ])
  }
}

@MainActor
protocol CommandApprovalHandler {
  func approve(
    commandID: ClairCommandID,
    title: String,
    risk: CommandRisk,
    reason: String
  ) -> Bool
}

@MainActor
final class GUICommandApprovalHandler: CommandApprovalHandler {
  func approve(
    commandID: ClairCommandID,
    title: String,
    risk: CommandRisk,
    reason: String
  ) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = risk == .destructive ? .critical : .warning
    alert.messageText = "Allow \(title)?"
    alert.informativeText =
      "Command \(commandID.rawValue) is a \(risk.rawValue) operation.\n\n\(reason)"
    alert.addButton(withTitle: "Allow")
    alert.addButton(withTitle: "Deny")
    return alert.runModal() == .alertFirstButtonReturn
  }
}

@MainActor
final class CommandAdapterRouter {
  let workspace: ProjectWorkspaceModel
  let registry: CommandRegistry
  let agentWorkflow: AgentWorkflowCoordinator?
  let worktreeCoordinator: ProjectWorktreeCoordinator?
  let approvalHandler: any CommandApprovalHandler

  private var reviewServices: [String: ProjectBranchReviewService] = [:]
  private var adoptionPlans:
    [UUID: (service: ProjectBranchReviewService, plan: ProjectBranchAdoptionPlan)] = [:]

  init(
    workspace: ProjectWorkspaceModel,
    agentWorkflow: AgentWorkflowCoordinator? = nil,
    worktreeCoordinator: ProjectWorktreeCoordinator? = nil,
    registry: CommandRegistry? = nil,
    approvalHandler: (any CommandApprovalHandler)? = nil
  ) {
    self.workspace = workspace
    self.agentWorkflow = agentWorkflow
    self.worktreeCoordinator = worktreeCoordinator
    self.registry = registry ?? workspace.commandRegistry
    self.approvalHandler = approvalHandler ?? GUICommandApprovalHandler()
  }

  func handle(_ request: CommandIPCRequest) -> CommandIPCResponse {
    switch request.operation {
    case .list:
      return CommandIPCResponse.success(
        requestID: request.requestID,
        result: listResult(source: request.source)
      )
    case .call:
      return handleCall(request)
    }
  }

  private func handleCall(_ request: CommandIPCRequest) -> CommandIPCResponse {
    guard let rawCommandID = request.commandID else {
      return failure(
        requestID: request.requestID,
        code: "invalid_command",
        message: "A commandID is required for a call.",
        commandID: nil,
        risk: nil,
        reason: "The call request did not include a commandID."
      )
    }
    let normalizedCommandID =
      rawCommandID.hasPrefix("clair.")
      ? String(rawCommandID.dropFirst("clair.".count))
      : rawCommandID
    guard let commandID = ClairCommandID(rawValue: normalizedCommandID) else {
      return failure(
        requestID: request.requestID,
        code: "unknown_command",
        message: "Unknown Clair command: \(rawCommandID)",
        commandID: normalizedCommandID,
        risk: nil,
        reason: "The command is not registered."
      )
    }
    guard let descriptor = registry.descriptor(for: commandID) else {
      return failure(
        requestID: request.requestID,
        code: "unknown_command",
        message: "Unknown Clair command: \(commandID.rawValue)",
        commandID: commandID.rawValue,
        risk: nil,
        reason: "The command is not registered."
      )
    }
    if request.source == .mcp, !descriptor.aiAvailable {
      return failure(
        requestID: request.requestID,
        code: "not_ai_available",
        message: "Command \(commandID.rawValue) is not available through MCP.",
        commandID: commandID.rawValue,
        risk: descriptor.risk,
        reason: "The command is intentionally excluded from the AI-facing surface."
      )
    }

    let command: ClairCommand
    do {
      command = try ClairCommandCodec.makeCommand(
        id: commandID,
        parameters: request.params
      )
    } catch let error as CommandAdapterCodecError {
      return failure(
        requestID: request.requestID,
        code: "invalid_parameters",
        message: error.localizedDescription,
        commandID: commandID.rawValue,
        risk: descriptor.risk,
        reason: "The request did not match the registered command input schema."
      )
    } catch {
      return failure(
        requestID: request.requestID,
        code: "invalid_parameters",
        message: error.localizedDescription,
        commandID: commandID.rawValue,
        risk: descriptor.risk,
        reason: "The request could not be decoded."
      )
    }

    let state = ProjectCommandState(
      openProjectIDs: Set(workspace.projects.map(\.id)),
      activeProjectID: workspace.activeProjectID
    )
    let preflight = registry.preflight(command, state: state)
    guard preflight.availability.isAvailable else {
      let reason = preflight.availability.reason ?? "The command is not available."
      return failure(
        requestID: request.requestID,
        code: "unavailable",
        message: reason,
        commandID: commandID.rawValue,
        risk: descriptor.risk,
        reason: reason
      )
    }

    let explicitlyConfirmedByCLI = request.source == .cli && request.confirmed
    if registry.requiresApproval(for: commandID),
      !explicitlyConfirmedByCLI,
      !approvalHandler.approve(
        commandID: commandID,
        title: descriptor.title,
        risk: descriptor.risk,
        reason:
          "The request came through the local \(request.source.rawValue.uppercased()) adapter."
      )
    {
      return failure(
        requestID: request.requestID,
        code: "approval_denied",
        message: "The command was denied by the GUI approval gate.",
        commandID: commandID.rawValue,
        risk: descriptor.risk,
        reason: "GUI approval is required for this command risk."
      )
    }

    do {
      let result = try execute(command)
      return CommandIPCResponse.success(
        requestID: request.requestID,
        result: encode(result: result)
      )
    } catch let error as CommandError {
      return commandErrorResponse(
        requestID: request.requestID,
        commandID: commandID,
        descriptor: descriptor,
        error: error
      )
    } catch {
      return failure(
        requestID: request.requestID,
        code: "internal",
        message: error.localizedDescription,
        commandID: commandID.rawValue,
        risk: descriptor.risk,
        reason: "The GUI command dispatcher failed while executing the command."
      )
    }
  }

  private func listResult(source: CommandIPCSource) -> CommandJSONValue {
    let commands = registry.descriptors.compactMap { descriptor -> CommandJSONValue? in
      guard source != .mcp || descriptor.aiAvailable else {
        return nil
      }
      return .object([
        "id": .string(descriptor.id.rawValue),
        "name": .string(descriptor.id.rawValue),
        "title": .string(descriptor.title),
        "description": .string(descriptor.title),
        "risk": .string(descriptor.risk.rawValue),
        "aiAvailable": .bool(descriptor.aiAvailable),
        "inputSchema": ClairCommandCodec.schema(for: descriptor.id),
      ])
    }
    return .object([
      "protocolVersion": .string("1"),
      "commands": .array(commands),
    ])
  }

  private func execute(_ command: ClairCommand) throws -> ClairCommandResult {
    switch command {
    case .openProject, .switchProject, .renameProject, .setProjectColor, .reorderProject,
      .closeProject, .gitRefresh, .gitShowDiff, .gitStage, .gitUnstage, .gitCommit,
      .gitSwitchBranch:
      return try workspaceResult(workspace.execute(command))
    case .navigationOpenFile(let input):
      return try openFile(input)
    case .navigationQuickOpen(let input):
      let surface = try surface(for: input.projectID)
      return .adapter(
        .quickOpen(
          projectID: input.projectID,
          query: input.query,
          items: Array(surface.quickOpenItems(matching: input.query).prefix(200))
        )
      )
    case .navigationSearch(let input):
      let surface = try surface(for: input.projectID)
      surface.search(query: input.query)
      return .adapter(
        .search(
          projectID: input.projectID,
          query: input.query,
          matches: Array(surface.searchResults.prefix(200))
        )
      )
    case .editorSave(let input):
      let surface = try surface(for: input.projectID)
      let tab = try editorTab(on: surface, tabID: input.tabID)
      do {
        try tab.save()
      } catch let error as ProjectEditorError {
        throw CommandError.editor(error)
      }
      return .adapter(.status("Saved \(tab.url.path)."))
    case .editorUndo(let input):
      let surface = try surface(for: input.projectID)
      let tab = try editorTab(on: surface, tabID: input.tabID)
      tab.undo()
      return .adapter(.status("Undid the latest change in \(tab.url.path)."))
    case .editorRedo(let input):
      let surface = try surface(for: input.projectID)
      let tab = try editorTab(on: surface, tabID: input.tabID)
      tab.redo()
      return .adapter(.status("Redid the latest change in \(tab.url.path)."))
    case .paneSplit(let input):
      let surface = try surface(for: input.projectID)
      surface.splitFocusedPane(orientation: input.orientation)
      return .adapter(
        .pane(
          projectID: input.projectID,
          focusedPaneID: surface.focusedPaneID,
          paneCount: surface.paneIDs.count
        )
      )
    case .paneFocus(let input):
      let surface = try surface(for: input.projectID)
      guard surface.paneIDs.contains(input.paneID) else {
        throw CommandError.adapter("The requested pane does not exist.")
      }
      surface.focusPane(id: input.paneID)
      return .adapter(
        .pane(
          projectID: input.projectID, focusedPaneID: surface.focusedPaneID,
          paneCount: surface.paneIDs.count))
    case .paneMoveTab(let input):
      let surface = try surface(for: input.projectID)
      guard surface.paneIDs.contains(input.paneID) else {
        throw CommandError.adapter("The requested pane does not exist.")
      }
      surface.moveActiveTab(to: input.paneID)
      return .adapter(
        .pane(
          projectID: input.projectID, focusedPaneID: surface.focusedPaneID,
          paneCount: surface.paneIDs.count))
    case .paneClose(let input):
      let surface = try surface(for: input.projectID)
      guard surface.paneIDs.contains(input.paneID) else {
        throw CommandError.adapter("The requested pane does not exist.")
      }
      surface.closePane(id: input.paneID)
      return .adapter(
        .pane(
          projectID: input.projectID, focusedPaneID: surface.focusedPaneID,
          paneCount: surface.paneIDs.count))
    case .paneToggleMaximize(let input):
      let surface = try surface(for: input.projectID)
      surface.toggleMaximizeFocusedPane()
      return .adapter(
        .pane(
          projectID: input.projectID, focusedPaneID: surface.focusedPaneID,
          paneCount: surface.paneIDs.count))
    case .paneEqualize(let input):
      let surface = try surface(for: input.projectID)
      surface.equalizeSplits()
      return .adapter(
        .pane(
          projectID: input.projectID, focusedPaneID: surface.focusedPaneID,
          paneCount: surface.paneIDs.count))
    case .terminalOpen(let input):
      let surface = try surface(for: input.projectID)
      guard let tabID = surface.openNewTerminal() else {
        throw CommandError.adapter("Clair could not open a terminal in the active pane.")
      }
      return .adapter(.terminal(projectID: input.projectID, tabID: tabID))
    case .terminalStop(let input):
      let surface = try surface(for: input.projectID)
      let tabID = input.tabID ?? surface.activeTabID
      guard let tabID, surface.terminalSession(tabID: tabID) != nil else {
        throw CommandError.adapter("No terminal tab is available to stop.")
      }
      surface.closeTab(id: tabID)
      return .adapter(.terminal(projectID: input.projectID, tabID: tabID))
    case .terminalRecover(let input):
      let surface = try surface(for: input.projectID)
      let tabID = input.tabID ?? surface.activeTabID
      guard let tabID,
        surface.tabStore.contains(where: {
          $0.id == tabID && $0.kind == .terminal
        })
      else {
        throw CommandError.adapter("No terminal tab is available to recover.")
      }
      surface.recoverTerminal(tabID: tabID)
      return .adapter(.terminal(projectID: input.projectID, tabID: tabID))
    case .agentList(let input):
      guard let agentWorkflow else {
        throw CommandError.adapter("Agent workflow is unavailable.")
      }
      return .adapter(.agents(agentWorkflow.controlSnapshots(for: input.projectID)))
    case .agentStatus(let input):
      return .adapter(.agentStatus(try agentSnapshot(sessionID: input.sessionID)))
    case .agentLaunch(let input):
      return try launchAgent(input)
    case .agentReveal(let input):
      guard let agentWorkflow else {
        throw CommandError.adapter("Agent workflow is unavailable.")
      }
      guard
        let session = agentWorkflow.sessions.first(where: {
          $0.id == input.sessionID && $0.projectID == input.projectID
        })
      else {
        throw CommandError.adapter("The requested agent session was not found.")
      }
      workspace.revealTerminal(projectID: input.projectID, tabID: session.terminalTabID)
      return .adapter(.status("Revealed agent session \(input.sessionID.uuidString)."))
    case .agentInput(let input):
      guard let agentWorkflow else {
        throw CommandError.adapter("Agent workflow is unavailable.")
      }
      do {
        return .adapter(
          .agentControl(
            try agentWorkflow.sendInput(
              sessionID: input.sessionID,
              data: Data(input.text.utf8)
            )
          )
        )
      } catch let error as AgentControlError {
        throw CommandError.agent(error)
      }
    case .agentInterrupt(let input):
      guard let agentWorkflow else {
        throw CommandError.adapter("Agent workflow is unavailable.")
      }
      do {
        return .adapter(.agentControl(try agentWorkflow.interrupt(sessionID: input.sessionID)))
      } catch let error as AgentControlError {
        throw CommandError.agent(error)
      }
    case .agentStop(let input):
      guard let agentWorkflow else {
        throw CommandError.adapter("Agent workflow is unavailable.")
      }
      do {
        return .adapter(.agentControl(try agentWorkflow.stop(sessionID: input.sessionID)))
      } catch let error as AgentControlError {
        throw CommandError.agent(error)
      }
    case .worktreeList(let input):
      let project = try project(for: input.projectID)
      guard let worktreeCoordinator else {
        throw CommandError.adapter("Managed worktrees are unavailable.")
      }
      worktreeCoordinator.refresh(project: project)
      return .adapter(
        .worktrees(
          projectID: input.projectID,
          worktrees: Array(worktreeCoordinator.worktrees(for: input.projectID).prefix(100))))
    case .worktreeCreate(let input):
      let project = try project(for: input.projectID)
      guard let worktreeCoordinator,
        let worktree = worktreeCoordinator.create(
          project: project, branch: input.branch, baseRevision: input.baseRevision,
          targetName: input.targetName)
      else {
        throw CommandError.adapter("Clair could not create the managed worktree.")
      }
      return .adapter(.worktrees(projectID: input.projectID, worktrees: [worktree]))
    case .worktreePrepareCleanup(let input):
      let project = try project(for: input.projectID)
      let surface = try surface(for: input.projectID)
      guard let worktreeCoordinator else {
        throw CommandError.adapter("Managed worktrees are unavailable.")
      }
      let activeSessions = surface.sessionIDsInUse(for: input.worktreeID)
        .union(agentWorkflow?.activeSessionIDs(for: input.worktreeID) ?? [])
      guard
        let plan = worktreeCoordinator.prepareCleanup(
          project: project,
          worktreeID: input.worktreeID,
          activeSessionIDs: activeSessions
        )
      else {
        throw CommandError.adapter("Clair could not prepare managed worktree cleanup.")
      }
      return .adapter(.cleanupPlan(plan))
    case .gitReview(let input):
      let project = try project(for: input.projectID)
      let worktree = try worktree(for: project, id: input.worktreeID)
      let service = reviewService(for: project, worktree: worktree)
      do {
        return .adapter(.review(try service.review()))
      } catch let error as ProjectBranchReviewError {
        throw CommandError.review(error)
      }
    case .gitPrepareAdoption(let input):
      let project = try project(for: input.projectID)
      let worktree = try worktree(for: project, id: input.worktreeID)
      let service = reviewService(for: project, worktree: worktree)
      do {
        let plan = try service.prepareAdoption()
        adoptionPlans[plan.confirmationID] = (service, plan)
        return .adapter(.adoptionPlan(plan))
      } catch let error as ProjectBranchReviewError {
        throw CommandError.review(error)
      }
    case .gitAdopt(let input):
      guard let pending = adoptionPlans[input.confirmationID],
        pending.plan.review.projectID == input.projectID,
        pending.plan.review.sourceWorktreeID == input.worktreeID
      else {
        throw CommandError.review(.confirmationRequired(input.confirmationID))
      }
      do {
        let result = try pending.service.adopt(pending.plan)
        adoptionPlans[input.confirmationID] = nil
        return .adapter(.adoption(result))
      } catch let error as ProjectBranchReviewError {
        throw CommandError.review(error)
      }
    case .notificationList(let input):
      guard let agentWorkflow else {
        throw CommandError.adapter("Notifications are unavailable.")
      }
      let activities = agentWorkflow.activities(for: input.projectID).filter { activity in
        input.sessionID == nil || activity.sessionID == input.sessionID
      }
      return .adapter(
        .notifications(projectID: input.projectID, activities: Array(activities.suffix(200))))
    case .notificationSetMute(let input):
      guard let agentWorkflow else {
        throw CommandError.adapter("Notifications are unavailable.")
      }
      agentWorkflow.setMuted(input.muted, projectID: input.projectID, sessionID: input.sessionID)
      return .adapter(.status("Notifications are now \(input.muted ? "muted" : "unmuted")."))
    }
  }

  private func openFile(_ input: NavigationOpenFileCommand) throws -> ClairCommandResult {
    let inputURL = URL(
      fileURLWithPath: input.path,
      relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ).standardizedFileURL
    let fileURL =
      FileManager.default.fileExists(atPath: inputURL.path)
      ? inputURL.resolvingSymlinksInPath().standardizedFileURL
      : inputURL

    let project: Project
    if let routedProject = CommandProjectRouter.longestPrefixProject(
      path: fileURL,
      projects: workspace.projects
    ) {
      project = routedProject
    } else {
      var isDirectory = ObjCBool(false)
      let rootURL =
        FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
          && isDirectory.boolValue
        ? fileURL
        : fileURL.deletingLastPathComponent()
      switch workspace.execute(.openProject(OpenProjectCommand(rootURL: rootURL))) {
      case .success(.project(let openedProject)):
        project = openedProject
      case .success:
        throw CommandError.adapter("The Project opened, but Clair returned no Project identity.")
      case .failure(let error):
        throw error
      }
    }

    let surface = try surface(for: project.id)
    guard let node = surface.fileTree.node(withID: fileURL.path), !node.isDirectory else {
      throw CommandError.navigation(.invalidPath(fileURL.path))
    }
    surface.reveal(nodeID: node.id)
    if let line = input.line, let document = surface.editorDocument(tabID: node.id) {
      document.requestSelection(line: line, column: input.column ?? 1, length: 0)
    }
    return .adapter(
      .openedFile(
        projectID: project.id,
        filePath: fileURL.path,
        line: input.line,
        column: input.column
      )
    )
  }

  private func launchAgent(_ input: LaunchAgentCommand) throws -> ClairCommandResult {
    guard let agentWorkflow else {
      throw CommandError.adapter("Agent workflow is unavailable.")
    }
    guard let profile = AgentLaunchProfile(rawValue: input.profileID) else {
      throw CommandError.adapter("Unknown agent profile: \(input.profileID)")
    }
    let project = try project(for: input.projectID)
    let surface = try surface(for: input.projectID)
    var worktree: ManagedWorktree?
    if let worktreeID = input.worktreeID {
      guard let worktreeCoordinator,
        let resolved = worktreeCoordinator.availableWorktree(project: project, id: worktreeID)
      else {
        throw CommandError.adapter("The managed worktree is not available for agent launch.")
      }
      worktree = resolved
    }
    guard
      let session = agentWorkflow.launch(
        profile: profile,
        modelID: input.modelID,
        projectID: project.id,
        projectRoot: project.rootURL,
        surface: surface,
        worktree: worktree
      )
    else {
      throw CommandError.adapter("Clair could not launch the requested agent.")
    }
    return .adapter(.agent(session))
  }

  private func agentSnapshot(sessionID: UUID) throws -> AgentControlSnapshot {
    guard let agentWorkflow else {
      throw CommandError.adapter("Agent workflow is unavailable.")
    }
    guard let snapshot = agentWorkflow.controlSnapshot(sessionID: sessionID) else {
      throw CommandError.agent(.sessionNotFound(sessionID))
    }
    return snapshot
  }

  private func project(for projectID: UUID) throws -> Project {
    guard let project = workspace.projects.first(where: { $0.id == projectID }) else {
      throw CommandError.project(.projectNotOpen(projectID))
    }
    return project
  }

  private func surface(for projectID: UUID) throws -> ProjectSurfaceModel {
    _ = try project(for: projectID)
    if workspace.activeProjectID != projectID {
      _ = try workspaceResult(
        workspace.execute(.switchProject(SwitchProjectCommand(projectID: projectID)))
      )
    }
    guard let surface = workspace.activeSurface, surface.projectID == projectID else {
      throw CommandError.project(.projectNotOpen(projectID))
    }
    return surface
  }

  private func editorTab(
    on surface: ProjectSurfaceModel,
    tabID: String?
  ) throws -> ProjectEditorTab {
    let resolvedTabID = tabID ?? surface.activeTabID
    guard let resolvedTabID, let tab = surface.editorDocument(tabID: resolvedTabID) else {
      throw CommandError.adapter("No editor tab is available.")
    }
    return tab
  }

  private func worktree(for project: Project, id: WorktreeID) throws -> ManagedWorktree {
    guard let worktreeCoordinator else {
      throw CommandError.adapter("Managed worktrees are unavailable.")
    }
    worktreeCoordinator.refresh(project: project)
    guard
      let worktree = worktreeCoordinator.worktrees(for: project.id).first(where: { $0.id == id })
    else {
      throw CommandError.worktree(.worktreeNotFound(id))
    }
    return worktree
  }

  private func reviewService(
    for project: Project,
    worktree: ManagedWorktree
  ) -> ProjectBranchReviewService {
    let key = "\(project.id.uuidString):\(worktree.id.uuidString)"
    if let service = reviewServices[key] {
      return service
    }
    let service = ProjectBranchReviewService(source: worktree, targetRootURL: project.rootURL)
    reviewServices[key] = service
    return service
  }

  private func workspaceResult(
    _ result: Result<ClairCommandResult, CommandError>
  ) throws -> ClairCommandResult {
    switch result {
    case .success(let result):
      return result
    case .failure(let error):
      throw error
    }
  }

  private func commandErrorResponse(
    requestID: String,
    commandID: ClairCommandID,
    descriptor: CommandDescriptor,
    error: CommandError
  ) -> CommandIPCResponse {
    let code: String
    let reason: String
    switch error {
    case .unavailable(_, let message):
      code = "unavailable"
      reason = message
    case .project, .git, .navigation, .editor, .worktree, .review, .agent:
      code = "execution_failed"
      reason = "The typed command reached the GUI but could not complete."
    case .adapter(let message):
      code = "execution_failed"
      reason = message
    }
    return failure(
      requestID: requestID,
      code: code,
      message: error.localizedDescription,
      commandID: commandID.rawValue,
      risk: descriptor.risk,
      reason: reason
    )
  }

  private func failure(
    requestID: String,
    code: String,
    message: String,
    commandID: String?,
    risk: CommandRisk?,
    reason: String?
  ) -> CommandIPCResponse {
    CommandIPCResponse.failure(
      requestID: requestID,
      error: CommandIPCError(
        code: code,
        message: message,
        commandID: commandID,
        risk: risk?.rawValue,
        reason: reason
      )
    )
  }

  private func encode(result: ClairCommandResult) -> CommandJSONValue {
    switch result {
    case .project(let project):
      return .object([
        "kind": .string("project"),
        "id": .string(project.id.uuidString),
        "rootPath": .string(project.rootURL.path),
        "name": .string(project.name),
        "color": .string(project.color.rawValue),
        "availability": .string(project.availability.rawValue),
      ])
    case .gitStatus(let snapshot):
      return encode(snapshot: snapshot)
    case .gitDiff(let diff):
      return .object([
        "kind": .string("gitDiff"),
        "path": .string(diff.change.path),
        "basis": .string(diff.basis.rawValue),
        "text": .string(String(diff.text.prefix(64 * 1024))),
      ])
    case .adapter(let result):
      return encode(adapterResult: result)
    case .none:
      return .object(["kind": .string("none")])
    }
  }

  private func encode(adapterResult result: CommandAdapterResult) -> CommandJSONValue {
    switch result {
    case .openedFile(let projectID, let filePath, let line, let column):
      return .object([
        "kind": .string("openedFile"),
        "projectID": .string(projectID.uuidString),
        "filePath": .string(filePath),
        "line": line.map { .number(Double($0)) } ?? .null,
        "column": column.map { .number(Double($0)) } ?? .null,
      ])
    case .quickOpen(let projectID, let query, let items):
      return .object([
        "kind": .string("quickOpen"),
        "projectID": .string(projectID.uuidString),
        "query": .string(query),
        "items": .array(
          items.map { item in
            .object([
              "id": .string(item.id),
              "filePath": .string(item.filePath),
              "relativePath": .string(item.relativePath),
              "title": .string(item.title),
            ])
          }),
      ])
    case .search(let projectID, let query, let matches):
      return .object([
        "kind": .string("search"),
        "projectID": .string(projectID.uuidString),
        "query": .string(query),
        "matches": .array(matches.map(encode(match:))),
      ])
    case .pane(let projectID, let focusedPaneID, let paneCount):
      return .object([
        "kind": .string("pane"),
        "projectID": .string(projectID.uuidString),
        "focusedPaneID": .string(focusedPaneID.uuidString),
        "paneCount": .number(Double(paneCount)),
      ])
    case .terminal(let projectID, let tabID):
      return .object([
        "kind": .string("terminal"),
        "projectID": .string(projectID.uuidString),
        "tabID": tabID.map(CommandJSONValue.string) ?? .null,
      ])
    case .agent(let session):
      return encode(
        agent: AgentControlSnapshot(session: session, lastActivity: nil)
      )
    case .agents(let agents):
      return .object([
        "kind": .string("agents"),
        "agents": .array(agents.map { encode(agent: $0) }),
        "profiles": .array(AgentLaunchProfile.all.map(encode(profile:))),
      ])
    case .agentStatus(let agent):
      return encode(agent: agent)
    case .agentControl(let receipt):
      return .object([
        "kind": .string("agentControl"),
        "operation": .string(receipt.operation.rawValue),
        "sessionID": .string(receipt.sessionID.uuidString),
        "accepted": .bool(receipt.accepted),
      ])
    case .worktrees(let projectID, let worktrees):
      return .object([
        "kind": .string("worktrees"),
        "projectID": .string(projectID.uuidString),
        "worktrees": .array(worktrees.map(encode(worktree:))),
      ])
    case .cleanupPlan(let plan):
      return .object([
        "kind": .string("cleanupPlan"),
        "confirmationID": .string(plan.confirmationID.uuidString),
        "worktreeID": .string(plan.worktreeID.uuidString),
        "rootPath": .string(plan.rootURL.path),
        "branch": .string(plan.branch),
        "state": .string(plan.state.rawValue),
        "expectedHeadRevision": plan.expectedHeadRevision.map(CommandJSONValue.string) ?? .null,
        "blockers": .array(plan.blockers.map { .string($0.rawValue) }),
        "canConfirm": .bool(plan.canConfirm),
      ])
    case .review(let review):
      return encode(review: review)
    case .adoptionPlan(let plan):
      return .object([
        "kind": .string("adoptionPlan"),
        "confirmationID": .string(plan.confirmationID.uuidString),
        "projectID": .string(plan.review.projectID.uuidString),
        "worktreeID": .string(plan.review.sourceWorktreeID.uuidString),
        "targetRootPath": .string(plan.targetRootURL.path),
        "targetBranch": plan.targetBranch.map(CommandJSONValue.string) ?? .null,
        "targetHeadRevision": .string(plan.targetHeadRevision),
        "blockers": .array(plan.blockers.map { .string($0.rawValue) }),
        "canAdopt": .bool(plan.canAdopt),
      ])
    case .adoption(let result):
      switch result {
      case .adopted(let mergeRevision):
        return .object([
          "kind": .string("adopted"),
          "mergeRevision": .string(mergeRevision),
        ])
      case .conflict(let conflict):
        return .object([
          "kind": .string("conflict"),
          "sourceWorktreeID": .string(conflict.sourceWorktreeID.uuidString),
          "sourceBranch": .string(conflict.sourceBranch),
          "targetBranch": .string(conflict.targetBranch),
          "targetRootPath": .string(conflict.targetRootURL.path),
          "paths": .array(conflict.paths.map(CommandJSONValue.string)),
          "commandMessage": .string(conflict.commandMessage),
        ])
      }
    case .notifications(let projectID, let activities):
      return .object([
        "kind": .string("notifications"),
        "projectID": .string(projectID.uuidString),
        "activities": .array(activities.map(encode(activity:))),
      ])
    case .status(let message):
      return .object([
        "kind": .string("status"),
        "message": .string(message),
      ])
    }
  }

  private func encode(match: ProjectSearchMatch) -> CommandJSONValue {
    .object([
      "id": .string(match.id),
      "filePath": .string(match.filePath),
      "relativePath": .string(match.relativePath),
      "line": .number(Double(match.line)),
      "column": .number(Double(match.column)),
      "lineText": .string(match.lineText),
      "matchLength": .number(Double(match.matchLength)),
    ])
  }

  private func encode(snapshot: ProjectGitSnapshot) -> CommandJSONValue {
    .object([
      "kind": .string("gitStatus"),
      "availability": .string(snapshot.isRepository ? "available" : "notRepository"),
      "branch": snapshot.branch.map(CommandJSONValue.string) ?? .null,
      "upstream": snapshot.upstream.map(CommandJSONValue.string) ?? .null,
      "ahead": .number(Double(snapshot.ahead)),
      "behind": .number(Double(snapshot.behind)),
      "branches": .array(snapshot.branches.map(CommandJSONValue.string)),
      "changes": .array(
        snapshot.changes.map { change in
          .object([
            "id": .string(change.id),
            "path": .string(change.path),
            "originalPath": change.originalPath.map(CommandJSONValue.string) ?? .null,
            "kind": .string(change.kind.rawValue),
            "indexStatus": .string(String(change.indexStatus)),
            "worktreeStatus": .string(String(change.worktreeStatus)),
          ])
        }),
      "message": snapshot.message.map(CommandJSONValue.string) ?? .null,
    ])
  }

  private func encode(worktree: ManagedWorktree) -> CommandJSONValue {
    .object([
      "id": .string(worktree.id.uuidString),
      "projectID": .string(worktree.projectID.uuidString),
      "repositoryRootPath": .string(worktree.repositoryRootURL.path),
      "rootPath": .string(worktree.rootURL.path),
      "branch": .string(worktree.branch),
      "baseRevision": .string(worktree.baseRevision),
      "createdAt": .string(ISO8601DateFormatter().string(from: worktree.createdAt)),
      "state": .string(worktree.state.rawValue),
      "headRevision": worktree.headRevision.map(CommandJSONValue.string) ?? .null,
      "currentBranch": worktree.currentBranch.map(CommandJSONValue.string) ?? .null,
      "isDirty": .bool(worktree.isDirty),
    ])
  }

  private func encode(review: ProjectBranchReviewSnapshot) -> CommandJSONValue {
    .object([
      "kind": .string("review"),
      "projectID": .string(review.projectID.uuidString),
      "sourceWorktreeID": .string(review.sourceWorktreeID.uuidString),
      "repositoryRootPath": .string(review.repositoryRootURL.path),
      "sourceRootPath": .string(review.sourceRootURL.path),
      "expectedSourceBranch": .string(review.expectedSourceBranch),
      "sourceBranch": review.sourceBranch.map(CommandJSONValue.string) ?? .null,
      "baseRevision": .string(review.baseRevision),
      "headRevision": .string(review.headRevision),
      "commits": .array(
        review.commits.map { commit in
          .object([
            "revision": .string(commit.revision),
            "author": .string(commit.author),
            "authoredAt": .string(commit.authoredAt),
            "subject": .string(commit.subject),
          ])
        }),
      "committedChanges": .array(
        review.committedChanges.map { change in
          .object([
            "path": .string(change.path),
            "originalPath": change.originalPath.map(CommandJSONValue.string) ?? .null,
            "kind": .string(change.kind.rawValue),
          ])
        }),
      "committedDiff": .string(String(review.committedDiff.prefix(64 * 1024))),
      "sourceStatus": encode(snapshot: review.sourceStatus),
      "targetStatus": encode(snapshot: review.targetStatus),
      "targetHeadRevision": .string(review.targetHeadRevision),
    ])
  }

  private func encode(activity: AgentActivity) -> CommandJSONValue {
    .object([
      "id": .string(activity.id.uuidString),
      "projectID": .string(activity.projectID.uuidString),
      "sessionID": activity.sessionID.map { .string($0.uuidString) } ?? .null,
      "source": .string(activity.source.rawValue),
      "kind": .string(activity.kind.rawValue),
      "occurredAt": .string(ISO8601DateFormatter().string(from: activity.occurredAt)),
      "summary": activity.summary.map(CommandJSONValue.string) ?? .null,
      "exitStatus": activity.exitStatus.map { .number(Double($0)) } ?? .null,
    ])
  }

  private func encode(agent: AgentControlSnapshot) -> CommandJSONValue {
    .object([
      "kind": .string("agent"),
      "id": .string(agent.id.uuidString),
      "sessionID": .string(agent.id.uuidString),
      "projectID": .string(agent.projectID.uuidString),
      "profileID": .string(agent.profileID),
      "modelID": agent.modelID.map(CommandJSONValue.string) ?? .null,
      "title": .string(agent.title),
      "projectRoot": .string(agent.projectRoot.path),
      "cwd": .string(agent.projectRoot.path),
      "terminalTabID": .string(agent.terminalTabID),
      "worktreeID": agent.worktreeID.map { .string($0.uuidString) } ?? .null,
      "lifecycle": .string(lifecycleStateDescription(agent.lifecycle)),
      "state": .string(agent.state.rawValue),
      "attention": .bool(agent.state == .attention),
      "startedAt": .string(ISO8601DateFormatter().string(from: agent.startedAt)),
      "finishedAt": agent.finishedAt.map {
        .string(ISO8601DateFormatter().string(from: $0))
      } ?? .null,
      "exitCode": agent.lifecycle.exitCode.map { .number(Double($0)) } ?? .null,
      "capabilities": .array(
        mobileCapabilities(for: agent)
      ),
      "controlCapabilities": .array(
        agent.capabilities
          .sorted { $0.rawValue < $1.rawValue }
          .map { .string($0.rawValue) }
      ),
      "lastActivity": agent.lastActivity.map(encode(activity:)) ?? .null,
      "lastActivityAt": agent.lastActivity.map {
        .string(ISO8601DateFormatter().string(from: $0.occurredAt))
      } ?? .null,
    ])
  }

  private func mobileCapabilities(for agent: AgentControlSnapshot) -> [CommandJSONValue] {
    var capabilities: Set<String> = ["agent_catalog", "agent_status"]
    if agent.capabilities.contains(.terminalInput) {
      capabilities.insert("terminal_input")
    }
    if agent.capabilities.contains(.interrupt) {
      capabilities.insert("terminal_interrupt")
    }
    if agent.capabilities.contains(.terminate) {
      capabilities.insert("agent_control")
    }
    return capabilities.sorted().map(CommandJSONValue.string)
  }

  private func encode(profile: AgentLaunchProfile) -> CommandJSONValue {
    .object([
      "id": .string(profile.stableID),
      "title": .string(profile.displayName),
      "executable": .string(profile.executable),
      "models": .array(profile.suggestedModels.map { model in
        .object([
          "id": .string(model.id),
          "title": .string(model.title),
        ])
      }),
      "capabilities": .array([.string("agent_launch")]),
    ])
  }

  private func lifecycleStateDescription(_ lifecycle: AgentSessionLifecycle) -> String {
    switch lifecycle {
    case .starting:
      "starting"
    case .running:
      "running"
    case .exited:
      "exited"
    }
  }

}

enum CommandProjectRouter {
  static func longestPrefixProject(path: URL, projects: [Project]) -> Project? {
    let canonicalPath = canonical(path).path
    return
      projects
      .filter { isWithin(canonicalPath, rootPath: canonical($0.rootURL).path) }
      .max { lhs, rhs in
        canonical(lhs.rootURL).path.count < canonical(rhs.rootURL).path.count
      }
  }

  private static func canonical(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
  }

  private static func isWithin(_ path: String, rootPath: String) -> Bool {
    if rootPath == "/" {
      return path.hasPrefix("/")
    }
    return path == rootPath || path.hasPrefix(rootPath + "/")
  }
}
