# H06: Scoped agent commands

Status: task-owned D5 design note, recorded before production edits
Date: 2026-09-14
Task: `H06`; base: `4cf191378eb6ae5befa04e22d3e0156a8acdc7ed`

## Boundary and invariants

1. The provider-independent command model lives in `ClairV2Agent`; the host
   command boundary lives in `ClairV2DaemonKit`, which already depends on H03
   transport and H04/H05 agent contracts. No new package dependency is needed.
   Prompt uses B03 `agent.input` / `steer_agent`; approval and deny use additive
   `agent.approve` and `agent.deny` / `approve`; interrupt uses additive
   `agent.interrupt` / `signal`; stop uses `agent.stop` / `terminate`.
2. Every command requires the exact H04 project, optional worktree, session,
   process generation, and H05 session epoch. A project grant may authorize a
   descendant, but a command may never omit or substitute its concrete session.
   Only trusted host composition installs a running H04 snapshot and its
   generation-bound provider command endpoint. Replacement and invalidation
   serialize with commands; a stale generation cannot address a new endpoint.
3. H03 tickets are necessary but are not effects. Add a synchronous, non-awaiting
   commit closure on the authority: ticket validation and H06 effect commitment
   occur in one authority actor turn, ordered against close, revoke, and grant
   update. H06's session/ledger lock is acquired only inside this closure;
   there is no lock held across an actor hop. Endpoints must synchronously and
   non-reentrantly commit a bounded effect to their exact generation, or reject
   without effects. They must not launch detached work that bypasses this gate.
4. Reuse B03 `OperationLedger` at the effect boundary, independently of H03's
   authorization receipts. The same canonical operation returns the original
   outcome and sequence without another endpoint call. Conflicting reuse is
   rejected. Failed and uncertain endpoint outcomes are retained too, so retry
   cannot repeat an uncertain effect. No implicit eviction is allowed here:
   once the configured bounded capacity is full, new IDs fail closed. Durable
   restart recovery and window renewal are explicitly H08, not this task.
5. An approval reference is the normalized attention request digest plus exact
   event ID, revision, and epoch. Only pending approval attention can be answered.
   A replacement request, provider reply, accepted/uncertain response, completion,
   interrupt, stop, lifecycle invalidation, or generation change invalidates it.
   H05 needs the additive requested/resolved attention lifecycle field so a
   `permission.replied` event cannot accidentally create a new approval.
6. Normalized event ingestion checks scope, epoch, kind, contiguous revisions,
   duplicates, and conflicts using B03 replay state with a digest-only projection.
   A gap or malformed event fences commands until a trusted new generation/epoch
   is installed; H06 does not implement journal, cursor resync, or recovery.
7. Prompt bytes, approval references, encoded commands, pending requests,
   sessions, operations, and audit entries have explicit bounds. Audit contains
   only allowlisted enums, counters, generations, and SHA-256 correlation digests
   of typed IDs (IDs may themselves contain user text). It never contains prompt,
   token, credential, provider identity/payload, path, raw error, or request text.
   B03 ledger fingerprints become digests, preserving canonical equality without
   retaining command bodies. Command descriptions are redacted.

## Threat and failure modes

| Failure | Required behavior |
|---|---|
| absent/closed/expired/revoked/generation-stale H03 authorization | no endpoint call, including cached-result requests |
| close/revoke/update between ticket and commit | revalidation fails; no effect |
| close/revoke queued during synchronous commit | commitment precedes closure/revocation; later commands fail |
| duplicate taps, concurrent same ID, reconnect retry | one endpoint effect, same outcome and sequence |
| same ID with changed prompt/kind/scope/epoch/generation/base revision | typed conflicting reuse; no extra effect |
| unknown kind, mismatched capability or payload variant | reject before endpoint access |
| wrong project/worktree/session or omitted worktree | reject, even with a broad grant |
| stale approval, provider resolution, completion, conflicting answer | reject without effect |
| provider rejects or reports unknown outcome | bounded typed result retained; never blindly retry |
| lifecycle changes while command waits for authorization | exact generation/epoch checks fail closed |
| malformed/gapped/old stream | no pending approval mutation from untrusted ordering; fence commands |
| maximum operation/audit/session/approval/prompt bounds | explicit rejection or audit ring eviction, no unbounded retention |

## Deterministic test matrix

Tests use H03 generated fixture keys and an injected clock, H04 typed snapshots,
H05 normalized events, and a synchronous counting endpoint. No network, provider
binary, credential, app launch, or timing sleeps are required. Continuation and
semaphore barriers explicitly order races, with bounded waits only as deadlock
guards.

| Area | Cases |
|---|---|
| command routing | all five commands; authoritative capabilities; project-owned and worktree-owned sessions |
| exactly once | sequential/concurrent duplicates; duplicate authorization before dispatch; reconnect; conflict in each binding field; failed/uncertain effects; full ledger |
| authorization | default deny; wrong capability/kind/payload; connection and grant scope; exact expiry; revoke; grant-generation update; ticket/connection substitution |
| approval | current request; deny; wrong request/revision/event/epoch; replacement; reply; duplicate event; already answered; completion; interrupt/stop; epoch/process replacement |
| races | ticket then close/revoke/update; suspended caller then invalidation/replacement; committed effect before queued close/revoke; concurrent answers |
| events | exact H05 seam, contiguous ordering, duplicate/conflict, gap/epoch/scope mismatch, resolved events never reopen approval |
| bounds/privacy | prompt UTF-8 and wire decode limits; reference validation; session/pending/operation limits; bounded audit; malicious IDs and endpoint errors; redacted descriptions and digest-only ledger |
| architecture | no v1 imports, no UI/APNs/journal changes, no rejected-command transport/provider effects |

## Deferred integration

The endpoint is a provider-independent synchronous effect contract, not a new
OpenCode HTTP/CLI protocol. Concrete provider transport, durable effect recovery,
and host composition remain their existing later server integration seams.
External provider completion is not claimed by a command receipt: it records the
endpoint's committed/rejected/indeterminate result. The controller owns the
independent D5 review and queue execution evidence.
