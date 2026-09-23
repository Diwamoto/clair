# Release and update distribution

## Purpose

Stable の `Clair.app` を公開ミラー [`Diwamoto/clair-releases`](https://github.com/Diwamoto/clair-releases)
の GitHub Release へ配布し、インストール済みの Stable が署名検証付きで更新する。
ソース(`Diwamoto/clair`)は private のまま、artifact と `latest.json` だけを public に置く
(ccedit と `ccedit-releases` の関係と同じ)。判断は [ADR-0009](../decisions/0009-stable-github-update-distribution.md)。
Dev はローカル build 専用で feed を持たない。

## 仕組み

- **トリガー**: `VERSION` を変更した commit が master に push されると `.github/workflows/release.yml` が走る。
  `VERSION` が変わらない push では配布しない。再実行は Actions の `workflow_dispatch`。
- **Runner**: self-hosted の Apple Silicon Mac(labels `self-hosted, macOS, ARM64`)。private repo でも
  課金されず、libghostty(zig + Metal toolchain)を毎回ビルドし直さずに済む。
- **本体**: `scripts/release.sh`。CI には依存しないので、他の CI(Codemagic など)や手元の Mac からも同じ
  入力で実行できる。処理は以下のとおり。
  1. `swift build -c release` で `ClairMacApp`・`ClairDaemon`・`clair` をビルドし、`Clair.app` を組み立てる
     (3 つとも `Contents/MacOS`、SwiftPM の resource bundle は `.app` 直下)。
  2. 使い捨ての `HOME` で起動し、最初の frame まで到達することを確認する(bundle の欠落は起動時に crash するため)。
  3. `Clair-<version>-macos-arm64.zip` と、Ed25519 署名付きの `latest.json` を作る。
  4. source repo に `v<version>` tag を push し、ミラーへ Release を作って `--latest` にする。
     既に Release がある version は何もせず終了する。
- **クライアント**: `ClairUpdateConfiguration.manifestURL` は
  `https://github.com/Diwamoto/clair-releases/releases/latest/download/latest.json` を見る。
  起動 5 秒後と 1 時間ごとに確認し、適用は利用者の操作だけで行う。`/Applications/Clair.app` だけが更新対象。

## 初回セットアップ(1 回だけ)

1. 署名鍵を作る。秘密鍵はログイン Keychain(`clair-update-signing`)と Actions secret
   `CLAIR_UPDATE_PRIVATE_KEY` にだけ保存され、画面には出ない。公開鍵が書かれる `Config/update-public-key` は commit する。

   ```sh
   scripts/setup-update-key.sh
   git add Config/update-public-key && git commit -m "build: add Stable update public key" -- Config/update-public-key
   ```

   秘密鍵をなくすと、インストール済みのアプリは二度と更新を受け取れない。Keychain の項目は消さないこと。
2. ミラーへ publish するための fine-grained PAT を作る(Repository access: `Diwamoto/clair-releases` のみ、
   Permissions: Contents = Read and write)。それを secret に登録する。

   ```sh
   gh secret set RELEASES_PAT --repo Diwamoto/clair
   ```

3. self-hosted runner を登録する(Settings → Actions → Runners → New self-hosted runner の手順どおり。
   macOS / ARM64)。`./svc.sh install && ./svc.sh start` で LaunchAgent として常駐させる。起動スモークで
   window を開くので、ログイン済みの GUI セッションで動かすこと。
   libghostty の vendor には Metal toolchain が要る(`xcodebuild -downloadComponent MetalToolchain`)。

## リリース手順

1. `VERSION` を上げる(例: `0.1.0` → `0.2.0`)。
2. その commit を master に push する。Release workflow が test → build → smoke → publish を行う。
3. <https://github.com/Diwamoto/clair-releases/releases> に zip と `latest.json` が出ていることを確認する。

手元で配布物だけ作るには `CLAIR_UPDATE_PRIVATE_KEY="$(security find-generic-password -s clair-update-signing -w)" scripts/release.sh --dry-run`
を使う(`.build/release/` に出力され、tag も publish もしない)。

## 初回インストール

zip を展開して `Clair.app` を `/Applications` に置く。Developer ID 署名と notarization をしていないので、
初回起動は Gatekeeper に止められる。システム設定 → プライバシーとセキュリティ →「このまま開く」を押すか、
`xattr -dr com.apple.quarantine /Applications/Clair.app` を実行する。アプリ内の更新でダウンロードした版には
quarantine が付かないので、この操作は初回だけで済む。

## 停止条件

- `latest.json` の署名が検証できない(`Config/update-public-key` と secret の鍵が食い違っている)
- 起動スモークが最初の frame に届かない
- ミラーの Release に asset か `latest.json` が欠けている

いずれの場合も `VERSION` を上げ直さずに原因を直し、`workflow_dispatch` で再実行する。途中で止まった Release は、
ミラー側の Release と tag を消してから再実行する。

## 対象外と今後

Developer ID 署名と notarization(Gatekeeper 警告をなくす)、resource bundle の `Contents/Resources` への移動
(bundle 全体の codesign)、x86_64 / universal、複数 channel は扱わない。
