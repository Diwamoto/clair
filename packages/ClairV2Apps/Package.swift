// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "ClairV2Apps",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .executable(name: "ClairV2MacApp", targets: ["ClairV2MacApp"]),
    .executable(name: "ClairV2MobileApp", targets: ["ClairV2MobileApp"]),
    .executable(name: "ClairDaemon", targets: ["ClairDaemon"]),
  ],
  dependencies: [
    .package(path: "../ClairV2Core")
  ],
  targets: [
    .executableTarget(
      name: "ClairV2MacApp",
      dependencies: [
        .product(name: "ClairV2AppKit", package: "ClairV2Core")
      ]
    ),
    .executableTarget(
      name: "ClairV2MobileApp",
      dependencies: [
        .product(name: "ClairV2MobileKit", package: "ClairV2Core")
      ]
    ),
    .executableTarget(
      name: "ClairDaemon",
      dependencies: [
        .product(name: "ClairV2Agent", package: "ClairV2Core"),
        .product(name: "ClairV2DaemonKit", package: "ClairV2Core"),
        .product(name: "ClairV2Push", package: "ClairV2Core"),
        .product(name: "ClairV2Transport", package: "ClairV2Core"),
        .product(name: "ClairV2Workspace", package: "ClairV2Core"),
      ]
    ),
    .testTarget(
      name: "ClairV2AppsTests",
      dependencies: [
        .product(name: "ClairV2AppKit", package: "ClairV2Core"),
        .product(name: "ClairV2DaemonKit", package: "ClairV2Core"),
        .product(name: "ClairV2MobileKit", package: "ClairV2Core"),
      ]
    ),
  ]
)
