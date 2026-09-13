# Clair v2 application targets

This package contains the three v2 composition roots:

- `ClairV2MacApp`: a macOS SwiftUI executable target.
- `ClairV2MobileApp`: an iOS/iPadOS SwiftUI executable target.
- `ClairDaemon`: the GUI-independent daemon executable target.

They depend only on products from `../ClairV2Core`. `ClairDaemon` owns a
GUI-independent lifecycle, an owner-only runtime lock, and an owner-only Unix
control socket. The local control endpoint uses B03's bounded frames and
provides typed health, version, and shutdown requests. The optional
`--directory` argument selects a runtime directory for development and tests.

They depend only on products from `../ClairV2Core`. The mobile composition
root injects `ClairV2MobileEnvironment` through a SwiftUI environment value and
drives the transport-neutral `ClairV2MobileStore`. Its plain navigation and
connection surfaces are a P0 state/command smoke shell; they do not replace the
Design canvas or Workbench UI contract.

`make v2-build` builds all targets for the host and cross-builds the mobile
executable for the iOS Simulator SDK. `ClairV2Mobile.xcodeproj` wraps the same
mobile source and `ClairV2Core` package for an iOS application bundle, unit
smoke target, UI smoke target, device signing, and TestFlight archiving. The
runbook in `docs/runbooks/native-mobile-v2.md` records the account-side steps.

The app and test targets never import the v1 `ClairMobileKit` or the reference
`apple/ClairMobileApp` runtime. Pairing, Keychain identity, transport, APNs,
and production UI remain owned by later queue tasks.
