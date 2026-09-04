---
project_code: p0020-mobile-agent-remote-control
title: "Clair terminal上のcoding agentをmobileから操作するprotocol"
status: in-progress
source_issue: "https://github.com/Diwamoto/clair/issues/20"
suggested_branch: "project/p0020-mobile-agent-remote-control"
created: 2026-08-27
updated: 2026-09-04
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

## Completion summary

Slice 0 の共有 `ClairMobileKit` に加え、Clair本体へ agent control plane を追加した。復元済みを含む agent
sessionをstable IDでカタログ化し、factual lifecycle/attention/capabilityを返し、input、interrupt、stopを
PTYへ安全に適用する。登録済みprofile launchと、同じ `CommandRegistry` を使う native Rust `clair`
CLI（JSON出力、明示的な `--yes` headless confirmation）まで実装済み。`scripts/clair`はsource-tree
compatibility adapterとして残る。Hostのremote bridge、iOS UI、
private transport adapter（Cloudflare/Tailscale）、QR/APNs、TestFlight CIは後続sliceとして未完了。

## Validation evidence

- 2026-09-03: `CLANG_MODULE_CACHE_PATH=/private/tmp/clair-mobile-clang-cache SWIFT_MODULECACHE_PATH=/private/tmp/clair-mobile-swift-cache swift test --package-path packages/ClairMobileKit` — 12 tests passed.
- 2026-09-03: `make test-swift` — 109 tests passed.
- 2026-09-03: `python3 -m py_compile scripts/clair`, `./scripts/clair --help`, `./scripts/clair agent --help`, `git diff --check`, and `./scripts/validate-xcode-project.rb` passed.
- 2026-09-03: 現行product scope、P07/P09のlocal foundation、既存ADRを確認し、raw-terminal firstのpriorityをADR-0011へ記録。
