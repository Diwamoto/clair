# Clair v2 application targets

This package contains the three v2 composition roots:

- `ClairV2MacApp`: a macOS SwiftUI executable target.
- `ClairV2MobileApp`: an iOS/iPadOS SwiftUI executable target.
- `ClairDaemon`: the GUI-independent daemon executable target.

They depend only on products from `../ClairV2Core`. The placeholder views and
daemon output are intentional until later queue items provide real behavior.

`make v2-build` builds all targets for the host and cross-builds the mobile
executable for the iOS Simulator SDK. iPadOS uses the same iOS SDK target
family; signing and device/TestFlight work are intentionally deferred.
