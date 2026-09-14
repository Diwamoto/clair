# H05: OpenCode streaming event normalization

Status: task-owned implementation note
Date: 2026-09-14
Task: `H05`
Depends on: `H04`

## Boundary

`ClairV2Agent` accepts bounded OpenCode stdout chunks and emits only the
provider-independent `EventEnvelope<ClairV2AgentEventPayload>` model. H04
continues to own process lifecycle, stdout/stderr retention, launch identity,
and the raw-output byte bound. H05 does not expose provider JSON, credentials,
prompts, terminal bytes, filesystem paths, or unknown provider fields to the
normalized event model. H06 owns commands and approvals; H08 owns journal,
replay storage, reconnect, and subscriber cursors; native UI, APNs, and the
session transport are outside this task.

## Invariants

1. Every normalized event carries the exact H04 `ResourceScope` derived from
   the `ClairV2AgentSessionIdentity`; provider-supplied project, worktree, and
   session fields cannot replace it.
2. Every emitted event carries the supplied `SessionEpoch` and the next
   `Revision`. Unknown events and duplicate delivery do not consume a
   revision. Revision overflow fails closed.
3. Input order is the only ordering authority. A complete record is emitted
   once; a transport chunk is buffered until its newline-delimited JSON record
   is complete. Completion is held until usage has been emitted when usage is
   delivered after completion, so completion is always the terminal normalized
   event.
4. An explicit provider event ID is used only for duplicate detection and is
   never copied into the wire event. Its normalized `EventID` is a stable
   digest. A conflicting reuse fails closed. Records without an explicit ID
   use a stable digest of the bounded canonical record, which makes identical
   retry delivery deterministic within the supported stream.
5. Only five allowlisted payload kinds are emitted: conversation, tool call,
   attention, completion, and usage. Unknown provider types are ignored
   deterministically and retain no payload. Malformed JSON, invalid UTF-8,
   over-bound records/fields, incomplete final records, and events after
   completion are typed failures.
6. Text, names, IDs, and usage counters are bounded before they enter a
   normalized value. Tool arguments, arbitrary metadata, credentials, paths,
   and raw provider objects are not retained. The normalized payload contains
   only allowlisted fields needed by later command/UI/session tasks.
7. The normalizer is a value type with no wall-clock, UUID, provider callback,
   or hash randomization dependency. The same identity, epoch, starting
   revision, and byte sequence produce the same event sequence and JSON.

## Failure modes

| Input or state | Required result |
|---|---|
| split JSON/SSE line | buffer without emitting a partial event |
| partial final line at `finish` | `ProtocolError.truncatedFrame` |
| invalid UTF-8, scalar/array JSON, or malformed JSON | `ProtocolError.malformedPayload` |
| record above `FrameLimits` or cumulative H04 output bound | typed bounded-input error; retain no oversized record |
| unknown provider event type | ignore without revision or raw-payload retention |
| duplicate explicit ID with identical record | no-op; no revision consumed |
| duplicate explicit ID with different record | typed conflicting-duplicate error |
| revision overflow | `ProtocolError.revisionOverflow` |
| usage after a pending completion | emit usage before completion |
| recognized event after completion is published | typed event-after-completion error |
| provider identity/scope fields disagree with H04 identity | ignore those fields; preserve H04 identity |
| provider credential/path/secret in unknown fields | never present in normalized event or error text |

## Test matrix

| Area | Deterministic cases |
|---|---|
| identity/position | project-owned and worktree-owned sessions; exact scope; epoch; starting and contiguous revisions |
| event mapping | conversation delta/role; tool call name/id/status; attention kind; completion status; usage counters |
| stream framing | one record, multiple records, split UTF-8/JSON chunks, SSE `data:` lines, `[DONE]`, partial final line |
| ordering | input order; usage before completion; completion before usage; completion only at finish; no post-completion event |
| duplicates | identical explicit-ID retry; conflicting explicit-ID reuse; identical no-ID retry; revision stability |
| unknown/malformed | unknown type; invalid JSON; invalid UTF-8; scalar payload; invalid numeric fields; provider identity mismatch fields |
| bounds | record, cumulative input, event count, text/name/ID, and usage bounds; no oversized allocation or retained raw payload |
| privacy | unknown secret/path/token/prompt fields absent from encoded normalized event and localized errors |
| repeatability | same input/identity produces byte-for-byte equal normalized envelopes |
