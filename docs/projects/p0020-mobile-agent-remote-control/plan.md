# Implementation plan

## Acceptance mapping

| Acceptance | Slice | Validation |
|---|---|---|
| AC-01 | 0 | `swift test --package-path packages/ClairMobileKit` |
| AC-02, AC-03 | 1 | broker multi-subscriber, cursor/gap, restart integration tests |
| AC-04 | 1, 2 | ordered input, operation dedupe, viewport/resize tests |
| AC-05, AC-11, AC-13 | 2 | QR scope/revoke/disable and per-device credential security tests |
| AC-06 | 1, 3 | private-network iOS smoke with shell and registered profiles |
| AC-07 | 3 | APNs payload redaction and foreground resume test |
| AC-08 | 3 | GitHub Actions TestFlight internal build workflow check |
| AC-09, AC-14 | 1, 2, 3, 4 | bounds, slow consumer, outage, single-endpoint isolation, agent exit, resource tests |
| AC-10 | 1A | shared agent registry, CLI projection, headless confirmation, and typed errors |
| AC-12 | 2, 3 | endpoint migration, host fingerprint pinning, and explicit re-pair tests |

## Dependencies

- P07 local session lifecycle and reattach.
- P09 raw agent workflow and attention.
- P10 managed worktree identity for worktree-scoped catalog filtering.
- P13 typed Command Registry for registered agent launch projection.
- Accepted product scope and [ADR-0011](../../decisions/0011-early-mobile-agent-control.md).

## Current execution status (2026-09-05)

- [x] `MobileControlHost`がhost identity、one-time pairing、P-256 challenge、opaque token digest、device revoke、
  scope/worktree visibility、remote disableを一元管理する。
- [x] localhost-only framed listenerとNetwork.framework clientが同じRPC/terminal envelopeを利用する。
- [x] session journal、per-subscriber bounded queue、epoch/cursor gap、arrival-order input、操作配送handlerを共有する。
- [x] iOS/macOS共有client stateがlocal viewport、bounded raw scrollback、duplicate/gap/exitを扱う。
- [x] APNs向けcontent-free attention payloadを定義する。
- [x] macOS app runtimeへhost/PTY/agent bridgeを接続し、復元済みProject/sessionとAgent状態をhostへ投影する。
- [x] macOS settingsへhost fingerprint、one-time QR/deep-link表示、device list/revoke UIを接続する。
- [x] native iOS UI、deep link pairing、Keychain credential store、raw session/agent controlsを実装する。
- [ ] Cloudflare/Tailscale実運用、APNs送信、private TestFlight CIを実装・検証する。

localhost endpointまでのmacOS sliceとnative iOS client foundationは検証済みだが、private route、APNs、TestFlightが未実装である。
この状態ではP16のキュー項目を`active`に保つ。host coreとruntime projectionの検証済み範囲を固定し、未実装の運用経路を完了扱いにしない。

## Slice 0: Shared protocol foundation — complete

### Changes

- `ClairMobileKit`をiOS/macOS Foundation-only Swift packageとして追加する。
- major/minor negotiation、capability、stable session catalog、device scopeを型にする。
- 64 KiB bounded binary terminal frameをbase64なしでencode/decodeする。
- device scope、worktree visibility、broker arrival-order input、bounded operation dedupeをテストする。

### Validation

- 2026-09-03: 8 tests passed. Covers version intersection/major rejection, raw byte preservation, bounds, stable-ID
  worktree filtering, ordered input, revoked/read-only rejection, and operation ID reuse.

### Completion

- [x] code
- [x] tests
- [x] shared fixture contract

## Slice 1A: Clair agent control plane and CLI projection — complete

### Changes

- Clairが復元済みを含むagent terminal tabをstable session IDで発見し、factual lifecycle、attention、
  capabilityを返す。
- `agent.list`、`agent.status`、`agent.input`、`agent.interrupt`、`agent.stop`をCommand Registryへ追加し、
  registered profile launch/revealと同じadapterから実行する。
- `ClairMobileKit`へagent catalog、registered profile launch、agent input/controlのoperationとscope
  authorizerを追加する。
- native Rust `clair` CLIへlist/status/launch/reveal/input/interrupt/stopを追加し、`--yes`で画面なしの
  mutating testを可能にする。`scripts/clair`はsource-tree compatibility adapterとして維持する。

### Validation

- MobileKit 12 tests、Clair Swift 109 tests、Rust CLI tests/clippy、Swift 6 type-check、CLI py_compile/help、
  Xcode project consistency、Debug/Release bundle smoke。

### Completion

- [x] code
- [x] tests
- [x] same command identity documented

## Slice 1: Host bridge and local multi-client contract

### Changes

- `clair-mobile-host`を`clair-ptyhost`の前段に置き、mobile APIの唯一のremote boundaryにする。hostはlocalhostで
  listenし、`clair-ptyhost`へはsame-user Unix socket/local IPCで接続する。
- `clair-ptyhost` session catalogをmobile protocolへ投影し、P07のjournal/subscriberをreuseする。
- initialize、session/list、session/subscribe、terminal/output、terminal/gap、terminal/input、agent/launchを接続する。
- per-subscriber bounded queue、epoch/cursor、arrival sequence、operation dedupeをhost側の唯一の正本にする。
- `MobileControlTransport`を導入し、WebSocket/binary protocolの上にTailscale Serve、Cloudflare private route、
  将来relayを差し替えられるようにする。transport adapterへscopeやdevice tokenの判断を漏らさない。
- mobile viewportをPTY resizeへ流さず、local brokerのsame-user boundaryを維持する。

### Implementation progress (2026-09-05)

- `MobileControlRuntimeBridge`をmacOS appへ組み込み、`ProjectWorkspaceModel`、`AgentWorkflowCoordinator`、
  `TerminalSession`の事実を共有hostへ投影した。accepted terminal/agent operationsは既存のMainActor所有者へ戻す。
- Mac settingsからremote kill switch、host fingerprint、one-time QR/deep link、paired device revokeを操作できる。
- 最後のworkspace windowを閉じてもapplication delegateは終了せず、明示的なQuitだけが通常のPTY cleanupを行う。
- 実ネットワーク経路は残課題のため、Slice 1/2は完了扱いにせずSlice 3へ引き継ぐ。

### Validation

- desktop 1台 + mobile viewer 2台、slow consumer、disconnect/reconnect、journal gap、host/app restart。
- shellとunknown CLIのraw input/interrupt、registered Claude/Codex/OpenCode launch。
- malformed/oversized/partial frameとlocal feature disable。
- `clair-ptyhost`にnetwork listenerがなく、mobileが`clair-mobile-host`の単一endpointからだけ到達できること。

## Slice 2: Pairing, authorization, and Mac controls

### Changes

- Orca型のexplicit QR/deep-link pairingを実装する。linkにはendpoint、`host_id`、server identity/TLS fingerprint、
  protocol version、短時間のone-time bootstrap secretだけを含める。
- mobile側でdevice key pairをprotected storageに作り、hostがpairing secretを一度だけ消費して端末固有の
  `device_id`、opaque device token、grant、generationを発行する。
- reconnectは保存token + device-key challenge proofで行う。endpoint変更はpinned host identity/fingerprintが同じ場合
  だけ許可し、fingerprint変更はexplicit re-pairにする。
- Macのdevice list/revoke、scope grant、remote kill switchを実装する。
- default `view`、dangerous operation guard、device generation、active connection closeを実装する。
- pairing secret/key materialをOS protected storageへ置き、terminal/prompt/cwdをログから除外する。

### Validation

- expired/reused QR、wrong device、host fingerprint mismatch、token/device-key mismatch、scope escalation、
  revoked connection、generation rollback、operation replay、secret redaction。
- 端末Aのtokenが端末Bで使えないこと、link再生成が未使用linkだけを無効化すること、既存grantがrevokeまで残ること。
- remote disable後もPTY、Mac terminal、local reattachが継続すること。

## Slice 3: iOS client, private transports, APNs, TestFlight

### Changes

- native iPhone/iPad clientにsession list、raw renderer、bounded scrollback、input、interrupt、agent launchを実装する。
- QR/deep link scanner、host list、fingerprint confirmation、per-host token storage、re-pair/revoke UXを実装する。
- `MobileControlTransport`のCloudflare One Client / Tunnel private route adapterを実装する。
- Tailscale Serveをself-owned/dev transportとして実装または検証し、localhostの`clair-mobile-host`だけを公開する。
- APNsはopaque wake identifierのみを送り、foregroundでsecure channelを再開する。
- GitHub Actionsでmain/manual/30日scheduleのprivate TestFlight internal buildを作る。

### Implementation progress (2026-09-05)

- `Clair Mobile` iOS 17 targetとURL scheme付きInfo.plistを追加した。
- SwiftUIで概要、session catalog、bounded raw terminal、local cursor/gap/exit、input/interrupt、attention、
  registered profile launch、pairing/settingsを実装した。
- pairing deep linkのdecode、host fingerprint確認、P-256 device keyとcredentialのKeychain保存、challenge認証、
  session subscribeの初期replay race処理を`ClairMobileKit`と接続した。
- iOS SDK型チェックに加えて、`make build-mobile-simulator`でiPhone 17 Simulator向けのunsigned destination buildを通し、
  `simctl install`、launch、`clair://pair`からpairing sheet表示まで確認した。vendor private route canaryと実機E2Eは未実施である。

### Validation

- network switch、background/foreground、duplicate push、CJK/IME、large paste、offline expiry、endpoint変更。
- Tailscale/Cloudflare private-network canaryでpair/view/input/revoke/disableを同じfixtureでmanual smokeする。

## Slice 4: Agent convenience and hardening

### Changes

- attentionをmobileで一覧・filterし、registered profileのlaunch/reveal/interruptを短い操作へまとめる。
- sleep policy、content-free diagnostics、resource/backpressure metricsを追加する。
- semantic adaptersは別flag・別contractとして、必要性が確認されたagentだけを追加する。

### Validation

- agent exit/bell/hook、adapter unavailable時のraw fallback、slow consumer、Tailscale/Cloudflare outage、rollback。
- mobileからの操作が同じCommand/operation identityを使うことを確認する。

## Deferred follow-ups

- host-owned portable terminal snapshotと完全resync。
- public relay/E2EE、traffic padding、team identity。
- semantic approval、Codex/OpenCode/ACP adapter、mobile branch review。
- Android、mobile source editor、attachments。
