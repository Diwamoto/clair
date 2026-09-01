---
id: ADR-0009
title: "Stable GitHub update distribution and restart handoff"
status: accepted
date: 2026-09-01
deciders:
  - Daiki
related_projects: []
related_issues:
  - 18
supersedes: []
superseded_by: []
---

# ADR-0009: Stable GitHub update distribution and restart handoff

## Context

P14は、Clairの個人利用向けStable buildをGitHubから配布し、アプリ内の更新操作から
現在のPTY/sessionを失わずに新しいprocessへ戻す。ADR-0008はStable/Devのruntime identityと
local unsigned buildを固定しており、AppleのDeveloper ID、Team ID、notarizationをこのsliceの
前提にしていない。P14の実装境界、公開channel、更新の信頼性、失敗時の復元方法を固定する必要がある。

## Decision drivers

- Stableを個人用の公開GitHub Releaseから再インストールなしで更新できる。
- Devのローカル開発loopがStableの更新channelやdataを汚染しない。
- Apple Developer ID/notarizationを準備する前でも、更新artifactの改ざんを検知できる。
- 更新失敗で`/Applications/Clair.app`を起動不能にせず、PTY/sessionを継続できる。
- window close、通常Quit、crash、update restartのlifecycleを混同しない。

## Options considered

### Option A: Apple Developer IDとnotarizationを初期distributionの必須条件にする

- Advantages: Gatekeeper上の配布体験がよく、Appleのdistribution identityを含む。
- Disadvantages: Developer ID certificate、Team ID、秘密credential、notarization運用が必要になり、
  personal PoCの更新sliceがApple account setupに依存する。
- Evidence: [ADR-0008](0008-stable-dev-runtime-identity.md)はsigning identity、Team ID、notarizationを
  後続decisionへ延期している。

### Option B: Stableの公開GitHub Releaseと署名付き更新artifactを使う

- Advantages: GitHubを公開distribution面としてそのまま使え、Apple notarizationなしでもartifactの
  version、URL、hashを署名検証できる。Devはfeedを持たずlocal buildに限定できる。
- Disadvantages: 初回起動時のmacOS警告は残り、更新署名用の秘密鍵を安全に管理する必要がある。
- Evidence: cceditは`tauri-plugin-updater`、`latest.json`、公開Release mirror、Tauri updater署名鍵を
  組み合わせている。Clairは同じ信頼境界をSwift/CryptoKitで実装する。

### Option C: GitHub HTTPSとSHA-256だけを信頼する

- Advantages: 実装とkey managementが最小になる。
- Disadvantages: manifestとhashを同時に差し替えられる攻撃者を検知できず、GitHubのrepository権限を
  artifact trustの唯一の根拠にしてしまう。
- Evidence: P14はverified feedを要求し、Stableの更新は実行ファイルを置き換えるため、hash単独では
  充分な更新artifact認証にならない。

## Decision

- 公開channelはStableだけとする。Stableの更新manifestは公開GitHub Releasesの`latest.json`から取得し、
  macOS artifactはRelease assetとして配布する。
- DevはGitHub Release、更新manifest、更新チェックを持たない。Devはローカルbuild/runだけを使う。
- Apple Developer ID、Team ID、notarizationはP14の完了条件に含めない。初回のmacOS警告は現時点の
  personal distribution policyとして許容する。
- 各Stable update artifactはEd25519署名を持つ。Stable appには公開鍵を埋め込み、manifestが示す
  channel、version、platform、architecture、URL、SHA-256を署名検証してからdownload済みarchiveを
  適用する。秘密鍵はrepositoryへ保存せず、release automationのsecret boundaryで管理する。
- Stableは起動後に自動checkするが、更新を自動適用しない。更新通知の適用ボタンを利用者が押したときだけ
  download、署名/hash検証、install、restartを開始する。
- Stableのインストールtargetは`/Applications/Clair.app`とする。ローカルDebug/Dev bundleは更新対象に
  しない。
- downloadと検証はtemporary locationで行う。適用前に現行appをchannel-local backupへ退避し、新appを
  配置する。適用または新processのstartup validationに失敗した場合は旧appを復元する。
- window closeはProject surfaceとbroker/sessionを終了しない。explicit app Quitだけは通常sessionへ
  terminateを送り、crashとupdate restartではterminateを送らずbrokerを生かす。新processは保存済みの
  terminal tab/session IDをreattachする。

## Rationale

Option Bは、cceditで利用者が受け入れているGitHub Release中心の運用を、native Swift/Rust appへ移植する
最小の境界である。Appleのapp identity署名と更新artifact署名は別責務なので、notarizationを後回しにしても
更新manifestとdownload archiveの改ざん検知を維持できる。Stableだけに公開feedを限定することで、Dev buildが
開発途中のartifactを誤ってStableへ適用する経路もなくなる。

明示的なbackup/restoreはcceditのapp-level実装より強いが、`/Applications/Clair.app`の置換を失敗したときに
利用者が手動再インストールする必要を減らす。startup validationは新appが実際に起動したことを確認してから
backupを破棄するため、単なるfile move成功を更新成功と誤認しない。

## Consequences

### Positive

- Stableは公開GitHub Releaseから再インストールなしで更新できる。
- Devのlocal buildはStableのfeed、bundle identity、Application Supportを共有しない。
- 署名、SHA-256、version/channel/architecture検証を通らないartifactは適用されない。
- 更新失敗時に現行appとchannel-local session brokerを回復できる。

### Negative

- 更新署名用の秘密鍵をCI secretとして初回設定する必要がある。
- Apple notarizationがないため、初回download/open時のGatekeeper警告は残る。
- `/Applications`への書き込み権限がない場合、更新は失敗して現行appを維持する。
- Ed25519 verifier、detached updater helper、startup validationをnative app側で保守する。

## Validation

- manifestのschema、Stable channel、current architecture、version ordering、URL、SHA-256、Ed25519署名を
  unit testで検証する。
- 署名改ざん、hash改ざん、Dev channel、古いversion、別architecture、malformed manifestを拒否する。
- temporary archiveの展開、bundle identity/version確認、成功時のbackup cleanup、install/startup失敗時の
  restoreをfixtureで検証する。
- update restartではbrokerをterminateせず、保存済みsession IDでreattachする。window closeでは同じsessionが
  継続し、explicit Quitではterminateされることをlifecycle testと手動smokeで確認する。
- release workflowはStable archive、`latest.json`、署名付きassetをGitHub Releaseへpublishする。

## Revisit conditions

- Stableを一般配布する必要が生じ、Gatekeeper warningをなくす必要がある。
- Apple certificate、Team ID、notarization credentialを管理できる運用境界が確立する。
- GitHub Release以外のdistribution provider、複数platform、preview/nightly channelが必要になる。
- `Clair.app`のinstall locationを変更する、または権限昇格を含むinstallerが必要になる。

## References

- Product scope: [Clair product scope](../product/scope.md)
- Runtime identity: [ADR-0008](0008-stable-dev-runtime-identity.md)
- Prior art: [ccedit updater implementation](https://github.com/Diwamoto/ccedit/blob/main/src/ipc/updater.ts)
- Prior art: [ccedit release workflow](https://github.com/Diwamoto/ccedit/blob/main/.github/workflows/release.yml)
- Issue: [#18](https://github.com/Diwamoto/clair/issues/18)
