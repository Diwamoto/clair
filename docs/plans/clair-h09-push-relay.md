# H09: Opaque push relay boundary

Status: task-owned implementation contract
Task: `H09`
Base: `4cf191378eb6ae5befa04e22d3e0156a8acdc7ed`

H09 implements ADR-0015's local, testable delivery boundary. It does not
deploy a service, select relay authentication, sign an Apple request, register
an iOS device, add notification UI/deep links, or implement H06/H08.

## Ownership and invariants

- `ClairPush` contains only bounded delivery contracts. Notifications carry
  UUID references, an allowlisted kind, epoch/revision hints, issue time and
  expiry. They cannot carry text, dictionaries, paths, provider events, or
  credentials. The strict bounded decoder rejects unknown fields; errors do
  not retain decoding context or input. APNs bodies contain this event and a
  fixed background wake dictionary only.
- `ClairDaemonPushRegistry` owns token registration, token generations,
  last-seen/expiry, revocation and scope decisions. It uses the actual H03
  authority and authenticated connection, never a decoded grant supplied by
  a caller. Registration needs `view` for the selected subscription scope;
  background delivery rechecks the current grant, generation, scope and expiry.
  These checks and synchronous delivery admission execute without suspension
  on H03's authority actor. Revoke cannot interleave with admission.
- Host/device/resource/wake references are opaque UUIDs derived from bounded
  identity metadata using a length-delimited SHA-256 projection. Raw B03 IDs
  permit arbitrary printable strings, so they never cross the relay boundary.
  H05 attention and completion are the only initial agent wake sources.
  Conversation, tool text, usage and raw provider output are not forwarded.
- Registry state is bounded and in memory. Replacements require a newer
  registration generation; equal identical retries do not extend expiry.
  Revoked/expired records retain bounded generation tombstones. Re-pair or
  grant-generation change requires a fresh authenticated registration.
- `ClairPushRelay` depends only on `ClairPush`, not transport, agent, daemon
  or UI. APNs credentials live only in this target's protected-store boundary.
  The daemon and apps do not link this target. Each environment has a separate
  credential and token namespace; the sole allowed topic is ADR-0015's mobile
  bundle ID. Rotation is monotonic; revoked and old generations cannot return.
- Relay admission, token replacement, revoke, and credential use/rotation are
  serialized. Provider and protected-store callbacks must be synchronous,
  bounded and non-reentrant. They represent an admission/response seam, not a
  place to wait indefinitely for network I/O. No notification can be recalled
  once admitted by an external provider.
- `now >= expiresAt` fails closed, including provider credential and device
  registration expiry. Clocks are injected, finite and range checked. Event
  TTL is at most 300 seconds; future-issued events are rejected. APNs expiry
  is carried as an absolute timestamp, never renewed by retries.
- A bounded in-memory ledger retains only a request digest, expiry and typed
  outcome per host/device/environment/wake. Exact duplicates return the first
  outcome without another provider call, including ambiguous failures. A
  conflicting wake ID fails closed. Live entries are never silently evicted;
  capacity exhaustion denies admission. Expired events cannot be replayed
  after pruning. Restart durability and distributed idempotency are H10 or a
  later deployed relay concern; this seam makes no exactly-once APNs claim.
- Token invalidation and environment mismatch require re-registration.
  Credential rejection is an infrastructure failure and does not falsely
  revoke the device grant. Provider errors and protected-store failures are
  reduced to fixed classifications; no response body or secret is retained.

## Deterministic coverage

Tests cover authenticated registration, absent/mismatched scope and grant,
token replacement and stale generations, expiry/revoke/re-pair, direct H03
revoke and admission ordering, strict payload size/privacy, H05 projection,
TTL at its exact boundary, sandbox/production isolation, credential rotation
and revoked/old credential rejection, duplicate/conflicting/concurrent sends,
ledger/store bounds, provider failures, locked storage and no secret echo.

## External integration

The in-memory protected store is a fixture boundary, not encrypted durable
storage. No Apple credential is provided and no real notification is sent.
Apple Developer access, a production secret-store adapter, APNs JWT/HTTP2/TLS,
authenticated daemon-to-relay transport, deployment, durable registry/ledger,
and physical lifecycle smoke remain explicit later integration dependencies.
N07 owns registration RPC, categories, notification actions and deep links.

APNs request conventions follow Apple's
[request documentation](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)
and [background update documentation](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app):
the fixture uses a background wake with priority 5 and absolute expiration.
