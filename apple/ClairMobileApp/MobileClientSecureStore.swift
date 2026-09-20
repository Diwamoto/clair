import ClairMobileKit
import Foundation
import Security

/// Keeps mobile credentials and device keys in the iOS Keychain.
///
/// The host record contains an opaque device token, so it must not be copied
/// to UserDefaults or a project file. The Keychain item is device-only and
/// unavailable while the phone is locked.
struct MobileClientSecureStore {
  enum StoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
      switch self {
      case .keychain(let status):
        "Keychain operation failed (status \(status))."
      }
    }
  }

  private static let service = "com.diwamoto.clair.mobile"
  private static let hostsAccount = "paired-hosts"

  func loadHosts() throws -> [MobileClientHostRecord] {
    guard let data = try read(account: Self.hostsAccount) else {
      return []
    }
    return try JSONDecoder().decode([MobileClientHostRecord].self, from: data)
  }

  func keyPair(for hostID: UUID) throws -> MobileDeviceKeyPair? {
    guard let data = try read(account: Self.keyAccount(hostID)) else {
      return nil
    }
    return try MobileDeviceKeyPair(rawRepresentation: data)
  }

  func save(host: MobileClientHostRecord, keyPair: MobileDeviceKeyPair) throws {
    var hosts = try loadHosts().filter { $0.hostIdentity.hostID != host.hostIdentity.hostID }
    hosts.append(host)
    hosts.sort { $0.hostIdentity.hostID.uuidString < $1.hostIdentity.hostID.uuidString }
    let hostData = try JSONEncoder().encode(hosts)
    try write(hostData, account: Self.hostsAccount)
    try write(keyPair.rawRepresentation, account: Self.keyAccount(host.hostIdentity.hostID))
  }

  func remove(hostID: UUID) throws {
    let hosts = try loadHosts().filter { $0.hostIdentity.hostID != hostID }
    try write(JSONEncoder().encode(hosts), account: Self.hostsAccount)
    try delete(account: Self.keyAccount(hostID))
  }

  private func read(account: String) throws -> Data? {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      return result as? Data
    case errSecItemNotFound:
      return nil
    default:
      throw StoreError.keychain(status)
    }
  }

  private func write(_ data: Data, account: String) throws {
    let query = baseQuery(account: account)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw StoreError.keychain(updateStatus)
    }

    var insert = query
    insert[kSecValueData as String] = data
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let insertStatus = SecItemAdd(insert as CFDictionary, nil)
    guard insertStatus == errSecSuccess else {
      throw StoreError.keychain(insertStatus)
    }
  }

  private func delete(account: String) throws {
    let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw StoreError.keychain(status)
    }
  }

  private func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: account,
    ]
  }

  private static func keyAccount(_ hostID: UUID) -> String {
    "device-key-\(hostID.uuidString.lowercased())"
  }
}
