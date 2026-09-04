import Foundation

enum AgentActivitySource: String, Codable, CaseIterable, Sendable {
  case bell
  case exit
  case officialHook = "official-hook"

  static var terminalBell: Self { .bell }

  static var processExit: Self { .exit }

  var displayName: String {
    switch self {
    case .bell:
      "ベル"
    case .exit:
      "終了"
    case .officialHook:
      "公式フック"
    }
  }
}

enum AgentActivityKind: String, Codable, CaseIterable, Sendable {
  case attention
  case started
  case completed
  case failed
  case notification
  case unknown

  var displayName: String {
    switch self {
    case .attention:
      "注意"
    case .started:
      "開始"
    case .completed:
      "完了"
    case .failed:
      "失敗"
    case .notification:
      "通知"
    case .unknown:
      "不明"
    }
  }
}

struct AgentActivityScope: Codable, Equatable, Hashable, Sendable {
  let projectID: UUID
  let sessionID: UUID?

  init(projectID: UUID, sessionID: UUID? = nil) {
    self.projectID = projectID
    self.sessionID = sessionID
  }

  var isProjectScoped: Bool {
    sessionID == nil
  }

  var isSessionScoped: Bool {
    sessionID != nil
  }
}

struct AgentActivity: Identifiable, Codable, Equatable, Sendable {
  static let maxSummaryUTF8Bytes = 512

  let id: UUID
  let projectID: UUID
  let sessionID: UUID?
  let source: AgentActivitySource
  let kind: AgentActivityKind
  let occurredAt: Date
  let summary: String?
  let exitStatus: Int?

  init(
    id: UUID = UUID(),
    projectID: UUID,
    sessionID: UUID? = nil,
    source: AgentActivitySource,
    kind: AgentActivityKind,
    occurredAt: Date = Date(),
    summary: String? = nil,
    exitStatus: Int? = nil
  ) {
    self.id = id
    self.projectID = projectID
    self.sessionID = sessionID
    self.source = source
    self.kind = kind
    self.occurredAt = occurredAt
    self.summary = AgentActivityText.sanitized(
      summary,
      maximumBytes: Self.maxSummaryUTF8Bytes
    )
    self.exitStatus = exitStatus
  }

  var scope: AgentActivityScope {
    AgentActivityScope(projectID: projectID, sessionID: sessionID)
  }

  var isProjectScoped: Bool {
    sessionID == nil
  }

  var isSessionScoped: Bool {
    sessionID != nil
  }

  var shouldNotify: Bool {
    switch source {
    case .bell, .exit:
      true
    case .officialHook:
      switch kind {
      case .attention, .notification, .completed, .failed:
        true
      case .started, .unknown:
        false
      }
    }
  }

  static func bell(
    id: UUID = UUID(),
    projectID: UUID,
    sessionID: UUID? = nil,
    occurredAt: Date = Date(),
    summary: String? = nil
  ) -> Self {
    Self(
      id: id,
      projectID: projectID,
      sessionID: sessionID,
      source: .bell,
      kind: .attention,
      occurredAt: occurredAt,
      summary: summary
    )
  }

  static func exit(
    id: UUID = UUID(),
    projectID: UUID,
    sessionID: UUID? = nil,
    status: Int,
    occurredAt: Date = Date(),
    summary: String? = nil
  ) -> Self {
    Self(
      id: id,
      projectID: projectID,
      sessionID: sessionID,
      source: .exit,
      kind: status == 0 ? .completed : .failed,
      occurredAt: occurredAt,
      summary: summary,
      exitStatus: status
    )
  }

  static func officialHook(
    id: UUID = UUID(),
    projectID: UUID,
    sessionID: UUID? = nil,
    kind: AgentActivityKind,
    occurredAt: Date = Date(),
    summary: String? = nil
  ) -> Self {
    Self(
      id: id,
      projectID: projectID,
      sessionID: sessionID,
      source: .officialHook,
      kind: kind,
      occurredAt: occurredAt,
      summary: summary
    )
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case projectID
    case sessionID
    case source
    case kind
    case occurredAt
    case summary
    case exitStatus
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    projectID = try container.decode(UUID.self, forKey: .projectID)
    sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
    source = try container.decode(AgentActivitySource.self, forKey: .source)
    kind = try container.decode(AgentActivityKind.self, forKey: .kind)
    occurredAt = try container.decode(Date.self, forKey: .occurredAt)
    summary = AgentActivityText.sanitized(
      try container.decodeIfPresent(String.self, forKey: .summary),
      maximumBytes: Self.maxSummaryUTF8Bytes
    )
    exitStatus = try container.decodeIfPresent(Int.self, forKey: .exitStatus)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(projectID, forKey: .projectID)
    try container.encodeIfPresent(sessionID, forKey: .sessionID)
    try container.encode(source, forKey: .source)
    try container.encode(kind, forKey: .kind)
    try container.encode(occurredAt, forKey: .occurredAt)
    try container.encodeIfPresent(
      AgentActivityText.sanitized(summary, maximumBytes: Self.maxSummaryUTF8Bytes),
      forKey: .summary
    )
    try container.encodeIfPresent(exitStatus, forKey: .exitStatus)
  }
}

enum AgentActivityText {
  static func sanitized(_ text: String?, maximumBytes: Int) -> String? {
    guard let text, !text.isEmpty else {
      return nil
    }
    let normalized = normalized(text)
    guard !normalized.isEmpty, !looksSensitive(normalized) else {
      return nil
    }
    return bounded(normalized, maximumBytes: maximumBytes)
  }

  static func bounded(_ text: String, maximumBytes: Int) -> String? {
    let limit = max(0, maximumBytes)
    guard limit > 0 else {
      return nil
    }

    let data = Data(text.utf8)
    guard data.count > limit else {
      return text
    }

    var bytes = Array(data.prefix(limit))
    while !bytes.isEmpty {
      if let bounded = String(bytes: bytes, encoding: .utf8) {
        return bounded
      }
      bytes.removeLast()
    }
    return nil
  }

  static func looksSensitive(_ text: String) -> Bool {
    let normalized = text.lowercased()
    let markers = [
      "password=", "password:", "passwd=", "passwd:",
      "api_key=", "api_key:", "api-key=", "api-key:", "apikey=", "apikey:",
      "access_token=", "access_token:", "refresh_token=", "refresh_token:",
      "client_secret=", "client_secret:", "secret=", "secret:",
      "token=", "token:", "authorization=", "authorization:",
      "bearer ", "private key", "credential=", "credential:",
      "cookie=", "cookie:", "-----begin",
    ]
    return markers.contains { normalized.contains($0) }
  }

  private static func normalized(_ text: String) -> String {
    let space = Unicode.Scalar(0x20)!
    var result = String()
    var hasPendingSpace = false

    for scalar in text.unicodeScalars {
      let value = scalar.value
      if value < 0x20 || (0x7f...0x9f).contains(value) {
        hasPendingSpace = true
        continue
      }
      if hasPendingSpace && !result.isEmpty {
        result.unicodeScalars.append(space)
      }
      hasPendingSpace = false
      result.unicodeScalars.append(scalar)
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct AgentActivityHistory: Codable, Equatable, Sendable {
  static let defaultMaximumCount = 200

  var activities: [AgentActivity]

  init(activities: [AgentActivity] = []) {
    self.activities = activities
  }

  var count: Int {
    activities.count
  }

  mutating func append(
    _ activity: AgentActivity,
    maximumCount: Int = Self.defaultMaximumCount
  ) {
    activities.append(activity)
    trim(to: maximumCount)
  }

  mutating func trim(to maximumCount: Int) {
    let limit = max(0, maximumCount)
    guard activities.count > limit else {
      return
    }
    activities = limit == 0 ? [] : Array(activities.suffix(limit))
  }

  func entries(for scope: AgentActivityScope) -> [AgentActivity] {
    activities.filter { $0.scope == scope }
  }

  func entries(forProject projectID: UUID) -> [AgentActivity] {
    activities.filter { $0.projectID == projectID }
  }

  func entries(forSession sessionID: UUID, in projectID: UUID? = nil) -> [AgentActivity] {
    activities.filter {
      $0.sessionID == sessionID && (projectID == nil || $0.projectID == projectID)
    }
  }
}

struct AgentMuteState: Codable, Equatable, Hashable, Sendable {
  let projectID: UUID
  let sessionID: UUID?
  let isMuted: Bool

  init(projectID: UUID, sessionID: UUID? = nil, isMuted: Bool = true) {
    self.projectID = projectID
    self.sessionID = sessionID
    self.isMuted = isMuted
  }

  init(projectID: UUID, sessionID: UUID? = nil, muted: Bool) {
    self.init(projectID: projectID, sessionID: sessionID, isMuted: muted)
  }

  var muted: Bool {
    isMuted
  }

  var scope: AgentActivityScope {
    AgentActivityScope(projectID: projectID, sessionID: sessionID)
  }
}

struct AgentActivityStoreSnapshot: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  var schemaVersion: Int
  var history: AgentActivityHistory
  var muteStates: [AgentMuteState]

  init(
    schemaVersion: Int = Self.currentSchemaVersion,
    history: AgentActivityHistory = AgentActivityHistory(),
    muteStates: [AgentMuteState] = []
  ) {
    self.schemaVersion = schemaVersion
    self.history = history
    self.muteStates = muteStates
  }

  static var empty: Self {
    Self()
  }

  var activities: [AgentActivity] {
    get { history.activities }
    set { history.activities = newValue }
  }

  var mutes: [AgentMuteState] {
    get { muteStates }
    set { muteStates = newValue }
  }

  func normalized(maximumActivityCount: Int) -> Self {
    var result = self
    result.history.trim(to: maximumActivityCount)

    struct MuteKey: Hashable {
      let projectID: UUID
      let sessionID: UUID?
    }

    var uniqueMutes: [MuteKey: AgentMuteState] = [:]
    for muteState in muteStates where muteState.isMuted {
      uniqueMutes[
        MuteKey(projectID: muteState.projectID, sessionID: muteState.sessionID)
      ] = muteState
    }
    result.muteStates = uniqueMutes.values.sorted {
      let left = "\($0.projectID.uuidString)|\($0.sessionID?.uuidString ?? "")"
      let right = "\($1.projectID.uuidString)|\($1.sessionID?.uuidString ?? "")"
      return left < right
    }
    return result
  }
}

struct AgentActivityLedger: Equatable, Sendable {
  var history: AgentActivityHistory
  var muteStates: [AgentMuteState]

  init(snapshot: AgentActivityStoreSnapshot = .empty) {
    self.history = snapshot.history
    self.muteStates = snapshot.muteStates
  }

  init(
    history: AgentActivityHistory = AgentActivityHistory(),
    muteStates: [AgentMuteState] = []
  ) {
    self.history = history
    self.muteStates = muteStates
  }

  var snapshot: AgentActivityStoreSnapshot {
    AgentActivityStoreSnapshot(history: history, muteStates: muteStates)
  }

  mutating func append(
    _ activity: AgentActivity, maximumActivityCount: Int = AgentActivityHistory.defaultMaximumCount
  ) {
    history.append(activity, maximumCount: maximumActivityCount)
  }

  mutating func setMuted(
    _ muted: Bool,
    projectID: UUID,
    sessionID: UUID? = nil
  ) {
    muteStates.removeAll {
      $0.projectID == projectID && $0.sessionID == sessionID
    }
    if muted {
      muteStates.append(
        AgentMuteState(projectID: projectID, sessionID: sessionID, isMuted: true)
      )
    }
  }

  func muteState(projectID: UUID, sessionID: UUID? = nil) -> AgentMuteState? {
    if let sessionID,
      let sessionState = muteStates.first(where: {
        $0.projectID == projectID && $0.sessionID == sessionID && $0.isMuted
      })
    {
      return sessionState
    }
    return muteStates.first(where: {
      $0.projectID == projectID && $0.sessionID == nil && $0.isMuted
    })
  }

  func isMuted(projectID: UUID, sessionID: UUID? = nil) -> Bool {
    muteState(projectID: projectID, sessionID: sessionID) != nil
  }

  func isMuted(for activity: AgentActivity) -> Bool {
    isMuted(projectID: activity.projectID, sessionID: activity.sessionID)
  }

  func entries(for scope: AgentActivityScope) -> [AgentActivity] {
    history.entries(for: scope)
  }
}

enum AgentActivityStoreError: Error, Equatable {
  case storeUnavailable
  case malformedStore
  case unsupportedStoreVersion(Int)
  case fileTooLarge(Int)
  case storeIO
}

struct AgentActivityStore {
  static let defaultMaximumActivityCount = AgentActivityHistory.defaultMaximumCount
  static let defaultMaximumFileBytes = 4 * 1024 * 1024

  let fileURL: URL?
  let maximumActivityCount: Int
  let maximumFileBytes: Int

  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(
    fileURL: URL?,
    maximumActivityCount: Int = Self.defaultMaximumActivityCount,
    maximumFileBytes: Int = Self.defaultMaximumFileBytes,
    fileManager: FileManager = .default
  ) {
    self.fileURL = fileURL
    self.maximumActivityCount = max(0, maximumActivityCount)
    self.maximumFileBytes = max(1, maximumFileBytes)
    self.fileManager = fileManager

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    self.encoder = encoder

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  init(
    fileURL: URL?,
    maxHistoryCount: Int,
    fileManager: FileManager = .default
  ) {
    self.init(
      fileURL: fileURL,
      maximumActivityCount: maxHistoryCount,
      fileManager: fileManager
    )
  }

  func load() throws -> AgentActivityStoreSnapshot {
    guard let fileURL else {
      throw AgentActivityStoreError.storeUnavailable
    }
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return .empty
    }

    if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
      let size = attributes[.size] as? NSNumber,
      size.intValue > maximumFileBytes
    {
      throw AgentActivityStoreError.fileTooLarge(size.intValue)
    }

    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      throw AgentActivityStoreError.storeIO
    }
    guard data.count <= maximumFileBytes else {
      throw AgentActivityStoreError.fileTooLarge(data.count)
    }

    let snapshot: AgentActivityStoreSnapshot
    do {
      snapshot = try decoder.decode(AgentActivityStoreSnapshot.self, from: data)
    } catch {
      throw AgentActivityStoreError.malformedStore
    }
    guard snapshot.schemaVersion == AgentActivityStoreSnapshot.currentSchemaVersion else {
      throw AgentActivityStoreError.unsupportedStoreVersion(snapshot.schemaVersion)
    }
    return snapshot.normalized(maximumActivityCount: maximumActivityCount)
  }

  func save(_ snapshot: AgentActivityStoreSnapshot) throws {
    guard let fileURL else {
      throw AgentActivityStoreError.storeUnavailable
    }
    guard snapshot.schemaVersion == AgentActivityStoreSnapshot.currentSchemaVersion else {
      throw AgentActivityStoreError.unsupportedStoreVersion(snapshot.schemaVersion)
    }

    let boundedSnapshot = snapshot.normalized(maximumActivityCount: maximumActivityCount)
    let data: Data
    do {
      data = try encoder.encode(boundedSnapshot)
    } catch {
      throw AgentActivityStoreError.storeIO
    }
    guard data.count <= maximumFileBytes else {
      throw AgentActivityStoreError.fileTooLarge(data.count)
    }

    do {
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: nil
      )
      try data.write(to: fileURL, options: [.atomic])
      try fileManager.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: fileURL.path
      )
    } catch {
      throw AgentActivityStoreError.storeIO
    }
  }

  @discardableResult
  func append(_ activity: AgentActivity) throws -> AgentActivityStoreSnapshot {
    var snapshot = try load()
    snapshot.history.append(activity, maximumCount: maximumActivityCount)
    try save(snapshot)
    return try load()
  }

  @discardableResult
  func setMuted(
    _ muted: Bool,
    projectID: UUID,
    sessionID: UUID? = nil
  ) throws -> AgentActivityStoreSnapshot {
    var ledger = AgentActivityLedger(snapshot: try load())
    ledger.setMuted(muted, projectID: projectID, sessionID: sessionID)
    try save(ledger.snapshot)
    return try load()
  }

  func loadLedger() throws -> AgentActivityLedger {
    AgentActivityLedger(snapshot: try load())
  }

  func save(_ ledger: AgentActivityLedger) throws {
    try save(ledger.snapshot)
  }
}

enum OfficialHookDecoderError: Error, Equatable {
  case payloadTooLarge(Int)
  case malformedJSON
  case unsupportedPayload
}

struct OfficialHookDecoder: Sendable {
  static let defaultMaximumPayloadBytes = 64 * 1024
  static let defaultMaximumSummaryBytes = AgentActivity.maxSummaryUTF8Bytes

  let maximumPayloadBytes: Int
  let maximumSummaryBytes: Int

  init(
    maximumPayloadBytes: Int = Self.defaultMaximumPayloadBytes,
    maximumSummaryBytes: Int = Self.defaultMaximumSummaryBytes
  ) {
    self.maximumPayloadBytes = max(1, maximumPayloadBytes)
    self.maximumSummaryBytes = max(1, maximumSummaryBytes)
  }

  func decode(
    _ data: Data,
    projectID: UUID,
    sessionID: UUID? = nil,
    receivedAt: Date = Date()
  ) throws -> AgentActivity? {
    guard data.count <= maximumPayloadBytes else {
      throw OfficialHookDecoderError.payloadTooLarge(data.count)
    }

    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch {
      throw OfficialHookDecoderError.malformedJSON
    }
    guard let dictionary = object as? [String: Any] else {
      throw OfficialHookDecoderError.unsupportedPayload
    }

    guard
      let eventName = string(
        in: dictionary,
        keys: [
          "hook_event_name", "event_name", "event", "type",
        ])
    else {
      return nil
    }
    guard let kind = kind(for: eventName) else {
      return nil
    }

    let candidateSummary = string(
      in: dictionary,
      keys: [
        "message", "notification", "reason", "status", "error", "description",
      ])
    let summary: String?
    if let candidateSummary {
      summary = AgentActivityText.sanitized(
        candidateSummary,
        maximumBytes: maximumSummaryBytes
      )
    } else {
      summary = AgentActivityText.sanitized(
        eventName,
        maximumBytes: maximumSummaryBytes
      )
    }

    return AgentActivity.officialHook(
      projectID: projectID,
      sessionID: sessionID,
      kind: kind,
      occurredAt: receivedAt,
      summary: summary
    )
  }

  func decode(
    data: Data,
    projectID: UUID,
    sessionID: UUID? = nil,
    receivedAt: Date = Date()
  ) throws -> AgentActivity? {
    try decode(
      data,
      projectID: projectID,
      sessionID: sessionID,
      receivedAt: receivedAt
    )
  }

  private func string(in dictionary: [String: Any], keys: [String]) -> String? {
    for key in keys {
      if let value = dictionary[key] as? String, !value.isEmpty {
        return value
      }
    }
    return nil
  }

  private func kind(for eventName: String) -> AgentActivityKind? {
    let normalized = String(
      eventName.lowercased().unicodeScalars.filter {
        CharacterSet.alphanumerics.contains($0)
      }
    )

    switch normalized {
    case "sessionstart", "sessionstarted", "startup":
      return .started
    case "sessionend", "sessionended", "stop", "subagentstop", "completed", "taskcompleted":
      return .completed
    case "permissionrequest", "permissionrequested", "permission", "idleprompt", "attention":
      return .attention
    case "notification", "notify":
      return .notification
    case "error", "failure", "failed":
      return .failed
    default:
      return nil
    }
  }
}

protocol AgentActivityNotifier: Sendable {
  func notify(activity: AgentActivity)
}

struct AgentActivityNotificationDispatcher: Sendable {
  private let notifier: any AgentActivityNotifier

  init(notifier: any AgentActivityNotifier) {
    self.notifier = notifier
  }

  @discardableResult
  func notifyIfNeeded(_ activity: AgentActivity, isMuted: Bool) -> Bool {
    guard !isMuted, activity.shouldNotify else {
      return false
    }
    notifier.notify(activity: activity)
    return true
  }
}
