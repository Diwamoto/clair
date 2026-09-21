---
id: ADR-0016
title: "遠隔 client 用 network transport を host listener と mobile adapter で実装する"
status: proposed
date: 2026-09-22
deciders: []
related_projects:
  - "p0020-mobile-agent-remote-control"
related_issues: []
supersedes: []
superseded_by: []
---

# ADR-0016: 遠隔 client 用 network transport を host listener と mobile adapter で実装する

`N11` の実装前設計。security 境界と公開 protocol に触れるため、**承認されるまで実装しない**
(`docs/clair-tasks.md` の `N11` user gate)。

## Context

[ADR-0012](0012-orca-style-mobile-pairing.md) は認証モデル(one-time pairing、device key、
challenge、grant scope、revoke)を決め、`H03`/`T04`/`N02` がそれを in-process で実装した。
しかし**線の上に載せる層が無い**。2026-09-22 の調査で確認した事実:

- `ClairPairingAuthority` は actor で、client(`ClairNativeClientTransport`/`ClairMobileClient`)は
  それを直接呼ぶ。network を渡る frame も listener も存在しない。`NWListener`/`NWConnection` は
  リポジトリに無い。`ClairNativeTransportChannel`(`send`/`receive`/`close`)と
  `ClairNativeTransportCodec`(frame 符号化)だけが seam として先に置かれている。
- mobile の transport 5 種(`ClairMobileTransport`、`ClairMobileAgentTransport`、
  `ClairMobileWorkspaceReading`、`ClairMobileSessionVerifying`、`ClairMobileTerminalTransport`、
  加えて `ClairMobilePushRegistering`)は protocol と `Unavailable` 実装のみ。
- daemon の `ClairPairingAuthority` は `wss://127.0.0.1/clair` という placeholder endpoint と、
  **起動ごとに新規生成される `ClairHostSigningKey()`** で作られる(`ClairDaemon/main.swift`)。grant・token も
  メモリ上だけ。つまり daemon を再起動すると host fingerprint が変わり、全 device が re-pair を要求される。
- `ClairMobileClient` はアプリ内で一度も生成されていない(`ClairMobileRootView` が参照しない)。
- `ClairAuthenticatedConnection` の `init` は `ClairTransport` module 内 internal で、wire から
  構築できないことが意図された設計。よって mobile module の adapter は現状これを作れない。

これらが揃わない限り、iPhone→Mac の terminal / agent / diff は実機で一度も動かない。

## Decision drivers

- 既存の H03/T04 契約(revoke、grant scope、epoch/cursor)を**変えない**。
- 認証・認可は channel でも network route でもなく authority が持つ(`ClairNativeTransportChannel` の doc)。
- 平文経路を作らない。LAN/tailnet に到達できるだけでは何もできない(ADR-0012 §6)。
- mobile が host-only の `ClairDaemonKit` を link しない。
- 最小の実装で実機の terminal attach を通す。

## Decision

### 1. 経路: Network.framework の TLS 1.3 over TCP、endpoint は `tls://host:port`

`ClairTransportEndpoint` は既に `tls`/`tcp`/`https`/`wss` を許す。追加の依存は無く、iOS/macOS 双方が
標準で持つ。WebSocket は使わない(frame 境界は `ClairNativeTransportChannel` が長さ prefix で持つ)。

- host: `NWListener` + TLS。leaf 証明書は persist した host key から作る自己署名で、
  client は pairing link の fingerprint に **pin** する(`ClairHostPin.certificateFingerprint` が既に受け口)。
  system trust store には頼らない。
- client: `NWConnection` の `sec_protocol_options_set_verify_block` で pin と一致しない証明書を拒否する。
  `ClairNetworkTLSMobileTransportBoundary.openChannel(to:pinnedTo:)` をこれで実装する(現状 `.unavailable`)。

### 2. wire protocol: authority の呼び出しを 1:1 で frame 化する

1 本の TLS connection = 1 本の `ClairNativeTransportChannel`。frame は既存の
`ClairNativeTransportCodec`(`ProtocolCodec`、`FrameLimits`)を使い、request ID を持つ request/response とする。

| 段階 | frame | host 側の処理 |
| --- | --- | --- |
| 未認証 | `presentation` / `pair` / `beginAuthentication` / `authenticate` | `ClairPairingAuthority` の同名メソッド |
| 認証後 | `authorizeRead` / `agent.dispatch` / `workspace.*` / `verify` / `terminal.*` / `push.*` | 既存の boundary(`ClairAgentCommandBoundary`、`ClairTerminalBoundary`、`ClairSessionJournal`、`ClairDaemonPushRegistry`) |

**認証後の frame が運ぶ `ClairAuthenticatedConnection` は host が無視する。** host は channel に
束縛した server 側の connection だけを使う。client が偽の値を送っても権限は増えない。

terminal は既存 protocol に合わせて **pull(`read`)のまま**とし、long-poll で受ける。push 配信は
backpressure の契約(`T04`)を作り直すことになるので今回は入れない。

### 3. `ClairAuthenticatedConnection` の client 側構築(**公開 API の変更**)

mobile 側 adapter が protocol の引数型を満たすため、`ClairConnectionInfo` から
**client 用の不活性な値**を作る公開 init を足す。値は authority が持つ handle と一致しないので、
仮に host へ送り返されても `authorize`/`close` は拒否される(上記の無視と二重で守る)。
既存 protocol のシグネチャは変えない。

### 4. host の永続化(N11 の最初の slice)

- host signing key は macOS Keychain に保存し、daemon 再起動で fingerprint を変えない。
- grant(`device_id`、公開鍵、scope、generation、token digest、revoked)は daemon の protected storage
  (`ClairDaemonPaths` 配下、0600)へ保存する。token 本体は保存せず digest のみ(現状の `StoredGrant` と同じ)。
- operation ledger(idempotency)の永続化は今回スコープ外。再起動をまたぐ重複実行の窓は
  `ponytail:` で明記する(上限: 再起動直後の 1 request)。

### 5. 待受と経路

- 既定は **loopback のみ bind**。実機からの到達は Tailscale Serve を **TCP passthrough**
  (`tailscale serve --tcp`、TLS 終端しない)で行い、Clair 自身の TLS を end-to-end にする。
  Tailscale が TLS を終端すると pin が成立しない。
- LAN 直接待受は設定で明示的に有効化したときだけ(既定 off)。ADR-0012 の「private route 前提」に従う。
- 待受 port、有効/無効、現在の接続 device 一覧は Mac の設定と `N09` の pairing 面に出す。

### 6. resource limit と失敗の閉じ方

- 未認証 connection: 認証完了までの deadline(10 秒)、同時数の上限、認証失敗の回数制限。
- 認証済み: device あたりの同時 connection は `ClairTransportValidation.maximumActiveConnections` を使う。
- frame 上限超過、未知 frame、不正 UTF-8 は connection ごと即切断(診断は `H10` の structured diagnostics)。
- revoke: `ClairPairingAuthority.revoke` が返す `closedConnectionIDs` の channel を listener が閉じる。
  channel が閉じたら `authority.close` を呼ぶ。

## Options considered

### Option A: TLS over TCP を直接(採用)

- Advantages: 依存ゼロ、pin と単一 endpoint が単純、`Network.framework` が iOS の後ろ盾。
- Disadvantages: 自前の frame と heartbeat を持つ。
- Evidence: `ClairNativeTransportChannel` と `ClairHostPin.certificateFingerprint` が既にこの形を想定している。

### Option B: WebSocket(`wss`)

- Advantages: 既存の reverse proxy / Cloudflare Tunnel と相性が良い。
- Disadvantages: HTTP upgrade と proxy 終端が入り、pin と Cloudflare の TLS 終端が衝突する。
  frame は結局 binary で、得るものが無い。

### Option C: ADR-0004 の outbound E2EE relay を先に作る

- Advantages: port を開けずに外出先から接続できる。
- Disadvantages: relay 運用、E2EE handshake、offline queue が必要。ADR-0004 自身が private-network を先行 canary と定めている。
  同じ logical protocol を載せるので、本 ADR の後続にできる。

## Consequences

### Positive

- 実機 iPhone→Mac の terminal / agent / diff が初めて通る(`N10`、`T07`、`N08` の前提)。
- 再起動をまたいで pairing が保たれる。

### Negative

- security 境界に新しい攻撃面(listener)ができる。D5 独立レビューと threat test が必須。
- mobile 側 adapter が 5〜6 個の protocol 分の frame 定義を持つ。

## Validation

- loopback の `NWListener` を使う integration test:
  pair → reconnect → terminal attach → input → detach、scope の無い device の拒否、
  pin 不一致の拒否、revoke で live channel が閉じること、未認証 deadline、oversize frame、
  daemon 再起動後の再接続。
- mobile module が `ClairDaemonKit` を link しないこと(既存の依存 test を維持)。
- 実機: `T07`(terminal integration gate)と `N08`(dogfood gate)。

## 提案する task 分割(承認後に queue へ反映)

1. **N11**(D5): host 永続化 + `NWListener` + wire protocol + loopback integration test。
2. **N12**(D4): mobile 側の具象 adapter 5〜6 種 + `ClairAuthenticatedConnection` の client 用 init。
3. **N13**(D3): `ClairMobileClient` のアプリ内 composition と `N10` が使う接続 state の供給。

`N10` の依存に `N12`/`N13` を足し、`N08` の依存は `N11` から `N13` まで広げる。

## 要判断

1. §1 の経路(TLS over TCP、自己署名 + pin)でよいか。
2. §5 の既定(loopback bind + Tailscale Serve の TCP passthrough、LAN 直接は opt-in)でよいか。
3. §3 の `ClairAuthenticatedConnection` の公開 init 追加を認めるか。
4. task 3 分割でよいか。

## Revisit conditions

- 外出先から port 設定無しで使う要件が優先になったら ADR-0004 の relay を前倒しする。
- pin と Tailscale Serve の組合せが実機で成立しないと分かったら、経路を見直す。
