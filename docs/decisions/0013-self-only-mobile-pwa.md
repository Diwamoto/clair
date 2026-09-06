---
id: ADR-0013
title: "自所有mobile clientをPWAとして配布する"
status: accepted
date: 2026-09-06
deciders:
  - "Daiki"
related_projects:
  - "p0020-mobile-agent-remote-control"
related_issues:
  - "https://github.com/Diwamoto/clair/issues/20"
supersedes:
  - "ADR-0011 (client distribution and notification portions)"
superseded_by: []
---

# ADR-0013: 自所有mobile clientをPWAとして配布する

## Context

P0020のmobile clientは、これまでnative iPhone/iPad app、private TestFlight、APNsを前提にしていた。しかし利用者の
要件は、App Storeへ公開せず、自所有のiPhoneからClairのremote controlだけを使えることである。native appを無料の
Personal Teamで配布する経路はあるが、provisioningが短期間で切れ、常用の配布経路としては扱いにくい。

一方、P0020のhost core、pairing、scope、revoke、session replay、raw terminal protocolはUI・transportから分離されている。
既存のInteraction Labでmobile UIの検証資産もあるため、browser clientへ投影すればAppleの署名・配布経路を要件から外せる。

## Decision drivers

- App Store、TestFlight、Apple Developer Programを自所有用途の必須依存にしない。
- iPhoneのホーム画面からアプリに近い操作感で起動できる。
- 既存のClair-owned host protocol、pairing、authorization、bounded streamを再利用する。
- mobile clientを公開せず、private networkとapplication-level grantを維持する。
- UI更新を再署名・再インストールなしで反映できる。

## Options considered

### Option A: 無料Personal Teamでnative appを直接インストールする

- Advantages: 現在のSwiftUI clientをそのまま使える。Appleへの支払いが不要。
- Disadvantages: provisioningとApp IDが短期間で切れ、常用時にMacから再ビルド・再インストールが必要になる。
- Evidence: AppleのPersonal Teamはdevice testing向けで、provisioning profileは発行から7日で期限切れになる。

### Option B: private TestFlightまたはAd Hocでnative appを配布する

- Advantages: App Storeの公開一覧へ載せずにnative appを配布できる。
- Disadvantages: Apple Developer Programへの加入が必要。TestFlight buildは90日で期限切れになり、Ad Hocもdevice登録と証明書運用が必要になる。
- Evidence: Apple Developer Programのmembership resourcesにTestFlight、App Store Connect、Ad Hoc distributionが含まれる。

### Option C: HTTPSで提供するPWAをmobile clientにする

- Advantages: AppleのiOS signing、App Store、TestFlightに依存せず、Safariからホーム画面へ追加できる。web UIを更新するだけで済む。
- Disadvantages: browserからraw TCPへ接続できないため、`clair-mobile-host`にWebSocket/HTTPS adapterを追加する必要がある。browserのprotected storage、background、pushにはnativeと異なる制約がある。
- Evidence: 既存host coreはtransport-neutralで、設計上WebSocket adapterを許容している。現行native clientのraw TCP接続はPWA用に別adapterが必要になる。

## Decision

Option CをP0020の主対象として採用する。

- mobile clientの配布形態は、HTTPSで提供するPWAとする。App Store、TestFlight、Ad Hoc、iOS signingをP0020の完了条件に含めない。
- iPhoneではSafariからホーム画面へ追加し、PWAとして起動する。PWAが公開App Store listingを持つことは要求しない。
- PWAは`clair-mobile-host`のWSS endpointへ接続する。既存のlocalhost-only framed TCP listenerはnative/reference clientまたはdiagnostic用に残してよいが、PWAはraw TCPへ直接接続しない。
- WebSocket adapterは既存の`MobileControlHost`、typed control/data protocol、認証、scope、ordering、replay境界を再利用し、別のauthorization pathを作らない。
- pairingはMac上の明示操作で生成した短命HTTPS pairing URLを基本とし、QRからSafariで開けるようにする。PWAのbootstrap
  materialはURL fragmentに限定し、shellへのHTTP request、referrer、server access logへ送らない。`clair://` deep linkは
  native/reference clientの互換経路として残してよい。
- PWAはWeb Cryptoでdevice key pairを生成し、非抽出private keyとcredentialをIndexedDB等のbrowser protected storageへ保存する。tokenやprivate keyをURL、localStorage、ログへ置かない。
- browser JavaScriptはTLS certificateを直接検証できないため、host identityのpinningはapplication-level challenge proofで行う。WSS/TLSはprivate routeとbrowserに任せ、pairingで表示されたhost fingerprintとchallenge identityの不一致を拒否する。
- attentionはPWAのforeground復帰後にprivate channelから取得することをMVPとする。Web Pushはcontent-free payloadを使う後続sliceとし、APNs senderはPWAの必須依存にしない。
- 既存native iOS targetはreference/比較用として保持するが、P0020のsupported distribution pathやrelease gateではない。

## Rationale

要件の中心はiOS native capabilityではなく、Mac上のagent sessionを自分のiPhoneから安全に見る・入力することである。PWAは
Appleの配布経路を避けながら、Interaction LabのUIとClairのtransport-neutral host coreを再利用できる。raw TCPからWebSocketへ
adapterを追加する作業は必要だが、authorizationやsession semanticsを作り直す必要はない。

private networkとapplication-level device grantを維持するため、PWAを単なる公開HTTP画面にはしない。HTTPS/WSS endpoint、
短命pairing、host identity challenge、device revokeを必須とし、`clair-ptyhost`は引き続きsame-user local IPCに閉じる。

## Consequences

### Positive

- App Store公開、TestFlight運用、Apple Developer Programの年額を自所有用途のblockerにしない。
- Safariのホーム画面から使え、web clientの更新を再署名・再インストールなしで反映できる。
- Interaction Labの画面資産と既存のtyped mobile protocolを再利用できる。
- native iOS implementationを将来のpush/background/native capability向けの参考実装として保持できる。

### Negative

- `clair-mobile-host`にWSS/WebSocket adapterとHTTPSで配信するPWA shellが必要になる。
- PWAのdevice key/token保存はKeychainと同じ保証ではなく、browser data消去時は再pairingが必要になる。
- browser lifecycleでは常時接続・background実行・通知の即時性をnative appと同じにはできない。
- QRのHTTPS URL、application-level host identity proof、WSS routeを別途検証する必要がある。

## Validation

- HTTPSでPWAを提供し、Safariからホーム画面へ追加して起動できる。
- PWAがWSSでinitialize、pair、challenge、session catalog、bounded terminal stream、input、interrupt、revokeを実行できる。
- binary terminal frameがbase64化されず、partial/oversized/gap/reconnectのcontractがnative/reference clientと一致する。
- browserのdevice keyがURL、localStorage、ログ、diagnosticへ出ず、pairing fragmentがhandshake後に残らず、browser data消去後は
  明示的な再pairingになる。
- `clair-ptyhost`がnetwork listenerを持たず、PWAが`clair-mobile-host`の単一endpointだけへ接続する。
- App Store Connect、TestFlight、Apple Developer Programなしでprivate-network smokeを完了できる。

## Revisit conditions

- backgroundでの確実なattention通知、Bluetooth/NFC、共有extension、Secure Enclaveなどnative-only capabilityがP0020の必須要件になる。
- 複数ユーザー、公開配布、team identity、監査、mobile device managementが必要になる。
- browser storageまたはWSS routeの制約により、self-only private-network smokeを安定して満たせない証拠が出る。

## References

- Project: [p0020-mobile-agent-remote-control](../projects/p0020-mobile-agent-remote-control/README.md)
- Raw-terminal priority: [ADR-0011](0011-early-mobile-agent-control.md)
- Pairing and transport boundary: [ADR-0012](0012-orca-style-mobile-pairing.md)
- [Apple: Turn a website into an app on iPhone](https://support.apple.com/en-ie/guide/iphone/iphea86e5236/ios)
- [Apple: Choosing a membership](https://developer.apple.com/jp/support/compare-memberships/)
