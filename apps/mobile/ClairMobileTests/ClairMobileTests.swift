import ClairMobileKit
import XCTest

final class ClairMobileTests: XCTestCase {
  func testCompositionStateCoversLifecycleConnectionAndNavigation() {
    var store = ClairMobileStore()

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
