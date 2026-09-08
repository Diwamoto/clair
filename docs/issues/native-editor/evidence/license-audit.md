# NE-01 依存・許諾監査

監査日: 2026-09-08。対象は `prototypes/native-editor-poc` の NE-00 完了時点の
`Package.resolved`、`evidence/dependencies.json`、`evidence/grammar-source-pins.json`、
およびNE-00の再現ビルドで取得した固定checkoutである。外部への問い合わせ、購入、配布は行っていない。

## 判定

調査は完了したが、通常版を配布可能とは判定できない（`NO`）。調査完了と配布許諾完了は別である。

- `CodeEditLanguages@331d5dbc5fc8513be5848fce8a2a312908f36a11` のrootにLICENSE/NOTICEがなく、
  `CodeLanguagesContainer.xcframework.zip` は37 grammarを一つのbinary frameworkへ包含する。grammar別の
  再配布許諾とbinary対応を、rootのMIT表示やSwiftTreeSitterのライセンスから推定してはいけない。
- `CodeEditSymbols@ae69712b08571c4469c2ed5cd38ad9f19439793e` のrootにLICENSE/NOTICEがなく、
  `Symbols.xcassets` はREADME上「mostly custom SF Symbols」である。各assetの自作範囲、元symbol、
  Apple利用条件、notice対応が確定していない。
- 37 grammarのsource pinは固定されているが、grammar別license/noticeは監査入力に収録されず、
  queryとparser binaryを同一source revisionへ対応付けた配布証跡になっていない。

NE-11/NE-15はこのゲートを無視して通常経路や本番資産を変更してはならない。

## SwiftPM 依存の突合

`Package.resolved` と `evidence/dependencies.json` は identity、location、revision、versionの
11 pinが一致した。root `Package.swift` の直接依存は `CodeEditSourceEditor` だけで、残りは解決グラフの
間接runtime依存またはbuild-time pluginである。test-onlyの `swift-custom-dump` と `SnapshotTesting`
はPoCのrelease解決結果・配布binaryには含まれない。

| lifecycle | package / revision | license evidence | 配布実体 |
|---|---|---|---|
| direct runtime | [CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor/tree/1fa4d3c3ffba007482111466cb9721416f97ae00) `1fa4d3c3ffba007482111466cb9721416f97ae00` | `LICENSE.md`, SHA-256 `a1c7f7ef3f326384c8edb428c9698654a4df4a4339149b4eccdac532f832678e`; MIT | Swift module |
| indirect runtime | [CodeEditTextView](https://github.com/CodeEditApp/CodeEditTextView/tree/d7ac3f11f22ec2e820187acce8f3a3fb7aa8ddec) `d7ac3f11f22ec2e820187acce8f3a3fb7aa8ddec` | `LICENSE.md`, SHA-256 `960d8436f97cac8fdf01cb011cee5bda3d292777c41840137b754f1d43f023dc`; MIT | Swift module |
| indirect runtime + binary/resources | [CodeEditLanguages](https://github.com/CodeEditApp/CodeEditLanguages/tree/331d5dbc5fc8513be5848fce8a2a312908f36a11) `331d5dbc5fc8513be5848fce8a2a312908f36a11` | root LICENSE/NOTICE absent; unresolved | `CodeLanguagesContainer.xcframework.zip` + `Resources` |
| indirect runtime + assets | [CodeEditSymbols](https://github.com/CodeEditApp/CodeEditSymbols/tree/ae69712b08571c4469c2ed5cd38ad9f19439793e) `ae69712b08571c4469c2ed5cd38ad9f19439793e` | root LICENSE/NOTICE absent; SF Symbols-derived provenance unresolved | `Symbols.xcassets` |
| indirect runtime | [Rearrange](https://github.com/ChimeHQ/Rearrange/tree/4de8be41dba304192e87dc0a11e0aa39e72aa2e8) `4de8be41dba304192e87dc0a11e0aa39e72aa2e8` | `LICENSE`, SHA-256 `72512faf072d3a4c0d9ae21552e0a3367e87b719ac511d06d2b5a0e427e8796d`; BSD-3-Clause | Swift module |
| indirect runtime | [swift-collections](https://github.com/apple/swift-collections/tree/a0cb0954ecb21e4e31b0070e6ed5674e8556685a) `a0cb0954ecb21e4e31b0070e6ed5674e8556685a` | `LICENSE.txt`, SHA-256 `770af8291f708538d8ff885a0bbc4e045cd700531741c4f99528d435c14d7f55`; Apache-2.0 | Swift module |
| indirect build-time | [SwiftLintPlugin](https://github.com/lukepistrol/SwiftLintPlugin/tree/b384a67cf45d9989aed5aab23e226cbc7bc2cd54) `b384a67cf45d9989aed5aab23e226cbc7bc2cd54` | `LICENSE`, SHA-256 `27075ecb18226ea6430fd191a4439a1696542c833f10b40fea7fb7cb3b49696b`; MIT | no shipped runtime binary |
| indirect runtime | [SwiftTreeSitter](https://github.com/ChimeHQ/SwiftTreeSitter/tree/08ef81eb8620617b55b08868126707ad72bf754f) `08ef81eb8620617b55b08868126707ad72bf754f` | `LICENSE`, SHA-256 `792197b8debcdecb17f429bab3a43a5911364e2a6e8e7c0f7faf02032212fb5f`; BSD-3-Clause | Swift module |
| indirect runtime | [TextFormation](https://github.com/ChimeHQ/TextFormation/tree/b1ce9a14bd86042bba4de62236028dc4ce9db6a1) `b1ce9a14bd86042bba4de62236028dc4ce9db6a1` | `LICENSE`, SHA-256 `d11b5eea8e9ae2f6dd06545633e8daf0dfcbc7dbb911a20d1504c905e5808775`; BSD-3-Clause | Swift module |
| indirect runtime | [TextStory](https://github.com/ChimeHQ/TextStory/tree/a52db1a2eca74d37c8c19bf3165416941632ed45) `a52db1a2eca74d37c8c19bf3165416941632ed45` | `LICENSE`, SHA-256 `afbec25c49bc05b3db57755ce2839d578c01319e5c7c29d7ad3781cd97660c9b`; BSD-3-Clause | Swift module |
| indirect runtime | [tree-sitter](https://github.com/tree-sitter/tree-sitter/tree/da6fe9beb4f7f67beb75914ca8e0d48ae48d6406) `da6fe9beb4f7f67beb75914ca8e0d48ae48d6406` | `LICENSE`, SHA-256 `5f9cf9fb6acb1972b35ae29119ce563bb60ec097656bc4b69b9bac2d04c7a147`; MIT; Unicode subset is separate | C/Swift runtime |

最終配布時は実Mach-O/Bundleを検査し、lifecycleと実体の対応が一致することを再確認する。

## Binaryと必要6言語

`CodeEditLanguages/Package.swift` の `binaryTarget(path:)` が参照する
`CodeLanguagesContainer.xcframework.zip` はSHA-256 `c6ee69d9d373a9c3cf93d239e05369d9b941275d31cd7956d0dc83b5a5c3e152`
（34,388,755 bytes）。macOS arm64/x86_64 frameworkのuncompressed binaryは392,757,416 bytesで、
container projectは37 grammar parser productsをframeworkへリンクする。root LICENSE/NOTICEとgrammar別
noticeがないため配布不可である。query `Resources` は81 files / 35 resource directoriesである。

| language | fixed grammar source | query files / SHA-256 | license / binary対応 |
|---|---|---|---|
| Swift | `alex-pinkus/tree-sitter-swift@eda05af7ac41adb4eb19c346883c0fa32fe3bdd8` | `highlights.scm` `33b43db0a1de5cca2e92ad35b2d4a1db9831bdaaf9470604cdf60e5dee1686c4`; `locals.scm` `91e92aa1662847605ee25a8fdec27f6619b739ffaae23c2a0d28673ea1177d`; `tags.scm` `9d24b288f032c18e79d5a37a86f2870bcd7789100cf93addb0171ecf910b3a50` | exact checkoutにMIT LICENSE（`3533cec129bb4ba...`）; final notice/binary mapping未完 |
| Rust | `tree-sitter/tree-sitter-rust@79456e6080f50fc1ca7c21845794308fa5d35a51` | `highlights.scm` `1121094caebe76ff176fe567bae9de3b2bd37c88bf8ed81a62d156ff5ad747e8`; `injections.scm` `723146f179bc0edfba2f51731c99afce8bed3b677dfb4435c303859fae299ba5`; `tags.scm` `399a103b7ca297e8de3efd63c1da55e3d617d4c9b77140265e88d51835cdf382` | grammar license/notice未確認、binary mapping未完 |
| TypeScript | `tree-sitter/tree-sitter-typescript@d847898fec3fe596798c9fda55cb8c05a799001a` | `highlights.scm` `e0c35adb819127bfd4f853fac5419e7d8ba44760246201d04a4a5ce0228a10c5`; `locals.scm` `c3680f9b56276fb2ccc9f1d5f04d03dbca5d64bdf3e6d52ce5a4ad342cec1625`; `tags.scm` `b391288bcc71b513a5df7c9bb232d8bc7418d7e274b125aa0aa4bdd6121a0338` | grammar license/notice未確認、binary mapping未完 |
| TSX | TypeScriptと同じpin | TypeScriptと同じquery set。`CodeLanguage.tsx`は同resourceを使用 | grammar license/notice未確認、別binaryなし |
| JSON | `tree-sitter/tree-sitter-json@3fef30de8aee74600f25ec2e319b62a1a870d51e` | `highlights.scm` `0511524465b56aed122580792254e68b6abbbfde7119f1d02b135acbe278233f` | grammar license/notice未確認、binary mapping未完 |
| Markdown | `tree-sitter-grammars/tree-sitter-markdown@5cdc549ab8f461aff876c5be9741027189299cec` | `highlights.scm` `0f8db8b016b0c739db7307215dcd1d33d9cbf5222b64e60d45dc4f4c08dc684b`; `injections.scm` `69f16cdc0a850c0a14e0f3844f878e68aaf8a055505d6f602f642508c1bbef81` | grammar license/notice未確認、binary mapping未完 |

queryの存在はlicense許諾やbinary対応の証明として扱わない。全37 grammarのsource pin（manifest
`originHash` `c940c7467f54711e27ceb0cef308954e1fdbcc20f3dd59d96d6efbe29d7a04ba`）は証跡JSONに列挙され、
必要6言語以外を含む一括binaryである。各pinのlicense file/noticeは未確認であり、通常版へ持ち込まない。

## Unicodeとicon

tree-sitterの `lib/src/unicode` はICU subsetで、source commit
`552b01f61127d30d6589aa4bf99468224979b661` と同梱 `LICENSE` SHA-256
`6a18c5fac70d7860b57f5b72b4e2c9a1ba6b3d2741eef7ff9767c5379364f10d` を別noticeとして要求する。
tree-sitterのMIT noticeだけでICU noticeを置き換えない。

`CodeEditSymbols` の `Symbols.xcassets` は33 files（SVG/Contents.json）でroot LICENSE/NOTICEなし。
Appleの[SF Symbols guidance](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)は、
Apple製品・機能を表すsymbolの制約を明記している。asset単位の元symbol・改変履歴・利用条件を確認するか、
必要最小限の独自SVGへ置換し、出典・作成者・日付をmanifest化するまで再配布しない。

## 解消案

CodeEditLanguagesの再配布根拠を固定revision単位で取得できない場合は、必要6言語だけをsource buildへ
切り替え、parser/query/license/noticeを同一revision manifestでhash固定し、未使用31 grammarを除去する。
Symbolsは出典確認済みの独自SVGへ置換する。この法務・外部許諾に関わるremediationは本Issueでは実装せず、
後続Issueを作成して通常版採用前の必須依存にする。
