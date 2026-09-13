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

`make v2-build` builds all targets for the host and cross-builds the mobile
executable for the iOS Simulator SDK. iPadOS uses the same iOS SDK target
family; signing and device/TestFlight work are intentionally deferred.
