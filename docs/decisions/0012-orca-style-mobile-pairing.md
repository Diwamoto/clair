---
id: ADR-0012
title: "Orca型mobile pairingとtransport-neutral host APIを採用する"
status: accepted
date: 2026-09-04
deciders:
  - "Daiki"
related_projects:
  - "p0020-mobile-agent-remote-control"
related_issues:
  - "https://github.com/Diwamoto/clair/issues/20"
supersedes: []
superseded_by: []
---

# ADR-0012: Orca型mobile pairingとtransport-neutral host APIを採用する

## Context

Mobile controlの接続経路には、Cloudflare private route、Tailscale、将来のClair-owned relayという複数の選択肢
がある。これらのnetwork identityや経路ごとのcredentialをmobile protocolへ直接持ち込むと、APIがtransportに
依存し、Tailscaleの到達性がそのままMac全体への権限になり得る。

Orcaのmobile companionは、desktopをsource of truthとして、明示的なone-time pairing、接続先、host fingerprint、
端末ごとのdevice token、端末単位のrevokeを組み合わせている。接続先がLAN/Tailscaleで変わっても、同じhostで
あることを確認できれば既存のpairingを再利用する。この境界はClairのsingle-user mobile controlにも適用できる。
採用するのはこの認証モデルとユーザー体験であり、Orcaのwire protocol、token形式、実装をそのまま依存・互換化する
ものではない。

## Decision

### 1. Clair-owned host APIを唯一のremote boundaryにする

- `clair-mobile-host`をmobile protocolのgatewayとする。
- mobileから外部に見えるのはこのgatewayの単一endpointだけにする。
- `clair-ptyhost`はsame-user Unix socket/local IPCに閉じ、raw TCP/HTTP/WebSocket listenerを持たせない。
- gatewayはsession catalog、terminal stream、operation authorization、pairing/revokeをClairのcontrol planeへ
  投影する。PTYのlifecycleとjournalの正本は引き続き`clair-ptyhost`が持つ。

### 2. TransportをAPIから分離する

`MobileControlTransport`はtyped control/data protocolへbyte streamを提供する薄い境界とする。初期の実装対象は
次のとおりとする。

- Cloudflare One Client / Tunnel private route: 配布向けの既定経路
- Tailscale Serve: 自所有環境・開発用の経路。localhostのgatewayだけをServeする
- outbound relay: private-network canary後の後続経路

Tailscale/Cloudflareのnetwork identity、route policy、account credentialは、Clairのdevice grantやoperation
scopeの代わりに使わない。Tailscaleではsubnet route/Exit Nodeを使わず、Cloudflareでは広いCIDR routeを避け、対象
host/portをgatewayへ限定する。

### 3. Orca型one-time pairingを採用する

Macの明示操作で、短時間だけ有効なpairing linkを生成する。QRまたはdeep linkには以下だけを含める。

- `host_id`
- 接続endpoint
- server identity / TLS public-key fingerprint
- protocol version
- one-time bootstrap secret
- expiry

Pairing linkにはdevice private key、発行済みdevice token、terminal bytes、prompt、cwd、credentialを含めない。
未使用linkは一度だけ消費でき、linkを再生成すると前の未使用linkだけを無効化する。すでにpair済みのdevice grant
はrevokeされるまで維持する。

### 4. 端末ごとのgrantとtokenを発行する

Pairing時にmobileはprotected storage内でdevice key pairを生成または再利用する。hostはbootstrap secretを原子的に
消費し、端末ごとに次を保存する。

- `device_id`
- device public key
- opaque device token
- token generation
- display name、scopes、visible worktrees
- created/last-used/revoked state

device tokenは発行時に一度だけmobileへ返し、mobile Keychainとhostのprotected storageへ保存する。共有tokenやMac
account tokenをmobileへ渡さない。reconnectではdevice ID、token、fresh challengeへのdevice-key proofを使う。

### 5. Host identityとendpointを分ける

mobileは`host_id`とserver fingerprintをpinする。保存済みhostのendpointは、LANからTailscale、または同一hostの
Cloudflare endpointへ変更できる。ただしfingerprintが一致しない場合は接続を停止し、explicit re-pairを要求する。
endpoint変更を理由にcredentialを再発行しない。

### 6. RevokeとscopeをClairが強制する

- 各deviceは独立したgrantを持つ。
- Macのdevice listから端末単位にrevokeできる。
- revokeはtoken generationを進め、active connectionを閉じ、旧token・challenge・operationを拒否する。
- pairing直後は`view`のみ。`write_terminal`、`signal`、`terminate`、`spawn_session`、`manage_devices`は個別
  scopeとして付与する。
- Tailscale/Cloudflareへ到達できることだけではsession catalogやcontrolを利用できない。

### 7. Private-network MVPとE2EE relayを分ける

Private-network MVPではTLS/public-key fingerprint pinning、device token、challenge、scope、revokeを必須とする。
Relayからpayloadを秘匿するapplication-layer E2EEのalgorithm、key rotation、offline queueは
[ADR-0004](0004-outbound-e2ee-relay.md)とsecure-link spikeで別途確定する。private-networkとrelayは、認証後に使う
logical MobileControl protocolを共有する。

## Pairing state machine

```text
unpaired
  └─ Mac: create link ─▶ link-issued
                         ├─ expired/reused ─▶ unpaired
                         └─ mobile confirms fingerprint
                              └─ host consumes secret ─▶ paired
                                                         ├─ reconnect: token + challenge
                                                         ├─ endpoint change, same fingerprint
                                                         └─ Mac revoke / reset ─▶ revoked
```

`link-issued`から`paired`への遷移は一回だけである。`revoked`のdevice ID/tokenは再利用せず、新しいpairingで新しい
device grantを作る。

## Consequences

### Positive

- Tailscale、Cloudflare、将来relayでmobile APIと認証状態機械を共有できる。
- Tailscaleのtailnet参加がMac全体の権限に昇格しない。
- Orcaと同じく、端末単位の削除・再接続・endpoint変更をユーザーに説明しやすい。
- `clair-ptyhost`のlocal same-user boundaryを保ったまま、mobile gatewayをテストできる。

### Negative

- QR link、device token、device key、host fingerprintのlifecycleを実装・テストする必要がある。
- Tailscale/Cloudflareのnetwork policyとClairのapplication grantを二重に設定する必要がある。
- Secure Enclave/Keychain fallbackと暗号algorithmの決定はまだsecure-link spikeに残る。
- mobile endpointが変更されても同一hostと判断できるよう、host identityを永続化する必要がある。

## Revisit conditions

- 一般配布でTailscale/Cloudflare Clientの導入が大きな障壁になった場合は、同じpairing/grant modelをoutbound relayへ
  移す。
- 複数ユーザー、team role、organization auditを導入する場合は、single-user device grantをteam identity ADRで
  拡張する。
- Secure-link spikeでhost fingerprint + token + challengeだけでは要件を満たせない証拠が出た場合は、E2EE handshake
  を先に適用する。

## References

- [Orca Mobile companion](https://www.onorca.dev/docs/mobile)
- [Orca Remote Server access and revocable grants](https://www.onorca.dev/docs/remote-servers)
- [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve)
- [Outbound E2EE relay ADR](0004-outbound-e2ee-relay.md)
- [Mobile agent control design](../projects/p0020-mobile-agent-remote-control/design.md)
