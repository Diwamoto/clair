# Clair v2 core packages

This package is the dependency root for the native rewrite foundation. Each
target is a deliberately small, independently buildable boundary for a v2
component. The targets contain no v1 application or mobile-control module.

'ClairV2Shared' owns the transport-neutral protocol contract used by later
daemon, client, and native UI tasks. It does not open a socket, perform
pairing, launch a provider, or provide a runtime fallback to v1.

## B03 shared protocol contract

The public contract is in
'Sources/ClairV2Shared/ClairV2Protocol.swift':

- 'ProjectID', 'WorktreeID', 'SessionID', 'OperationID', and 'EventID' are
  distinct validated wire identities. A 'ResourceScope' carries the hierarchy
  explicitly; path names and branch names are not identity keys.
- 'Revision' is a non-negative scalar. 'SessionEpoch' is strictly positive.
  A session event must carry both epoch and revision, while a project/worktree
  event must carry neither. 'ReplayCursor' is always session-scoped.
- 'ProtocolOffer' negotiates a common major and the highest overlapping minor.
  Major mismatch and disjoint minor ranges fail closed. Capabilities are
  open-ended wire names, so unknown capabilities remain decodable and the
  negotiated set is the deterministic intersection.
- 'BoundedFrame' is a four-byte big-endian length-prefixed frame. The default
  payload bound is 64 KiB and the hard bound is 16 MiB. The decoder checks the
  declared length before slicing or allocating a payload and rejects truncated
  or trailing bytes.
- 'OperationLedger' assigns the broker arrival sequence only on first sight.
  A retry with the same operation ID and canonical operation fingerprint
  returns the original sequence; a conflicting reuse is rejected. The
  idempotency history is bounded, so eviction is explicit rather than an
  unbounded memory commitment.
- 'ReplayState' accepts only the next revision in the same epoch and scope.
  It reports gaps, regressions, epoch changes, conflicting event-ID reuse, and
  scope changes as typed failures. 'AccessBoundary' is default-deny: the server
  resolves the required capability from each known operation kind (`terminal.input`
  uses `write_terminal`; `terminal.interrupt` uses `signal`), rejects a
  mismatched request declaration, and rejects unknown kinds before checking the
  visible hierarchical scope. Session scopes are exact, including optional
  worktree presence.
- 'EventKind', 'OperationKind', 'Capability', and 'ProtocolErrorCode' retain
  unknown raw names. Codable keyed envelopes ignore unknown fields so a newer
  peer can add fields without breaking an older peer; re-encoding does not
  invent or forward fields it did not understand.

'ErrorEnvelope' is the serializable error boundary. It contains a stable
error code, retry hint, optional typed scope/operation/revision context, and
bounded non-secret details. Raw payloads, prompts, terminal bytes, paths, and
credentials are not part of this contract.

## Invariants and failure modes

| Boundary | Invariant | Fail-closed result |
|---|---|---|
| Identity | Non-empty printable UTF-8 value, at most 256 bytes, and correct ID type | 'invalidIdentifier' |
| Version | Same major and overlapping minor range are required | 'unsupportedMajor' / 'noCompatibleVersion' |
| Frame | Declared payload length is positive-bounded by negotiated limits | 'invalidFrameLength' / 'frameTooLarge' / 'truncatedFrame' |
| Scope | Project and worktree scopes are hierarchical; session scope requires exact project, optional worktree, and session IDs | 'scopeDenied' / 'invalidScope' |
| Replay | Same session scope/epoch and exactly the next revision are required | 'epochMismatch' / 'replayGap' / 'replayRegression' |
| Idempotency | An operation ID maps to one canonical fingerprint inside a bounded window | 'operationIDReuse' |
| Capability | Empty grants deny all operations; operation kind resolves the required capability (`write_terminal` / `signal` for terminal mutations); unknown kinds and mismatched declarations fail closed | 'capabilityDenied' / 'capabilityMismatch' / 'unknownOperationKind' |

## B03 test matrix

'ClairV2CoreTests' contains deterministic golden coverage for:

1. minor-version negotiation, capability intersection, major rejection, and
   disjoint ranges;
2. event and error JSON golden bytes, unknown envelope/payload fields, and
   unknown wire names;
3. exact frame bytes, partial/batched decoding, oversized lengths, oversized
   input suffixes, truncation, and trailing bytes;
4. contiguous replay, duplicate delivery, gaps, regressions, epoch mismatch,
   scope mismatch, exact session-scope containment, and event-ID reuse;
5. operation arrival ordering, same-fingerprint retry, conflicting operation
   reuse, bounded eviction, authoritative operation-to-capability mapping,
   correct `write_terminal`/`signal` grants, rejection of legacy or peer-only
   capabilities, mismatched/unknown operation rejection, and default-deny
   capability/scope authorization;
6. invalid identities, zero epochs, and invalid envelope position
   combinations.

The v1 packages may remain evidence or fixture sources for their own tasks,
but no 'ClairV2Core' target imports them.

## H02 read-only workspace runtime

`ClairV2Workspace` provides `ClairV2WorkspaceRuntime` for the Mac daemon's
read-only workspace surface. A caller registers a typed `ProjectID` with an
absolute `ClairV2ProjectRoot`; the runtime discovers the repository root and
Git worktrees without modifying the checkout. Catalog entries retain typed
`WorktreeID` values and report missing, inaccessible, non-directory, and
symlink roots explicitly.

`ClairV2WorkspacePath` accepts only bounded relative paths. Resolution checks
each component with `lstat` and opens text files through `openat` with
`O_NOFOLLOW`, so absolute paths, parent traversal, and symlink traversal fail
closed. File reads reject files above the configured byte bound, binary data,
and invalid UTF-8. File-tree and Git changed-file responses carry explicit
entry/file/output limits and an `isTruncated` marker; Git status is collected
with `GIT_OPTIONAL_LOCKS=0` and no write operation.
