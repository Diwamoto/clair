// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "ClairMobileKit",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(
      name: "ClairMobileKit",
      targets: ["ClairMobileKit"]
    )
  ],
  targets: [
    .target(name: "ClairMobileKit"),
    .testTarget(
      name: "ClairMobileKitTests",
      dependencies: ["ClairMobileKit"]
    ),
  ]
)
