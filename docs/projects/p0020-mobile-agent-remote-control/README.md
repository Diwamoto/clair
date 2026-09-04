---
project_code: p0020-mobile-agent-remote-control
title: "Clair terminal上のcoding agentをmobileから操作するprotocol"
status: in-progress
source_issue: "https://github.com/Diwamoto/clair/issues/20"
suggested_branch: "project/p0020-mobile-agent-remote-control"
created: 2026-08-27
updated: 2026-09-05
owners:
  - "Daiki"
related_adrs:
  - "../../decisions/0006-adopt-project-owned-workspaces-and-optional-worktrees.md"
  - "../../decisions/0010-m1-control-plane-swift-with-selective-rust-migration.md"
  - "../../decisions/0011-early-mobile-agent-control.md"
  - "../../decisions/0002-layered-agent-remote-control.md"
  - "../../decisions/0003-versioned-session-broker-protocol.md"
  - "../../decisions/0004-outbound-e2ee-relay.md"
  - "../../decisions/0012-orca-style-mobile-pairing.md"
related_investigations:
  - "../../investigations/p0020-protocol-landscape/README.md"
  - "../../investigations/p0020-terminal-snapshot-spike/README.md"
  - "../../investigations/p0020-secure-link-spike/README.md"
---

# Clair terminal上のcoding agentをmobileから操作するprotocol

## Outcome

Clairが管理するPTY sessionを、自所有のiPhone/iPadから安全に選択・閲覧・入力できる。Clair自身が
Project/worktree/session、agent profile、lifecycle、attentionを正本として把握し、入力・interrupt・stop・
registered profile launchを同じcontrol planeから実行する。最初は raw terminal を正本とし、Claude Code、
Codex、OpenCode、未知CLIを同じ経路で扱う。agent-specific semantic status/approvalはMVPの前提にせず、
対応可否を確認してから別sliceで追加する。

初期版はprivate-network transportに限定し、Cloudflare One Client / Tunnelを配布向けの既定経路、Tailscale
Serveを自所有環境・開発用の経路として同じAPIへ接続する。外部に見せるのは`clair-mobile-host`の単一endpoint
だけで、`clair-ptyhost`はlocal IPCに閉じる。認証はOrca型のone-time QR/deep-link pairing、ホストfingerprint
pinning、端末ごとのdevice token/grant、端末単位のrevokeをClairが所有する。APNsの内容秘匿attention通知と
private TestFlight CIも含む。

## Documents

- [Requirements](requirements.md)
- [Design](design.md)
- [Implementation plan](plan.md)
- Accepted product scope: [Early mobile agent control](../../product/scope.md#early-mobile-agent-control)
- Priority decision: [ADR-0011](../../decisions/0011-early-mobile-agent-control.md)

## Context

- Source issue: [#20](https://github.com/Diwamoto/clair/issues/20)
- Local PTY/session foundation: [P07](../../plans/clair-poc-queue.md#p07-local-session-lifecycle-and-reattach)
- Raw agent foundation: [P09](../../plans/clair-poc-queue.md#p09-raw-agent-workflow-and-attention)
- Protocol prior art: [protocol landscape](../../investigations/p0020-protocol-landscape/README.md)

## Readiness

- [x] single-user・自所有device・raw-terminal MVPへscopeを固定した
- [x] private-network transportとClair-owned単一API endpointの境界を固定した
- [x] Orca型one-time pairing・per-device token・fingerprint pinning・revokeを仕様化した
- [x] concurrent inputをbroker到着順、mobile viewportを非resizeとした
- [x] semantic adapter、公開relay/E2EE、branch reviewを後続へ分離した
- [x] protocol foundationの実装とテストを開始した
- [x] Clair-owned agent control planeと復元済みagent session discoveryを実装した
- [x] 同じagent commandをlocal CLIからJSONで実行できるようにした
- [x] host identity、one-time pairing、device challenge/revoke、bounded stream hostを実装した
- [x] localhost-only listener、共有Network client、client-side gap/scrollback stateを実装した
- [x] APNsへ渡せるcontent-free attention payloadを実装した
- [x] Clair macOS runtimeへhost/PTY/agent bridgeとMac側のpairing UIを接続する（localhost endpointまで）
- [ ] native iOS UI、vendor private-route運用、APNs送信、private TestFlight CIを完了する

## Completion summary

Slice 0/1A の共有 protocol と agent control plane に加え、今回のP16実装で `ClairMobileKit` に host core、
localhost-only framed listener、Network.framework client、client-local bounded scrollback、操作配送handlerを
追加した。さらにClair macOS runtimeへ `MobileControlRuntimeBridge` を接続し、復元済みProject/session、Agent状態、
raw output/input/interrupt/launchをhostへ投影する。設定画面にはhost fingerprint、one-time QR/deep link、端末一覧と
revokeを追加し、最後のworkspace windowを閉じてもユーザーがQuitするまでhost/PTYを残す。hostはone-time pairing、
P-256 challenge、opaque token digest、per-device revoke、session epoch/cursor/gap、broker到着順のraw inputを正本として
持つ。APNs向け通知はopaque wake IDだけを含む。`clair-ptyhost`を直接公開せず、private routeは同じTCP endpointへ
proxyする境界に固定した。

まだP16を完了扱いにはしない。native iOS UI、Cloudflare/Tailscaleの実運用設定、APNs送信、private TestFlight CIは
次のSlice 3/4で残っている。モバイル情報設計の確認用Interaction Labは[private preview](https://clair-interaction-lab.daiki-work-0118.chatgpt.site)
で、Project/session catalog、bounded raw terminal、入力/割り込み、pairing状態を確認できる。

## Validation evidence

- 2026-09-05: `swift test`（`packages/ClairMobileKit`）— 27 tests passed。host/store、pair/revoke、session projection更新、stream gap、ordered input、RPC、loopback listener/client、client scrollback、APNs payload redaction、disable fallback、multi-connection isolationを確認。
- 2026-09-05: `xcodebuild -project Clair.xcodeproj -scheme 'Clair Dev' -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO` — Swift 6 native build passed。`ClairMobileKit` local package、macOS runtime bridge、設定画面のQR生成、GUI close後のlifecycle変更を含む。
- 2026-09-05: Interaction Labで`npm run build`、`npm run lint`、`git diff --check`を通過し、モバイルの概要→セッション一覧→raw terminal入力→設定→QR/deep link sheetをブラウザで確認した。
- 2026-09-03: `make test-swift` — 109 tests passed.
- 2026-09-03: `python3 -m py_compile scripts/clair`, `./scripts/clair --help`, `./scripts/clair agent --help`, `git diff --check`, and `./scripts/validate-xcode-project.rb` passed.
- 2026-09-03: 現行product scope、P07/P09のlocal foundation、既存ADRを確認し、raw-terminal firstのpriorityをADR-0011へ記録。
