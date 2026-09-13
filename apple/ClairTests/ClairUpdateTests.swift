import AppKit
import CryptoKit
import Foundation
import XCTest

@testable import ClairApp

@MainActor
final class ClairUpdateTests: XCTestCase {
  func testSignedStableManifestCreatesAnUpdateForTheCurrentArchitecture() throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let manifest = try makeManifest(privateKey: privateKey)
    let verifier = try ClairUpdateSignatureVerifier(
      base64EncodedPublicKey: privateKey.publicKey.rawRepresentation.base64EncodedString()
    )

    let update = try manifest.makeUpdate(
      currentVersion: "0.1.0",
      architecture: "arm64",
      verifier: verifier
    )

    XCTAssertEqual(update.version, "0.2.0")
    XCTAssertEqual(update.artifact.platform, "macos")
    XCTAssertEqual(update.artifact.architecture, "arm64")
  }

  func testManifestSignatureCoversTheArtifactHashAndURL() throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let manifest = try makeManifest(privateKey: privateKey)
    let tamperedArtifact = ClairUpdateArtifact(
      platform: manifest.artifacts[0].platform,
      architecture: manifest.artifacts[0].architecture,
      url: manifest.artifacts[0].url,
      sha256: String(repeating: "0", count: 64),
      signature: manifest.artifacts[0].signature
    )
    let tamperedManifest = ClairUpdateManifest(
      schemaVersion: manifest.schemaVersion,
      channel: manifest.channel,
      version: manifest.version,
      artifacts: [tamperedArtifact],
      notes: manifest.notes
    )
    let verifier = try ClairUpdateSignatureVerifier(
      base64EncodedPublicKey: privateKey.publicKey.rawRepresentation.base64EncodedString()
    )

    XCTAssertThrowsError(
      try tamperedManifest.makeUpdate(
        currentVersion: "0.1.0",
        architecture: "arm64",
        verifier: verifier
      )
    ) { error in
      XCTAssertEqual(error as? ClairUpdateError, .invalidSignature)
    }
  }

  func testManifestRejectsDevChannelAndOlderVersion() throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let verifier = try ClairUpdateSignatureVerifier(
      base64EncodedPublicKey: privateKey.publicKey.rawRepresentation.base64EncodedString()
    )
    let manifest = try makeManifest(privateKey: privateKey)
    let devManifest = ClairUpdateManifest(
      schemaVersion: manifest.schemaVersion,
      channel: .dev,
      version: manifest.version,
      artifacts: manifest.artifacts,
      notes: manifest.notes
    )

    XCTAssertThrowsError(
      try devManifest.makeUpdate(
        currentVersion: "0.1.0",
        architecture: "arm64",
        verifier: verifier
      )
    ) { error in
      XCTAssertEqual(error as? ClairUpdateError, .unsupportedChannel("dev"))
    }

    XCTAssertThrowsError(
      try manifest.makeUpdate(
        currentVersion: "0.2.0",
        architecture: "arm64",
        verifier: verifier
      )
    ) { error in
      XCTAssertEqual(
        error as? ClairUpdateError,
        .updateNotNewer(current: "0.2.0", available: "0.2.0")
      )
    }
  }

  func testDevCoordinatorDoesNotCheckStableFeed() {
    let configuration = ClairUpdateConfiguration(
      channel: .dev,
      manifestURL: nil,
      publicKeyBase64: nil,
      currentVersion: "0.1.0",
      bundleIdentifier: ClairRuntimeProfile.dev.bundleIdentifier,
      currentAppURL: URL(fileURLWithPath: "/tmp/Clair Dev.app"),
      installURL: ClairUpdateConfiguration.defaultInstallURL,
      applicationSupportURL: URL(fileURLWithPath: "/tmp/Clair Dev", isDirectory: true),
      architecture: "arm64"
    )
    let coordinator = ClairUpdateCoordinator(
      profile: .dev,
      configuration: configuration,
      manifestLoader: { _ in Data() },
      artifactDownloader: { _ in URL(fileURLWithPath: "/tmp/update.zip") }
    )

    XCTAssertFalse(coordinator.canCheck)
    XCTAssertEqual(coordinator.state, .disabled("Dev builds do not use the Stable update feed."))
  }

  func testCLIInstallerTreatsMissingDirectoryAsMissingAndCreatesItBeforeInstall() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appendingPathComponent("ClairCLIInstallerTests-\(UUID().uuidString)", isDirectory: true)
    let sourceURL = root.appendingPathComponent("clair", isDirectory: false)
    let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: sourceURL)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sourceURL.path)

    let installer = ClairCLIInstaller(
      fileManager: fileManager,
      homeDirectory: homeDirectory,
      environment: [:],
      bundledCLIURL: sourceURL
    )

    XCTAssertEqual(installer.status().destination, .missing)
    XCTAssertFalse(fileManager.fileExists(atPath: installer.installDirectoryURL.path))

    try installer.install()

    XCTAssertTrue(fileManager.fileExists(atPath: installer.installDirectoryURL.path))
    XCTAssertTrue(fileManager.isExecutableFile(atPath: installer.installURL.path))
    XCTAssertEqual(installer.status().destination, .installed)
  }

  func testPendingUpdateWritesStartupSuccessOnlyForMatchingStableLaunch() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClairUpdateTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try ClairUpdateRecovery.recordPending(
      version: "0.2.0",
      bundleIdentifier: ClairRuntimeProfile.stable.bundleIdentifier,
      applicationSupportURL: root
    )
    XCTAssertFalse(
      ClairUpdateRecovery.markSuccessfulLaunchIfNeeded(
        profile: .dev,
        bundleIdentifier: ClairRuntimeProfile.dev.bundleIdentifier,
        version: "0.2.0",
        applicationSupportURL: root
      )
    )
    XCTAssertTrue(
      ClairUpdateRecovery.markSuccessfulLaunchIfNeeded(
        profile: .stable,
        bundleIdentifier: ClairRuntimeProfile.stable.bundleIdentifier,
        version: "0.2.0",
        applicationSupportURL: root
      )
    )
    XCTAssertEqual(
      try String(contentsOf: ClairUpdateRecovery.successURL(for: root), encoding: .utf8),
      "0.2.0"
    )
  }

  func testTerminationReasonSkipsNormalSessionTerminationForUpdateRestart() {
    let delegate = ClairApplicationDelegate()
    var normalTerminationCount = 0
    delegate.onNormalTermination = {
      normalTerminationCount += 1
    }

    XCTAssertEqual(delegate.terminationReason, .userQuit)
    XCTAssertEqual(
      delegate.applicationShouldTerminate(NSApplication.shared),
      .terminateNow
    )
    XCTAssertEqual(normalTerminationCount, 1)

    delegate.prepareForUpdateRestart()
    XCTAssertEqual(delegate.terminationReason, .updateRestart)
    XCTAssertEqual(
      delegate.applicationShouldTerminate(NSApplication.shared),
      .terminateNow
    )
    XCTAssertEqual(normalTerminationCount, 1)
  }

  private func makeManifest(
    privateKey: Curve25519.Signing.PrivateKey
  ) throws -> ClairUpdateManifest {
    let unsignedArtifact = ClairUpdateArtifact(
      platform: "macos",
      architecture: "arm64",
      url: URL(
        string: "https://github.com/Diwamoto/clair/releases/download/v0.2.0/"
          + "Clair-0.2.0-macos-arm64.zip"
      )!,
      sha256: String(repeating: "a", count: 64),
      signature: ""
    )
    let unsignedManifest = ClairUpdateManifest(
      schemaVersion: ClairUpdateManifest.currentSchemaVersion,
      channel: .stable,
      version: "0.2.0",
      artifacts: [unsignedArtifact],
      notes: "Test release"
    )
    let signature = try privateKey.signature(
      for: ClairUpdateSignatureVerifier.signedPayload(
        manifest: unsignedManifest,
        artifact: unsignedArtifact
      )
    )
    let signedArtifact = ClairUpdateArtifact(
      platform: unsignedArtifact.platform,
      architecture: unsignedArtifact.architecture,
      url: unsignedArtifact.url,
      sha256: unsignedArtifact.sha256,
      signature: signature.base64EncodedString()
    )
    return ClairUpdateManifest(
      schemaVersion: unsignedManifest.schemaVersion,
      channel: unsignedManifest.channel,
      version: unsignedManifest.version,
      artifacts: [signedArtifact],
      notes: unsignedManifest.notes
    )
  }
}
