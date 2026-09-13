---
id: ADR-0015
title: "Native iPhone/iPad clientとAPNsを製品経路に採用する"
status: accepted
date: 2026-09-14
deciders:
  - "Daiki"
related_projects:
  - "p0020-mobile-agent-remote-control"
related_issues:
  - "https://github.com/Diwamoto/clair/issues/20"
supersedes:
  - "ADR-0013 (PWA distribution and notification portions)"
superseded_by: []
---

# ADR-0015: Native iPhone/iPad clientとAPNsを製品経路に採用する

## Context

ADR-0013は、自所有用途での配布コストと再署名の負担を避けるため、P0020のsupported clientをPWAとして扱った。
しかし、Clair v2ではagentの承認要求、review完了、session異常を、アプリがforeground・background・terminatedのどの
状態でも利用者へ届け、通知から対象workspaceやreviewへ安全に復帰できることが製品要件になった。PWAのforeground resumeや
後付けWeb Pushではこのlifecycleと通知品質を製品の基準として固定できない。

一方、P0020で実装・検証したhost identity、one-time pairing、device grant、scope、revoke、session journal、raw
terminal protocolはclientの配布形態から独立している。これらのhost/pairing/session境界を捨てず、v2の製品clientと
通知経路だけをnative platformへ切り替える必要がある。

## Decision drivers

- foreground・background・terminatedをまたぐ通知とdeep linkの挙動を、Appleの製品lifecycleで検証できること。
- iPhone/iPadのKeychain、UserNotifications、background task、scene phaseを使い、credentialと接続復旧の境界を明示できること。
- APNsを状態の正本にせず、通知をopaqueなwake signalとして扱うこと。
- Apple Developer、署名、TestFlight、push entitlementのownershipを、実装担当が迷わない粒度で分離すること。
- P0020のhost/pairing/session protocolとADR-0011/0012のsecurity boundaryを継続利用すること。

## Options considered

### Option A: PWAをsupported clientとして継続する

- Advantages: App Store、TestFlight、iOS signingへの依存を減らし、web UIの更新を再インストールなしで配布できる。
- Disadvantages: terminated/background時の通知品質、Web Pushの制約、browser storageのlifecycleを製品の基準として引き受ける必要がある。
- Evidence: [ADR-0013](0013-self-only-mobile-pwa.md)、[P0020](../projects/p0020-mobile-agent-remote-control/README.md)。

### Option B: iPhone/iPadのnative clientとAPNsをsupported product pathにする

- Advantages: UserNotifications、APNs、Keychain、scene phase、background taskをAppleのsupported lifecycleで統合できる。署名済み
  buildをTestFlightで実機検証できる。
- Disadvantages: Apple Developer account、bundle ID、signing、entitlement、App Store Connect、credential rotationを運用する必要がある。
- Evidence: v2の[Native Rewrite Plan](../plans/clair-v2-native-rewrite.md)がnative mobileとAPNsをPhase 0から管理対象にしている。

## Decision

1. Clair v2のsupported mobile clientは、iOS/iPadOSのSwiftUI native appとする。PWAは製品の操作面・通知経路・認証面には使わず、
   web UIは開発用の検証・診断に限定する。
2. APNsは通知配送のprovider boundaryとし、payloadにはopaqueなresource ID、event kind、wake identifier、revision hint、TTLだけを
   許可する。terminal bytes、prompt、cwd、diff、credential、agentの秘密は通知、ログ、metrics、crash reportへ入れない。
3. P0020のhost/pairing/session protocol、ADR-0011のraw-terminal優先順位、ADR-0012のone-time pairing・device grant・revoke・
   transport-neutral APIは継続する。native clientはこれらへ接続する製品clientであり、別のauthorization pathを作らない。
4. APNsはbest-effortであり、通知を状態の正本にしない。アプリ起動、foreground復帰、notification tap後は、認証済みの
   `ClairDaemon`からrevisionと最新状態を取得する。

## Apple identifiers, signing, and entitlement ownership

既存のXcode設定にある識別子をv2の初期値として固定する。bundle IDはwildcardを使わず、Apple Developer portal、Xcode target、
TestFlightのbuild metadataで同じ値を使う。Team IDは識別子であり、証明書・秘密鍵・API keyではない。

| Surface | Bundle ID / identifier | Ownership and boundary |
|---|---|---|
| macOS Stable | `com.diwamoto.clair` | Clair desktop release owner。`Config/Stable.xcconfig`の既存値を維持する。 |
| macOS Dev | `com.diwamoto.clair.dev` | Clair development owner。Stableとsettings、更新、通知環境を混同しない。 |
| iOS/iPadOS mobile | `com.diwamoto.clair.mobile` | native mobile owner。`ClairMobile` targetとApple Developer App IDを一対一で対応させる。 |
| Test bundle | `com.diwamoto.clair.tests` | test lane専用。製品のAPNs登録やTestFlight配布には使わない。 |
| Apple Developer Team | `3UY66R4X2N` | 現在の`Config/App.xcconfig`に設定されているClairのApple team。account membershipとApp ID登録はClair release ownerが管理する。 |

署名の責任境界は次の通りとする。

- ローカル開発はXcodeのAutomatic signingと`Apple Development` identityを使い、team選択とtargetのbundle IDを一致させる。現在の共有設定は
  `Config/App.xcconfig`にある。Simulator向けのunsigned buildは検証用であり、製品配布の証拠にはしない。
- 実機・TestFlight buildはnative mobile/release ownerが署名設定、provisioning、capability、archive、uploadを管理する。証明書の
  private key、provisioning profile、App Store Connect API key、issuer secretは開発者のKeychainまたはCI secret storeに置き、repositoryへ追加しない。
- `ClairMobile` targetのpush capabilityと`com.apple.developer.aps-environment` entitlementはnative mobile ownerが管理する。
  Debug/development buildは`development`、TestFlightおよびproduction buildは`production`とし、環境をbuild metadataとdevice registryへ記録する。
- macOSアプリ、PWA、`ClairDaemon`へAPNs provider credentialやpush entitlementを埋め込まない。Macアプリは通知イベントをdaemonへ渡すだけで、
  Apple providerとして認証しない。

## APNs and device-token ownership

| Component | Owns | Must not own |
|---|---|---|
| `ClairMobile` | 通知権限の要求、APNs device tokenの取得・更新・登録解除、tokenと`device_id`の紐付け、notification tapからのdeep link、Keychain保存 | APNs provider key、他deviceのtoken、terminal content |
| `ClairDaemon` | authenticated mobile connectionからのtoken登録、`device_id`・bundle ID・APNs environment・token・generation・last-seen・revoke stateのdevice registry、TTLと再登録要求 | Apple provider credential、raw terminalやproject全体のpush payload |
| `ClairPushRelay` | daemonから受けたopaque eventのAPNs送信、development/production endpointの選択、provider credentialのrotation、APNs responseの分類 | pairing authority、device grantのscope判断、コード内容やagent秘密の永続化 |
| Apple Developer / App Store Connect | App ID、push capability、signing certificate、provisioning、TestFlight buildとtester distribution | Clairのsession state、device grant、notification payloadの正本 |

登録と配送は次の順序で行う。

1. native appがUserNotificationsの許可を取得し、APNsからtokenを受け取る。tokenは環境ごとに異なり得るため、`bundle_id`と
   `aps_environment`を伴う登録レコードとして扱う。
2. appは既存のauthenticated pairing/sessionを通じて`device_id`、bundle ID、environment、token、client build versionをdaemonへ送る。
   daemonはscopeとdevice grantを確認し、同一deviceのtoken更新を原子的に置き換える。
3. daemonは通知イベントを、宛先device、event kind、opaque resource ID、revision hint、TTLだけのrelay requestへ変換する。
   relayはprovider credentialをsecret storeから読み、environmentに対応するAPNs endpointへ送る。
4. token invalidation、environment mismatch、credential rejectionはrelayが分類してdaemonへ返す。daemonは古いtokenを無効化し、
   次回のnative app接続で再登録を要求する。tokenを無期限に再利用しない。
5. appは通知を受けた後、またはforegroundへ戻った後、daemonへ再接続してrevisionを検証し、認証済みchannelから詳細を取得する。

APNs provider credentialのownerはnative mobile/release infrastructure ownerとし、`ClairPushRelay`の実行環境だけへ注入する。
credentialの発行・rotation・失効はApple Developer/App Store Connectの管理者が行い、`ClairDaemon`、iOS app、Git repositoryには配置しない。

## TestFlight ownership and release gate

native mobile/release ownerがApp Store Connectの`Clair Mobile` app record、signed archiveのupload、build metadata、internal tester、
TestFlightの配布停止・期限管理を所有する。実装担当は、署名済みbuildが次の動作を満たす証拠を残してから配布を完了扱いにする。

- development buildとTestFlight buildが、それぞれ正しいAPNs environmentへ登録される。
- physical iPhone/iPadのforeground、background、terminated状態でopaque notification、tap、再接続、revision resyncを確認できる。
- device tokenの更新、revoke、再pair、logout/再インストール後の再登録が古いtokenやgenerationを受け入れない。
- TestFlight buildにApple Developer signingとpush entitlementがあり、production provider credentialを開発環境へ流用しない。
- App Store公開はこのADRの要件ではない。private TestFlightをv2の実機検証とself-owned distributionに使う。

## Supersession map

| Previous source | Status after ADR-0015 | Scope |
|---|---|---|
| [ADR-0013](0013-self-only-mobile-pwa.md) | `superseded` | PWAをsupported clientとし、TestFlight/APNs/signingを必須にしない配布・通知方針。 |
| [P0020 bundle](../projects/p0020-mobile-agent-remote-control/README.md) | PWA distribution path `superseded`; protocol evidence retained | host、pairing、scope、revoke、session protocolとnative referenceは再利用し、PWAのrequirements/design/planはv1 evidenceとして読む。 |
| [Clair v2 roadmap](../plans/clair-v2-roadmap.md) | historical; PWA milestone `superseded` | 実装順の正本は[Native Rewrite Plan](../plans/clair-v2-native-rewrite.md)とtask queueへ移る。 |

ADR-0013がADR-0011のclient distribution and notification portionsだけをrefineしていた関係は維持する。ADR-0011のraw-terminal、
private-network、host ownershipの結論と、ADR-0012のpairing・transport boundaryはこのADRでは変更しない。

## Consequences

### Positive

- background/terminated notification、deep link、Keychain、signed physical-device buildを製品lifecycleとして検証できる。
- APNs provider credentialをMacアプリとmobile appから隔離し、device token、revoke、environment分離をdaemonのregistryで管理できる。
- P0020で確立したhost/pairing/session semanticsを維持したままclient配布方針を変更できる。

### Negative

- Apple Developer membership、bundle ID、signing、push entitlement、App Store Connect、TestFlightを継続運用する必要がある。
- development/productionのAPNs environment、device token rotation、provider credential rotationを別々に検証する必要がある。
- native appのrelease cadenceとAppleのbuild/tester制約を受け、PWAの即時更新は製品経路から外れる。

## Validation

- Apple Developer portal、Xcode target、entitlement、TestFlight metadataのbundle IDが`com.diwamoto.clair.mobile`で一致する。
- `development`と`production`のAPNs endpoint、device registry、provider credentialを混同しないintegration fixtureがある。
- signed physical-device buildでforeground/background/terminated、tap、reconnect、revision resync、token replacement、revokeを確認する。
- notification payloadのredaction testでterminal bytes、prompt、cwd、diff、credentialが存在しないことを確認する。
- PWA関連文書、旧ADR、roadmapからADR-0015へのリンクとstatusが検証できる。

## Revisit conditions

- background/terminated notificationが製品要件から外れ、native-only capabilityを維持する理由がなくなった場合。
- Apple Developer/TestFlightの利用不能が、self-owned deviceの実用性を満たせない外部制約になった場合。
- APNsのbest-effort通知とauthenticated resyncでは要件を満たせない証拠が出た場合。
- 複数ユーザー、team identity、Android、公開配布、別providerが必要になり、device registryとcredential ownershipを拡張する場合。

## References

- [Clair v2 Native Rewrite Plan](../plans/clair-v2-native-rewrite.md)
- [Clair v2 native rewrite task queue](../plans/clair-v2-native-rewrite-queue.md)
- [P0020 mobile agent remote control](../projects/p0020-mobile-agent-remote-control/README.md)
- [ADR-0011: early mobile agent control](0011-early-mobile-agent-control.md)
- [ADR-0012: Orca-style pairing](0012-orca-style-mobile-pairing.md)
- [ADR-0013: self-only mobile PWA (superseded)](0013-self-only-mobile-pwa.md)
