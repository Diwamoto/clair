import ClairV2MobileKit
import XCTest

final class ClairV2MobileTests: XCTestCase {
  func testCompositionStateCoversLifecycleConnectionAndNavigation() {
    var store = ClairV2MobileStore()

    store.send(.sceneBecameActive)
    store.send(.selectDestination(.sessions))
    store.send(.connectRequested)

    XCTAssertEqual(store.state.lifecycle, .active)
    XCTAssertEqual(store.state.destination, .sessions)
    XCTAssertEqual(store.state.connection, .connecting)

    store.send(.connectionEstablished)
    XCTAssertEqual(store.state.connection, .connected)
  }
}
