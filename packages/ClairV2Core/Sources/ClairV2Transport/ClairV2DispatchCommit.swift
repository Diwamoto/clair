import ClairV2Shared

extension ClairPairingAuthority {
  /// Raw terminal admission and FIFO commitment share a single authority turn.
  /// The bounded closure cannot await, reenter authorization, or perform
  /// blocking I/O. This also linearizes concurrent device input with revoke.
  public func commitAuthorizedOperation<Payload: Codable & Sendable, Result: Sendable>(
    _ operation: OperationRequest<Payload>, on connection: ClairAuthenticatedConnection,
    commit: @Sendable () throws -> Result
  ) throws -> Result {
    _ = try authorize(operation, on: connection)
    return try commit()
  }

  public func readAuthorized<Result: Sendable>(
    scope: ResourceScope, on connection: ClairAuthenticatedConnection,
    read: @Sendable () throws -> Result
  ) throws -> Result {
    try authorizeRead(scope: scope, on: connection)
    return try read()
  }

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
