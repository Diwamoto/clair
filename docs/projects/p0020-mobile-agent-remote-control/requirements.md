# Requirements

## Motivation

利用者はClairのterminalでcoding agentを長時間動かす。席を離れた後も、どのProject/sessionが動いているかを
確認し、必要な入力やinterruptを返し、registered agentを起動したい。現在のP07/P09はMacのlocal lifecycleと
raw agent workflowを持つため、mobileを別のagent UIではなく同じPTY sessionの追加clientとして早期に接続する。

## Goals

- `G-01`: Clairが管理する任意のPTY sessionを、iPhone/iPadのPWAからraw terminalとして閲覧・操作できる。
- `G-02`: Project/sessionをstable IDで選択し、registered agent profileを安全に起動できる。
- `G-03`: Macとmobileの同時接続、切断、再接続、Mac GUI終了後のhost継続を扱える。
- `G-04`: mobile入力をbrokerの到着順で同じPTYへ適用し、重複operationを一度だけ適用する。
- `G-05`: single-user・自所有deviceのpairing、scope、revoke、秘匿されたattention通知を提供する。

## Non-goals

- mobile full IDE、source editor、file browser、diff/review、汎用remote shellの新規起動。
- TUI画面のscreen scrapingによるsemantic status、tool call、approvalの推測。
- ACP/Codex/OpenCode等のsemantic adapter、vendor remote機能のproxy。
- team account、multi-tenant、organization audit、公開relay、Clair account同期。
- Android、App Store一般配布、TestFlight、Ad Hoc、Apple Developer ProgramをP0020の配布依存にすること、relayのSRE・課金・abuse prevention。
- native iPhone/iPad clientのrelease配布、APNs送信、native-only background capability。

## Resolved initial scope

- 対象はsingle-user・自所有Mac・自所有iPhone/iPad。team roleは扱わない。
- 初期版はprivate-network onlyとし、Cloudflare One Client / Tunnel private routeを配布向けの既定経路、Tailscale
  Serveを自所有環境・開発用の経路として同じmobile APIへ接続する。mobile clientはHTTPSで提供するPWAとし、
  App Store、TestFlight、Ad Hoc、Apple Developer Programを配布の前提にしない。public listenerとClair-owned relayは持たない。
  公開relay/E2EEはprivate-network版の実利用後に別decisionとする。
- 外部に公開するのはlocalhost上の`clair-mobile-host`一つだけとし、`clair-ptyhost`はsame-user Unix socket/local IPC
  に閉じる。PWAは`clair-mobile-host`のWSS endpointへ接続し、既存のframed TCP listenerはnative/reference clientまたは
  diagnostic用に限定する。Tailscale/Cloudflareのnetwork identityだけでmobile APIを認証しない。
- Macで明示的にOrca型QR/HTTPS pairingを開始し、device key、表示名、scope、作成日時、最終利用日時、revoke stateを
  端末単位で管理する。native/reference clientではdeep linkも互換経路として許可する。
- Pairing linkはPWAを開くHTTPS endpoint、`host_id`、server identity、host fingerprint、protocol version、短時間だけ
  有効なone-time bootstrap secretを含む。PWAではpairing materialをURL fragmentに置き、shellへのHTTP request、
  referrer、server access logへ送らない。device private key、発行済みdevice token、terminal content、prompt、cwd、
  credentialは含めない。
- PWAはWeb Cryptoでdevice key pairを生成し、非抽出private keyと発行済みdevice tokenをIndexedDB等のbrowser protected
  storageへ保存する。native/reference clientはKeychain等のplatform protected storageを使う。以後の接続ではdevice ID、
  token、challenge proofを使い、host identityが同一ならendpoint変更後も再pairingしない。
- 端末ごとに独立したdevice grant/tokenを発行する。link再生成は未使用linkだけを無効化し、既存grantはrevokeまで
  有効とする。revokeはactive connectionを直ちに閉じ、旧generationの接続・operationを拒否する。
- pairing直後のscopeは`view`。`write_terminal`、`signal`、`terminate`、`spawn_session`、`manage_devices`は個別に付与する。
- mobileのviewportはclient-localであり、PTYのrows/columnsを変更しない。
- desktopとmobileのinputはbrokerが受信した順に直列化する。入力を暗黙に奪うcontrol leaseはMVPに置かない。
- mobileはterminal outputやdiffを永続cacheしない。再接続はsession epochとcursorで行い、保持範囲外は明示gapにする。
- PWAはforeground復帰時にprivate channelからattentionを取得する。将来Web Pushを追加する場合もpayloadは内容を含まず、
  private channelを再接続するopaque wake identifierだけを送る。APNsはP0020の必須経路にしない。
- raw terminalは全agent共通のbaseline。agent convenienceはregistered launch、interrupt、attention、再接続を先に提供する。
- Clair自身がagent sessionのstable identityとfactual stateを所有し、UI、mobile、CLIが同じcontrol planeを利用する。

## Functional requirements

- `FR-01`: hostは`project_id`、`worktree_id`、`session_id`、`session_epoch`、lifecycle、cwd、agent profileをstable identityとして管理する。branch名やpathだけでsessionを再関連付けない。
- `FR-02`: initializeでprotocol major/minor、client identity、frame limit、capabilityをnegotiationし、major不一致を拒否する。PWAはWSS WebSocket messageへ同じcontrol/data contractを載せる。
- `FR-03`: terminal outputは最大64 KiBのbase64なしbinary frameで運び、epochと単調増加byte offsetを含める。
- `FR-04`: 複数subscriberは独立cursorを持つ。保持範囲外・epoch不一致はtyped gapを通知し、欠落をsilentに継続しない。
- `FR-05`: terminal input、paste、signal、terminate、agent launchを別operationとし、device scope、session visibility、operation IDを検証する。
- `FR-06`: 同一sessionのMac/mobile inputをbroker到着順に適用する。operation IDの再送は同じ結果を返し、異なるpayloadでの再利用を拒否する。
- `FR-07`: mobileのviewport変更はPTY resizeへ変換しない。desktop geometryはdesktop ownerが保持する。
- `FR-08`: session catalogはdeviceに許可されたworktreeだけを返し、missing/detached/exitを明示する。
- `FR-09`: QR pairingはone-time・短時間expiry・user presenceを要求し、revoke時はactive connectionを閉じる。
- `FR-10`: mobileから利用できるagent profileはhostが登録したものに限定し、任意のshell commandをspawn APIとして公開しない。
- `FR-11`: attention通知、browser storage、ログ、diagnosticにはterminal bytes、prompt、cwd、command line、credentialを含めない。将来のWeb Pushもopaque wake metadataだけを運ぶ。
- `FR-12`: remote feature flagをMacに持ち、disable/revoke後もlocal PTYとClair GUIを継続する。
- `FR-13`: hostは復元済みを含むagent tabを`session_id`、Project/worktree、registered profile、lifecycle、attention、
  capabilityとともにカタログ化する。`starting`、`running`、`attention`、`exited`はPTY/hookの事実からのみ導出し、
  screen scrapingでsemantic statusを推測しない。
- `FR-14`: agentのlist/status/launch/reveal/input/interrupt/stopはstable command ID（`agent.*`）で定義し、
  mobile method（`agent/*`）と`clair agent` CLIが同じhost control planeへ投影する。CLIの危険操作は明示的な
  `--yes`を要求できる。
- `FR-15`: `clair-mobile-host`はmobile APIの唯一のremote boundaryとなり、`clair-ptyhost`をraw TCP/HTTP/WebSocket
  endpointとして公開しない。PWA向けWSS/HTTPS adapter、native向けframed TCP adapter、Tailscale/Cloudflare/relay adapterは
  typed control/data protocolの外側でbyte stream/messageを運ぶだけとする。
- `FR-16`: hostは明示操作ごとにone-time・短時間expiryのpairing linkを生成し、PWA向けHTTPS URLまたはnative向けdeep linkで
  endpoint、host identity、application fingerprint、protocol version、bootstrap secretを伝える。PWAのpairing materialは
  URL fragmentに限定し、未使用linkは一度だけ消費できる。
- `FR-17`: pairing成功時にhostは端末ごとの`device_id`、device public key、opaque device token、generation、default
  `view` grantを保存する。tokenはmobileへ一度だけ返し、ログ・diagnostic・QR再表示に含めない。
- `FR-18`: reconnectは保存済みtokenとdevice keyによるchallenge-responseで認証し、hostはgeneration、revoke state、
  protocol compatibility、scope、visible worktreeをoperation dispatch前に検証する。tokenだけのnetwork reachabilityを
  authorizationとみなさない。
- `FR-19`: mobileが接続endpointを編集できる場合、pinned host identity/fingerprintが一致するときだけ再pairingなしの
  reconnectを許可する。fingerprint変更、未知host、pairing expiry、pairing reuseは明示的に拒否する。

## Quality attributes

- `QR-01 Security`: private network外へterminal内容を公開せず、device scopeとrevokeを全operationで検証する。公開relayへ拡張する前にapplication-layer E2EEを別レビューする。
- `QR-02 Privacy`: PWAのbrowser storage、native client、Web Push/APNs、ログ、crash reportへraw terminal、prompt、cwd、secretを永続化しない。
- `QR-03 Reliability`: partial/oversized/duplicate frame、network reconnect、host/app restart、agent exitを再現テストできる。
- `QR-04 Backpressure`: subscriberごとのbounded queueを使い、遅いmobileがPTY readやMac clientを停止させない。
- `QR-05 Compatibility`: protocol major不一致は拒否し、minor差はcapability縮退で扱う。golden fixtureを共有する。
- `QR-06 Recovery`: remote component停止・disable・rollbackでPTYをkillせず、Mac local reattachを継続する。
- `QR-07 Headless testability`: 画面操作なしでagent catalog、status、input、interrupt、stop、registered launchの
  成否とtyped errorをJSONで検証できる。
- `QR-08 Credential isolation`: pairing secretはQR/短命URL fragmentまたはhandshake中のin-memory状態に限定し、URL query、
  shellへのHTTP request、referrer、browser storage、ログ、metrics、crash reportへ残さない。device token、device private key、
  host private key、terminal contentはQR、browser storage、ログ、metrics、crash reportへ出さず、hostと各clientのprotected
  storageに限定する。
- `QR-09 Transport neutrality`: PWAのWSS、native framed TCP、Tailscale Serve、Cloudflare private route、将来relayで同じ
  MobileControl APIのgolden fixtureと認証状態機械を再利用できる。transport固有の認証情報をoperation payloadへ混ぜない。

## Acceptance criteria

- `AC-01`: protocol packageにversion negotiation、session catalog、scope、binary frame、ordered input dedupeのgolden/unit testがある。
- `AC-02`: desktop 1台とmobile viewer 2台が同一PTYを購読し、遅いviewerのgap/disconnect後も他clientとPTY readが継続する。
- `AC-03`: cursor replay、epoch mismatch、journal gap、Mac GUI restartを跨いで、重複・欠落を検出できる。
- `AC-04`: Mac/mobile concurrent input、operation retry、mobile viewport変更で、到着順・at-most-once・非resizeが維持される。
- `AC-05`: QR pair、default view、scope deny、device revoke、active connection close、remote disableを検証できる。
- `AC-06`: Safariからホーム画面へ追加したPWAで、Project/session選択、current screen/bounded scrollback、raw input、interrupt、registered agent launchがprivate network上で動作する。
- `AC-07`: PWAがforeground復帰後にprivate channelへ再接続し、attentionを取得できる。通知を追加する場合もsecret/contentを含めない。
- `AC-08`: PWA shellをHTTPSで提供し、manifest、cache policy、WSS接続、Safariのホーム画面起動を確認できる。App Store Connect、TestFlight、Apple Developer Programは不要とする。
- `AC-09`: malformed/oversized input、slow consumer、agent exit、Tailscale/Cloudflare route outageでtyped error、bounded resource、local fallbackが確認できる。
- `AC-10`: Clairのagent registryが復元済みsessionを含むstable IDで返り、`scripts/clair agent list/status/input/interrupt/stop`
  とregistered `launch`が同じCommand Registryの結果・エラーを返す。mutating CLI callは`--yes`なしではapprovalで止まり、
  `--yes`指定時だけheadlessに実行できる。
- `AC-11`: QR/deep-link pairがone-time・expiry・user confirmation・host fingerprint pinを検証し、pair成功後に端末固有
  token/grantを一度だけ発行できる。QRやログにtoken・private key・terminal contentが出ない。
- `AC-12`: 同一host identityでLAN/Tailscale/Cloudflare endpointを切り替えても再pairingなしでreconnectでき、fingerprint変更時は
  接続を停止してexplicit re-pairを要求する。
- `AC-13`: 端末Aのtokenを端末Bで使えず、device revokeがactive connectionを閉じ、旧token/generation・operation replayを
  拒否する。Tailscale/Cloudflareに到達できるだけではcatalog/controlを利用できない。
- `AC-14`: `clair-ptyhost`がnetwork listenerを持たず、mobileは`clair-mobile-host`の単一typed endpointからのみ同じ
  session brokerへ到達する。PWAのWSS、Tailscale Serve、Cloudflare private routeで同一protocol fixtureが通る。

## Deferred follow-ups

- host-owned portable terminal snapshotとgap後の完全resync。
- Codex/OpenCode/ACP semantic adapter、structured prompt/approval/status。
- public relay、application-layer E2EE、traffic-analysis resistance。private-network pairingで確立したdevice identity
  をrelayへ移す際の暗号handshakeはsecure-link spikeで別途確定する。
- Web Push、native iOS release distribution、mobile branch review、diff/source editing、team role、Android。
