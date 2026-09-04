---
id: ADR-0002
title: "Raw PTYを共通基盤としsemantic agent adapterを追加層にする"
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

# ADR-0002: Raw PTYを共通基盤としsemantic agent adapterを追加層にする

## Context

Clair上のterminalではClaude Code、Codex CLI、OpenCodeだけでなく、未知または将来追加されるcoding agentも起動される。利用者はどのagentでもmobileから進捗確認と基本操作を行いたい。一方、prompt、tool call、permission、approval、statusのstructured interfaceはagentごとに異なり、通常のTUI processが後付け可能なlocal APIを公開するとも限らない。

Raw PTYには表示bytesとinput channelがあるため普遍性は高いが、表示文字列だけではapproval対象、arguments、expiry、one-time identityを安全に決定できない。Semantic integrationだけに依存すると、対応していないagentや通常起動済みTUIを扱えない。

関連調査は[protocol landscape](../investigations/p0020-protocol-landscape/README.md)、設計は[p0020](../projects/p0020-mobile-agent-remote-control/design.md)を参照する。

## Decision drivers

- Clairが管理する任意のPTY sessionを最低限操作できること。
- Approvalやdangerous actionをTUI表示のheuristicへ依存させないこと。
- Agent vendorのschema変更をClair remote protocol全体へ漏らさないこと。
- Unsupported adapterがlocal/remote terminalを停止させないこと。
- ACP等のopen protocolを活用しつつ、既存PTY attachとの違いを保つこと。

## Options considered

### Option A: Raw PTYだけを提供する

- Advantages: 全agentへ同じ実装を使え、vendor追従が不要。
- Disadvantages: approval、tool call、status、diff等の意味を安全に扱えず、mobile UXがterminal操作に限定される。
- Evidence: PTY streamはaction identityやauthorization contextを持たない。

### Option B: Vendorごとのsemantic interfaceだけを提供する

- Advantages: 対応agentではrich UIと正確なapprovalが可能。
- Disadvantages: 未知agentとattach不能な通常TUIを扱えず、Clairの「任意terminal」要件を満たさない。
- Evidence: Codex、OpenCode、Claude Codeで公開surfaceとremote modelが異なる。

### Option C: TUI screen parsingで共通semantic modelを推測する

- Advantages: Agent側のpublic APIが不要に見える。
- Disadvantages: version、theme、locale、terminal stateに依存し、approvalの誤同定がsecurity incidentになる。
- Evidence: screen bytesにはauthoritative request ID、arguments digest、expiryがない。

### Option D: Raw PTY baselineとoptional semantic adapterを併用する

- Advantages: Universal compatibilityとstructured safetyを両立し、adapter failure時にrawへdegradeできる。
- Disadvantages: 同じsessionにterminalとsemanticという2 control surfaceが生まれ、mapping、lease、capability UIが必要。
- Evidence: ACP、Codex App Server、OpenCode serverはstructured surfaceを提供するが、任意PTYの代替ではない。

## Decision

Option Dを採用候補とする。

- 全Clair-managed sessionは`raw_terminal` capabilityを持つ。
- Semantic capabilityはagent adapterがauthoritative local interfaceへ接続できる場合だけ追加する。
- 通常起動済みagentへofficial attach surfaceがなければraw-onlyとする。
- TUI text/screen scrapingをapproval、tool call、statusの正本にしない。
- Semantic adapterのversion mismatch、crash、detachではcapabilityをremoveし、PTYを継続する。
- Terminal inputとagent prompt/steerは同じper-session control leaseで競合制御する。
- Raw terminalで送ったキー入力をsemantic approvalとして記録・表示しない。

## Rationale

「任意agent」と「安全なapproval」は1つの最低共通interfaceでは同時に満たせない。Raw PTYを互換層、semantic adapterを追加能力と明示すれば、Clairはagent非依存の利用価値を失わず、対応agentだけ安全で読みやすい操作へ段階的に引き上げられる。

Agent protocolをadapter boundaryの内側に置くことで、vendor schemaのbreaking changeをClair mobile wire protocolから分離できる。Capability-driven clientは、使えない操作を曖昧なerrorではなく事前に非表示またはdisabledにできる。

## Consequences

### Positive

- 未知agent、shell、REPLもmobile terminalとして利用できる。
- Structured approvalをauthoritative requestへbindできる。
- Adapter障害がPTY lifecycleの障害にならない。
- ACPとvendor-specific APIを同じnormalized client modelへ載せられる。

### Negative

- Sessionとagent sessionのidentity mappingが必要になる。
- Rawとsemanticの入力競合を1つのlease policyで扱う必要がある。
- Vendorごとのadapter、version fixture、support matrixを保守する。
- 通常起動済みagentはraw-onlyになり、Clair-aware launch profileとの差が生まれる。

## Validation

- Unknown CLIをadapterなしでview/input/interruptできるend-to-end test。
- ACP、Codex、OpenCode adapterのcapability/approval contract test。
- Adapter crash/version mismatch時にPTYが継続しraw-onlyへ遷移するtest。
- Session mapping mismatch、stale approval、duplicate responseを拒否するsecurity test。
- Terminal inputとsemantic promptのconcurrent operationがsingle leaseで直列化されるtest。

## Revisit conditions

- 実質すべてのtarget agentが、既存PTYへのattach、terminal stream、permissionを含む同一stable protocolを公開する。
- Raw terminal rendererのmobile保守costが利用価値を上回り、supported agent限定productへscope変更する。
- Semantic adapterとTUIを同時利用するとvendor側でsession consistencyを保証できないことが実証される。

## References

- Project: [p0020-mobile-agent-remote-control](../projects/p0020-mobile-agent-remote-control/README.md)
- Investigation: [Protocol landscape](../investigations/p0020-protocol-landscape/README.md)
- Issue: [#20](https://github.com/Diwamoto/clair/issues/20)
- [Agent Client Protocol v1 overview](https://agentclientprotocol.com/protocol/v1/overview)
- [Codex App Server](https://learn.chatgpt.com/docs/app-server)
- [OpenCode server](https://dev.opencode.ai/docs/server/)
- [OpenCode ACP support](https://dev.opencode.ai/docs/acp/)
