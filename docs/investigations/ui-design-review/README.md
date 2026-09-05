---
title: "Clair native UIのdesign review"
status: complete
related_project: "cross-cutting (P02-P14 native shell)"
date: 2026-09-05
---

# Clair native UIのdesign review

## Question

Clairのnative UIは、Orca、VS Code、Cursor、Zedと並べたときに劣らないか。劣るとすれば、
どのdocsが欠けていて、どの実装が product docsの原則を裏切っているか。

## Scope

`apple/ClairApp`のSwiftUI shell全体（30,255行、うち`ContentView.swift`が5,087行）、
`apple/ClairMobileApp`、および`docs/product`、`docs/plans/clair-poc-queue.md`のUI contract。

実装のbuildや実機操作は行っていない。source読解による静的reviewである。

## Summary

Clairの土台は健全である。One Darkのtoken集約（`WorkspaceChrome`）、Command Registry駆動の
palette、Projectごとのsurface所有、raw terminalの一級扱いは、いずれも名前の挙がった
editorと同じ水準の構造的判断である。

一方で、名前の挙がったeditorに「負けない」水準には届いていない。理由は視覚的な洗練ではなく、
次の3つである。

1. **docsにdesign contractが無い。** UI contractは`docs/plans/clair-poc-queue.md`の
   6行だけであり、product docsに視覚・密度・focus・motionの正本が無い。
2. **workspaceの不変条件が壊れている。** activityの切り替えがpane layoutごと置き換える箇所があり、
   principle 2（editorとterminalを同格に扱う）を実装が裏切っている。
3. **editorとして当然の操作が無い。** split dividerがdragできない、pane間のfocus移動shortcutが無い、
   command paletteの↑↓が装飾になっている。

以下、docs側の欠落と実装側の指摘を分けて記述する。

---

## Part 0: reviewの後に確定した方針

canvas上のreviewを経て、利用者が次を決定した。本文の該当箇所にも「決定」として反映してある。
review時点の指摘そのものは記録として残す。

| # | 決定 | 影響する指摘 |
|---|---|---|
| 1 | tabはtitlebarの1本のstripに集約し、**全Projectのtabを並列に扱う**。別Projectのtabへ移動したらProjectも一緒に切り替わる。 | S1-5を不採用 |
| 2 | **paneはtab barもheaderも持たない**。Ghosttyと同じく、terminalとeditorがそのまま描かれる。 | S1-5、S2-2、S2-4の解決手段を変更 |
| 3 | split dividerは**1pxのborderのみ**。hoverでつかめるようにし、dragで比率を変える。3点リーダのgripは置かない。 | S1-3の表現を変更 |
| 4 | paneの入れ替えは**terminal上部の横向き3点リーダ**をdragして行う。Ghosttyと同じ形式。 | S2-4を置換 |
| 5 | 検索欄をtitlebarのcommandの**左**へ置く。commandは日本語ラベルと枠を持たない。 | 新規 |
| 6 | activity barは**元どおりsidebarの中**に置く。全幅rowにはしない。 | S1-2を不採用 |
| 7 | status barの右端に**agentのrate limit**を表示する。 | 新規、N6として追加 |

決定2と3の結果、code到達までの縦chromeは48 + 26 = **74px**になる（現在174px、Zed約52px）。

---

## Part 1: docsに欠けているもの

### D1. Design contractの正本が無い（最重要）

現在のUI contractは`docs/plans/clair-poc-queue.md`の29-34行にある6行の段落だけである。
内容は「One Dark基調、compact、traffic lightsと同じrowのProject group、右端のCommand
Window/Settings、first-classなNotifications/History」で、これはlayoutの列挙であって
contractではない。

`docs/README.md`の分類表に照らすと、UIの正本を置く場所が存在しない。product/はWhatを、
architecture/はHowを扱うが、「どう見え、どう反応するか」の正本が無い。

結果として`WorkspaceChrome`のtokenは実装のコメントでのみ正当化されており、
新しいviewを書く人が参照できる規範が無い。実際にPart 2のC1（2つのdesign systemの混在）は
これが原因で発生している。

**提案:** `docs/product/interaction.md`をproduct docsの4つ目として追加する。
draftを[proposed-design-contract.md](proposed-design-contract.md)に置いた。

### D2. Latency budgetが定義されていない

principle 10は「同じ作業をcceditより明確に快適に行えること」を合格線としているが、
これは測定できない。Zedがこの4つの中で際立っているのは配色ではなく入力遅延である。
「快適」を数値契約にしない限り、native化の合格判定は主観のままになる。

`docs/benchmarks/`にはmetric contractがあるが、対象はoperation scriptであり、
UIの応答時間は含まれていない。

**提案:** keystroke-to-glyph、tab切替、Project切替、file open、palette表示の5つに
p50/p99の予算を置き、benchmark corpusへ追加する。具体値はproposed-design-contract.mdに記載。

### D3. Focus modelが定義されていない

keyboard-firstを名乗るeditorにとってfocusは中核概念だが、docsに記述が無い。
実装では`surface.focusedPaneID`が存在し、focused paneは1pxのaccent borderで示されるが、
次が未定義である。

- pane間のfocus移動手段（shortcutが存在しない、Part 2 K1）
- overlay（palette、Quick Open）を閉じたときのfocus復帰先
- terminal paneにfocusがあるとき、shortcutをPTYへ渡すかClairが横取りするかの境界
- Project切替時にfocusがどのpaneへ戻るか

3番目はraw terminalを正本にする（principle 3）以上、避けて通れない。
GhosttyやiTerm2は明示的なcontractを持っている。

### D4. Theme方針が暗黙の実装になっている

`ContentView`は`.preferredColorScheme(.dark)`をhardcodeしている。personal用途で
dark固定は妥当な判断だが、docsのどこにも記録が無く、ADRも無い。
`WorkspaceChrome`のcommentが唯一の根拠である。

「light themeを作らない」は立派な決定である。決定として書けば、将来の再検討の起点になる。
書かなければ、単に忘れられた実装になる。

### D5. Density scaleとtypographyが場当たりである

`ContentView.swift`には8, 9, 10, 11, 12, 13, 14, 15pxの8段階のfont sizeが混在する。
compactなdesktop UIで8段階は多すぎる。名前の挙がったeditorはいずれも3-4段階で運用している。

同様にcorner radius（3, 4, 5, 6, 7, 8, 10, 12）、header height（34, 42, 48, 54, 58, 64, 68）も
scaleを持たない。

### D6. Empty / error / loading stateのcontractが無い

`ContentUnavailableView`が11箇所、alertが12箇所あるが、いずれもad hocである。
「いつ空状態を出すか」「errorをalertで出すかinlineで出すか」の規範が無いため、
Git errorはalert、editor load errorは全画面のorange icon、terminal missingはpane内のbutton、
と3つの様式が併存している。

### D7. Accessibilityが部分的である

`accessibilityLabel`は広く付いており良い。ただし次が欠けている。

- Reduce Motionは`TactileButtonStyle`だけが尊重している
- contrast比の検証記録が無い。`textQuaternary` rgb(112,120,113)は`canvas` rgb(18,20,22)上で
  約6.0:1だが、`surface`や`chromeRaised`上での値は未検証
- keyboard-onlyでの全操作到達可能性が未検証（Part 2 K1により実際に到達できない操作がある）

### D8. Mobileがdesign systemの外にある

`MobileControlAppView.swift`は`MobileAppPalette`という独自palette（10色）を持ち、
`WorkspaceChrome`と値が異なる。canvasはdesktopがrgb(18,20,22)、mobileが約rgb(14,15,18)で、
mobileの方が青寄りである。accentも2種類の青が存在する。

同一製品の2つのclientが別のbrandを持っている状態であり、docsにも「mobileは別のlookを持つ」
という決定が無い。

---

## Part 2: 実装の指摘

深刻度順。S1は名前の挙がったeditorとの比較で明確に劣る箇所、S2以降は品質の問題。

### S1. Workspaceの不変条件

#### S1-1. activityの切替がpane layoutを置き換える

`ContentView.swift:211-285`の`contentBody`で、activityごとにmain areaの中身が変わる。

| Activity | main area |
|---|---|
| files | pane layout |
| search | pane layout |
| review | pane layout |
| **git** | **`ProjectDiffPreview`（pane layoutを置換）** |
| **activity** | **`ProjectActivityDetailView`（pane layoutを置換）** |

Git iconを押すと、実行中のagent terminalを含むpane layoutが画面から消える。
sessionはbackgroundで生き続けるが、利用者から見えなくなる。

これはprinciple 2（「各paneはeditor、terminal、diffを混在できるtab group」）と
principle 1（「非表示中も明示的に終了されるまでsessionを継続する」の可視性側）の両方に反する。
VS Code、Cursor、Zedはいずれも、sidebarのview切替でeditor areaを触らない。

Clairにとって特に痛いのは、Clairの中心的な作業が「agentを走らせながら別のことをする」ことである点である。
その最中にGitを見るとagentが見えなくなるのは、この製品が最も避けるべき挙動である。

**提案:** activityはsidebarの内容だけを変える。Gitのdiffとactivityのdetailは、
pane layout内のtabとして開く（`ProjectPaneTabKind.diff`は既に存在する）。

#### S1-2. sidebarを閉じるとactivity barごと消える

`WorkspaceActivityLayout`（652-691行）と`ProjectWorkspaceDetail`（890-920行）で、
activity barは`if showsNavigation`の内側にある。`showsNavigation`は`isSidebarVisible`である。

つまり⌘Bでsidebarを閉じると、Files / Search / Git / Review / Activityへの導線が全て消える。
再表示するには⌘Bで開き直すしかない。

VS Codeのactivity barはsidebarと独立して残る。Zedはdockが閉じてもstatus barのbuttonが残る。
Clairだけが、closeしたら戻れなくなる。

**決定（不採用）:** activity barはsidebarの中に残す。全幅rowにも縦railにもしない。

この結果、⌘Bでsidebarを閉じている間はicon経由の導線が無い状態が残る。緩和として、
Files / Search / Git / Review / Activity / Sessionsの各表示をCommand Registryへ登録し、
shortcutとcommand paletteから直接到達できるようにする（K4と同じ対応）。
iconが唯一の導線である状態を解消すれば、sidebarに置いたままでも詰まらない。

#### S1-3. split dividerがdragできない

`ProjectPaneLayoutView`（2525-2578行）は`ratio`から固定幅を計算し、`Divider()`を置くだけである。
`DragGesture`が無い。

```swift
case .split(_, let orientation, let ratio, let first, let second):
  // ratio は surface 側からしか変わらない
  HStack(spacing: 0) {
    nodeView(first).frame(width: proxy.size.width * fraction)
    Divider()
    nodeView(second)
  }
```

利用者はsplitの比率をmouseで変えられない。変更手段は`equalizeSplits`（均等化）だけである。

scopeには「幅均等、高さ均等」が明記されているが、これは「dragもできる上で均等化commandもある」
という意味で読むのが自然である。dragできないeditorは、この4つの中に存在しない。

`ratio`はmodel側に既にあるので、divider上に`DragGesture`を載せて`ratio`を更新すれば済む。
hit areaはdividerの1pxではなく±4pxを取り、`.onHover`で`resizeLeftRight`カーソルを出す。

**決定:** 見た目は1pxのborderのままにする。gripのような装飾は置かず、hoverしたときに
つかめると分かる状態（cursorとborderの色）だけで示す。

#### S1-4. branch reviewが286pxのsidebarに入っている

`ProjectBranchReviewView`（2995行〜）は`WorkspaceActivityLayout`の`context`として渡される。
contextの幅は`minWidth: 204, idealWidth: 286, maxWidth: 340`である。

principle 6は「branch全体を成果物としてreviewする」をClairの中核価値に据えている。
その画面が、`GroupBox` + `Picker` + `Label`の縦積みformとして340px以内に押し込まれている。

一方でmain areaには`editorPane`が表示されている。つまり最も重要な画面が最も狭い場所にあり、
広い場所には関係の薄いeditorがある。

**提案:** branch reviewをpane内の全幅surfaceにする。sidebarには対象worktreeの選択と
変更fileのlistだけを残し、main areaにcommit済み / 未commit を分けた差分を出す。
これはprinciple 6の「commit済みと未commit/untrackedを分けて表示」を実際に読める形にする唯一の方法である。

#### S1-5. per-pane tab barが無い

全tabがtitlebarのProject group内strip（`WorkspaceTabStrip`）に集約されている。
strip幅は`maxWidth: 360`に固定され、tabは`minWidth: 124, maxWidth: 220`。
実質2-3枚しか見えない。

splitがあるとtabに`P1` `P2`のtext prefixが付く（1560-1564行）。
これは「どのtabがどのpaneのものか」をtextで説明している状態で、
本来はtabがそのpaneの上にあれば説明が要らない。

Projectが2つ開いていれば、strip 2本 + Project label 2つがtitlebarに並ぶ。
`clair-mock-lab`の契約は「file-tabの2段目を作らない」だったが、
これはsplitが無い前提のmockでの判断である。splitを一級にした時点で前提が変わっている。

**決定（不採用）:** per-pane tab barは作らない。tabはtitlebarの1本のstripのままとし、
全Projectのtabを並列に扱う。tab切り替えで別Projectのtabへ移ったら、そのProjectへも切り替わる。

`P1` / `P2`のprefixは、paneがtabを持たなくなるため不要になり削除する。
「どのtabがどのpaneか」という問い自体が消えるためである。

paneは代わりに**chromeを一切持たない**。terminalとeditorがpaneいっぱいに直接描かれる
（Ghosttyと同じ）。paneの識別と実行contextはstatus barとsession railが担う。

### S2. Chrome budget

#### S2-1. code領域に到達するまでの縦chromeが厚い

単一pane、editorを開いた状態の積み上げ:

| 要素 | 高さ |
|---|---|
| titlebar (`WorkspaceTitlebarMetrics.height`) | 48 |
| activity bar | 34 |
| editor pane header (`ContentView.swift:4664`) | 58 |
| status bar | 34 |
| **合計** | **174** |

参考として、Zedはtab bar約30 + status bar約22で約52、VS Codeはtitle 35 + tab 35 + status 22で約92。
Clairはその約2倍である。

splitすると`ProjectNativeEditorTab`のheaderが1つ増えるごとに58px、
terminal paneは`ProjectTerminalPanel`のheaderで42px消費する。
2x2 splitでは、4つのheaderが合計200px以上を占める。

**決定後の構成:** titlebar 48 + status bar 26 = **74px**。activity barはsidebarの中へ入るので
main areaの縦を消費せず、paneはheaderもtab barも持たない。splitしても74pxのまま増えない。

#### S2-2. editor pane headerが重い

`ProjectNativeEditorTab`のheader（4586-4665行）は58px高で、
breadcrumb、dirty表示、ellipsis menu、`保存` buttonを持つ。

- `保存` buttonは`.borderedProminent`で、system accentの塗り。
  ⌘Sがあるeditorで常時表示のprimary buttonは、この4つのどれにも無い。
- dirty状態が3箇所で重複表示される。tabの`•`とdot、headerの`未保存`、status barの`未保存の変更`。
- breadcrumbはmonospacedの単一textで、`Project / path/to/file.swift`という文字列である。
  segmentごとにclickできない。VS Code / Cursorのbreadcrumbはsymbol階層まで辿れる。

**決定:** headerを縮小するのではなく**廃止する**。paneはcontentだけを描く。

- breadcrumbはstatus barへ移す（focusしているpaneのpathを出す）。
- `保存` buttonは廃止する。⌘Sとtabのdotで足りる。
- dirty表示はtabのdotだけに一本化する。
- ellipsis menuは廃止し、paneの操作はcommand paletteとshortcutから行う。

#### S2-3. sidebar section headerが64px

`ProjectGitView`、`ProjectSearchView`、`ProjectBranchReviewView`、`ProjectActivityView`の
headerがいずれも`.frame(height: 64)`である（2811, 3042, 3756, 4030行）。

286pxのsidebarで64pxのheaderは、縦方向の予算をtitle文字列に使いすぎている。
28-32pxで足りる。

#### S2-4. pane操作menuがcontentの上に浮いている

`ProjectPaneView.paneActions`（2586-2600行）は`.overlay(alignment: .topTrailing)`で
contentの上に置かれる。editorのcodeやterminalの出力の右上を常時覆う。

`allowsHitTesting`も切っていないので、その位置のcodeはclickできない。

**決定:** 廃止する。paneの操作はCommand Registry経由で行う。

代わりに、paneの入れ替え用として**terminal上部に横向きの3点リーダ**を置き、これをdragして
paneを移動・入れ替えする。Ghosttyと同じ形式である。contentの上に浮かせず、paneの上端に
薄く置く。editorのpaneにも同じhandleを付ける（editorのpaneだけ移動できないのは不自然なため）。

### S3. 一貫性

#### S3-1. 2つのdesign systemが同居している

`ContentView.swift`の集計:

| 記述 | 件数 |
|---|---|
| `.buttonStyle(.borderedProminent)` | 14 |
| `.buttonStyle(.bordered)` | 11 |
| `ContentUnavailableView` | 11 |
| `.foregroundStyle(.secondary)`等 | 51 |
| `.listStyle(.inset)` | 4 |

`WorkspaceChrome`はtokenを持ち、commentで「surfaceが独自themeへdriftするのを防ぐ」と
宣言しているが、実際にはnative controlが並走している。

native controlはsystem accent（利用者のmacOS設定色）で描かれるため、
`WorkspaceChrome.accent` rgb(91,136,247)と競合する。
利用者がsystem accentをpurpleにしていれば、同じ画面に2色のprimaryが出る。

`GroupBox`、`Picker(.menu)`、`List(.inset)`はいずれもmacOSのsystem metricsで描かれ、
`WorkspaceChrome`のcompactな密度と合わない。

**提案:** `WorkspaceChrome`にbutton、field、list row、section header、empty stateの
component setを追加し、`ContentView`をそれで書き換える。
`.tint(WorkspaceChrome.accent)`をroot viewに置くのは最低限の応急処置になる。

#### S3-2. Quick OpenとCommand Paletteが別のUIである

同じ⌘系overlayでありながら、

| | Command Palette | Quick Open |
|---|---|---|
| 実装 | 独自chrome、`LazyVStack` | `.textFieldStyle(.roundedBorder)`、`List` |
| header | 68px、icon + title + subtitle + Esc chip | 12px padding、field + 閉じるbutton |
| footer | ↑↓/↵のhint | 無し |
| 空状態 | 独自text | `ContentUnavailableView` |

`.roundedBorder`のtext fieldはmacOSのsystem描画で、dark chromeの中で明らかに浮く。

**提案:** 1つのoverlay shell componentを作り、両者をそのcontentとして実装する。
将来のsymbol検索、Project切替、行移動も同じshellに載る。

#### S3-3. `ProjectEditorTabHost`が`.background(.background)`

4501行。`WorkspaceChrome.canvas`ではなくsystem背景色を使っている。
他の全paneと色が違う。

#### S3-4. mobileの独自palette

D8の実装側。`MobileAppPalette`（708-718行）は`WorkspaceChrome`と別値。
両者を1つのshared token moduleへ寄せるべきである。
`packages/`にSwift packageの置き場所が既にあるので、`ClairDesignKit`として切り出せる。

### S4. 操作

#### K1. pane間のfocus移動shortcutが無い

`ClairKeyboardShortcutAction`（`ClairLifecycle.swift:9-32`）の23個に、
pane focusの移動、pane最大化、split均等化、pane closeが無い。

scopeには「paneのfocus、移動、close、最大化、幅均等、高さ均等、全体均等」が
cutover条件として書かれている。現状これらは`ProjectPaneView`のellipsis menuからしか呼べない。

splitを一級機能にしながらkeyboardでpane間を移動できないのは、
名前の挙がったeditorとの差が最も分かりやすく出る箇所である。
Zedは`cmd-k`+方向キー、VS Codeは`cmd-k`+方向キーまたは`cmd-1/2/3`を持つ。

**提案:** `focusPaneLeft/Right/Up/Down`、`maximizePane`、`equalizeSplits`、`closePane`を
Command Registryへ登録する（registryがあるのでshortcut割当は自動的に付いてくる）。

#### K2. command paletteの↑↓が動かない

`WorkspaceCommandPalette`（1161行〜）のstateは`query`と`searchFocused`だけである。
選択indexが無い。footerには`↑↓で移動` `↵で実行`と表示されるが（1240-1245行）、
`onSubmit`は`runFirstAvailableMatch()`を呼ぶ。つまり常に先頭が実行される。

`clair-mock-lab`の契約に「重要なcontrolを説明の無い装飾のまま残さない」とあるが、
これはその状態である。

**提案:** `@State private var selectedIndex`を追加し、`.onMoveCommand`または
`onKeyPress(.upArrow/.downArrow)`で移動、`onSubmit`で選択中を実行する。
選択行に`surfaceActive`のhighlightを出す。

#### K3. Quick Openの検索体験が弱い

- ↑↓navigationが無い（`List`のselectionを使っていない）
- 一致部分のhighlightが無い
- 最近開いたfileの優先が無い
- `path:42`のような行指定を受け付けない（別overlayの`行へ移動`がある）

VS CodeとCursorの⌘Pは、この3つを全て持っている。Clairの⌘Pは現状「前方一致のlist」である。

#### K4. Review / Activityを開くshortcutが無い

`showExplorer`、`showSearch`、`showSourceControl`はあるが、
`showReview`と`showActivity`が無い。activity barの5項目のうち2つがkeyboardから開けない。

#### K5. attentionへjumpする手段が無い

Project group labelにattention countのbadgeが出る（1400-1406行）が、
click先はProject切替である。「注意が必要なterminalへ移動」ができない。

agentを複数走らせる製品として、これは中心的な動線である。
`⌥Tab`相当の「次のattentionへ」があるべきである。

### S5. 名前の挙がったeditorに対して足りないもの

ここまでは既存実装の問題である。以下は「無いこと」自体が差になるものを挙げる。

#### N1. agent sessionの一覧surfaceが無い（最重要の追加提案）

principle 3はTUIのscreen scrapingを禁じているが、根拠のある情報の利用は許している。
実際`AgentActivity`は bell、exit code、公式hookを既に持っている。

しかしworkspace上でこれが見えるのは、Project labelの数字badgeとactivity barの数字badgeだけである。
「今どのagentが、どのworktreeで、どれだけ走っていて、どれが入力待ちか」を
一目で見る場所が無い。

これはClairが4つのeditorに対して勝てる唯一の領域である。
VS Code、Cursor、Zedはこの問題を持っていない（agentを並列に走らせる前提が無い）。
Orcaが近いが、Clairはraw terminalを正本にする分だけ、より正確な情報を出せる。

**提案:** status barの上、またはactivity barの1項目として「sessions」を追加し、
全terminal/agentを次の列で並べる。

| 列 | source | principle 3への適合 |
|---|---|---|
| state (running/idle/exited/bell) | `TerminalSession.State` | PTYのprocess状態、推測なし |
| agent種別 | launch profile | 起動時に選ばせた値 |
| cwd / worktree | `session.agent.cwd` | 起動時の値 |
| 経過時間 | session開始時刻 | 計測値 |
| 最後のsignal | `AgentActivity.source` | bell / exit / 公式hook |

いずれも既存のmodelから取得でき、新しい推測を一切導入しない。

#### N2. 実行contextがpaneから判別できない

principle 5により、agentはProject rootでもmanaged worktreeでも動く。
しかしterminal paneのheader（`ProjectTerminalPanel`、2455行〜）は
`terminal` icon、状態text、`列×行`しか出さない。

どのbranchのどのworktreeで動いているかがpaneから読めない。
`rm -rf`をProject rootで走らせるのとworktreeで走らせるのでは結果が違う。
これは美観ではなく安全性の問題である。

**提案:** terminal pane headerにworktree/branch chipを出す。
managed worktreeのときはProject accentと別の色で明示する。

#### N3. cross-project viewが無い

principle 1は「一つのClair processが複数ProjectをChromeのtab groupのように保持する」と
定めているが、全Projectを俯瞰する画面が無い。titlebarのstripが唯一の一覧である。

Projectが5つ、それぞれにagentが2つあると、titlebarに収まらない。

#### N4. diagnostics/problemsの置き場所が無い

LSPは後段のroadmapだが、shellにその席が用意されていない。
activity barは5項目でhardcodeされ、status barにもdiagnostics slotが無い。

先に席だけ作っておかないと、LSPを入れる段でshellの再設計が必要になる。

#### N5. minimapもscroll mapも無い

`CodeMirrorEditor`にminimapがない。
Zedはminimapを持たない設計判断をした上でscrollbarにdiagnostics markerを載せている。
どちらの方針でもよいが、現状は「決めていない」に見える。

#### N6. agentのrate limitが見えない

利用者からの指摘で追加。複数のClaude Codeを並列に走らせる運用では、どの枠がどれだけ
残っているかが作業計画に直結する。現状Clairはこれを一切表示しない。

**決定:** status barの右端に、最も逼迫している枠を1つだけ compact meterで表示する。
clickでpopoverを開き、agent・枠種別ごとの内訳とリセット時刻を出す。

principle 3との整合が要点になる。値の入力は次に限る。

| 入力 | 可否 |
|---|---|
| agentが公式hook / CLIの構造化出力で報告した枠と残量 | 採用 |
| TUI画面からの読み取り | 不可（principle 3） |
| token数からのClair独自の推定 | 不可。ずれた値は無い値より悪い |

報告しないagentは「不明」と表示せず、行ごと出さない。
枠の枯渇はagentの停止と同じ扱いで1回だけ通知し、回復は通知しない。

---

## Recommendation

優先順位付きで、実装量の小さい順に並べる。Part 0の決定を反映済みである。

### 今すぐ直すべきもの（1-2日規模、明確な不具合）

1. **K2** command paletteの↑↓を実装する。表示と挙動が食い違っている。
2. **S1-3** split dividerにdrag gestureを付ける。`ratio`は既にmodelにある。
   見た目は1pxのまま、hoverでcursorとborder色を変える。
3. **S3-3** `.background(.background)`を`WorkspaceChrome.canvas`にする。
4. **K1/K4** pane操作とactivity切替をCommand Registryへ登録する。
   activity barをsidebarに残す決定により、K4は必須になった。

### 次に着手すべきもの（構造の修正）

5. **S1-5決定** tabのstripを全Project並列の1本に統一し、`P1`/`P2` prefixを削除する。
   別Projectのtabへの切り替えでProjectも切り替える。
6. **S2-2 + S2-4決定** paneのheaderとellipsis menuを廃止する。
   breadcrumbはstatus barへ、pane操作はcommandへ。
7. **S2-4決定** paneの上端に横向き3点リーダのdrag handleを置き、pane入れ替えを可能にする。
8. **S1-1** activity切替でpane layoutを置換しない。Gitのdiffとactivity detailはpane tabへ。
9. **S1-4** branch reviewをmain areaの全幅surfaceへ移す。
10. **titlebar** 検索欄をcommandの左へ置き、commandからラベルと枠を外す。

### docsとして残すべきもの

11. **D1** `docs/product/interaction.md`を追加する。draftを添付した。
12. **D4** dark固定をADRにする。
13. **D2** latency budgetをbenchmark contractへ追加する。
14. **D3** focus modelを書く。特にterminal focus時のshortcut境界。

### 差別化のための追加

15. **N1** session railを作る。Clairが4つのeditorに勝てる唯一の領域である。
16. **N6** rate limit表示を作る。入力はagentの公式報告に限る。
17. **N2** 実行contextをstatus barに出す。paneがchromeを持たない決定により、
    worktree/branchの表示先はstatus barとsession railになった。
18. **S3-4/D8** `ClairDesignKit`としてtokenをpackageへ切り出し、mobileと共有する。

## Limitations

- 実機での操作、build、screenshotによる検証を行っていない。指摘はsource読解に基づく。
- latencyとscroll性能は測定していない。D2の予算値は他製品の一般的な水準からの提案であり、
  Clairでの実測に基づかない。
- contrast比は`textQuaternary`/`canvas`の1組のみ概算した。全組み合わせは未検証。
- `NativeEditor.swift`と`CodeMirrorEditor.swift`のeditor内部描画はreviewの対象外とした。

## 関連

- [Proposed design contract (draft)](proposed-design-contract.md)
- [Product principles](../../product/principles.md)
- [Product scope](../../product/scope.md)
- [PoC queue UI contract](../../plans/clair-poc-queue.md)
