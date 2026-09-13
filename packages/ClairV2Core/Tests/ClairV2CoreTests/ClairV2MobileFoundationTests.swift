import Testing

@testable import ClairV2MobileKit

@Test
func mobileEnvironmentUsesTheAcceptedNativeIdentity() {
  #expect(ClairV2MobileEnvironment.defaultBundleIdentifier == "com.diwamoto.clair.mobile")
  #expect(ClairV2MobileEnvironment.development.distribution == .development)
  #expect(ClairV2MobileEnvironment.testFlight.distribution == .testFlight)
  #expect(ClairV2MobileEnvironment.development.clientVersion == "0.1.0")
}

@Test
func mobileStoreTracksLifecycleAndConnectionWithoutTransportSideEffects() {
  var store = ClairV2MobileStore()

  store.send(.sceneBecameActive)
  store.send(.connectRequested)
  #expect(store.state.lifecycle == .active)
  #expect(store.state.connection == .connecting)

  store.send(.connectionEstablished)
  #expect(store.state.connection == .connected)

  store.send(.sceneEnteredBackground)
  #expect(store.state.lifecycle == .background)
  #expect(store.state.connection == .connected)

  store.send(.disconnectRequested)
  #expect(store.state.connection == .disconnected)
}

@Test
func mobileStoreRoutesNavigationCommands() {
  var store = ClairV2MobileStore()

  for destination in ClairV2MobileDestination.allCases {
    store.send(.selectDestination(destination))
    #expect(store.state.destination == destination)
  }
}

@Test
func mobileStoreCanRetryAfterAConnectionFailure() {
  var store = ClairV2MobileStore()

  store.send(.connectRequested)
  store.send(.connectionFailed)
  #expect(store.state.connection == .failed)

  store.send(.connectRequested)
  #expect(store.state.connection == .connecting)
}
