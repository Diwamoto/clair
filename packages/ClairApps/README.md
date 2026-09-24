# Clair application targets

This package contains the three composition roots:

- `ClairMacApp`: a macOS SwiftUI executable target.
- `ClairMobileApp`: an iOS/iPadOS SwiftUI executable target.
- `ClairDaemon`: the GUI-independent daemon executable target.

They depend only on products from `../ClairCore`. `ClairDaemon` owns a
GUI-independent lifecycle, an owner-only runtime lock, and an owner-only Unix
control socket. The local control endpoint uses B03's bounded frames and
provides typed health, version, and shutdown requests. The optional
`--directory` argument selects a runtime directory for development and tests.

They depend only on products from `../ClairCore`. The mobile composition
root injects `ClairMobileEnvironment` through a SwiftUI environment value and
drives the transport-neutral `ClairMobileStore`. Its plain navigation and
connection surfaces are a P0 state/command smoke shell; they do not replace the
Design canvas or Workbench UI contract.

`make build` builds all targets for the host and cross-builds the mobile
executable for the iOS Simulator SDK. `ClairMobile.xcodeproj` wraps the same
mobile source and `ClairCore` package for an iOS application bundle, unit
smoke target, UI smoke target, device signing, and TestFlight archiving. The
runbook in `docs/runbooks/native-mobile.md` records the account-side steps.

The app and test targets never import the v1 `ClairMobileKit` or the reference
`apple/ClairMobileApp` runtime. N02 owns the typed client, protected identity,
pairing, certificate/host pin, and reconnect seam in `ClairMobileKit`; APNs, the concrete
Network.framework/TLS channel, and production UI remain owned by later queue
tasks.
