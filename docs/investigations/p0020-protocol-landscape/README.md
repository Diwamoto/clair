---
title: "Clair mobile agent control protocol landscape"
status: complete
related_project: "p0020-mobile-agent-remote-control"
date: 2026-08-27
---

# Clair mobile agent control protocol landscape

## Question

1. ccedit V1のdetached ptyhostから、Clairのmobile remote controlへ何を再利用でき、何を置き換える必要があるか。
2. Codex、OpenCode、Claude Code、ACPには、任意のClair terminal sessionへ共通化できるどのofficial integration surfaceがあるか。
3. Raw PTYとsemantic agent controlの境界をどこに置くべきか。

## Decision unlocked

- [ADR-0002](../../decisions/0002-layered-agent-remote-control.md): raw PTY baselineとsemantic adapterを分けるか。
- [ADR-0003](../../decisions/0003-versioned-session-broker-protocol.md): ccedit V1 wire compatibilityを保つか、Clair protocolへforkするか。
- [ADR-0004](../../decisions/0004-outbound-e2ee-relay.md): Clair自身のoutbound remote linkを持つか。

## Hypothesis

ccedit V1からはdetached PTY ownershipとrestart reattachの考え方を再利用できるが、wire protocolとsingle-subscriber managerはforkが必要である。任意agentはraw PTYでしか共通化できず、structured approvalやstatusはofficial interfaceを持つagentへのoptional adapterにすべきである。

## Compared options

- ccedit V1 protocolを拡張する。
- Agent vendorのremote/server protocolを共通protocolとして採用する。
- ACPを共通protocolとして採用する。
- Clair-owned session brokerを作り、raw PTYとagent adapterをlayeringする。

## Environment and corpus

- hardware: Static documentation/source inspectionのためnot applicable。
- OS: macOS、調査実行日は2026-08-27。
- toolchain/build: 実行buildなし。
- Clair checkout: current `master` working tree。Source issue [#20](https://github.com/Diwamoto/clair/issues/20)。
- ccedit commit: `80eef4d30f66c4520445872bed73e95c594e2695`。Relevant tracked filesにlocal modificationなし。
- Official documentation: 2026-08-27取得。
- fixture/corpus: ccedit PTY protocol/manager/session/proxy/terminal/shell integration、Clair issue #1/#6/#15、各agent公式文書。

## Method

1. Clair issue #1、#6、#15、#20とaccepted ADR-0001を読み、native rewriteのprocess/transport境界を抽出した。
2. cceditのtracked sourceをcommitに固定して静的に読み、framing、subscriber、ring replay、resize、lifecycle、shell metadataを記録した。
3. Codex App Server/Remote、OpenCode server/ACP、Claude Code Remote Control/hooks/Agent SDK、ACP v1 overviewをofficial documentationで比較した。
4. 「通常TUIを任意terminalで起動した場合」と「Clair-aware launch profileで起動した場合」を分け、後付けattach可能性を過大評価しないようにした。
5. 実行spikeが必要なterminal snapshotとsecure pairingは、別のplanned investigationへ分離した。

## Evidence

### ccedit V1

| Area | Observed fact | Remote implication |
|---|---|---|
| Framing | `protocol.rs`はu32 big-endian length + JSON。PTY data/inputはbase64。Decoderは宣言長をそのままallocateする | Binary hot path、hard frame bound、version negotiationが必要 |
| Commands | Spawn/Write/Resize/Kill/List/Attach/AttachAll/Detach/DetachAll | Local lifecycleのoperation vocabularyはprior artになるが、auth/lease/cursorがない |
| Subscriber | `manager.rs`は全sessionで1つのshared event sinkを差し替える | Desktop + multiple mobile subscriberへ拡張できない |
| Replay | 256 KiB raw byte ringをattach時に1回のData eventとして送る。Sequence、ack、gap、safe parser checkpointなし | Arbitrary tail replayはterminal parser stateを保証できず、cursor/snapshot contractが必要 |
| Geometry | Attachがrows/colsを受けて実PTYをresizeする | Mobile attachがdesktop layoutを壊すためgeometry ownershipを分離する |
| Lifecycle | `proxy.rs`はdetached sidecarへUDSで再接続し、app quitでPTYをkillしない | Detached ownershipとlocal recoveryは再利用価値が高い |
| Frontend bridge | PTY eventをTauri eventへ再emitし、xterm.jsへ渡す | Clairではlibghostty/AppKitへbinary streamを直接渡す境界へ変わる |
| Shell metadata | `shell_integration.rs`はOSC 633でcwdとcommand lineをemitする | Raw bytesはE2EE対象。Command lineをlog/relay metadataへ抽出しない |

### Clair native rewriteとの差

- [Issue #1](https://github.com/Diwamoto/clair/issues/1)はSwiftUI/AppKit shell、libghostty、Rust static core、detached Rust ptyhostを提案する。
- [ADR-0001](../../decisions/0001-adopt-swiftui-appkit-frontend.md)はterminal hot pathをper-message JSON/UniFFIから外し、binary Unix socket/shared buffer/thin C ABIを使う。
- [Issue #6](https://github.com/Diwamoto/clair/issues/6)はlocal binary transport、restart reattach、backpressure、protocol versioningを担当する。Mobile protocolはこれをpublic internet endpointにせず、同じsession stateへ別clientとして接続する必要がある。
- [Issue #15](https://github.com/Diwamoto/clair/issues/15)はagent integration parityとsecurity confirmationを扱う。Remote protocolはagent-specific detailをadapter内へ閉じ、Clair UIへnormalized capabilityを渡す必要がある。

### Agent/platform surfaces

| Surface | Officially documented behavior | Fit for Clair |
|---|---|---|
| [Codex App Server](https://learn.chatgpt.com/docs/app-server) | Rich client向けにauthentication、history、approval、streamed agent eventを提供するJSON-RPC interface。stdio、experimental WebSocket、Unix socket transport。`codex --remote` TUIを接続可能 | Clair-aware Codex sessionのsemantic adapterに適する。TCP WebSocketはexperimental/unsupportedなのでinternetへ直接露出せず、local Unix socket/stdioの外側をClair remote linkで包む |
| [Codex Remote](https://learn.chatgpt.com/docs/remote) | ChatGPT mobileからconnected computer上のtaskを開始・steer・approve・reviewするOpenAI product | UX/security precedentになるが、任意agent向けのClair third-party protocolとはしない |
| [OpenCode server](https://dev.opencode.ai/docs/server/) | `opencode serve`はOpenAPI 3.1 HTTP server。SSE event、session/message/abort/permission APIs、Basic auth、multiple clientsを提供。TUI自身もserver client | Fixed localhost address/credentialでClair-aware launchするsemantic adapterに適する。Randomly assigned既存TUI serverの安全なdiscoveryは仮定しない |
| [OpenCode ACP](https://dev.opencode.ai/docs/acp/) | `opencode acp`がJSON-RPC stdioのACP subprocessとして動く | Generic ACP adapter経由のClair-native sessionに適する。任意の既存PTYへのattachではない |
| [Claude Code Remote Control](https://code.claude.com/docs/en/remote-control) | Local Claude Codeがoutbound HTTPSだけでAnthropic APIへ接続し、mobile/webと同期。Short-lived credentialsを使い、remote中のtranscriptをAnthropic serverへ保存 | Vendor提供UIとしては要件に近いが、Clair/unknown agent共通transportにできない。公式ページでthird-party client protocolは示されていない |
| [Claude Code hooks](https://code.claude.com/docs/en/hooks) | Session、turn、tool、permission等のlifecycleでcommand/HTTP等へstructured JSONを渡し、eventによってdecisionも返せる | Status/observability/policy integrationに利用可能。ただしremote client session transport、replay、mobile identityを提供しない |
| [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/overview) | Custom application内でagent loopを実行し、local filesystem/toolsを使えるSDK | Clair-native Claude sessionのsemantic implementation候補。Terminalで通常起動した既存Claude Code sessionと同一ではない |
| [ACP v1](https://agentclientprotocol.com/protocol/v1/overview) | JSON-RPC、initialize capability negotiation、session/prompt/update/cancel、permission、terminal、extensibilityを定義。Agentは通常clientのsubprocess | Normalized semantic modelの強い参考/adapter。PTY stream broker、multi-viewer remote、E2EE/device lifecycleは別途必要 |

## Results

1. ccedit V1から再利用すべき中心は、PTYをUI processから分離して生存させるprocess ownershipである。Wire formatとsubscriber managerはremote要件に適合しない。
2. Clair native化により`base64 -> Tauri event -> JavaScript -> xterm.js`を維持する理由がなくなる。Localもbinary streamへ移行するため、V1 wire compatibilityを捨てるcostは相対的に小さい。
3. Raw PTYは唯一のagent-independent interfaceである。ただしterminal tailだけのreplayではrenderer stateを正しく復元できる保証がなく、snapshot spikeが必要である。
4. CodexとOpenCodeはsemantic adapterに利用できるofficial local surfaceを持つ。どちらもClair-aware launchならsession mappingを確実にできるが、通常起動済みTUIへ後付けattachできるとは限らない。
5. Claude Code Remote ControlはClairの目標に近いproduct precedentだが、Anthropic-managed connection/transcript modelである。Clair protocolのtransportとして利用するのではなく、raw PTYまたは別のAgent SDK profileを検討する。
6. Claude hooksはevent/policy補助に使えるが、host-mobile protocolの代替ではない。
7. ACPはsemantic normalizationとcapability negotiationの参考になるが、「clientがagent subprocessを所有する」modelであり、任意の既存terminal sessionを包括しない。

## Analysis

Vendor protocolを1つ選ぶだけでは、任意agent、同一PTYのdesktop/mobile同時表示、detached lifecycle、device revocationを満たせない。一方、すべてをraw terminalへ落とすとapprovalをdisplay heuristicで扱う危険がある。

従って、Clair-owned session brokerがPTY lifecycle、output cursor、subscriber、lease、device policyの正本になり、agent adapterはoptional capabilityとして同じsessionへ紐付く構成が最も要件に合う。ACPのmethod/capability modelは参考にできるが、Clair固有のterminal stream、remote security、multi-client contractは独立して定義する必要がある。

Internet transportはvendor local serverを直接公開しない。Codexのdocumented TCP WebSocketがexperimental/unsupportedであること、OpenCode serverがHTTP Basic authを基本とすることからも、Clairがlocal adapterとremote trust boundaryを分離する方が安全である。

## Recommendation

- ccedit V1 ptyhostをsource-levelでforkし、Clair-owned versioned session brokerへ進化させる。V1 wire compatibilityは維持しない。
- Raw PTYを全sessionのbaselineにし、structured actionをTUI parsingで推測しない。
- ACPをgeneric semantic adapterとして実装し、Codex App ServerとOpenCode server/ACPをvendor adapterへ追加する。
- Claude Code通常TUIはraw-onlyとし、hooksは補助、Agent SDKは別のClair-native launch profileとして評価する。
- Local multi-subscriber/cursor/leaseを先に完成させ、private-network read-only canary、E2EE relay、semantic adapterの順に導入する。
- Terminal snapshotとsecure linkは実装前spikeを完了し、proposed ADRをacceptできる証拠を作る。

## Limitations

- 各agentを実際に起動したwire capture、version matrix、latency/throughput measurementは行っていない。
- Codex/OpenCode/Claudeのofficial surfaceは更新され得るため、adapter実装時にpinned versionのschemaを再取得する必要がある。
- Claude Code公式文書にthird-party Remote Control protocolが見つからないことは「非公開interfaceが存在しない」証明ではない。設計上はpublic supported contractとして依存しない。
- Terminal snapshotのlibghostty serialization可否、mobile renderer互換性は未検証。
- Crypto algorithm/library、Secure Enclave/Keychain integration、relay運用は未検証。
