---
id: ADR-0003
title: "ccedit ptyhostをforkしClair-owned session broker protocolを定義する"
status: proposed
date: 2026-08-27
deciders: []
related_projects:
  - "p0020-mobile-agent-remote-control"
related_issues:
  - "https://github.com/Diwamoto/clair/issues/6"
  - "https://github.com/Diwamoto/clair/issues/20"
supersedes: []
superseded_by: []
---

# ADR-0003: ccedit ptyhostをforkしClair-owned session broker protocolを定義する

## Context

ccedit V1 ptyhostはapplication restartをまたいでPTYを維持するが、1 shared subscriber、u32 length-prefixed JSON、base64 PTY bytes、256 KiB raw ring replay、attach時resizeを前提とする。Protocol version、frame allocation bound、subscriber cursor、gap、authorization、control ownershipがない。

Clairは#6でlocal native terminal用のbinary transportへ移行し、#20でdesktopとmobileを同じsessionへ接続する。V1 wire compatibilityを保ちながらremote要件を追加すると、single-client前提とsecurity boundaryがcompatibility constraintとして残る。

## Decision drivers

- Detached PTY lifecycleとrestart reattachの実績を再利用する。
- Local terminal hot pathからbase64/JSONを除去する。
- Multiple subscriber、cursor replay、gap、backpressureをprotocol primitiveにする。
- Local agent serverをinternetへ直接公開せず、Clairがauthorizationを統一する。
- Version skewとmalformed frameを明示的に処理する。
- Remote機能のrollbackでlocal PTYを停止しない。

## Options considered

### Option A: V1 wire protocolを維持してmethodを追加する

- Advantages: ccedit側client/host codeを小さな変更で再利用できる。
- Disadvantages: base64、single sink、unbounded frame allocation、resize side effectをcompatibility contractとして残す。Sequenceやauthを後付けしてもsemanticが複雑になる。
- Evidence: ccedit `protocol.rs`と`manager.rs`のstatic analysis。

### Option B: V1 ptyhostと別にremote-only daemonを作る

- Advantages: Existing local codeを変更せず、remote experimentを隔離できる。
- Disadvantages: 2 processがPTY output、journal、resize、input ownershipを同期する必要があり、sessionの正本が二重化する。
- Evidence: Remote daemonがPTY masterを持たなければbrokerへ接続する必要があり、結局broker protocolが必要になる。

### Option C: V1 implementation conceptをforkし、Clair-owned broker protocolを新設する

- Advantages: PTY survivalを再利用しつつ、wire/manager modelをClair要件で設計できる。Localとremoteが同じsession stateを利用する。
- Disadvantages: ccedit V1とのwire互換を失い、migrationと新しいcodec/testが必要。
- Evidence: Clair #1と#6は別app data、binary transport、protocol compatibility判断を前提にしている。

### Option D: Agent vendor serverをsession brokerとして使う

- Advantages: 対応agentのconversation、event、approvalを利用できる。
- Disadvantages: Generic shell/unknown agent/PTY lifecycleを扱えず、vendorごとにsessionの正本が分かれる。
- Evidence: Codex App Server、OpenCode server、Claude Remote Controlは相互互換ではない。

## Decision

Option Cを採用候補とする。

- ccedit V1のdetached PTY lifecycle implementationをsource-level prior artとしてforkする。
- Clair wire protocolはV1と非互換にし、protocol major/minorとcapability negotiationを最初から持つ。
- `clair-host`をsession identity、PTY lifecycle、output epoch/offset、journal、subscriber、lease、adapter mappingの唯一の正本にする。
- Control planeはJSON-RPC 2.0、terminal data planeはbounded binary frameとする。
- Subscriberごとにcursorとbounded queueを持たせ、slow consumerを他client/PTYから隔離する。
- Local Clair.appはsame-user Unix socket、remote clientは同じlogical protocolをauthenticated E2EE channel内で利用する。
- Mobileは初期versionでgeometry ownerにならず、desktop sizeを暗黙に変更しない。
- V1 sessionとwire stateをClairへ自動migrationしない。

## Rationale

V1から価値があるのはwire shapeではなく、PTYをapplication lifecycleから分離し、reconnectできるownership modelである。Clairではterminal rendererとUI processが変わるため、V1互換のためにbase64/JSON/single sinkを残す合理性がない。

Session brokerを唯一の正本にすれば、desktopとmobileのoutput順序、input lease、resize、agent mappingを一箇所で決定できる。Vendor serverはsemantic adapterとして使い、Clairのgeneric session lifecycleを置き換えない。

## Consequences

### Positive

- Localとremoteで同じsession/cursor/lease contractを使える。
- Binary PTY hot pathとbounded resourceを設計できる。
- V1のsingle-client raceとattach resize side effectを解消できる。
- Adapterやrelayを外してもlocal brokerを単独で利用できる。

### Negative

- New codec、schema generation、Swift/Rust client、migration codeが必要。
- `clair-host`が重要なsecurity/reliability boundaryになり、fuzz/soak testが必須。
- Snapshot formatが決まるまでfull resync contractは確定しない。
- V1で生存中のPTYをClairからreattachできない。

## Validation

- Major/minor negotiationとgolden fixtureのcross-language test。
- 3 subscriber、slow consumer、10 MiB/s outputのbounded-memory integration test。
- Disconnect、cursor replay、journal gap、host/app restartのfault-injection test。
- Concurrent input/lease/geometry ownershipのstate-machine test。
- Malformed length、oversized payload、partial frameのfuzz test。
- Remote module disable後もlocal PTY/restart reattachが継続するtest。

## Revisit conditions

- #6 spikeでV1互換を維持しながらbinary/multi-subscriber/versioningを単純に実現できる証拠が得られる。
- Detached hostを置かずにOS-level terminal/session serviceが必要lifecycleとsecurityを満たす。
- Mobile scopeを廃止し、local single-clientだけがpermanent requirementになる。

## References

- Project: [p0020-mobile-agent-remote-control](../projects/p0020-mobile-agent-remote-control/README.md)
- Investigation: [Protocol landscape](../investigations/p0020-protocol-landscape/README.md)
- Issue: [#6](https://github.com/Diwamoto/clair/issues/6)、[#20](https://github.com/Diwamoto/clair/issues/20)
- [ccedit V1 protocol](https://github.com/Diwamoto/ccedit/blob/80eef4d30f66c4520445872bed73e95c594e2695/src-tauri/ptyhost/src/protocol.rs)
- [ccedit V1 manager](https://github.com/Diwamoto/ccedit/blob/80eef4d30f66c4520445872bed73e95c594e2695/src-tauri/ptyhost/src/manager.rs)
