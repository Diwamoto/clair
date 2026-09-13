// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "ClairV2Core",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "ClairV2Shared", targets: ["ClairV2Shared"]),
    .library(name: "ClairV2Workspace", targets: ["ClairV2Workspace"]),
    .library(name: "ClairV2Agent", targets: ["ClairV2Agent"]),
    .library(name: "ClairV2Review", targets: ["ClairV2Review"]),
    .library(name: "ClairV2Terminal", targets: ["ClairV2Terminal"]),
    .library(name: "ClairV2Transport", targets: ["ClairV2Transport"]),
    .library(name: "ClairV2DaemonKit", targets: ["ClairV2DaemonKit"]),
    .library(name: "ClairV2MobileKit", targets: ["ClairV2MobileKit"]),
    .library(name: "ClairV2AppKit", targets: ["ClairV2AppKit"]),
  ],
  targets: [
    .target(name: "ClairV2Shared"),
    .target(
      name: "ClairV2Workspace",
      dependencies: ["ClairV2Shared"]
    ),
    .target(
      name: "ClairV2Agent",
      dependencies: ["ClairV2Shared"]
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
        "ClairV2Review",
        "ClairV2Shared",
        "ClairV2Workspace",
      ]
    ),
    .target(
      name: "ClairV2AppKit",
      dependencies: [
        "ClairV2Agent",
        "ClairV2DaemonKit",
        "ClairV2Review",
        "ClairV2Shared",
        "ClairV2Terminal",
        "ClairV2Workspace",
      ]
    ),
    .testTarget(
      name: "ClairV2CoreTests",
      dependencies: [
        "ClairV2Agent",
        "ClairV2AppKit",
        "ClairV2DaemonKit",
        "ClairV2MobileKit",
        "ClairV2Review",
        "ClairV2Shared",
        "ClairV2Terminal",
        "ClairV2Transport",
        "ClairV2Workspace",
      ]
    ),
  ]
)
