# Stable release and update

## Purpose

Stableだけを公開GitHub Releaseへ配布し、実行中の`Clair.app`から署名検証付きで更新する。
Devはローカルbuild/run専用で、Releaseとupdate feedを持たない。

この運用は[ADR-0009](../decisions/0009-stable-github-update-distribution.md)に従う。
Apple Developer ID、Team ID、notarizationはまだ使わないため、初回起動時のmacOS警告は想定内である。

## Prerequisites and secret boundary

- GitHub repositoryでActionsが有効であること
- tagからReleaseを作成できる`contents: write`権限
- macOS 14 arm64 runnerが利用できること
- リポジトリActions secret `CLAIR_UPDATE_PRIVATE_KEY`
- リポジトリActions variable `CLAIR_UPDATE_PUBLIC_KEY`

鍵を一度だけ生成する。private valueは端末出力やshell historyに残さず、GitHub Actions secretへ登録する。
public valueはActions variableへ登録する。private keyをrepository、Issue、workflow logへ保存しない。

```sh
xcrun swift scripts/generate-update-key.swift
```

`CLAIR_UPDATE_PUBLIC_KEY`はprivate keyから導出される値と完全一致させる。Release workflowはmanifest生成時にも
この一致を検証し、private valueをprocess argumentには渡さない。

## Release procedure

1. Stableに含める変更をcommitし、通常のCIが通っていることを確認する。
2. semantic version tagを作る。workflowがtagの`v`を除いた値をアプリのversionへ渡す。

   ```sh
   git tag v0.2.0
   git push origin v0.2.0
   ```

3. `Stable release` workflowが`Clair.app`をRelease configurationでbuildする。
   workflowはApple signing/notarizationを行わず、Rust製`clair` CLIをapp executableへ、
   `clair-ptyhost`をapp resourceへ含める。CLIは`Clair.app/Contents/MacOS/clair`から利用できる。
4. workflowが`Clair-<version>-macos-arm64.zip`と`latest.json`を同じGitHub Releaseへpublishする。
   `latest.json`はartifactのversion、channel、platform、architecture、download URL、SHA-256をEd25519で署名する。

同じtagのReleaseが既にある場合はworkflowを再実行せず、既存Releaseを確認してから次のversionを使う。

## Client behavior

- Stableは`/Applications/Clair.app`にインストールされた場合だけupdate対象になる。
- 起動5秒後と、その後1時間ごとに公開`latest.json`を確認する。
- updateが見つかっても自動適用しない。通知の`Restart and install`、またはClair menuの確認操作が必要である。
- `Later`は6時間だけ通知を抑制する。
- download後にEd25519署名とSHA-256を再検証し、archive内のbundle identifier/versionも検証する。
- Devはmanifest URL/public keyを持たず、update check自体を行わない。

## Restart, session, and rollback

更新前に現行appをApplication Support内のowner-only `updates-v1`へbackupし、pending markerを書き込む。
helper processが現行process終了を待って`/Applications/Clair.app`を置き換え、新processのstartup validationを待つ。

- 起動成功時、期待versionとbundle identifierが一致すればsuccess markerを書き込む。
- timeout、起動失敗、marker不一致ではbackupを元のpathへ戻し、旧appを再起動する。
- update restartでは通常Quit callbackを抑止し、broker/sessionへterminateを送らない。
- 新processは保存済みterminal tabのSessionIDを使ってbrokerへreattachする。
- window closeはapp processとbroker/sessionを終了しない。
- ユーザーが明示的にQuitしたときだけ、通常終了callbackから全terminal sessionへterminateを送る。

失敗時は、まず更新前のStableが起動できることと、`~/Library/Application Support/Clair/updates-v1`にpending markerが残っていないことを確認する。
残った一時archiveやbackupを手動削除する前に、原因調査のためディレクトリを保存する。更新中にこのディレクトリを再利用したり、
別のapp pathへ`mv`したりしない。

## Local validation

```sh
swift format lint --recursive --parallel --strict apple
ruby scripts/validate-xcode-project.rb
xcodebuild -project Clair.xcodeproj -scheme "Clair Stable" -configuration Debug \
  -derivedDataPath .build/xcode/p14-stable \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
xcodebuild -project Clair.xcodeproj -scheme "Clair Dev" -configuration Debug \
  -derivedDataPath .build/xcode/p14-tests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -only-testing:ClairTests/ClairUpdateTests test
```

## Stop conditions and deferred work

停止して判断を取り直す条件は、鍵pairの不一致、Release assetまたは`latest.json`の欠落、Stable bundleの
install path不一致、rollback後も旧appが起動しない場合である。

Gatekeeper warningをなくす正式配布、Apple signing/notarization、x86_64またはuniversal artifact、複数channel、
background broker serviceはこのrunbookの対象外である。

最終検証日: 2026-09-01（Swift format、Xcode project validation、Stable/Dev build、P14専用XCTest）。
