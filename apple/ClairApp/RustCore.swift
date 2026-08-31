import Foundation

enum RustCore {
  static let expectedSmokeValue: UInt32 = 0x434C_4149

  static func smokeValue() -> UInt32 {
    clair_core_smoke()
  }
}
