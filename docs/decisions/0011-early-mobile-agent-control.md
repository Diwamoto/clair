---
id: ADR-0011
title: "Mobile agent controlを早期raw-terminal sliceとして開始する"
status: accepted
date: 2026-09-03
deciders:
  - "Daiki"
related_projects:
  - "p0020-mobile-agent-remote-control"
related_issues:
  - "https://github.com/Diwamoto/clair/issues/20"
supersedes: []
superseded_by:
  - "ADR-0013 (client distribution and notification portions)"
---

# ADR-0011: Mobile agent controlを早期raw-terminal sliceとして開始する

## Context

ClairのP07/P09で、Mac上のPTY lifecycle、restart reattach、raw agent launch、attentionが利用可能になった。
一方、従来のroadmapはmobileをcutover後へ送り、semantic adapter、relay、snapshot、team向け要件を同時に解こうと
していた。そのままでは、席を離れた後にagentを確認・操作したいという価値の検証が遅すぎる。

利用者の優先順位に合わせ、mobile controlをGo editorやdebuggerの前に開始する。ただし、terminal内容を推測する
semantic layerや公開relayを先に作ると、agentごとの互換性とsecurity reviewがMVPをblockする。

## Decision

1. Mobile controlはM1と並行するearly milestoneとして、`p0020-mobile-agent-remote-control`で実装する。
2. 初期MVPはsingle-user・自所有Mac・自所有iPhone/iPad・raw terminalに限定する。shell、未知CLI、Claude Code、Codex、
   OpenCodeは同じPTY pathで扱う。
3. 初期transportはCloudflare One Client / Cloudflare Tunnelのprivate network routeとし、Macのpublic inbound portや
   Clair-owned public relayを持たない。
4. Macの明示操作からone-time QRでdevice keyをpairし、default `view` scope、端末単位のrevoke、Mac側global kill
   switchを提供する。APNsはopaque wake identifierだけを扱う。
5. Macとmobileのinputはbroker到着順に直列化する。MVPでは暗黙のsingle-writer leaseで入力を止めず、operation ID
   dedupeとscope checkで安全性を確保する。mobile viewportはPTY resizeを行わない。
6. Mobile clientはProject/session catalog、current screen、bounded scrollback、raw input、interrupt、registered
   agent profile launch、attentionを提供する。terminal outputとdiffはmobileへ永続保存しない。
7. Semantic approval/status、portable terminal snapshot、public relay/E2EE、branch review、team identityは後続の
   独立sliceとし、initial raw-terminal valueをblockしない。

## Rationale

Raw PTYはagent vendorに依存せず、P09の既存workflowを最短でmobileへ延長できる。Cloudflare private networkを先に
使うことで、router設定やpublic relay運用を増やさずに実利用を検証できる。broker arrival orderはdesktopとmobileの
同時入力を決定的にし、UI上のlease transferという追加状態を初期MVPから外せる。

Semantic operationはstructuredなagent interfaceがある場合だけ安全に導入できる。TUIの文字列からapprovalやtool
callを推測することは誤操作のリスクがあるため採用しない。公開relayへ進む場合は、提案済みADR-0004を再レビューし、
暗号境界・key lifecycle・replay protectionを別途受け入れる。

## Consequences

### Positive

- agentの進捗確認と短い操作を早く実地検証できる。
- 既存のstable SessionID、journal、subscriber、raw launchを再利用できる。
- semantic adapterとrelayの未決事項が初期MVPのblockerにならない。
- capability-drivenな共通protocolを先に作り、対応agent機能を後から追加できる。

### Negative

- initial mobileはterminal操作中心で、structured approval/statusは提供しない。
- Cloudflare One/Tunnel、QR、APNs、private TestFlightという外部運用が必要になる。
- journal保持範囲外の完全なterminal復元は後続課題として残る。
- inputはarrival orderであり、ユーザーが意図した順序をbroker到着前に保証するものではない。

## Follow-up decision

Client packaging and distribution assumptions in this ADR are refined by [ADR-0013](0013-self-only-mobile-pwa.md): PWA is the
supported self-only client path, while the raw-terminal scope, host ownership, private-network boundary, and pairing authorization
decided here remain in force.

## Revisit conditions

- private-network canaryでmobile controlの利用価値が確認できた場合、public relay/E2EEをsecurity review付きで検討する。
- agent操作でstructured approval/statusの需要が確認でき、公式local interfaceまたはClair-aware launch profileがある場合、
  semantic adapterを追加する。
- mobileの入力競合が実利用で問題になった場合、leaseを後続protocol versionで追加する。

## References

- Project: [p0020-mobile-agent-remote-control](../projects/p0020-mobile-agent-remote-control/README.md)
- Product scope: [Early mobile agent control](../clair-spec.md#early-mobile-agent-control)
- Roadmap: [Milestone 1.5](../clair-spec.md#milestone-15-early-mobile-agent-control)
- Prior local foundation: [development workspace architecture](../architecture/development-workspace.md)
- Historical follow-up: [ADR-0004 outbound E2EE relay](0004-outbound-e2ee-relay.md)
