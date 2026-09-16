import Foundation
import Testing

@testable import ClairV2Transport

@Suite
struct ClairV2PairingLinkCodecTests {
  private func makeLink(expiresAt: Date = Date().addingTimeInterval(300)) throws -> ClairPairingLink
  {
    try ClairPairingLink(
      pairingID: .random(),
      hostID: ClairHostID("n09-host"),
      endpoint: ClairTransportEndpoint("wss://n09.example.test/mobile"),
      hostFingerprint: ClairHostSigningKey().publicKey.fingerprint,
      protocolOffer: .current,
      bootstrapSecret: .random(),
      expiresAt: expiresAt
    )
  }

  @Test func n09RoundTripsAllFieldsIncludingSecretAndExpiry() throws {
    let link = try makeLink()
    let code = try ClairPairingLinkCodec.encode(link)
    #expect(code.hasPrefix(ClairPairingLinkCodec.prefix))
    let decoded = try ClairPairingLinkCodec.decode(code)
    #expect(decoded == link)
  }

  @Test func n09DecodeIgnoresSurroundingWhitespaceFromPasteOrScan() throws {
    let link = try makeLink()
    let code = try ClairPairingLinkCodec.encode(link)
    #expect(try ClairPairingLinkCodec.decode("  \n\(code)\t ") == link)
  }

  @Test func n09RejectsMissingOrWrongPrefixWithoutAttemptingToDecode() {
    #expect(throws: ClairTransportError.invalidPairingLink) {
      try ClairPairingLinkCodec.decode("not-a-pairing-code")
    }
    #expect(throws: ClairTransportError.invalidPairingLink) {
      try ClairPairingLinkCodec.decode("clairpair2.someBase64Payload")
    }
    #expect(throws: ClairTransportError.invalidPairingLink) {
      try ClairPairingLinkCodec.decode("")
    }
  }

  @Test func n09RejectsCorruptBase64AfterAValidPrefix() {
    #expect(throws: ClairTransportError.invalidPairingLink) {
      try ClairPairingLinkCodec.decode(ClairPairingLinkCodec.prefix + "not!!valid$$base64")
    }
  }

  @Test func n09RejectsTamperedPayloadBytesRatherThanProducingAWrongLink() throws {
    let link = try makeLink()
    let code = try ClairPairingLinkCodec.encode(link)
    // Flip one character deep in the payload, keeping it syntactically
    // plausible base64url, to prove tampering fails decode rather than
    // silently producing a different, still-"valid" pairing link.
    var mutated = Array(code)
    let flipIndex = mutated.count - 3
    mutated[flipIndex] = mutated[flipIndex] == "A" ? "B" : "A"
    #expect(throws: ClairTransportError.invalidPairingLink) {
      try ClairPairingLinkCodec.decode(String(mutated))
    }
  }

  @Test func n09RejectsTruncatedCode() throws {
    let link = try makeLink()
    let code = try ClairPairingLinkCodec.encode(link)
    #expect(throws: ClairTransportError.invalidPairingLink) {
      try ClairPairingLinkCodec.decode(String(code.dropLast(20)))
    }
  }

  @Test func n09PreservesExpiryAcrossTheRoundTripForCallerSideExpiryChecks() throws {
    let expiresAt = Date(timeIntervalSince1970: 1_700_000_000)
    let link = try makeLink(expiresAt: expiresAt)
    let decoded = try ClairPairingLinkCodec.decode(try ClairPairingLinkCodec.encode(link))
    #expect(decoded.isExpired(at: expiresAt.addingTimeInterval(1)))
    #expect(!decoded.isExpired(at: expiresAt.addingTimeInterval(-1)))
  }
}
