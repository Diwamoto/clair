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
  @State private var hostManagement = ClairMobileHostManagementState()
  @State private var showingPairing = false
  @State private var pairingCode = ""

  var body: some View {
    NavigationStack {
      List {
        hostSection
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

  private var hostSection: some View {
    Section("Hosts") {
      if hostManagement.hosts.isEmpty {
        ContentUnavailableView("No paired hosts", systemImage: "desktopcomputer")
      } else {
        ForEach(hostManagement.hosts) { host in
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text(host.displayName ?? host.id.description)
                .font(.headline)
              Spacer()
              Text(host.connection.rawValue.capitalized)
                .foregroundStyle(host.connection == .connected ? .green : .secondary)
            }
            Text("Fingerprint: \(host.fingerprint.description.prefix(16))…")
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
            Text(host.scopes.isEmpty ? "No device scope" : "\(host.scopes.count) device scope(s)")
              .font(.caption)
            if host.connection == .fingerprintChanged {
              Label(
                "Fingerprint changed — re-pair required", systemImage: "exclamationmark.triangle"
              )
              .foregroundStyle(.orange)
            }
            Button("Revoke device", role: .destructive) {
              hostManagement.markRevoked(hostID: host.id)
            }
            .disabled(host.connection == .revoked)
          }
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("host-\(host.id)")
        }
      }
      Button("Pair or re-pair host", systemImage: "qrcode") {
        showingPairing = true
      }
      .accessibilityIdentifier("pair-host")
    }
    .sheet(isPresented: $showingPairing) {
      NavigationStack {
        Form {
          Section("Pairing QR") {
            TextField("Paste pairing link", text: $pairingCode)
            Text(
              "Pairing links are one-time and expire. Confirm the host fingerprint before trusting it."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
          }
          Section {
            Button("Cancel", role: .cancel) { showingPairing = false }
          }
        }
        .navigationTitle("Pair host")
      }
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
