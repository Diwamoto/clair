import ClairV2MobileKit
import SwiftUI

private struct ClairV2MobileEnvironmentKey: EnvironmentKey {
  static let defaultValue = ClairV2MobileEnvironment.development
}

extension EnvironmentValues {
  var clairV2Mobile: ClairV2MobileEnvironment {
    get { self[ClairV2MobileEnvironmentKey.self] }
    set { self[ClairV2MobileEnvironmentKey.self] = newValue }
  }
}

struct ClairV2MobileRootView: View {
  @Environment(\.clairV2Mobile) private var environment
  @Environment(\.scenePhase) private var scenePhase
  @State private var store = ClairV2MobileStore()

  var body: some View {
    NavigationStack {
      List {
        connectionSection
        navigationSection
        surfaceSection
        buildSection
      }
      .navigationTitle("Clair v2 Mobile")
    }
    .onAppear {
      store.send(.sceneBecameActive)
    }
    .onChange(of: scenePhase) { _, phase in
      store.send(command(for: phase))
    }
  }

  private var connectionSection: some View {
    Section("Connection") {
      LabeledContent("State", value: store.state.connection.rawValue)
      Button("Connect") {
        store.send(.connectRequested)
      }
      .disabled(store.state.connection == .connected)
      Button("Disconnect") {
        store.send(.disconnectRequested)
      }
      .disabled(store.state.connection == .disconnected)
    }
  }

  private var navigationSection: some View {
    Section("Navigation") {
      ForEach(ClairV2MobileDestination.allCases) { destination in
        Button {
          store.send(.selectDestination(destination))
        } label: {
          HStack {
            Text(destination.title)
            Spacer()
            if store.state.destination == destination {
              Image(systemName: "checkmark")
                .accessibilityHidden(true)
            }
          }
        }
      }
    }
  }

  private var surfaceSection: some View {
    Section("Current surface") {
      HStack {
        Text("Destination")
        Spacer()
        Text(store.state.destination.title)
          .accessibilityIdentifier("current-destination")
      }
      LabeledContent("Lifecycle", value: store.state.lifecycle.rawValue)
    }
  }

  private var buildSection: some View {
    Section("Build") {
      LabeledContent("Bundle", value: environment.bundleIdentifier)
      LabeledContent("Version", value: environment.clientVersion)
      LabeledContent("Distribution", value: environment.distribution.rawValue)
    }
  }

  private func command(for phase: ScenePhase) -> ClairV2MobileCommand {
    switch phase {
    case .active:
      .sceneBecameActive
    case .inactive:
      .sceneBecameInactive
    case .background:
      .sceneEnteredBackground
    @unknown default:
      .sceneBecameInactive
    }
  }
}
