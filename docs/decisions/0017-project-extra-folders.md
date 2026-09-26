---
id: ADR-0017
title: "Project に root 外の folder を追加し、root 相対 path で扱う"
status: accepted
date: 2026-09-27
deciders:
  - "Daiki"
related_projects: []
related_issues: []
supersedes: []
superseded_by: []
---

# ADR-0017: Project に root 外の folder を追加し、root 相対 path で扱う

## Context

owner は tab group の右クリックから「プロジェクトにフォルダを追加」できることを求めた
(2026-09-27、マルチルート化を選択)。Project は 1 つの root を持ち、editor・検索・保存・
diff・debug など約 20 か所が `root + "/" + rel` で絶対 path を組み立てている。
Project 名は layout と terminal 再接続 (`project#pane`) の key でもある。

## Decision

- `WorkbenchProject.folders` に追加 folder の絶対 path を保存する(旧 workspace.json は
  field なしで読める optional)。
- 追加 folder の file は `files` に **root からの相対 path**(`../docs/readme.md`)で入れる。
  既存の `root + "/" + rel` はすべてそのまま解決するので、呼び出し側は変えない。
- explorer は相対 prefix ごとに folder 名の top-level 行を 1 つ出す。
- root と入れ子になる folder(どちら向きでも)と重複追加は拒否する。
- `project.addFolder` は `ai: false`(agent が読める範囲を勝手に広げない)。

## Consequences

- 追加 folder の Git status・file 監視・terminal/agent の cwd は root だけ。追加 folder の
  変更は root の再 scan で拾う。必要になったら folder ごとの watcher を足す。
- diff tab と remote workspace protocol は `..` を含む path を拒否するため、追加 folder の
  file は diff / mobile からは開けない。
- 表示名の変更は `label` だけを変え、`name` (key) は変えない。

## Alternatives

- 全呼び出し側を root 解決関数に置き換える: 変更が約 20 か所に散り、同じ結果になる。
- root 内に symlink を作る: user の folder を書き換えるうえ、scan は symlink を辿らない。
