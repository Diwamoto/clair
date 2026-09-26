# Release and update distribution

## Purpose

Stable の `Clair.app` をこのリポジトリ(`Diwamoto/clair`、public)の GitHub Release へ配布し、
インストール済みの Stable が署名検証付きで更新する。判断は
[ADR-0009](../decisions/0009-stable-github-update-distribution.md)。Dev はローカル build 専用で feed を持たない。

## 仕組み

- **トリガー**: `VERSION` を変更した commit が main に push されると `.github/workflows/release.yml` が走る。
  `VERSION` が変わらない push では配布しない。再実行は Actions の `workflow_dispatch`。
- **Runner**: GitHub hosted の `macos-26`(public repo なので無料)。libghostty(zig + Metal toolchain)は
  `actions/cache` に載せ、`Config/ghostty-pin.json` か `scripts/ghostty.sh` が変わったときだけ再ビルドする。
- **本体**: `scripts/release.sh`。CI には依存しないので、他の CI や手元の Mac からも同じ入力で実行できる。
  1. `swift build -c release` で `ClairMacApp`・`ClairDaemon`・`clair` をビルドし、`Clair.app` を組み立てる
     (3 つとも `Contents/MacOS`、SwiftPM の resource bundle は `.app` 直下)。
  2. 使い捨ての `HOME` で起動し、最初の frame まで到達することを確認する(bundle の欠落は起動時に crash するため)。
  3. `Clair-<version>-macos-arm64.zip` と、Ed25519 署名付きの `latest.json` を作る。
  4. `v<version>` tag を push し、Release を作って `--latest` にする(notes は `CHANGELOG.md` の `## [<version>]` 節。無ければ失敗する)。
     既に Release がある version は何もせず終了する。
- **クライアント**: `ClairUpdateConfiguration.manifestURL` は
  `https://github.com/Diwamoto/clair/releases/latest/download/latest.json` を見る。
  起動 5 秒後と 1 時間ごとに確認し、適用は利用者の操作だけで行う。`/Applications/Clair.app` だけが更新対象。

## 初回セットアップ(1 回だけ)

署名鍵を作る。秘密鍵はログイン Keychain(`clair-update-signing`)と Actions secret
`CLAIR_UPDATE_PRIVATE_KEY` にだけ保存され、画面には出ない。公開鍵が書かれる `Config/update-public-key` は commit する。

```sh
scripts/setup-update-key.sh
git add Config/update-public-key && git commit -m "build: add Stable update public key" -- Config/update-public-key
```

秘密鍵をなくすと、インストール済みのアプリは二度と更新を受け取れない。Keychain の項目は消さないこと。
fork からの pull request には secret が渡らないので、release は main の push でしか動かない。

## リリース手順

通常は `clair-release` skill(`.agents/skills/clair-release/SKILL.md`)が 1〜2 をまとめて行う。

1. `CHANGELOG.md` の `## [Unreleased]` を `## [<version>] - <date>` にし、`VERSION` を同じ値へ上げる(SemVer)。
2. その commit を main に push する。Release workflow が test → build → smoke → publish を行う。
3. <https://github.com/Diwamoto/clair/releases> に zip と `latest.json` が出ていることを確認する。

手元で配布物だけ作るには `CLAIR_UPDATE_PRIVATE_KEY="$(security find-generic-password -s clair-update-signing -w)" scripts/release.sh --dry-run`
を使う(`.build/release/` に出力され、tag も publish もしない)。

## 初回インストール

`scripts/install.sh` を使う。最新 Release の `latest.json` から arm64 の zip を取り、sha256 を確かめて
`/Applications/Clair.app` に置き、起動する。curl で取った zip には quarantine が付かないので Gatekeeper に止められない
(Developer ID 署名と notarization は未導入)。

```sh
curl -fsSL https://raw.githubusercontent.com/Diwamoto/clair/main/scripts/install.sh | sh
```

再実行すると最新版で入れ直す(起動中の Clair は終了させる)。2 回目以降の更新はアプリ内の updater が行い、
こちらは Ed25519 署名まで検証する。install.sh は TLS 越しの manifest の sha256 だけを信頼する。
ブラウザで zip を落とした場合は quarantine が付くので、`xattr -dr com.apple.quarantine /Applications/Clair.app` が要る。

## 停止条件

- `latest.json` の署名が検証できない(`Config/update-public-key` と secret の鍵が食い違っている)
- 起動スモークが最初の frame に届かない
- Release に asset か `latest.json` が欠けている

いずれの場合も `VERSION` を上げ直さずに原因を直し、`workflow_dispatch` で再実行する。途中で止まった Release は、
Release と tag を消してから再実行する。

## 対象外と今後

Developer ID 署名と notarization(Gatekeeper 警告をなくす)、resource bundle の `Contents/Resources` への移動
(bundle 全体の codesign)、x86_64 / universal、複数 channel は扱わない。
