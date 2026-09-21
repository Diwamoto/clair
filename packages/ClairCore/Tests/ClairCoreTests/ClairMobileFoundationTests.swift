import Testing

@testable import ClairMobileKit

@Test
func mobileEnvironmentUsesTheAcceptedNativeIdentity() {
  #expect(ClairMobileEnvironment.defaultBundleIdentifier == "com.diwamoto.clair.mobile")
  #expect(ClairMobileEnvironment.development.distribution == .development)
  #expect(ClairMobileEnvironment.testFlight.distribution == .testFlight)
  #expect(ClairMobileEnvironment.development.clientVersion == "0.1.0")
}

@Test
func mobileStoreTracksLifecycleAndConnectionWithoutTransportSideEffects() {
  var store = ClairMobileStore()

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
  var store = ClairMobileStore()

  for destination in ClairMobileDestination.allCases {
    store.send(.selectDestination(destination))
    #expect(store.state.destination == destination)
  }
}

@Test
func mobileStoreCanRetryAfterAConnectionFailure() {
  var store = ClairMobileStore()

  store.send(.connectRequested)
  store.send(.connectionFailed)
  #expect(store.state.connection == .failed)

  store.send(.connectRequested)
  #expect(store.state.connection == .connecting)
}
