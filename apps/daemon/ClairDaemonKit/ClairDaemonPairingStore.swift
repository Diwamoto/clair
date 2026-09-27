#if os(macOS)

  import Foundation

  import ClairTransport

  public enum ClairDaemonPairingStoreError: Error, Equatable, LocalizedError, Sendable {
    case unreadable
    case malformed
    case unsafePermissions
    case writeFailed

    public var errorDescription: String? {
      switch self {
      case .unreadable: "The daemon pairing state cannot be read."
      case .malformed: "The daemon pairing state is malformed."
      case .unsafePermissions: "The daemon pairing state must be owner-only."
      case .writeFailed: "The daemon pairing state cannot be saved."
      }
    }
  }

  /// Owner-only persistence for the long-lived host identity and paired device
  /// grant digests. It intentionally never contains a device token, challenge,
  /// pairing bootstrap secret, or active connection handle.
  public struct ClairDaemonPairingStore: Sendable {
    private struct State: Codable, Sendable {
      let hostKey: Data
      let grants: [ClairPersistedDeviceGrant]
    }

    public let paths: ClairDaemonPaths

    public init(paths: ClairDaemonPaths) {
      self.paths = paths
    }

    public func loadOrCreateHostKey() throws -> (ClairHostSigningKey, [ClairPersistedDeviceGrant]) {
      let url = paths.pairingStateURL
      let manager = FileManager.default
      guard manager.fileExists(atPath: url.path) else {
        return (ClairHostSigningKey(), [])
      }
      let attributes: [FileAttributeKey: Any]
      do { attributes = try manager.attributesOfItem(atPath: url.path) } catch {
        throw ClairDaemonPairingStoreError.unreadable
      }
      guard let permissions = attributes[.posixPermissions] as? NSNumber,
        permissions.intValue & 0o077 == 0
      else { throw ClairDaemonPairingStoreError.unsafePermissions }
      let data: Data
      do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch {
        throw ClairDaemonPairingStoreError.unreadable
      }
      let state: State
      do { state = try JSONDecoder().decode(State.self, from: data) } catch {
        throw ClairDaemonPairingStoreError.malformed
      }
      do { return (try ClairHostSigningKey(rawRepresentation: state.hostKey), state.grants) } catch {
        throw ClairDaemonPairingStoreError.malformed
      }
    }

    public func save(hostKey: ClairHostSigningKey, grants: [ClairPersistedDeviceGrant]) throws {
      let data: Data
      do {
        data = try JSONEncoder().encode(State(hostKey: hostKey.rawRepresentation, grants: grants))
      } catch { throw ClairDaemonPairingStoreError.writeFailed }
      do {
        try ClairDaemonSocketSupport.ensurePrivateDirectory(at: paths.directoryURL)
        try data.write(to: paths.pairingStateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.pairingStateURL.path)
      } catch { throw ClairDaemonPairingStoreError.writeFailed }
    }
  }

#endif
