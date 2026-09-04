# Design

## Current state

P07の`clair-ptyhost`はsame-user Unix socket、stable SessionID、bounded journal、複数subscriber、cursor replay、
gap通知を持つ。P09はraw Claude Code/Codex/OpenCode launch、agent activity、attentionを持つ。P13はtyped Command
RegistryをGUI/CLI/MCPへ投影する。今回、Clair本体に復元済みagent tabを含むagent control planeを追加し、
mobile methodと`clair agent` CLIはこの同じstable commandへ投影する。これらをmobile用に別実装せず、hostがsession
の正本であり続ける。

初期共有契約は [`packages/ClairMobileKit`](../../../packages/ClairMobileKit) に置く。これはiOS/macOSの両方でビルド
できるFoundation-only packageで、network、Keychain、APNsのSDK差をprotocol modelへ漏らさない。

## Initial architecture

```text
Clair.app (macOS)
  |- agent control plane (catalog, factual state, input, signal, stop, launch)
  `- local MobileControlAPI caller
             |
             | same-user Unix socket / in-process call
             v
clair-mobile-host
  |- versioned MobileControl API (WebSocket control + binary terminal frames)
  |- Orca-style pairing, device token/grant, scope, and revoke
  |- session catalog projection and operation authorization
  |- binds to localhost; this is the only remote-facing Clair endpoint
  `- transport adapter: Tailscale Serve / Cloudflare private route / relay later
             ^
             | WSS or equivalent authenticated byte stream
  native iPhone/iPad client
  |- session list and raw terminal renderer
  |- local viewport / input controls
  `- opaque APNs wake handling

clair-ptyhost
  |- PTY lifecycle, session catalog, journal, subscriber cursor
  `- same-user local IPC only; never exposed directly to mobile
```

Transport is replaceable, while the endpoint and protocol remain stable. Tailscale Serve may proxy a localhost service
for a private/dev path; Cloudflare Tunnel / One private route remains the distribution-oriented private path. Neither
network identity is treated as Clair application authorization. Cloudflare/Tailscale configuration, device enrollment,
APNs provider, and TestFlight signing are operational interfaces kept outside the application protocol. A public relay
still requires the security gate in [ADR-0004](../../decisions/0004-outbound-e2ee-relay.md).

## Protocol layering

```text
Transport: Tailscale Serve or Cloudflare private route (same contract); public relay later
Control: JSON-RPC-like typed request/response and notifications
Data: bounded binary terminal frames
Identity: project_id + worktree_id + session_id + session_epoch
Authentication: Orca-style one-time pairing + host fingerprint pin + per-device credential
Authorization: paired device grant + scope + visible worktree set
Ordering: broker arrival sequence
```

The initial binary frame layout is fixed by `MobileTerminalFrame`:

| Field | Size | Meaning |
|---|---:|---|
| magic | 2 | `MC` |
| protocol major/minor | 1 + 1 | decoder contract |
| kind/flags | 1 + 1 | output or snapshot; initial flags are zero |
| stream ID | 4 | connection-local non-zero ID |
| session epoch | 8 | PTY history generation |
| start offset | 8 | uncompressed PTY byte offset |
| payload length | 4 | checked before allocation |
| payload | variable | maximum 64 KiB, raw bytes |

The package rejects invalid magic, unsupported versions, unknown kinds, non-zero flags, truncated/trailing data, and
oversized payloads. JSON control messages may carry metadata, but the terminal data path never base64-encodes raw bytes.

## Orca-style pairing and authentication

The network path only makes `clair-mobile-host` reachable. Clair owns the application identity and authorization so the
same mobile API works over Tailscale, Cloudflare, and a future relay.

“Orca-style” means the pairing and credential lifecycle, not compatibility with Orca's wire protocol or token format.

### Pairing records

The host keeps a persistent host identity and a separate grant for every paired mobile device:

| Record | Owner | Lifetime | Contents |
|---|---|---|---|
| Host identity | Mac | host lifetime | `host_id`, server public-key identity, TLS fingerprint |
| Pairing link | Mac | one-time, short expiry | endpoint, `host_id`, fingerprint, protocol version, bootstrap secret |
| Device grant | Mac + mobile | until revoke or reset | `device_id`, device public key, opaque device token, generation, scopes, visible worktrees, timestamps |
| Connection session | host | one connection | negotiated protocol, challenge result, connection ID, last-seen state |

The pairing link is a secret, not an account login. It must not contain a device private key, terminal data, prompt, cwd,
credential, or an already-issued device token. The QR/deep link may include the endpoint selected for the current path;
the mobile host record can later replace that endpoint without re-pairing if the pinned host identity is unchanged.

### Pairing flow

1. The Mac user explicitly chooses **Pair mobile**. The host creates a fresh one-time pairing link with a short expiry.
   Generating another link invalidates the previous unused link; already-paired devices keep their own grants.
2. The mobile scans the QR or opens the deep link, shows the host name/address/fingerprint, and requires user confirmation.
3. The mobile creates or loads a device key pair in protected storage. The private key never leaves the mobile device.
4. The mobile connects to the advertised endpoint, verifies the server TLS/public-key fingerprint, and sends the bootstrap
   secret plus the device public key over the authenticated channel.
5. The host atomically consumes the bootstrap secret, allocates a new `device_id`, stores the device public key, and issues
   an opaque device token with the default `view` scope. The token is returned once and stored in the mobile Keychain.
6. The mobile stores the host record, endpoint, pinned fingerprint, device ID, and token. It then performs normal protocol
   version/capability negotiation and requests the visible session catalog.

### Reconnect and authorization flow

1. A reconnect uses the saved endpoint, `host_id`, `device_id`, and device token. It does not show the QR again.
2. The host sends a fresh challenge. The mobile proves possession of the paired device key and presents the token.
3. The host checks token generation, device revoke state, protocol compatibility, and the requested operation scope before
   admitting the connection or dispatching any operation.
4. Each operation includes `device_id`, `session_id`, `operation_id`, and its payload. The existing broker ordering and
   bounded operation-dedupe rules then apply.

An endpoint edit is allowed without re-pairing only when the host identity/fingerprint remains the same. A fingerprint
change is treated as a new host and requires explicit re-pairing; the client must not silently trust a changed key.

## Session and input flow

1. After authentication, mobile initializes, negotiates version/capabilities, and requests the visible session catalog.
2. Host filters catalog entries by stable worktree identity. `cwd` is only returned over the private authenticated channel;
   branch/path strings are not identity keys.
3. Mobile subscribes with its last epoch/cursor. In-range bytes replay before live output. Out-of-range cursors get an
   explicit gap and stop live application until the client performs the documented resync path.
4. Every input gets a device ID, session ID, operation ID, and payload. The host serializes accepted operations at the
   broker boundary in arrival order and remembers a bounded recent-operation window.
5. Mobile viewport changes remain local. Only the desktop geometry owner can send PTY resize.

There is intentionally no implicit lease in the initial product. If Mac and mobile send input concurrently, the broker's
arrival sequence is the audit/replay order. Dangerous signal/terminate operations still require separate scopes and, later,
user-presence policy.

## Agent boundary

Raw PTY is universal: shell, unknown CLI, Claude Code, Codex, and OpenCode all remain controllable without screen parsing.
Clair's agent control plane registers current and restored agent tabs by stable session ID, exposes factual lifecycle and
attention, and applies input/interrupt/stop only to the owning terminal. The first convenience functions are registered
profile launch, interrupt, attention notification, session reveal, safe reconnect, and the corresponding `clair agent`
CLI. Mobile `agent/*` methods and CLI `agent.*` commands share the same operation semantics; the network bridge is still
responsible for device grant and operation replay protection. A semantic adapter may be added only behind a capability bit
when an official local interface or Clair-aware launch profile exists. The adapter cannot change the raw session identity
and a crash must degrade to raw PTY.

## Security and privacy boundary

- Local broker remains owner-only same-user IPC. Mobile access is disabled by default and has an explicit Mac kill switch.
- Only `clair-mobile-host` is remotely reachable. `clair-ptyhost` remains on same-user Unix socket/local IPC and is never
  published as a raw port or generic shell endpoint.
- Pairing is one-time, short-lived, user-present, and bound to a device key. Each mobile device receives a distinct grant
  and token; there is no shared static token. Revoke increments the device generation, closes active connections, and
  rejects old tokens, signatures, and operations.
- Tailscale/Cloudflare is a coarse reachability gate, not the application identity. A device that can reach the Mac still
  needs a valid Clair grant, and a valid grant still cannot exceed its scopes or visible worktree set.
- Tailscale deployment uses a localhost-only service behind Serve, a single allowed endpoint, and no subnet routes or Exit
  Node. Cloudflare deployment targets one private host/port rather than a broad CIDR route.
- Scopes default to deny. The initial read-only grant cannot write, signal, terminate, spawn, or manage devices.
- APNs receives only an opaque wake identifier. Terminal text, prompt, cwd, command line, and credentials never enter push
  payloads, logs, metrics, or crash reports.
- Mobile stores no terminal transcript or diff after the session ends. Host journal retention remains bounded.
- Device token handling, host key pinning, and challenge replay protection are part of the private-network contract.
  Algorithm/library selection for application-layer E2EE remains the separate secure-link investigation.
- Public internet relay and application-layer E2EE are not implied by the private-network MVP; they require the separate
  cryptographic decision and review before any public write/approval path.

## Failure handling

| Failure | Required behavior |
|---|---|
| mobile disconnect | PTY continues; reconnect uses new connection identity and session epoch/cursor |
| slow subscriber | that subscriber gets gap/resync or disconnect; other readers continue |
| cursor outside journal | typed gap; no silent live continuation |
| Mac GUI close | host and PTY continue; local/mobile reconnect remains possible |
| Tailscale/Cloudflare route outage | local Mac PTY continues; remote write is not queued indefinitely |
| revoked device | active link closes and later catalog/control requests are denied |
| expired or reused pairing link | pairing is rejected; no device grant is created |
| host fingerprint changed | connection is rejected and mobile requires explicit re-pairing |
| endpoint changed with same host identity | saved device grant is reused after reconnect |
| malformed frame | reject before allocation/dispatch; do not log content |
| agent exit | session exit and attention state are visible; no semantic fallback is inferred |

## Alternatives

Vendor remote services do not cover arbitrary PTYs or give Clair a common session catalog. Screen scraping cannot safely
identify approvals. ACP is a useful later adapter but is not a protocol for attaching to every existing PTY. A relay-first
design would delay a useful private-network MVP and enlarge the security boundary before the local contract is tested.

Tailscale and Cloudflare are not competing mobile protocols. They are transport choices below the same
`clair-mobile-host` endpoint. The Orca precedent is useful here because it keeps the desktop as source of truth, makes
pairing explicit, issues a separate revocable grant per client, and lets a saved host address change without silently
changing the host identity.

The raw-terminal-first choice and early roadmap placement are recorded in [ADR-0011](../../decisions/0011-early-mobile-agent-control.md);
the older adapter/relay proposals remain historical follow-up decisions.

The transport boundary and Orca-style pairing contract are recorded in
[ADR-0012](../../decisions/0012-orca-style-mobile-pairing.md).

## References

- [Orca Mobile companion pairing](https://www.onorca.dev/docs/mobile)
- [Orca Remote Server access and revocable grants](https://www.onorca.dev/docs/remote-servers)
- [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve)
