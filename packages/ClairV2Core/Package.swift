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
let ghosttyXCFrameworkPath = ghosttyVendorRoot
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
    .library(name: "ClairV2Ghostty", targets: ["ClairV2Ghostty"]),
    .executable(name: "EditorFixtureGenerator", targets: ["EditorFixtureGenerator"]),
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
      name: "ClairV2GhosttyABI",
      dependencies: ghosttyABIDependencies,
      cSettings: [
        .headerSearchPath("Vendor/ghostty/include"),
        ghosttyVendored ? .define("CLAIR_GHOSTTY_VENDORED") : nil,
      ].compactMap { $0 },
      linkerSettings: ghosttyVendored
        ? [.linkedFramework("GhosttyKit")]
        : []
    ),
    .target(
      name: "ClairV2Ghostty",
      dependencies: ["ClairV2GhosttyABI"],
      swiftSettings: ghosttyVendored
        ? [.define("CLAIR_GHOSTTY_VENDORED")]
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
