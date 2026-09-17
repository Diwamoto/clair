// swift-tools-version: 6.0

import Foundation
import PackageDescription

// T01: libghostty/GhosttyKit foundation.
//
// `scripts/v2-ghostty.sh vendor` materializes the pinned commit's headers
// and a built `GhosttyKit.xcframework` into this git-ignored directory. Its
// presence — checked here, at manifest-evaluation time, not hardcoded —
// decides whether `ClairV2GhosttyABI`/`ClairV2Ghostty` compile in "linked"
// mode (real headers checked by `_Static_assert`, real library linked) or
// "not linked" mode (subset types only, every runtime call throws
// `GhosttyError.runtimeUnavailable`). Either way the package graph builds;
// see `docs/plans/clair-v2-t01-libghostty-foundation.md`.
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

let package = Package(
  name: "ClairV2Core",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "ClairV2Push", targets: ["ClairV2Push"]),
    .library(name: "ClairPushRelay", targets: ["ClairPushRelay"]),
    .library(name: "ClairV2Shared", targets: ["ClairV2Shared"]),
    .library(name: "ClairV2DesignSystem", targets: ["ClairV2DesignSystem"]),
    .library(name: "ClairV2Workspace", targets: ["ClairV2Workspace"]),
    .library(name: "ClairV2Agent", targets: ["ClairV2Agent"]),
    .library(name: "ClairV2Review", targets: ["ClairV2Review"]),
    .library(name: "ClairV2Terminal", targets: ["ClairV2Terminal"]),
    .library(name: "ClairV2Transport", targets: ["ClairV2Transport"]),
    .library(name: "ClairV2DaemonKit", targets: ["ClairV2DaemonKit"]),
    .library(name: "ClairV2MobileKit", targets: ["ClairV2MobileKit"]),
    .library(name: "ClairV2AppKit", targets: ["ClairV2AppKit"]),
    .library(name: "ClairV2EditorFixtures", targets: ["ClairV2EditorFixtures"]),
    .library(name: "ClairV2EditorCore", targets: ["ClairV2EditorCore"]),
    .library(name: "ClairV2EditorLanguage", targets: ["ClairV2EditorLanguage"]),
    .library(name: "ClairV2EditorView", targets: ["ClairV2EditorView"]),
    .library(name: "ClairV2Ghostty", targets: ["ClairV2Ghostty"]),
    .executable(name: "EditorFixtureGenerator", targets: ["EditorFixtureGenerator"]),
  ],
  dependencies: [
    // E05: tree-sitter incremental parse and LSP coordinate/lifecycle. The
    // JSON grammar used by tests is vendored directly in
    // `ClairV2EditorLanguageFixtures` instead of depending on
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
  ],
  targets: [
    .target(name: "ClairV2PTY"),
    .target(name: "ClairV2Shared"),
    .target(name: "ClairV2DesignSystem"),
    .target(name: "ClairV2EditorCore"),
    .target(name: "ClairV2Push"),
    .target(name: "ClairPushRelay", dependencies: ["ClairV2Push"]),
    .target(
      name: "ClairV2Workspace",
      dependencies: ["ClairV2Shared"]
    ),
    .target(
      name: "ClairV2Agent",
      dependencies: [
        .target(name: "ClairV2PTY", condition: .when(platforms: [.macOS])),
        "ClairV2Terminal",
        "ClairV2Shared",
        "ClairV2Workspace",
      ]
    ),
    .target(
      name: "ClairV2Review",
      dependencies: ["ClairV2Shared"]
    ),
    .target(
      name: "ClairV2Terminal",
      dependencies: ["ClairV2Shared"]
    ),
    .target(
      name: "ClairV2Transport",
      dependencies: ["ClairV2Shared"]
    ),
    .target(
      name: "ClairV2DaemonKit",
      dependencies: [
        "ClairV2Push",
        "ClairV2Agent",
        "ClairV2Shared",
        "ClairV2Terminal",
        "ClairV2Transport",
        "ClairV2Workspace",
      ]
    ),
    .target(
      name: "ClairV2MobileKit",
      dependencies: [
        "ClairV2Agent",
        "ClairV2Push",
        "ClairV2Review",
        "ClairV2Shared",
        "ClairV2Transport",
        "ClairV2Workspace",
      ]
    ),
    .target(
      name: "ClairV2AppKit",
      dependencies: [
        "ClairV2Agent",
        "ClairV2DaemonKit",
        .target(name: "ClairV2PTY", condition: .when(platforms: [.macOS])),
        "ClairV2Ghostty",
        "ClairV2Review",
        "ClairV2Shared",
        "ClairV2Terminal",
        "ClairV2Transport",
        "ClairV2Workspace",
      ]
    ),
    .target(
      name: "ClairV2EditorFixtures",
      dependencies: ["ClairV2Shared"]
    ),
    .target(
      name: "ClairV2EditorLanguage",
      dependencies: [
        "ClairV2EditorCore",
        .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
        .product(name: "TreeSitter", package: "tree-sitter"),
        .product(name: "LanguageServerProtocol", package: "LanguageServerProtocol"),
      ]
    ),
    // E06: macOS custom NSView / CoreText viewport renderer. AppKit-only;
    // every file guards its body with `#if os(macOS)` (same pattern as
    // `ClairV2AppKit`) so the target still builds empty on the iOS slice.
    .target(
      name: "ClairV2EditorView",
      dependencies: ["ClairV2EditorCore"]
    ),
    // Test-only vendored tree-sitter-json grammar; see `VENDOR.md`. Not a
    // public product: nothing outside `ClairV2CoreTests` should link it.
    .target(
      name: "ClairV2EditorLanguageFixtures",
      publicHeadersPath: "include",
      cSettings: [.headerSearchPath("src")]
    ),
    .target(
      name: "ClairV2GhosttyABI",
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
      name: "ClairV2Ghostty",
      dependencies: ["ClairV2GhosttyABI"],
      // `.define("CLAIR_GHOSTTY_VENDORED")` alone only sets a *Swift*
      // compilation flag, guarding `#if CLAIR_GHOSTTY_VENDORED` blocks
      // written in this target's own Swift source. It does not reach the
      // Clang importer that parses `ClairV2GhosttyABI`'s public header
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
    .testTarget(
      name: "ClairV2CoreTests",
      dependencies: [
        .target(name: "ClairV2PTY", condition: .when(platforms: [.macOS])),
        "ClairV2Push",
        "ClairPushRelay",
        "ClairV2Agent",
        "ClairV2AppKit",
        "ClairV2DaemonKit",
        "ClairV2EditorFixtures",
        "ClairV2EditorCore",
        "ClairV2EditorLanguage",
        "ClairV2EditorLanguageFixtures",
        "ClairV2EditorView",
        "ClairV2Ghostty",
        "ClairV2MobileKit",
        "ClairV2Review",
        "ClairV2Shared",
        "ClairV2Terminal",
        "ClairV2Transport",
        "ClairV2Workspace",
      ]
    ),
    .testTarget(
      name: "ClairV2DesignSystemTests",
      dependencies: ["ClairV2DesignSystem"]
    ),
    .executableTarget(
      name: "EditorFixtureGenerator",
      dependencies: ["ClairV2EditorFixtures"]
    ),
  ] + ghosttyABITargets
)
