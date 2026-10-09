---
id: ADR-0023
title: "main の RC ビルドを rolling prerelease で配布する"
status: accepted
date: 2026-10-09
deciders: [Diwamoto]
related_projects: []
related_issues: []
supersedes: []
superseded_by: []
---

# ADR-0023: RC channel

## Context

開発用 Mac 以外の Mac で、リリース前の変更を確かめたいことがある。その Mac には開発環境がないので
`make dev` は使えず、Stable は `v<version>` tag のリリースまで変わらない(オーナー依頼 2026-10-09)。

## Decision

- Stable / Dev に加えて第 3 の channel **RC** を持つ。bundle ID `com.diwamoto.clair.rc`、
  表示名・data directory `Clair RC`、remote listener port 47613、アイコンは Dev と同じ作りの青い「RC」リボン
  (`AppIconRC.icon`)。Stable / Dev と並行起動でき、互いの workspace・socket・update state に触れない([ADR-0008](0008-stable-dev-runtime-identity.md))。
- RC は main の HEAD から `.github/workflows/rc.yml`(`workflow_dispatch` のみ)→ `scripts/release.sh --rc` で作る。
  version は `VERSION.<main の commit 数>`。commit 数は main で単調増加するので、RC 同士は常に新しい方が上になる。
- 配布先は `Diwamoto/clair` の tag `rc` の prerelease 1 つ。毎回作り直し、`--latest` にはしないので Stable の
  `releases/latest` feed には影響しない。RC アプリは `releases/download/rc/latest.json` を見る。
- 署名鍵は Stable と共有する。署名 payload に channel が入っており、client は自分の channel の manifest しか
  受け付けないので、RC manifest で Stable を(その逆も)更新させられない。
- `clair-task` の完了時に、オーナーの OK があれば main を push して RC workflow を起動する。

## Consequences

- RC の配布は tag push を要さず、CHANGELOG も要さない(notes は HEAD の commit 件名)。
- rolling release なので、作り直しの数十秒は RC feed が 404 になる。client は次の定期確認で拾う。
- 別 Mac の初回インストールは `CLAIR_CHANNEL=rc` を付けた `scripts/install.sh`。
