# Clair apps

One folder per shipped program. Each holds its composition root and the
app-only library it links; shared code lives in `../packages`. Every target is
declared in the root `Package.swift`.

- `mac/` — `ClairMacApp` (executable) and `ClairAppKit` (macOS UI).
- `mobile/` — `ClairMobileApp`, `ClairMobileKit` (client state, identity,
  pairing), `ClairTerminalView` (iOS terminal view), and the Xcode wrapper
  `ClairMobile.xcodeproj` with `Support/Info.plist` and the XCTest/XCUITest
  smoke targets. The runbook is `docs/runbooks/native-mobile.md`.
- `daemon/` — `ClairDaemon` (GUI-independent daemon: runtime lock, owner-only
  Unix control socket, bounded B03 frames), `ClairDaemonKit`, and
  `ClairPushRelay`.
- `cli/` — the `clair` command.

`make build` builds every target for the host and cross-builds the mobile
executable for the iOS Simulator SDK.
