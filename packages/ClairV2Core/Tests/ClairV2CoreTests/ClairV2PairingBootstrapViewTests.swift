import Foundation
import Testing

@testable import ClairV2AppKit

#if os(macOS)
  @Suite
  struct ClairV2PairingBootstrapViewTests {
    @Test func n09QRCodeImageRendersADeterministicNonEmptyImageForARealCode() {
      let code = "clairpair1." + String(repeating: "A", count: 200)
      let first = ClairV2PairingBootstrapView.qrCodeImage(for: code)
      let second = ClairV2PairingBootstrapView.qrCodeImage(for: code)
      let firstImage = try! #require(first)
      let secondImage = try! #require(second)
      #expect(firstImage.width > 0 && firstImage.height > 0)
      #expect(firstImage.width == secondImage.width && firstImage.height == secondImage.height)
    }

    @Test func n09QRCodeImageFailsClosedOnEmptyInputRatherThanCrashing() {
      #expect(ClairV2PairingBootstrapView.qrCodeImage(for: "") == nil)
    }
  }
#endif
