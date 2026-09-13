import Testing

@testable import ClairV2AppKit
@testable import ClairV2DaemonKit
@testable import ClairV2MobileKit

@Test
func appPackageUsesOnlyTheNewCorePackage() {
  #expect(ClairV2AppComposition.packageName == "ClairV2Core")
  #expect(ClairV2MobileModule.name.hasPrefix("ClairV2"))
  #expect(ClairV2DaemonModule.name.hasPrefix("ClairV2"))
}
