import Foundation
import Testing

@testable import ClairTransport

@Suite
struct ClairPairingLinkCodecTests {
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
    // Flip one payload character, keeping it syntactically plausible base64url, to prove tampering fails decode
    // rather than silently producing a different, still-"valid" pairing link. The first one encodes the JSON's
    // opening brace: a character near the end could land in a random field's digits (the secret, the expiry) and
    // still decode, which made this test fail now and then.
    var mutated = Array(code)
    let flipIndex = ClairPairingLinkCodec.prefix.count
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
