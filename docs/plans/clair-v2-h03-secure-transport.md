# H03: Native transport and device authorization contract

Status: implementation contract
Date: 2026-09-14
Task: `H03`
Parent: [Clair v2 native rewrite](clair-v2-native-rewrite.md)
Related decisions: [ADR-0012](../decisions/0012-orca-style-mobile-pairing.md), [ADR-0015](../decisions/0015-native-mobile-apns.md)

This document is the D5 implementation contract for the host-side security
boundary and the transport-neutral native client seam. It makes the security
invariants and threat coverage explicit before production code is changed. It
does not select a public relay, TLS library, Keychain storage format, or APNs
provider credential; those remain later connection-layer decisions.

## Scope and boundary

H03 owns the testable, transport-neutral security runtime:

- persistent-host-identity-shaped types and public-key fingerprint pinning;
- one-time, short-lived pairing links and atomic bootstrap consumption;
- device key proof, opaque device token, typed token expiry, and generation binding;
- per-device grant capabilities and typed visible `ResourceScope` values;
- authenticated connection lifecycle, scope-bound challenges, operation
  authorization, replay rejection, and immediate revocation;
- a wire-safe `ClairConnectionInfo` DTO kept separate from the unforgeable
  in-memory authenticated connection handle;
- a generation-checked authorization ticket seam for H06 dispatch, plus an
  explicit client connection-state refresh/invalidation boundary;
- a native client transport protocol that can be backed by Network.framework,
  TLS, or another byte-stream adapter later.

The runtime accepts an injected clock and exposes
`ClairNativeTransportChannel` plus `ClairNativeTransportCodec` as the future
byte-stream/frame boundary, so threat tests are deterministic and do not
require a network listener or production credential. H01's daemon lifecycle
and owner-only Unix control channel are consumed but not changed. B03's
`ClairV2Shared` identities, operation kinds, `AccessBoundary`, protocol
negotiation, and bounded frames remain the wire contract. H02 catalog, N02
mobile storage/UI, APNs, and the old v1 runtime are outside this task.

## Security invariants

1. **Default deny.** No authenticated connection exists without a valid,
   unexpired pairing/reconnect proof and unexpired device credential. An empty
   capability set or empty visible scope set authorizes nothing. Every
   operation is checked against its authoritative B03 operation-kind
   capability and typed scope before dispatch.
2. **One-time bootstrap.** A pairing secret is high-entropy, compared as an
   exact opaque value, expires when `now >= expiresAt`, and is consumed
   atomically only by a successful pairing. A second consume, malformed secret,
   or expired link never creates a grant. Issuing a new link invalidates only
   the previous unused link; existing device grants are unaffected.
3. **Device-key binding.** A grant is bound to one device public key and a
   typed credential expiry. A token without a valid signature over the fresh,
   connection-specific challenge is insufficient. A signature from another
   key, another host, another device, another generation, or another
   challenge is rejected. `now >= tokenExpiresAt` rejects pairing-derived
   authentication, authorization, and reconnect.
4. **Host identity pinning.** The host fingerprint is the canonical SHA-256
   digest of the host signing public-key representation. A pinned client may
   change endpoints only when host ID and fingerprint still match. A changed
   fingerprint or unknown host requires explicit re-pairing and cannot be
   bypassed by presenting a valid token.
5. **Fresh challenge and replay resistance.** Each challenge is unique,
   short-lived, bound to host/device/generation/connection and the selected
   `ResourceScope`, and consumable once. Pending admission is bounded both
   globally and per device, so a valid-token flood from one device cannot
   starve other devices. Expired, already-consumed, duplicated, or
   differently-bound challenge proofs are rejected before connection
   authorization; an invalid proof consumes its pending challenge slot.
6. **Generation and revocation.** A grant has one current generation. Revoke
   atomically marks the grant revoked, advances its generation, and closes all
   active connections for that device. Authorization and H03 ticket
   revalidation linearize with revoke: no operation can be accepted after the
   revoke linearization point, and stale tokens, challenges, signatures, and
   operation IDs do not regain access. H06 owns the separate effect/dispatch
   linearization; H03 does not claim atomic dispatch-plus-revoke semantics.
7. **Scope containment.** Visible resources are typed B03 scopes, not paths,
   branches, or endpoint strings. Session scopes require exact project,
   optional worktree, and session identity. A project/worktree grant may
   contain descendants only according to B03 containment; a sibling project,
   wrong worktree, wrong session, or different host is denied.
8. **Opaque credentials.** Device private keys and issued tokens are never
   present in pairing links, protocol error details, logs, diagnostics, or push
   payloads. The host grant keeps only a SHA-256 token digest; the raw token is
   returned to the client exactly at pairing and has no user-facing
   description. The one-time pairing result is the intentional credential
   delivery exception. Public host/device keys and fingerprints may be
   displayed as identity material. Challenge proofs redact signatures in
   descriptions.
9. **Fail-closed parsing.** Secret, identity, endpoint, signature, challenge,
   grant, and operation inputs have explicit size/format bounds. H03 wire DTOs
   preflight credential `Data`, capability arrays, and protocol version-range
   arrays before constructing their B03 values. Malformed or ambiguous input
   is rejected without authorization, dispatch, or unbounded allocation.
10. **Transport neutrality.** Authentication and authorization do not infer
    trust from LAN, Tailscale, Cloudflare, or a socket being reachable. The
    transport adapter carries typed/authenticated messages and does not own
    grant scope or revocation decisions.

## Failure modes and required result

| Failure mode | Required result |
|---|---|
| Pairing link at `now == expiresAt` or later | Reject as expired; do not consume or create a grant |
| Pairing secret reused, malformed, or paired twice concurrently | Reject; at most one grant is created |
| New pairing link | Previous unused link is invalid; existing grants remain valid |
| Credential at `now == tokenExpiresAt` or later | Reject pairing-derived authentication and authorization; close active connections |
| Wrong host ID or changed host fingerprint | Reject before token/challenge authorization; require explicit re-pair |
| Stolen token with no device private key | Reject; no connection or operation is authorized |
| Valid key used with another device/token/generation | Reject as binding mismatch |
| Expired, reused, wrong-connection, or wrong-generation challenge | Reject; challenge cannot be replayed |
| One device fills pending challenge slots | Reject further challenges for that device; other devices retain their quota |
| Empty capabilities or visible scopes | Reject every operation, including reads |
| Wrong project/worktree/session or undeclared operation scope | Reject with typed scope denial |
| Unknown operation or peer-declared capability mismatch | Reject using B03 authoritative mapping |
| Revoke during authorize/dispatch | Linearize under the authority lock; post-revoke work is denied and active connection is closed |
| Forged Codable connection metadata | Treat as DTO only; it cannot close or authorize a live connection handle |
| External channel close or revoke notification | Client invalidates immediately when notified, or uses the explicit authority refresh before trusting `isConnected` |
| Malformed frame/message or oversized credential | Reject before dispatch; do not include input bytes in error output |
| Transport unavailable or production credential absent | Keep local daemon boundary usable; report an external connection-layer dependency |

## Threat test matrix

The tests use a fixed clock, generated test key material, the in-process
authority/client seam, and the bounded frame codec. They assert both the
positive path and the absence of a grant/connection/operation after each
failure.

| ID | Threat or boundary | Evidence required |
|---|---|---|
| T01 | Pairing happy path | Link fingerprint/expiry are shown as identity metadata; one default `view` grant is returned; secret material is not in the encoded link except the one-time bootstrap secret |
| T02 | Default deny | Unpaired client, empty grant, missing capability, and empty visible scope cannot authorize a catalog or mutating operation |
| T03 | Expiry boundary | Pairing and challenge fail at exact expiry and after expiry; valid values immediately before expiry succeed |
| T04 | One-time/replay | Duplicate pairing, concurrent pairing, reused bootstrap, reused challenge, and duplicate signed proof are rejected |
| T05 | Device binding/stolen token | Copying token to a second key fails; original key with a different token/device/generation fails |
| T06 | Host pinning | Same host identity with a changed endpoint reconnects; changed fingerprint, wrong host, and unknown host fail closed |
| T07 | Scope containment | Correct project/worktree/session succeeds; sibling project, wrong worktree, wrong session, and session optional-worktree mismatch fail |
| T08 | Capability authority | `view` cannot write/signal/terminate/spawn/manage; operation kind determines required capability; peer mismatch/unknown kind fails |
| T09 | Active revoke | Revoke closes all device connections, advances generation, and denies old token/challenge/signature and subsequent operations |
| T10 | Concurrent revoke/authorize and H06 ticket revalidation | Interleaving is serialized; every result is either accepted before revoke or denied after it, with no post-revoke acceptance |
| T11 | Malformed input/bounds | Invalid IDs, endpoint/fingerprint, secret/key/signature lengths, challenge fields, grant fields, nested capability/version arrays, extreme timestamps, and oversized frames fail without dispatch or secret echo |
| T12 | Privacy/redaction | Pairing/link/error/transport diagnostics and proof descriptions contain no device private key, issued token, challenge signature, terminal bytes, prompt, cwd, or user content; only the one-time pairing result carries the credential for delivery |
| T13 | Protocol boundary | Negotiation uses B03 protocol contracts and bounded frames; no v1 module, raw PTY listener, Network.framework, Keychain, APNs credential, or public relay is introduced |

## Deferred production dependencies

The H03 public seam is intentionally usable with a future byte-stream adapter
and protected-credential adapter. The following are explicit follow-ups:

- Network.framework and TLS certificate/public-key pinning for the concrete
  native connection;
- Keychain/Secure Enclave storage and device-key lifecycle on iOS/macOS;
- APNs provider boundary, opaque wake payloads, and production credentials;
- public relay and application-layer E2EE, pending the secure-link decision.

None of these external credentials are required for the local security state
machine or its threat tests, and no production secret is committed by H03.
