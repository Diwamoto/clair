---
id: ADR-0008
title: "Stable / Dev runtime identityとdeployment baselineを固定する"
status: accepted
date: 2026-08-30
deciders:
  - Daiki
related_projects:
  - p0003-native-workspace-bootstrap
related_issues:
  - 2
  - 3
supersedes: []
superseded_by: []
---

# ADR-0008: Stable / Dev runtime identityとdeployment baselineを固定する

## Context

Clair Stableを使って同じrepositoryからClair Devをbuild・起動するdogfooding loopでは、両processが
同時に存在する。bundle identity、Dock表示、preferences、application dataのいずれかを共有すると、
Devの変更がStableの設定やstateを破壊し、起動中appのroutingも曖昧になる。

Issue #2はidentity方針の正本化をIssue #3のdependencyとしているが、2026-08-30に利用者は#3の
開発環境を先行して完成させるよう明示した。このため、実装前に#3が必要とする具体値を本ADRで固定する。

## Decision drivers

- StableとDevを同時起動し、OSと人間の両方が確実に区別できる。
- Devの失敗やschema変更がStableのsettings/dataへ影響しない。
- Xcode、Swift runtime、shell smoke testから同じidentity値を検証できる。
- 将来のDeveloper ID signingやdistributionへ移行できるreverse-DNS形を使う。
- personal macOS-only製品として古いOS互換よりnative APIと保守性を優先する。

## Options considered

### Option A: Stable base identity + Dev suffix

- Stable: `com.diwamoto.clair`, `Clair`, `~/Library/Application Support/Clair`
- Dev: `com.diwamoto.clair.dev`, `Clair Dev`, `~/Library/Application Support/Clair Dev`
- Advantages: production identityが短く、Devが明示的な派生である。Xcode targetとfilesystemで判別しやすい。
- Disadvantages: reverse-DNS prefixを後でorganization domainへ変える場合はpreferences migrationが必要になる。
- Evidence: repository ownerは`Diwamoto`であり、product nameはaccepted docsで`Clair`に固定されている。

### Option B: 同じbundle IDでenvironment flagだけを変える

- Advantages: targetとsigning設定が一つで済む。
- Disadvantages: macOS application identity、preferences domain、open routingが衝突し、同時起動境界を満たさない。
- Evidence: Issue #3は別bundleでの同時起動をacceptance criteriaにしている。

### Option C: Bundle IDだけ分け、display/data nameを共有する

- Advantages:設定項目が少ない。
- Disadvantages: Dockでの識別が弱く、Application Supportの明示pathを共有してDevがStable dataを変更し得る。
- Evidence: Issue #2と#3はbundleだけでなくsettings/dataとDock表示の分離を求める。

## Decision

次のidentityとbaselineを採用する。

| Property | Stable | Dev |
|---|---|---|
| Product/display name | `Clair` | `Clair Dev` |
| Bundle ID | `com.diwamoto.clair` | `com.diwamoto.clair.dev` |
| UserDefaults domain | standard bundle domain | standard bundle domain |
| Application Support directory | `Clair` | `Clair Dev` |
| Compile condition | `CLAIR_STABLE` | `CLAIR_DEV` |

- Runtime codeはshared preferences suiteまたはfallback data pathを使わない。
- minimum deployment targetはmacOS 14.0とする。
- Swift language modeは6とし、full local buildのbaselineをXcode 16以降とする。
- Issue #3のlocal/CI buildはunsignedとし、signing identity、Team ID、notarizationは後続decisionに委ねる。
- 正式iconは後続branding/distribution workで決める。Bootstrapでは異なるdisplay nameでDock表示を分離する。

## Rationale

OS-level identity、利用者向け表示、保存pathを同じchannel boundaryで揃えることで、どれか一つの設定漏れに
よるcross-channel contaminationを防げる。Dev suffixは目的が明確で、Stableを将来のdistribution identity
としてそのまま扱える。macOS 14.0はpersonal-use-firstの初期実装で保守対象を抑えつつ、現在のSwiftUI/AppKit
APIを使うための十分に保守的なdeployment baselineである。

## Consequences

### Positive

- StableとDevを同時に起動し、process、Dock、preferences、dataを独立して扱える。
- CIが`Info.plist`とcompiled profileの両方からidentity driftを検出できる。
- Dev dataを破棄してもStable dataへ影響しない。

### Negative

- Xcode target、scheme、DerivedData、launch commandを2系統維持する。
- Bundle prefixを将来変更する場合、preferencesとdataの明示migrationが必要になる。
- 正式iconが入るまで視覚差はdisplay nameに限定される。

## Validation

- Stable/Dev `.app`の`CFBundleIdentifier`、`CFBundleName`、`CFBundleDisplayName`をsmoke testで比較する。
- Swift unit testで全runtime profile fieldが異なることを検証する。
- 両bundleを`open -n`で同時起動し、初期windowに異なるidentity/data pathが表示されることを確認する。
- Standard `UserDefaults`へchannel markerを書いたtest fixtureが他方のdomainから見えないことを確認する。

## Revisit conditions

- Developer ID certificateまたはdistribution channelが別のbundle prefixを要求する。
- macOS 14 supportがSwift/Xcode dependencyの導入を阻害し、実測された利用deviceがより新しいOSだけになる。
- Stable/Dev以外のnightly、preview、test channelが必要になる。
- Persisted schema導入後にbundle IDまたはApplication Support directoryを変更する必要が生じる。

## References

- Project: [p0003-native-workspace-bootstrap](../projects/p0003-native-workspace-bootstrap/README.md)
- Issue: https://github.com/Diwamoto/clair/issues/2
- Issue: https://github.com/Diwamoto/clair/issues/3
- Product scope: [Clair product scope](../product/scope.md)
- Existing frontend decision: [ADR-0001](0001-adopt-swiftui-appkit-frontend.md)
