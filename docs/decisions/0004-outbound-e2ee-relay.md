---
id: ADR-0004
title: "Outbound-only relay上にapplication-layer E2EE remote linkを構築する"
status: proposed
date: 2026-08-27
deciders: []
related_projects:
  - "p0020-mobile-agent-remote-control"
related_issues:
  - "https://github.com/Diwamoto/clair/issues/20"
supersedes: []
superseded_by: []
---

# ADR-0004: Outbound-only relay上にapplication-layer E2EE remote linkを構築する

## Context

Mobileから自宅・職場のMacへ接続する際、router port forwarding、固定IP、inbound firewall設定を要求したくない。一方、terminal output、prompt、approval、cwd、repository情報はrelayやpush providerからも秘匿する必要がある。

Vendor remote serviceの例ではhostからoutbound connectionを作るmodelが一般的だが、data retentionとthird-party client protocolはvendorごとに異なる。Clairはagent非依存のため、自身のdevice identity、authorization scope、session resumeを持つ必要がある。

Handshakeとlibraryの詳細は[secure link spike](../investigations/p0020-secure-link-spike/README.md)が未完了であり、本ADRはproposedである。

## Decision drivers

- Mac側のinbound portを開けずにinternetから接続できる。
- Relay compromiseだけでsession内容の閲覧、入力、approvalができない。
- Device単位のpairing、scope、revocationをClairが管理できる。
- iOS background/push制約下で再接続できる。
- Private networkとrelayで同じlogical protocolを検証できる。
- Relay障害やremote disableがlocal PTY lifecycleへ影響しない。

## Options considered

### Option A: LAN/Tailscale/SSHだけをsupportする

- Advantages: Relay運用が不要で、既存network securityを利用できる。
- Disadvantages: User setupとnetwork依存が強く、一般のmobile回線からoutbound-onlyで使うproduct flowを満たさない。
- Evidence: Canary transportとしては有用だが、issue #20のrelay/push scopeを満たさない。

### Option B: RelayでTLSを終端しplaintextをrouteする

- Advantages: Server-side queue、search、push内容生成、debugが容易。
- Disadvantages: Relay operator/compromiseがterminal、prompt、approval、repository dataを読める。Retention/compliance burdenが大きい。
- Evidence: TLSはnetwork observerを防ぐが、terminating serverからpayloadを秘匿しない。

### Option C: Direct peer-to-peer/WebRTCを必須にする

- Advantages: 接続成立時にrelay bandwidthを削減できる。
- Disadvantages: NAT traversal、TURN、mobile background、enterprise networkで複雑になり、結局relay fallbackが必要。
- Evidence: Initial single-user protocolに不要なconnection-path complexityを追加する。

### Option D: Outbound relay + application-layer E2EE

- Advantages: Router設定なしで接続でき、relayからpayloadを秘匿し、opaque pushでmobileをwakeできる。
- Disadvantages: Pairing、key lifecycle、ciphertext queue、metadata leakage、relay運用をClairが設計する必要がある。
- Evidence: Host/mobileの両方がoutbound TLSを利用でき、payload encryptionをtransportの上に置ける。

## Decision

Option Dを採用候補とする。

- Hostとmobileはrelayへoutbound TLS/WebSocket connectionを作る。
- Host-mobile間にmutually authenticated application-layer E2EE sessionを確立し、Clair control/data frame全体を暗号化する。
- Relayはopaque route、ciphertext、delivery TTL、connection metadataだけを扱い、session keyを持たない。
- Push payloadはopaque wake identifierだけとし、notification内容はencrypted connection確立後に取得する。
- Device pairingはMac上のexplicit action、QR、fingerprint confirmation、scope grantを含む。
- Device revokeでactive connectionとderived session keyを即時無効化する。
- Private-network transportを先行canaryにし、同じE2EE/session protocolをrelayへ移す。
- Relay outageまたはremote disable中もlocal broker、PTY、Clair.appを継続する。

具体的なhandshake、algorithm、key storage、rotation、offline ciphertext retentionはsecure-link spikeとsecurity reviewで確定する。

## Rationale

Outbound relayはmobile usabilityとMac network safetyを両立する。Application-layer E2EEを追加することで、Clair運営または第三者運営のrelayをsession contentのtrust boundaryから外せる。Private-network canaryと同じlogical protocolを使えば、relay投入前にcursor、lease、revocationを検証できる。

TLS-only relayやvendor remoteへの委譲は短期実装量を減らすが、agent非依存protocolのprivacyとdevice policyをClairが保証できない。P2P-onlyはmobile/network条件のfailure modeが多いため初期必須経路にしない。

## Consequences

### Positive

- Router port forwardingなしでremote accessを提供できる。
- Relayとpush providerへsession plaintextを渡さない。
- Device-scoped keyとauthorizationをvendor accountから独立して管理できる。
- Relayをself-host/private deploymentへ置換可能なboundaryを保てる。

### Negative

- Crypto protocol/library integrationとsecurity reviewがcritical dependencyになる。
- RelayはIP、timing、packet size、online status等のmetadataを観測できる。
- Offline queueはciphertextでもretention、replay、expiry設計が必要。
- Mobile background制約で即時deliveryを保証できない。
- Lost-device responseとkey rotationのrunbookが必要。

## Validation

- Pairing expiry、one-time use、fingerprint mismatch、MITM、replay、counter rollbackのsecurity test。
- Relayがcaptured frameとserver stateからsession payloadを復号できないことを確認するtest。
- Device revoke後にactive connectionを閉じ、old key/frameを拒否するtest。
- Relay outage、duplicate push、offline TTL、network switch後のresume test。
- Log/crash/metricへkey、prompt、cwd、terminal bytesが出ないreview。
- Externalまたはindependent security review完了までinternet write/approvalをreleaseしないgate。

## Revisit conditions

- AppleまたはOS platformがClair要件を満たすaudited end-to-end device relayを提供する。
- Initial productをprivate-network-onlyに限定する明示的なproduct decisionがacceptedになる。
- Relay metadata leakageが許容不能となり、padding、mix network、P2Pを必須にする。
- Selected crypto libraryが保守停止、重大脆弱性、platform非対応になる。

## References

- Project: [p0020-mobile-agent-remote-control](../projects/p0020-mobile-agent-remote-control/README.md)
- Investigation: [Secure link spike](../investigations/p0020-secure-link-spike/README.md)
- Issue: [#20](https://github.com/Diwamoto/clair/issues/20)
- [Claude Code Remote Control connection and security](https://code.claude.com/docs/en/remote-control#connection-and-security)
- [Codex App Server transports](https://learn.chatgpt.com/docs/app-server)
