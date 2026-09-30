---
id: ADR-0021
title: "異常を利用者自身の gh ログインで GitHub issue に報告する"
status: accepted
date: 2026-10-01
deciders: [Diwamoto]
related_projects: []
related_issues: []
supersedes: []
superseded_by: []
---

# ADR-0021: 異常を GitHub issue に自動報告する

## Context

放置した Clair の terminal が `transportTimedOut` で切れる、update の download が
たまに失敗する、といった異常は利用者の Mac 上でしか起きず、原因の手がかり
(発生時刻、sleep/wake、error の種類、crash の stack)が残らない。
`Diwamoto/clair` は PUBLIC repository で、Clair は GitHub Release で配布している。

## Decision drivers

- 原因調査に使える情報が owner の手元に自動で届く
- app に認証情報を埋め込まない。常時稼働の relay など継続 cost を持たない
- 他人の GitHub account で勝手に投稿しない。user 名などを公開しない
- 同じ異常で issue を量産しない

## Options considered

### Option A: 利用者の `gh` CLI で投稿する

- Advantages: token 不要。owner の Mac では完全自動
- Disadvantages: `gh` のない Mac では自動化できない

### Option B: 下書き入りの new-issue page を開くだけ

- Advantages: 最も安全
- Disadvantages: 自動ではなく、放置中の異常を拾えない

### Option C: 埋め込み token または relay server

- Advantages: 誰の Mac からでも自動
- Disadvantages: 公開 binary の token は漏れる。relay は継続 cost と運用が要る

## Decision

Option A を採り、使えない場合は B に落とす。`ClairIssueReporter`(`ClairDaemonKit`)が
次の異常を `[auto] <種類>` という title の issue にする。

- `clair attach` が pane を終了した(`cannot attach` / `lost the daemon`)
- daemon の応答が control timeout を超え、`clair attach` が再試行した
- update の install(download・検証・展開)が失敗した
- `ClairMacApp` / `ClairDaemon` / `clair` の crash report(`.ips`)が新しく出た。
  起動時と 1 時間ごとに確認する。初回は既存の report を報告せず、確認済みの印だけ付ける

投稿の規則:

- 報告するのは `/Applications/Clair.app` の Stable build だけ。Dev、`make dev`、test は報告しない
- `gh` の login がこの repository に push できる場合だけ自動で投稿する。同じ title の
  open issue があれば comment、なければ新規作成する。それ以外は下書き入りの
  new-issue page を browser で開く
- 同じ title は Mac ごとに 24 時間に 1 回まで。投稿の前に記録するので、`gh` が
  失敗しても再試行が繰り返されない
- home directory は `~` に置換する。環境情報は Clair version、macOS、uptime、
  直近の sleep/wake、thermal state、低電力 mode に限る
- `clair attach` は失敗を表示してから 3 秒待って報告する。pane を閉じたときや
  Clair を終了したときは、surface の hangup(SIGHUP)でその前に process が終わる

## Rationale

owner は常に `gh` にログインしているので、A だけで owner の Mac では全自動になる。
push 権限で判定すると、第三者の account から勝手に投稿することがない。token を
埋め込まず relay も持たないので、秘密情報の管理も継続 cost も発生しない。

## Consequences

### Positive

- 原因不明の stall や crash が、発生時の文脈とともに issue として集まる

### Negative

- `gh` のない Mac、または push 権限のない Mac では、異常が起きるたびに browser が開く
  (title ごとに 1 日 1 回)
- 3 秒以内に hangup しない surface では、pane を閉じたときに誤報告しうる
- 報告文は公開される。home 以外の path(`/Volumes/...` など)は置換しない

## Validation

- `ClairIssueReporterTests`: 重複の抑止、error 種別名、crash の要約、home の置換、
  test binary では報告しないこと
- 運用: `[auto]` issue の sleep/wake 時刻と stall が相関するかを見る

## Revisit conditions

- 第三者の利用者が増え、browser が開くことが負担になったとき(設定での opt-out や
  opt-in を検討する)
- 誤報告の issue が目立ったとき

## References

- Code: `apps/daemon/ClairDaemonKit/ClairIssueReporter.swift`
