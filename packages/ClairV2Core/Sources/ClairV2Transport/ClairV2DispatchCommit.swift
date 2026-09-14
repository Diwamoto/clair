import ClairV2Shared

extension ClairPairingAuthority {
  /// The synchronous H06 effect linearization seam. Validation and commitment
  /// share one non-suspending authority turn with close/revoke/grant updates.
  /// The closure must be bounded, non-reentrant, and must not defer an
  /// unchecked effect to another task. No authority lock crosses an await.
  public func commitDispatch<Payload: Codable & Sendable, Result: Sendable>(
    _ ticket: ClairAuthorizationTicket<Payload>,
    on connection: ClairAuthenticatedConnection,
    commit: @Sendable () throws -> Result
  ) throws -> Result {
    _ = try validateDispatch(ticket, on: connection)
    return try commit()
  }
}
