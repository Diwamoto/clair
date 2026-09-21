// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "ClairApps",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .executable(name: "ClairMacApp", targets: ["ClairMacApp"]),
    .executable(name: "ClairMobileApp", targets: ["ClairMobileApp"]),
    .executable(name: "ClairDaemon", targets: ["ClairDaemon"]),
    .executable(name: "clair", targets: ["clair"]),
  ],
  dependencies: [
    .package(path: "../ClairCore")
  ],
  targets: [
    .executableTarget(
      name: "ClairMacApp",
      dependencies: [
        .product(name: "ClairAppKit", package: "ClairCore")
      ]
    ),
    .executableTarget(
      name: "clair",
      dependencies: [
        .product(name: "ClairDaemonKit", package: "ClairCore"),
        .product(name: "ClairTerminal", package: "ClairCore"),
        .product(name: "ClairWorkspace", package: "ClairCore")
      ]
    ),
    .executableTarget(
      name: "ClairMobileApp",
      dependencies: [
        .product(name: "ClairMobileKit", package: "ClairCore")
      ]
    ),
    .executableTarget(
      name: "ClairDaemon",
      dependencies: [
        .product(name: "ClairAgent", package: "ClairCore"),
        .product(name: "ClairDaemonKit", package: "ClairCore"),
        .product(name: "ClairPush", package: "ClairCore"),
        .product(name: "ClairShared", package: "ClairCore"),
        .product(name: "ClairTransport", package: "ClairCore"),
        .product(name: "ClairWorkspace", package: "ClairCore"),
      ]
    ),
    .testTarget(
      name: "ClairAppsTests",
      dependencies: [
        .product(name: "ClairAppKit", package: "ClairCore"),
        .product(name: "ClairDaemonKit", package: "ClairCore"),
        .product(name: "ClairMobileKit", package: "ClairCore"),
      ]
    ),
  ]
)
