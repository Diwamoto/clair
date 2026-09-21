import ClairEditorCore
import LanguageServerProtocol

/// The LSP spec's own lifecycle state machine (initialize -> initialized ->
/// requests/notifications -> shutdown -> exit): a request sent out of order
/// (a `didOpen` before `initialized`, a request after `shutdown`) is a
/// protocol violation, not something a real server is required to tolerate.
public enum LSPLifecycleState: Sendable, Equatable {
  case uninitialized
  case initializing
  case initialized
  case shuttingDown
  case exited
}

public enum LSPSessionError: Error, Sendable, Equatable {
  case invalidLifecycleTransition(from: LSPLifecycleState, to: String)
  case documentAlreadyOpen
  case documentNotOpen
}

/// Client-side LSP lifecycle and document-sync state for exactly one document.
/// Not Sendable, for the same reason as `TextBuffer`: keep the session on the
/// actor that owns the document.
///
/// Owns the LSP document `version` the wire protocol requires to be
/// monotonically increasing: since one document's `TextRevision.sequence`
/// already increases by exactly one per accepted edit for the lifetime of
/// that document (`TextBuffer.replace`), `version` mirrors it directly
/// instead of keeping a second counter that could drift from it.
public final class LSPDocumentSession {
  public let uri: DocumentUri
  public let languageId: String
  public private(set) var lifecycle: LSPLifecycleState = .uninitialized
  public private(set) var isOpen = false
  public private(set) var version: Int?

  public init(uri: DocumentUri, languageId: String) {
    self.uri = uri
    self.languageId = languageId
  }

  public func beginInitialize() throws {
    guard lifecycle == .uninitialized else {
      throw LSPSessionError.invalidLifecycleTransition(from: lifecycle, to: "initializing")
    }
    lifecycle = .initializing
  }

  public func serverInitialized() throws {
    guard lifecycle == .initializing else {
      throw LSPSessionError.invalidLifecycleTransition(from: lifecycle, to: "initialized")
    }
    lifecycle = .initialized
  }

  @discardableResult
  public func open(_ snapshot: TextSnapshot) throws -> DidOpenTextDocumentParams {
    guard lifecycle == .initialized else {
      throw LSPSessionError.invalidLifecycleTransition(from: lifecycle, to: "didOpen")
    }
    guard !isOpen else { throw LSPSessionError.documentAlreadyOpen }
    isOpen = true
    let openVersion = Int(snapshot.revision.sequence)
    version = openVersion
    return DidOpenTextDocumentParams(
      textDocument: TextDocumentItem(
        uri: uri, languageId: languageId, version: openVersion, text: snapshot.string()))
  }

  /// Builds an incremental `didChange` notification: one content-change event
  /// per edit, each carrying only its own range and replacement text rather
  /// than the whole document.
  @discardableResult
  public func change(
    edits: [ClairEditorCore.TextEdit], oldSnapshot: TextSnapshot, newSnapshot: TextSnapshot
  ) throws -> DidChangeTextDocumentParams {
    guard lifecycle == .initialized else {
      throw LSPSessionError.invalidLifecycleTransition(from: lifecycle, to: "didChange")
    }
    guard isOpen else { throw LSPSessionError.documentNotOpen }
    let changes = try edits.map { edit in
      TextDocumentContentChangeEvent(
        range: try LSPCoordinates.range(edit.range, in: oldSnapshot),
        rangeLength: nil, text: edit.replacement
      )
    }
    let newVersion = Int(newSnapshot.revision.sequence)
    version = newVersion
    return DidChangeTextDocumentParams(uri: uri, version: newVersion, contentChanges: changes)
  }

  @discardableResult
  public func close() throws -> DidCloseTextDocumentParams {
    guard isOpen else { throw LSPSessionError.documentNotOpen }
    isOpen = false
    return DidCloseTextDocumentParams(uri: uri)
  }

  public func beginShutdown() throws {
    guard lifecycle == .initialized else {
      throw LSPSessionError.invalidLifecycleTransition(from: lifecycle, to: "shutdown")
    }
    lifecycle = .shuttingDown
  }

  public func exit() throws {
    guard lifecycle == .shuttingDown else {
      throw LSPSessionError.invalidLifecycleTransition(from: lifecycle, to: "exit")
    }
    lifecycle = .exited
  }

  /// Rejects a diagnostics batch published for any version other than the
  /// document's current one: a slow or out-of-order server response for a
  /// stale revision must not overwrite fresher diagnostics with old ones. A
  /// server that omits `version` (legal in the spec) cannot be checked and is
  /// passed through as-is.
  public func accept(_ diagnostics: PublishDiagnosticsParams) -> [Diagnostic]? {
    guard let published = diagnostics.version else { return diagnostics.diagnostics }
    return published == version ? diagnostics.diagnostics : nil
  }

  /// Rejects a position-anchored response (completion, hover, ...) whose
  /// request was issued against a revision that is no longer current: the
  /// caller records `version` at the moment it sends the request and passes
  /// it back here when the response arrives.
  public func accept<Response>(_ response: Response, requestedAtVersion: Int) -> Response? {
    requestedAtVersion == version ? response : nil
  }
}
