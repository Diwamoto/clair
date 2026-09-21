import Testing

@testable import ClairAppKit
@testable import ClairDaemonKit
@testable import ClairMobileKit

@Test
func appPackageUsesOnlyTheNewCorePackage() {
  #expect(ClairAppComposition.packageName == "ClairCore")
  #expect(ClairMobileModule.name.hasPrefix("Clair"))
  #expect(ClairDaemonModule.name.hasPrefix("Clair"))
}
