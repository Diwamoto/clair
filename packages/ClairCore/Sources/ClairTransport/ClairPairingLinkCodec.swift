import Foundation

/// Encodes a `ClairPairingLink` into a compact, copy/paste- and QR-friendly
/// transport string, and decodes it back. This is a carrier only: the actual
/// trust decision still happens in `ClairPairingAuthority.pair(_:)`, which
/// independently re-validates the pairing ID, host identity, fingerprint
/// confirmation, expiry, and single-use consumption. A string that decodes
/// here is not yet a trusted pairing link — it is only a well-formed one.
public enum ClairPairingLinkCodec {
  /// Versioned so a future incompatible payload shape fails closed instead
  /// of decoding into a subtly wrong link.
  public static let prefix = "clairpair1."

  public static func encode(_ link: ClairPairingLink) throws -> String {
    let data: Data
    do {
      data = try JSONEncoder().encode(link)
    } catch {
      throw ClairTransportError.invalidPairingLink
    }
    return prefix + base64URLEncode(data)
  }

  public static func decode(_ string: String) throws -> ClairPairingLink {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix(prefix) else { throw ClairTransportError.invalidPairingLink }
    guard let data = base64URLDecode(String(trimmed.dropFirst(prefix.count))) else {
      throw ClairTransportError.invalidPairingLink
    }
    do {
      return try JSONDecoder().decode(ClairPairingLink.self, from: data)
    } catch {
      throw ClairTransportError.invalidPairingLink
    }
  }

  private static func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func base64URLDecode(_ string: String) -> Data? {
    guard !string.isEmpty,
      string.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    else { return nil }
    var base64 =
      string
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder > 0 {
      base64.append(String(repeating: "=", count: 4 - remainder))
    }
    return Data(base64Encoded: base64)
  }
}
