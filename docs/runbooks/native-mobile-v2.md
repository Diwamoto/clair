# Clair v2 native mobile build and TestFlight smoke

Status: N01 foundation procedure

この runbook は `ClairV2Mobile` の SwiftUI composition root を、Simulator、登録済みの
iPhone/iPad、private TestFlight で再現可能な形に検証するための手順である。配布・通知の
責任境界は [ADR-0015](../decisions/0015-native-mobile-apns.md) に従う。

N01 は state、command、navigation の接続検証用 shell までを所有する。pairing、Keychain
device identity、transport、APNs entitlement/provider、完成 UI は後続 task の責務である。
このため、N01 の smoke は app の bundle、起動、lifecycle、navigation、foundation state を
確認し、通知配送の成功とは扱わない。

## Preconditions

- Xcode 26 以降、Swift 6、iOS 17 以降の Simulator または実機を用意する。
- package-only の foundation check は Apple Developer account なしで実行できる。
- 実機署名には Apple Developer membership、Team `3UY66R4X2N`、Automatic signing、端末登録、
  署名 identity が必要である。TestFlight には App Store Connect の `Clair Mobile` app record と
  internal tester 権限も必要である。
- bundle ID は `com.diwamoto.clair.mobile` に固定する。証明書、provisioning profile、APNs key、
  App Store Connect API key は repository に保存しない。
- Xcode bundle は `ClairV2Mobile.xcodeproj` を使う。v1 の `Clair.xcodeproj` は削除済みである。

## Package and Simulator smoke

作業ツリーの repository root で次を実行する。

```sh
make v2-foundation
```

これは v2 package graph、全 v2 target、iOS Simulator cross-build、Core/App package tests を
確認する。Xcode の unit/UI smoke target まで実行する場合は、利用可能な Simulator 名に置き換えて
次を実行する。

```sh
xcodebuild \
  -project ClairV2Mobile.xcodeproj \
  -scheme ClairV2Mobile \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -derivedDataPath .build/xcode/v2-mobile-simulator \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  test \
  -parallel-testing-enabled NO
```

成功条件は `ClairV2MobileTests` と `ClairV2MobileUITests` が build/test され、root view の
Overview 表示と Sessions への navigation smoke が通ることである。Simulator の device 名が
異なる場合は `xcrun simctl list devices available` で確認して destination だけ変更する。

## Signed physical-device build

Apple account の操作は release owner が行う。次の手順は account access が利用可能な場合だけ
実行し、秘密情報をコマンドライン、ログ、repositoryへ残さない。

1. Xcode で `ClairV2Mobile.xcodeproj` を開き、`ClairV2Mobile` target の Signing & Capabilities
   で Automatic signing と Team `3UY66R4X2N` を選ぶ。Bundle Identifier が
   `com.diwamoto.clair.mobile` と一致し、登録済みの iPhone/iPad が選択できることを確認する。
2. `generic/platform=iOS` 向けに Release archive を作る。

   ```sh
   xcodebuild \
     -project ClairV2Mobile.xcodeproj \
     -scheme ClairV2Mobile \
     -configuration Release \
     -destination 'generic/platform=iOS' \
     -archivePath .build/xcode/v2-mobile/ClairV2Mobile.xcarchive \
     -derivedDataPath .build/xcode/v2-mobile \
     -allowProvisioningUpdates \
     CODE_SIGNING_ALLOWED=YES \
     CODE_SIGNING_REQUIRED=YES \
     archive
   ```

3. archive の `Info.plist` と署名を確認する。

   ```sh
   /usr/libexec/PlistBuddy \
     -c 'Print :CFBundleIdentifier' \
     '.build/xcode/v2-mobile/ClairV2Mobile.xcarchive/Info.plist'
   codesign --verify --deep --strict \
     '.build/xcode/v2-mobile/ClairV2Mobile.xcarchive/Products/Applications/Clair v2 Mobile.app'
   ```

   identifier が `com.diwamoto.clair.mobile` で、`codesign` が成功することを確認する。失敗時は
   export や install に進まず、profile/certificate の状態を release owner が確認する。
4. Xcode Devices and Simulators または `xcrun devicectl` で archive の signed app を登録済み
   device へ install し、root view が起動すること、4つの navigation destination を選択できること、
   foreground/background 復帰後に lifecycle 表示が更新されることを確認する。

N01 では push capability と APNs environment はまだ追加しない。notification tap、background/
terminated push、device-token replacement、revoke は N07/N08 の実機 gate で確認する。

## TestFlight internal smoke

1. signed Release archive を Xcode Organizer の `Distribute App` から `TestFlight & App Store`
   の internal testing へ upload する。App record、bundle ID、version/build、team が
   `com.diwamoto.clair.mobile` と一致していることを upload 前に確認する。
2. internal tester が TestFlight build を iPhone/iPad に install し、次を確認する。
   - app が起動し、`Clair v2 Mobile` の foundation shell が表示される。
   - Overview、Sessions、Activity、Settings の navigation state が保持される。
   - Connect/Disconnect が local state を更新し、background から foreground へ戻れる。
3. build metadata、device model/OS、実行日時、失敗理由だけを release evidence に記録する。
   prompt、terminal bytes、cwd、diff、credential、device token は記録しない。

TestFlight upload と実機 smoke は Apple Developer/App Store Connect の account access が必要な
外部工程である。access が無い環境では package、Simulator、unit/UI smoke までを完了とし、署名済み
実機 build や TestFlight upload を実施済みとは報告しない。

## Stop and recovery

- signing、provisioning、bundle ID、team のいずれかが不一致なら archive を破棄せず release owner
  の確認で停止する。
- export/upload が必要な場合も、certificate private key、profile、APNs key、App Store Connect
  API key を `.build` や repositoryへコピーしない。誤って露出した場合は upload を停止し、keyを
  revoke/rotate してから再開する。
- build output は `.build/` の disposable artifact として扱い、commit、push、TestFlight配布を
  N01 worker が行わない。

最終確認日: 2026-09-14（N01 source/package/Xcode metadata に対する手順レビュー）。Apple account
access、registered physical device、signed archive、TestFlight upload は未確認の外部依存である。
