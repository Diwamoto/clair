import CryptoKit
import Foundation

struct UpdateArtifact: Encodable {
  let architecture: String
  let platform: String
  let sha256: String
  let signature: String
  let url: String
}

struct UpdateManifest: Encodable {
  let artifacts: [UpdateArtifact]
  let channel: String
  let notes: String?
  let schemaVersion: Int
  let version: String
}

struct ArtifactInput {
  let architecture: String
  let url: URL
  let archiveURL: URL
}

struct Arguments {
  let version: String
  let privateKeyBase64: String
  let publicKeyBase64: String?
  let outputURL: URL
  let notes: String?
  let artifacts: [ArtifactInput]

  init(commandLineArguments: [String]) throws {
    var version: String?
    var privateKeyBase64: String?
    var publicKeyBase64: String?
    var outputURL: URL?
    var notes: String?
    var artifacts: [ArtifactInput] = []
    var index = 0

    while index < commandLineArguments.count {
      switch commandLineArguments[index] {
      case "--version":
        version = try Self.nextValue(
          from: commandLineArguments,
          index: &index,
          option: "--version"
        )
      case "--private-key":
        privateKeyBase64 = try Self.nextValue(
          from: commandLineArguments,
          index: &index,
          option: "--private-key"
        )
      case "--private-key-env":
        let environmentName = try Self.nextValue(
          from: commandLineArguments,
          index: &index,
          option: "--private-key-env"
        )
        guard let value = ProcessInfo.processInfo.environment[environmentName], !value.isEmpty
        else {
          throw ManifestError.invalidKey(
            "private key environment variable is empty: \(environmentName)"
          )
        }
        privateKeyBase64 = value
      case "--public-key":
        publicKeyBase64 = try Self.nextValue(
          from: commandLineArguments,
          index: &index,
          option: "--public-key"
        )
      case "--output":
        let path = try Self.nextValue(
          from: commandLineArguments,
          index: &index,
          option: "--output"
        )
        outputURL = URL(fileURLWithPath: path)
      case "--notes":
        notes = try Self.nextValue(
          from: commandLineArguments,
          index: &index,
          option: "--notes"
        )
      case "--artifact":
        let architecture = try Self.nextValue(
          from: commandLineArguments,
          index: &index,
          option: "--artifact architecture"
        )
        let urlString = try Self.nextValue(
          from: commandLineArguments,
          index: &index,
          option: "--artifact URL"
        )
        let archivePath = try Self.nextValue(
          from: commandLineArguments,
          index: &index,
          option: "--artifact archive"
        )
        guard let url = URL(string: urlString) else {
          throw ManifestError.invalidArgument("artifact URL is invalid: \(urlString)")
        }
        artifacts.append(
          ArtifactInput(
            architecture: architecture,
            url: url,
            archiveURL: URL(fileURLWithPath: archivePath)
          )
        )
      default:
        throw ManifestError.invalidArgument("unknown option: \(commandLineArguments[index])")
      }
      index += 1
    }

    guard let version, Self.isVersion(version) else {
      throw ManifestError.invalidArgument("--version must be a dotted numeric version")
    }
    guard let privateKeyBase64, !privateKeyBase64.isEmpty else {
      throw ManifestError.invalidArgument("--private-key is required")
    }
    guard let outputURL else {
      throw ManifestError.invalidArgument("--output is required")
    }
    guard !artifacts.isEmpty else {
      throw ManifestError.invalidArgument("at least one --artifact is required")
    }

    self.version = version
    self.privateKeyBase64 = privateKeyBase64
    self.publicKeyBase64 = publicKeyBase64
    self.outputURL = outputURL
    self.notes = notes
    self.artifacts = artifacts
  }

  private static func nextValue(
    from arguments: [String],
    index: inout Int,
    option: String
  ) throws -> String {
    index += 1
    guard index < arguments.count else {
      throw ManifestError.invalidArgument("missing value for \(option)")
    }
    return arguments[index]
  }

  private static func isVersion(_ value: String) -> Bool {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard !parts.isEmpty, parts.count <= 4 else {
      return false
    }
    return parts.allSatisfy { part in
      !part.isEmpty && part.allSatisfy { $0.isNumber }
    }
  }
}

enum ManifestError: Error, CustomStringConvertible {
  case invalidArgument(String)
  case invalidKey(String)
  case invalidArtifact(String)

  var description: String {
    switch self {
    case .invalidArgument(let message):
      message
    case .invalidKey(let message):
      message
    case .invalidArtifact(let message):
      message
    }
  }
}

func sha256(of fileURL: URL) throws -> String {
  let handle = try FileHandle(forReadingFrom: fileURL)
  defer { try? handle.close() }

  var hasher = SHA256()
  while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
    hasher.update(data: chunk)
  }
  return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func signedPayload(
  version: String,
  artifact: ArtifactInput,
  sha256: String
) -> Data {
  let value =
    [
      "clair-update-v1",
      "stable",
      version,
      "macos",
      artifact.architecture,
      artifact.url.absoluteString,
      sha256,
    ].joined(separator: "\n") + "\n"
  return Data(value.utf8)
}

func run() throws {
  let arguments = try Arguments(commandLineArguments: Array(CommandLine.arguments.dropFirst()))
  guard let privateKeyData = Data(base64Encoded: arguments.privateKeyBase64) else {
    throw ManifestError.invalidKey("private key is not base64")
  }
  let privateKey: Curve25519.Signing.PrivateKey
  do {
    privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
  } catch {
    throw ManifestError.invalidKey("private key must be a 32-byte Ed25519 seed")
  }

  let derivedPublicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
  if let publicKeyBase64 = arguments.publicKeyBase64, publicKeyBase64 != derivedPublicKey {
    throw ManifestError.invalidKey("public key does not match private key")
  }

  let updateArtifacts = try arguments.artifacts.map { artifact in
    guard artifact.url.scheme?.lowercased() == "https",
      artifact.url.host?.lowercased() == "github.com"
    else {
      throw ManifestError.invalidArtifact("artifact URL must be an HTTPS GitHub URL")
    }
    guard FileManager.default.fileExists(atPath: artifact.archiveURL.path) else {
      throw ManifestError.invalidArtifact("archive is missing: \(artifact.archiveURL.path)")
    }
    let digest = try sha256(of: artifact.archiveURL)
    let signature = try privateKey.signature(
      for: signedPayload(version: arguments.version, artifact: artifact, sha256: digest)
    )
    return UpdateArtifact(
      architecture: artifact.architecture,
      platform: "macos",
      sha256: digest,
      signature: signature.base64EncodedString(),
      url: artifact.url.absoluteString
    )
  }

  let manifest = UpdateManifest(
    artifacts: updateArtifacts,
    channel: "stable",
    notes: arguments.notes,
    schemaVersion: 1,
    version: arguments.version
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  let data = try encoder.encode(manifest)
  try data.write(to: arguments.outputURL, options: [.atomic])
  print("Generated \(arguments.outputURL.path) for Stable v\(arguments.version).")
}

do {
  try run()
} catch {
  FileHandle.standardError.write(Data("generate-update-manifest: \(error)\n".utf8))
  exit(1)
}
