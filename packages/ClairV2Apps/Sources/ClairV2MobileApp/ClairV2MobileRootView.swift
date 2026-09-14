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
  @State private var destinationBrowser = ClairMobileDestinationBrowserState()
  @State private var showingPairing = false
  @State private var pairingCode = ""
  @State private var conversation = ClairV2MobileConversationController()
  @State private var conversationSnapshot = ClairV2MobileConversationState()
  @State private var conversationDraft = ""
  @State private var conversationError: String?

  var body: some View {
    NavigationStack {
      List {
        hostSection
        destinationBrowserSection
        conversationSection
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
      if phase == .active {
        // A response streamed while backgrounded is already folded by the
        // actor regardless of scene phase; returning to the foreground only
        // needs to refresh this view's snapshot of that state.
        Task { await refreshConversation() }
      }
    }
  }

  private var conversationSection: some View {
    Section("Conversation") {
      guard destinationBrowser.selectedScope?.isSessionScope == true else {
        return AnyView(
          ContentUnavailableView(
            "No session selected",
            systemImage: "bubble.left.and.bubble.right",
            description: Text("Select a session above to open its conversation.")
          )
        )
      }
      return AnyView(
        VStack(alignment: .leading, spacing: 12) {
          if conversationSnapshot.messages.isEmpty {
            Text("No messages yet.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          } else {
            ForEach(conversationSnapshot.messages) { message in
              VStack(alignment: .leading, spacing: 2) {
                Text(message.role.rawValue.capitalized)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Text(message.text)
                  .font(.body)
              }
              .accessibilityIdentifier("conversation-message-\(message.id)")
            }
          }

          ForEach(conversationSnapshot.pendingApprovals) { approval in
            HStack {
              VStack(alignment: .leading) {
                Text("Approval requested")
                  .font(.subheadline)
                Text(approval.kind.rawValue.capitalized)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Button("Approve") {
                respondToApproval(requestID: approval.requestID, approve: true)
              }
              .accessibilityIdentifier("approve-\(approval.requestID)")
              Button("Deny", role: .destructive) {
                respondToApproval(requestID: approval.requestID, approve: false)
              }
              .accessibilityIdentifier("deny-\(approval.requestID)")
            }
          }

          HStack {
            TextField("Message", text: $conversationDraft)
              .accessibilityIdentifier("conversation-composer")
            Button("Send") {
              submitPrompt()
            }
            .disabled(conversationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("conversation-send")
          }

          HStack {
            Button("Interrupt") {
              dispatchLifecycleCommand { try await conversation.interrupt() }
            }
            .accessibilityIdentifier("conversation-interrupt")
            Button("Stop", role: .destructive) {
              dispatchLifecycleCommand { try await conversation.stop() }
            }
            .accessibilityIdentifier("conversation-stop")
          }

          if let conversationError {
            Label(conversationError, systemImage: "exclamationmark.triangle")
              .font(.footnote)
              .foregroundStyle(.orange)
              .accessibilityIdentifier("conversation-error")
          }
        }
      )
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

  private var destinationBrowserSection: some View {
    Section("Projects") {
      if destinationBrowser.projects.isEmpty {
        ContentUnavailableView(
          "No available Projects",
          systemImage: "folder",
          description: Text("Connect to a paired host to browse its read-only Project catalog.")
        )
      } else {
        ForEach(destinationBrowser.projects, id: \.id) { project in
          Button {
            _ = destinationBrowser.selectProject(project.id)
          } label: {
            HStack {
              VStack(alignment: .leading) {
                Text(project.rootURL.lastPathComponent)
                Text(project.state.rawValue.replacingOccurrences(of: "_", with: " "))
                  .font(.caption)
                  .foregroundStyle(project.state == .available ? Color.secondary : Color.orange)
              }
              Spacer()
              if destinationBrowser.selectedScope?.projectID == project.id {
                Image(systemName: "checkmark")
                  .accessibilityHidden(true)
              }
            }
          }
          .disabled(project.state != .available)
          .accessibilityIdentifier("project-\(project.id)")

          ForEach(destinationBrowser.worktrees(for: project.id), id: \.id) { worktree in
            Button {
              _ = destinationBrowser.selectWorktree(projectID: project.id, worktreeID: worktree.id)
            } label: {
              HStack {
                Image(systemName: "arrow.triangle.branch")
                  .foregroundStyle(.secondary)
                Text(worktree.branch ?? worktree.rootURL.lastPathComponent)
                Spacer()
                Text(worktree.state.rawValue.replacingOccurrences(of: "_", with: " "))
                  .font(.caption)
                  .foregroundStyle(worktree.state == .available ? Color.secondary : Color.orange)
              }
            }
            .disabled(worktree.state != .available)
            .accessibilityIdentifier("worktree-\(worktree.id)")
          }

          ForEach(destinationBrowser.sessions(forProjectID: project.id)) { session in
            Button {
              _ = destinationBrowser.selectSession(session.id)
            } label: {
              HStack {
                Image(systemName: "terminal")
                  .foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                  Text(session.displayName)
                  Text(session.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if destinationBrowser.selectedScope == session.scope {
                  Image(systemName: "checkmark")
                    .accessibilityHidden(true)
                }
              }
            }
            .accessibilityIdentifier("session-\(session.id)")
          }
        }
      }

      if let recent = destinationBrowser.recentDestination {
        Button("Clear recent destination", role: .destructive) {
          destinationBrowser.clearRecentDestination()
        }
        .accessibilityIdentifier("clear-recent-destination")
        Text(verbatim: "Recent: \(recent.scope.projectID.description)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let error = destinationBrowser.lastError {
        Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
          .font(.footnote)
          .foregroundStyle(.orange)
          .accessibilityIdentifier("destination-browser-error")
      }
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

  private func submitPrompt() {
    let text = conversationDraft
    conversationDraft = ""
    dispatchLifecycleCommand { _ = try await conversation.submitPrompt(text) }
  }

  private func respondToApproval(requestID: String, approve: Bool) {
    dispatchLifecycleCommand {
      if approve {
        _ = try await conversation.approve(requestID: requestID)
      } else {
        _ = try await conversation.deny(requestID: requestID)
      }
    }
  }

  /// Wraps one scoped-command action: clears any previous error, awaits the
  /// actor (which owns duplicate/in-flight de-duplication on its own), then
  /// refreshes this view's snapshot. Errors are surfaced, never thrown away.
  private func dispatchLifecycleCommand(_ action: @escaping () async throws -> Void) {
    conversationError = nil
    Task {
      do {
        try await action()
      } catch {
        conversationError = error.localizedDescription
      }
      await refreshConversation()
    }
  }

  private func refreshConversation() async {
    conversationSnapshot = await conversation.state
  }
}
