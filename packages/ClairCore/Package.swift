// swift-tools-version: 6.0

import Foundation
import PackageDescription

// T01: libghostty/GhosttyKit foundation.
//
// `scripts/ghostty.sh vendor` materializes the pinned commit's headers
// and a built `GhosttyKit.xcframework` into this git-ignored directory. Its
// presence — checked here, at manifest-evaluation time, not hardcoded —
// decides whether `ClairGhosttyABI`/`ClairGhostty` compile in "linked"
// mode (real headers checked by `_Static_assert`, real library linked) or
// "not linked" mode (subset types only, every runtime call throws
// `GhosttyError.runtimeUnavailable`). Either way the package graph builds;
// see `docs/plans/clair-t01-libghostty-foundation.md`.
let ghosttyVendorRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .appendingPathComponent("Vendor/ghostty", isDirectory: true)
let ghosttyHeaderPresent = FileManager.default.fileExists(
  atPath: ghosttyVendorRoot.appendingPathComponent("include/ghostty.h").path
)
let ghosttyXCFrameworkPath =
  ghosttyVendorRoot
  .appendingPathComponent("GhosttyKit.xcframework")
let ghosttyArtifactPresent = FileManager.default.fileExists(
  atPath: ghosttyXCFrameworkPath.appendingPathComponent("Info.plist").path
)
// Both must be present: a header without a linkable binary (or vice versa)
// is a broken half-vendored state, and this build must not silently treat
// it as either "fully linked" or "fully absent".
let ghosttyVendored = ghosttyHeaderPresent && ghosttyArtifactPresent

var ghosttyABITargets: [Target] = []
var ghosttyABIDependencies: [Target.Dependency] = []
if ghosttyVendored {
  ghosttyABITargets.append(
    .binaryTarget(name: "GhosttyKit", path: "Vendor/ghostty/GhosttyKit.xcframework")
  )
  ghosttyABIDependencies.append(.target(name: "GhosttyKit"))
}

// T05: libghostty-vt (iOS terminal VT parsing, no GPU embedder -- see
// `ClairGhosttyVTABI`'s header comment and `Config/ghostty-pin.json`'s
// `libghostty_vt` block for why this is a separate vendored artifact from
// `GhosttyKit.xcframework` above). `scripts/ghostty.sh vendor-vt`
// materializes both pieces independently of the macOS embedder vendor
// step, so a worktree can have either, both, or neither vendored.
let ghosttyVTHeaderPresent = FileManager.default.fileExists(
  atPath: ghosttyVendorRoot.appendingPathComponent("include-vt/ghostty/vt.h").path
)
let ghosttyVTXCFrameworkPath =
  ghosttyVendorRoot
  .appendingPathComponent("GhosttyVT.xcframework")
let ghosttyVTArtifactPresent = FileManager.default.fileExists(
  atPath: ghosttyVTXCFrameworkPath.appendingPathComponent("Info.plist").path
)
let ghosttyVTVendored = ghosttyVTHeaderPresent && ghosttyVTArtifactPresent

// `GhosttyVT.xcframework` only has ios-arm64/ios-arm64-simulator slices
// (see `libghostty_vt.slices` in `Config/ghostty-pin.json`) -- unlike
// `GhosttyKit.xcframework`, which has a macos-arm64 slice and so needs no
// platform-conditioned dependency edge. Linking it into a macOS build
// would fail ("no applicable architecture") the moment anything actually
// tries to link, so every place this artifact reaches a target must be
// `.when(platforms: [.iOS])`-gated, the same mechanism this file already
// uses for `ClairPTY` (macOS-only) below.
var ghosttyVTABITargets: [Target] = []
var ghosttyVTABIDependencies: [Target.Dependency] = []
if ghosttyVTVendored {
  ghosttyVTABITargets.append(
    .binaryTarget(name: "GhosttyVTKit", path: "Vendor/ghostty/GhosttyVT.xcframework")
  )
  ghosttyVTABIDependencies.append(.target(name: "GhosttyVTKit", condition: .when(platforms: [.iOS])))
}

let package = Package(
  name: "ClairCore",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "ClairPush", targets: ["ClairPush"]),
    .library(name: "ClairPushRelay", targets: ["ClairPushRelay"]),
    .library(name: "ClairShared", targets: ["ClairShared"]),
    .library(name: "ClairDesignSystem", targets: ["ClairDesignSystem"]),
    .library(name: "ClairWorkspace", targets: ["ClairWorkspace"]),
    .library(name: "ClairAgent", targets: ["ClairAgent"]),
    .library(name: "ClairReview", targets: ["ClairReview"]),
    .library(name: "ClairTerminal", targets: ["ClairTerminal"]),
    .library(name: "ClairTransport", targets: ["ClairTransport"]),
    .library(name: "ClairDaemonKit", targets: ["ClairDaemonKit"]),
    .library(name: "ClairMobileKit", targets: ["ClairMobileKit"]),
    .library(name: "ClairAppKit", targets: ["ClairAppKit"]),
    .library(name: "ClairEditorFixtures", targets: ["ClairEditorFixtures"]),
    .library(name: "ClairEditorCore", targets: ["ClairEditorCore"]),
    .library(name: "ClairEditorLanguage", targets: ["ClairEditorLanguage"]),
    .library(name: "ClairEditorView", targets: ["ClairEditorView"]),
    .library(name: "ClairGhostty", targets: ["ClairGhostty"]),
    .library(name: "ClairGhosttyVT", targets: ["ClairGhosttyVT"]),
    .library(name: "ClairTerminalView", targets: ["ClairTerminalView"]),
    .executable(name: "EditorFixtureGenerator", targets: ["EditorFixtureGenerator"]),
  ],
  dependencies: [
    // E05: tree-sitter incremental parse and LSP coordinate/lifecycle. The
    // JSON grammar used by tests is vendored directly in
    // `ClairEditorLanguageFixtures` instead of depending on
    // tree-sitter-json's own SwiftPM package, whose `SwiftTreeSitter` pin
    // (`0.8.0`, semver-locked below `0.9.0`) conflicts with this one.
    .package(
      url: "https://github.com/ChimeHQ/SwiftTreeSitter.git",
      revision: "08ef81eb8620617b55b08868126707ad72bf754f"),
    .package(
      url: "https://github.com/tree-sitter/tree-sitter",
      revision: "da6fe9beb4f7f67beb75914ca8e0d48ae48d6406"),
    .package(
      url: "https://github.com/ChimeHQ/LanguageServerProtocol.git",
      revision: "82770aa7d6e54e52f3b4339c49a64ee794ad1cfe"),
    // E12: the stdio transport under `LanguageServerProtocol`'s connection. Already resolved
    // transitively; named here because `ClairEditorLanguage` imports it directly.
    .package(url: "https://github.com/ChimeHQ/JSONRPC", from: "0.9.0"),
  ],
  targets: [
    .target(name: "ClairPTY"),
    .target(name: "ClairShared"),
    .target(name: "ClairDesignSystem"),
    .target(name: "ClairEditorCore"),
    .target(name: "ClairPush"),
    .target(name: "ClairPushRelay", dependencies: ["ClairPush"]),
    .target(
      name: "ClairWorkspace",
      dependencies: ["ClairShared", "ClairEditorCore"]
    ),
    .target(
      name: "ClairAgent",
      dependencies: [
        .target(name: "ClairPTY", condition: .when(platforms: [.macOS])),
        "ClairTerminal",
        "ClairShared",
        "ClairWorkspace",
      ]
    ),
    .target(
      name: "ClairReview",
      dependencies: ["ClairShared", "ClairEditorCore"]
    ),
    .target(
      name: "ClairTerminal",
      dependencies: ["ClairShared"]
    ),
    .target(
      name: "ClairTransport",
      dependencies: ["ClairShared"]
    ),
    .target(
      name: "ClairDaemonKit",
      dependencies: [
        .target(name: "ClairPTY", condition: .when(platforms: [.macOS])),
        "ClairPush",
        "ClairAgent",
        "ClairShared",
        "ClairTerminal",
        "ClairTransport",
        "ClairWorkspace",
      ]
    ),
    .target(
      name: "ClairMobileKit",
      dependencies: [
        "ClairAgent",
        "ClairGhosttyVT",
        "ClairPush",
        "ClairReview",
        "ClairShared",
        "ClairTerminal",
        "ClairTransport",
        "ClairWorkspace",
      ]
    ),
    .target(
      name: "ClairAppKit",
      dependencies: [
        "ClairAgent",
        "ClairDaemonKit",
        "ClairDesignSystem",
        "ClairEditorCore",
        "ClairEditorLanguage",
        "ClairEditorView",
        .target(name: "ClairPTY", condition: .when(platforms: [.macOS])),
        "ClairGhostty",
        "ClairReview",
        "ClairShared",
        "ClairTerminal",
        "ClairTransport",
        "ClairWorkspace",
      ]
    ),
    .target(
      name: "ClairEditorFixtures",
      dependencies: ["ClairShared"]
    ),
    .target(
      name: "ClairEditorLanguage",
      dependencies: [
        "ClairEditorCore",
        "ClairEditorView",
        "ClairEditorLanguageGo",
        "ClairEditorLanguageJSON",
        "ClairEditorLanguageJavaScript",
        "ClairEditorLanguageMarkdown",
        "ClairEditorLanguagePython",
        "ClairEditorLanguageRust",
        "ClairEditorLanguageShell",
        "ClairEditorLanguageSwift",
        "ClairEditorLanguageTypeScript",
        .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
        .product(name: "TreeSitter", package: "tree-sitter"),
        .product(name: "LanguageServerProtocol", package: "LanguageServerProtocol"),
        .product(name: "JSONRPC", package: "JSONRPC"),
      ]
    ),
    // E11: production vendored tree-sitter grammars (raw generated C
    // source, same vendoring pattern as `ClairEditorLanguageFixtures` — see
    // each target's own `VENDOR.md`). Separate targets, not one combined
    // target, because every grammar's `src/` has its own `parser.c`, and a
    // shared target would collide on that filename.
    .target(
      name: "ClairEditorLanguageJSON",
      publicHeadersPath: "include",
      cSettings: [.headerSearchPath("src")]
    ),
    .target(
      name: "ClairEditorLanguagePython",
      publicHeadersPath: "include",
      cSettings: [.headerSearchPath("src")]
    ),
    .target(
      name: "ClairEditorLanguageGo",
      publicHeadersPath: "include",
      cSettings: [.headerSearchPath("src")]
    ),
    .target(
      name: "ClairEditorLanguageRust",
      publicHeadersPath: "include",
      cSettings: [.headerSearchPath("src")]
    ),
    .target(
      name: "ClairEditorLanguageShell",
      publicHeadersPath: "include",
      cSettings: [.headerSearchPath("src")]
    ),
    .target(
      name: "ClairEditorLanguageJavaScript",
      publicHeadersPath: "include",
      cSettings: [.headerSearchPath("src")]
    ),
    .target(
      name: "ClairEditorLanguageTypeScript",
      publicHeadersPath: "include",
      cSettings: [.headerSearchPath("src")]
    ),
    .target(
      name: "ClairEditorLanguageMarkdown",
      publicHeadersPath: "include",
      cSettings: [.headerSearchPath("src")]
    ),
    .target(
      name: "ClairEditorLanguageSwift",
      publicHeadersPath: "include",
      cSettings: [.headerSearchPath("src")]
    ),
    // E06: macOS custom NSView / CoreText viewport renderer. AppKit-only;
    // every file guards its body with `#if os(macOS)` (same pattern as
    // `ClairAppKit`) so the target still builds empty on the iOS slice.
    .target(
      name: "ClairEditorView",
      dependencies: ["ClairEditorCore"]
    ),
    // Test-only vendored tree-sitter-json grammar; see `VENDOR.md`. Not a
    // public product: nothing outside `ClairCoreTests` should link it.
    .target(
      name: "ClairEditorLanguageFixtures",
      publicHeadersPath: "include",
      cSettings: [.headerSearchPath("src")]
    ),
    .target(
      name: "ClairGhosttyABI",
      dependencies: ghosttyABIDependencies,
      cSettings: [
        .headerSearchPath("Vendor/ghostty/include"),
        ghosttyVendored ? .define("CLAIR_GHOSTTY_VENDORED") : nil,
      ].compactMap { $0 },
      // GhosttyKit.xcframework wraps `libghostty-internal.a`, a static
      // library. Its Metal renderer, its font shaping, and its embedded
      // process/display handling (T08's `ghostty_surface_*` subset) pull in
      // system frameworks that libghostty itself does not (and, as a
      // static library, cannot) declare as link dependencies; every
      // consumer has to name them, exactly like the real Xcode-based
      // Ghostty app's project settings do. This list was derived by
      // linking T08's real macOS smoke test against the pinned commit's
      // built xcframework and resolving every "undefined symbol" error.
      //
      // `GhosttyKit` itself is not listed with `.linkedFramework`: the
      // vendored xcframework's macOS slice wraps a static library
      // (`libghostty-internal.a`), not a `.framework` bundle, so
      // `-framework GhosttyKit` fails at final link time with "framework
      // 'GhosttyKit' not found" (T01's original setting was never
      // exercised because nothing had ever been vendored). The
      // `.binaryTarget`/`.target(name: "GhosttyKit")` dependency above is
      // sufficient on its own for SwiftPM to link the static library into
      // anything that depends on it transitively.
      linkerSettings: ghosttyVendored
        ? [
          // libghostty statically links several C++ dependencies (glslang,
          // SPIRV-Cross, Dear ImGui, Breakpad) for its shader/inspector
          // tooling; their exception-handling/RTTI symbols need libc++.
          .linkedLibrary("c++"),
          .linkedFramework("AppKit", .when(platforms: [.macOS])),
          .linkedFramework("Metal", .when(platforms: [.macOS])),
          .linkedFramework("QuartzCore", .when(platforms: [.macOS])),
          .linkedFramework("CoreVideo", .when(platforms: [.macOS])),
          .linkedFramework("IOSurface", .when(platforms: [.macOS])),
          .linkedFramework("CoreText", .when(platforms: [.macOS])),
          .linkedFramework("CoreGraphics", .when(platforms: [.macOS])),
          .linkedFramework("Carbon", .when(platforms: [.macOS])),
          .linkedFramework("Security", .when(platforms: [.macOS])),
          .linkedFramework("SystemConfiguration", .when(platforms: [.macOS])),
          .linkedFramework("CoreServices", .when(platforms: [.macOS])),
          .linkedFramework("UniformTypeIdentifiers", .when(platforms: [.macOS])),
          .linkedFramework("IOKit", .when(platforms: [.macOS])),
          .linkedFramework("OSLog", .when(platforms: [.macOS])),
        ]
        : []
    ),
    .target(
      name: "ClairGhostty",
      dependencies: ["ClairGhosttyABI"],
      // `.define("CLAIR_GHOSTTY_VENDORED")` alone only sets a *Swift*
      // compilation flag, guarding `#if CLAIR_GHOSTTY_VENDORED` blocks
      // written in this target's own Swift source. It does not reach the
      // Clang importer that parses `ClairGhosttyABI`'s public header
      // when this target `import`s it — that importer needs its own
      // `-Xcc -D…`, or every declaration inside
      // `clair_ghostty_abi.h`'s `#if defined(CLAIR_GHOSTTY_VENDORED)`
      // block (the entire real ABI surface: init/info/config *and* T08's
      // `ghostty_surface_*` subset) is invisible to Swift here regardless
      // of whether the library is actually vendored — a real, silent gap
      // T08 found the moment it vendored for the first time and ran
      // `swift build` against the result (T01 never caught this because
      // nothing had ever been vendored in that environment).
      swiftSettings: ghosttyVendored
        ? [
          .define("CLAIR_GHOSTTY_VENDORED"),
          .unsafeFlags(["-Xcc", "-DCLAIR_GHOSTTY_VENDORED"]),
        ]
        : []
    ),
    // T05: libghostty-vt C ABI subset. Mirrors `ClairGhosttyABI`'s
    // vendored/not-vendored gating exactly, but against the separate
    // `GhosttyVT.xcframework` artifact (see the `ghosttyVTVendored` block
    // above and `ClairGhosttyVTABI`'s header comment).
    .target(
      name: "ClairGhosttyVTABI",
      dependencies: ghosttyVTABIDependencies,
      // The header search path and `CLAIR_GHOSTTY_VT_VENDORED` define are
      // both `.when(platforms: [.iOS])`-gated: the headers themselves are
      // plain C and harmless to expose on macOS, but the define also
      // switches on the function-pointer probes/`_Static_assert`s that
      // reference real `ghostty_*` symbols, and only the iOS slice of
      // `GhosttyVTKit` actually provides them (see the comment above
      // `ghosttyVTABIDependencies`). Gating only the define, not the
      // header search path, keeps a macOS build from silently seeing a
      // half-vendored header set.
      cSettings: [
        .headerSearchPath("Vendor/ghostty/include-vt"),
        ghosttyVTVendored
          ? .define("CLAIR_GHOSTTY_VT_VENDORED", .when(platforms: [.iOS])) : nil,
      ].compactMap { $0 },
      // libghostty-vt has no GPU/windowing surface (unlike GhosttyKit), so
      // it needs no Apple framework beyond libc++ for its statically
      // linked C++ dependencies (simdutf, highway) -- derived the same way
      // T08 derived `ClairGhosttyABI`'s much longer framework list: by
      // linking against the real vendored library and reading `nm -m`'s
      // undefined-symbol list, which contains only libSystem/libc symbols
      // and internal C++ mangled names, no CoreFoundation/AppKit/UIKit.
      linkerSettings: ghosttyVTVendored
        ? [.linkedLibrary("c++", .when(platforms: [.iOS]))] : []
    ),
    .target(
      name: "ClairGhosttyVT",
      dependencies: ["ClairGhosttyVTABI"],
      // Same reasoning as `ClairGhostty`'s swiftSettings comment: the
      // Swift `#if CLAIR_GHOSTTY_VT_VENDORED` guard alone does not reach
      // the Clang importer parsing `ClairGhosttyVTABI`'s header when this
      // target imports it. iOS-gated for the same reason as the ABI
      // target's cSettings above.
      swiftSettings: ghosttyVTVendored
        ? [
          .define("CLAIR_GHOSTTY_VT_VENDORED", .when(platforms: [.iOS])),
          .unsafeFlags(["-Xcc", "-DCLAIR_GHOSTTY_VT_VENDORED"], .when(platforms: [.iOS])),
        ]
        : []
    ),
    // T05: iOS/iPadOS terminal `UIView` (touch scroll/selection, hardware
    // keyboard, safe-area/rotation). `#if os(iOS)`-gated like
    // `ClairEditorView`'s `+iOS.swift` files; builds empty on macOS.
    .target(
      name: "ClairTerminalView",
      dependencies: [
        "ClairGhosttyVT", "ClairMobileKit", "ClairTerminal", "ClairTransport",
        "ClairEditorView",
      ]
    ),
    .testTarget(
      name: "ClairCoreTests",
      dependencies: [
        .target(name: "ClairPTY", condition: .when(platforms: [.macOS])),
        "ClairPush",
        "ClairPushRelay",
        "ClairAgent",
        "ClairAppKit",
        "ClairDaemonKit",
        "ClairEditorFixtures",
        "ClairEditorCore",
        "ClairEditorLanguage",
        "ClairEditorLanguageFixtures",
        "ClairEditorView",
        "ClairGhostty",
        "ClairGhosttyVT",
        "ClairMobileKit",
        "ClairReview",
        "ClairShared",
        "ClairTerminal",
        "ClairTerminalView",
        "ClairTransport",
        "ClairWorkspace",
      ]
    ),
    // Real subprocess/PTY/daemon-socket/ghostty integration tests, split out
    // of `ClairCoreTests` so the fast unit suite (`swift test`) doesn't pay
    // for spawning real `/bin/sh` children and real daemon sockets on every
    // run. Run explicitly via `swift test --filter ClairCoreIntegrationTests`.
    .testTarget(
      name: "ClairCoreIntegrationTests",
      dependencies: [
        .target(name: "ClairPTY", condition: .when(platforms: [.macOS])),
        "ClairPush",
        "ClairPushRelay",
        "ClairAgent",
        "ClairAppKit",
        "ClairDaemonKit",
        "ClairEditorFixtures",
        "ClairEditorCore",
        "ClairEditorLanguage",
        "ClairEditorLanguageFixtures",
        "ClairEditorView",
        "ClairGhostty",
        "ClairGhosttyVT",
        "ClairMobileKit",
        "ClairReview",
        "ClairShared",
        "ClairTerminal",
        "ClairTerminalView",
        "ClairTransport",
        "ClairWorkspace",
      ]
    ),
    .testTarget(
      name: "ClairDesignSystemTests",
      dependencies: ["ClairDesignSystem"]
    ),
    .executableTarget(
      name: "EditorFixtureGenerator",
      dependencies: ["ClairEditorFixtures"]
    ),
  ] + ghosttyABITargets + ghosttyVTABITargets
)
