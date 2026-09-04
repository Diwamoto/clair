import Foundation

public enum MobileAttentionKind: String, Codable, CaseIterable, Sendable {
  case bell
  case agentNotification = "agent_notification"
  case agentCompleted = "agent_completed"
  case agentFailed = "agent_failed"
}

/// Content-free wake metadata suitable for an APNs payload.
///
/// The payload intentionally contains no terminal bytes, prompt, cwd, agent
/// text, or secret. The client uses `wakeID` to resume the authenticated
/// private channel and fetch current state from the host.
public struct MobileAttentionNotification: Codable, Equatable, Sendable {
  public let wakeID: String
  public let hostID: UUID
  public let sessionID: UUID?
  public let kind: MobileAttentionKind

  public init(
    wakeID: String,
    hostID: UUID,
    sessionID: UUID? = nil,
    kind: MobileAttentionKind
  ) throws {
    let normalized = wakeID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty,
      normalized.utf8.count <= 256,
      !normalized.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    else {
      throw MobileHostError.invalidOperation
    }
    self.wakeID = normalized
    self.hostID = hostID
    self.sessionID = sessionID
    self.kind = kind
  }

  public var apnsUserInfo: [String: String] {
    var values = [
      "clair_wake_id": wakeID,
      "clair_host_id": hostID.uuidString,
      "clair_kind": kind.rawValue,
    ]
    if let sessionID {
      values["clair_session_id"] = sessionID.uuidString
    }
    return values
  }
}
