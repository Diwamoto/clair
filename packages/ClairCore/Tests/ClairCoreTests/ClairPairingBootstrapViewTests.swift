import Foundation
import Testing

@testable import ClairAppKit

#if os(macOS)
  @Suite
  struct ClairPairingBootstrapViewTests {
    @Test func n09QRCodeImageRendersADeterministicNonEmptyImageForARealCode() {
      let code = "clairpair1." + String(repeating: "A", count: 200)
      let first = ClairPairingBootstrapView.qrCodeImage(for: code)
      let second = ClairPairingBootstrapView.qrCodeImage(for: code)
      let firstImage = try! #require(first)
      let secondImage = try! #require(second)
      #expect(firstImage.width > 0 && firstImage.height > 0)
      #expect(firstImage.width == secondImage.width && firstImage.height == secondImage.height)
    }

    @Test func n09QRCodeImageFailsClosedOnEmptyInputRatherThanCrashing() {
      #expect(ClairPairingBootstrapView.qrCodeImage(for: "") == nil)
    }
  }
#endif
