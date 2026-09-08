// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ClairNativeEditorPoC", platforms: [.macOS(.v14)], products: [.executable(name: "NativeEditorPoC", targets: ["NativeEditorPoC"])], dependencies: [.package(url: "https://github.com/CodeEditApp/CodeEditSourceEditor.git", revision: "1fa4d3c3ffba007482111466cb9721416f97ae00")], targets: [.executableTarget(name: "NativeEditorPoC", dependencies: [.product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor")])])
