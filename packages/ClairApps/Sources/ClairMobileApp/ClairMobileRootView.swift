import ClairMobileKit
import ClairShared
import ClairTerminal
#if os(iOS)
  import ClairTerminalView
#endif
import ClairTransport
import SwiftUI

private struct ClairMobileEnvironmentKey: EnvironmentKey {
  static let defaultValue = ClairMobileEnvironment.development
}

extension EnvironmentValues {
  var clairMobile: ClairMobileEnvironment {
    get { self[ClairMobileEnvironmentKey.self] }
    set { self[ClairMobileEnvironmentKey.self] = newValue }
  }
}

/// Shared native client composition created by `ClairMobileApp`. It owns the
/// credentials and authenticated handle; SwiftUI observes only its redacted
/// snapshot and actor-backed feature surfaces.
private struct ClairMobileCompositionKey: EnvironmentKey {
  static let defaultValue = ClairMobileConnectionComposition()
}

extension EnvironmentValues {
  var clairMobileComposition: ClairMobileConnectionComposition {
    get { self[ClairMobileCompositionKey.self] }
    set { self[ClairMobileCompositionKey.self] = newValue }
  }
}

struct ClairMobileRootView: View {
  @Environment(\.clairMobile) private var environment
  @Environment(\.scenePhase) private var scenePhase
  @State private var store = ClairMobileStore()
  @State private var hostManagement = ClairMobileHostManagementState()
  @State private var compositionSnapshot = ClairMobileCompositionSnapshot(
    clientState: .disconnected,
    sessionGeneration: nil,
    connectionSummary: nil
  )
  @State private var destinationBrowser = ClairMobileDestinationBrowserState()
  @State private var showingPairing = false
  @State private var pairingCode = ""
  @State private var pairingError: String?
  @State private var isPairing = false
  @State private var conversation = ClairMobileConversationController()
  @State private var conversationSnapshot = ClairMobileConversationState()
  @State private var conversationDraft = ""
  @State private var conversationError: String?
  @State private var diffReview = ClairMobileDiffReviewController()
  @State private var diffReviewSnapshot = ClairMobileDiffReviewState()
  @State private var diffReviewError: String?
  @Environment(\.clairMobileComposition) private var composition
  @State private var reconnectState = ClairMobileReconnectState.idle
  @State private var reconnectError: String?
  @State private var hasProcessedLaunch = false
  @State private var terminalSessions: [ClairRemoteTerminalSession] = []
  @State private var terminalSessionsError: String?

  var body: some View {
    NavigationStack {
      List {
        hostSection
        destinationBrowserSection
        terminalSessionsSection
        conversationSection
        diffReviewSection
        reconnectSection
        connectionSection
        navigationSection
        surfaceSection
        buildSection
      }
      .navigationTitle("Clair Mobile")
    }
    .onAppear {
      store.send(.sceneBecameActive)
      guard !hasProcessedLaunch else { return }
      hasProcessedLaunch = true
      // A cold launch with no deep link still runs through the same typed
      // reconnect state machine as any other foreground: the last cached
      // destination (if any) is re-verified against the host, never trusted
      // silently just because the process just started.
      Task {
        compositionSnapshot = ClairMobileCompositionSnapshot(
          clientState: .connecting,
          sessionGeneration: nil,
          connectionSummary: nil
        )
        compositionSnapshot = await composition.restoreAndReconnect()
        hostManagement = await composition.hostManagementState()
        await refreshComposedSurfaces()
        reconnectState = await composition.handle(.launched(deepLink: nil))
        compositionSnapshot = await composition.snapshot
      }
    }
    .onOpenURL { url in
      // A deep link handed to an already-running process is processed
      // exactly like a cold launch with that link: it is never trusted
      // without an independent host verification.
      guard let deepLink = try? ClairMobileDeepLink(url: url) else {
        reconnectError = ClairMobileReconnectError.invalidDeepLink.localizedDescription
        return
      }
      dispatchReconnectEvent(.launched(deepLink: deepLink))
    }
    .onChange(of: scenePhase) { _, phase in
      store.send(command(for: phase))
      switch phase {
      case .active:
        // A response streamed while backgrounded is already folded by the
        // actor regardless of scene phase; returning to the foreground only
        // needs to refresh this view's snapshot of that state.
        Task { await refreshConversation() }
        dispatchReconnectEvent(.foregrounded)
      case .background:
        dispatchReconnectEvent(.backgrounded)
      default:
        break
      }
    }
    .onChange(of: destinationBrowser.selectedScope) { _, scope in
      // A device token can arrive from the OS before any destination is
      // selected; registration is attempted (or re-attempted for the new
      // scope) whenever the selection changes, using whatever token the
      // controller has already recorded.
      guard let scope, scope.isSessionScope else { return }
      Task {
        guard let generation = compositionSnapshot.sessionGeneration else { return }
        _ = await composition.attachReadSurfaces(to: scope, generation: generation)
        if scope.isSessionScope, let deepLink = try? ClairMobileDeepLink(scope: scope) {
          reconnectState = await composition.handle(.launched(deepLink: deepLink))
        }
        await refreshDiffReview()
        _ = await composition.registerPendingPushTokenIfNeeded(
          environment: environment.pushEnvironment, scope: scope
        )
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

  private var diffReviewSection: some View {
    Section("Changed files") {
      // A project, worktree, or session selection all resolve to the same
      // underlying Project/Worktree Git status, so any selection is enough
      // to show this section.
      guard destinationBrowser.selectedScope != nil else {
        return AnyView(
          ContentUnavailableView(
            "No project selected",
            systemImage: "doc.on.doc",
            description: Text("Select a project or worktree above to review its changed files.")
          )
        )
      }
      return AnyView(
        VStack(alignment: .leading, spacing: 12) {
          Button("Refresh changed files") {
            dispatchDiffReviewCommand { try await diffReview.refreshChangedFiles() }
          }
          .accessibilityIdentifier("diff-review-refresh")

          if diffReviewSnapshot.files.isEmpty {
            Text("No changed files loaded.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          } else {
            if diffReviewSnapshot.isChangedFileListTruncated {
              Label(
                "Changed-file list truncated — not every changed file is shown",
                systemImage: "exclamationmark.triangle"
              )
              .font(.footnote)
              .foregroundStyle(.orange)
              .accessibilityIdentifier("diff-review-files-truncated")
            }
            ForEach(diffReviewSnapshot.files, id: \.path) { file in
              Button {
                dispatchDiffReviewCommand { try await diffReview.selectFile(file.path) }
              } label: {
                HStack {
                  Text(file.path.rawValue)
                  Spacer()
                  Text(file.kind.rawValue.replacingOccurrences(of: "_", with: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  if diffReviewSnapshot.selectedPath == file.path {
                    Image(systemName: "checkmark")
                      .accessibilityHidden(true)
                  }
                }
              }
              .accessibilityIdentifier("diff-review-file-\(file.path.rawValue)")
            }
          }

          if let diff = diffReviewSnapshot.diff {
            Divider()
            if diffReviewSnapshot.isBinary {
              Label("Binary file — no text diff available", systemImage: "doc.badge.gearshape")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("diff-review-binary")
            } else if let text = diff.text {
              Text(text)
                .font(.system(.footnote, design: .monospaced))
                .accessibilityIdentifier("diff-review-text")
            }

            if diffReviewSnapshot.isTruncated {
              Label(
                "Diff truncated at \(diff.maximumOutputBytes) bytes — showing a bounded excerpt, not the complete diff",
                systemImage: "exclamationmark.triangle"
              )
              .font(.footnote)
              .foregroundStyle(.orange)
              .accessibilityIdentifier("diff-review-truncated")
            }

            if !diffReviewSnapshot.hunks.isEmpty {
              HStack {
                Button("Previous hunk") {
                  dispatchDiffReviewNavigation { await diffReview.previousHunk() }
                }
                .accessibilityIdentifier("diff-review-previous-hunk")
                Spacer()
                if let hunk = diffReviewSnapshot.currentHunk {
                  Text(hunk.header)
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("diff-review-current-hunk")
                }
                Spacer()
                Button("Next hunk") {
                  dispatchDiffReviewNavigation { await diffReview.nextHunk() }
                }
                .accessibilityIdentifier("diff-review-next-hunk")
              }
            }

            if let seed = diffReviewSnapshot.followUpPromptSeed {
              Button("Draft follow-up") {
                conversationDraft = seed
              }
              .accessibilityIdentifier("diff-review-draft-follow-up")
            }
          }

          if let diffReviewError {
            Label(diffReviewError, systemImage: "exclamationmark.triangle")
              .font(.footnote)
              .foregroundStyle(.orange)
              .accessibilityIdentifier("diff-review-error")
          }
        }
      )
    }
  }

  /// Third sibling section alongside `conversationSection` (N05) and
  /// `diffReviewSection` (N06): a minimal functional surface for the
  /// scene-lifecycle/deep-link/push reconnect state, not production visual
  /// design. It only ever displays what `ClairMobileReconnectController`
  /// reports -- it never itself decides a destination is current.
  private var reconnectSection: some View {
    Section("Reconnect") {
      switch reconnectState {
      case .idle:
        Text("Not yet checked.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("reconnect-idle")
      case .verifying(let scope):
        LabeledContent("Verifying", value: scope.projectID.description)
          .accessibilityIdentifier("reconnect-verifying")
      case .verified(let cursor):
        VStack(alignment: .leading, spacing: 4) {
          Label("Verified with host", systemImage: "checkmark.shield")
            .foregroundStyle(.green)
          Text(verbatim: "Project: \(cursor.scope.projectID.description)")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(
            verbatim: "Revision: \(cursor.revision.description) (epoch \(cursor.epoch.description))"
          )
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reconnect-verified")
      case .mustReconnect(let scope, let error):
        VStack(alignment: .leading, spacing: 4) {
          Label("Must reconnect", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
          if let scope {
            Text(verbatim: "Destination: \(scope.projectID.description)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Text(error.localizedDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reconnect-must-reconnect")
      }

      if let reconnectError {
        Label(reconnectError, systemImage: "exclamationmark.triangle")
          .font(.footnote)
          .foregroundStyle(.orange)
          .accessibilityIdentifier("reconnect-error")
      }
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
          Section("Pairing code") {
            TextField("Paste pairing code", text: $pairingCode)
              .accessibilityIdentifier("pairing-code-field")
            Button("Decode") { decodePairingCode() }
              .disabled(pairingCode.isEmpty)
              .accessibilityIdentifier("decode-pairing-code")
            if let pairingError {
              Text(pairingError)
                .font(.footnote)
                .foregroundStyle(.red)
            }
            Text(
              "Pairing links are one-time and expire. Confirm the host fingerprint before trusting it."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
          }
          if let pairing = hostManagement.pairing {
            Section("Confirm this host") {
              LabeledContent("Host", value: pairing.hostID.description)
              Text("Fingerprint: \(pairing.fingerprint.description.prefix(16))…")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
              switch pairing.state {
              case .ready:
                Text(
                  "Ready to pair. Verify this fingerprint out of band before trusting this host."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
              case .expired:
                Text("This pairing code has expired. Ask the host to issue a new one.")
                  .font(.footnote)
                  .foregroundStyle(.orange)
              case .fingerprintChanged:
                Text("This host's fingerprint changed since it was last seen.")
                  .font(.footnote)
                  .foregroundStyle(.red)
              }
              Button("Confirm fingerprint and pair") {
                beginPairing()
              }
              .disabled(pairing.state != .ready || isPairing)
              .accessibilityIdentifier("confirm-host-pairing")
            }
          }
          Section {
            Button("Cancel", role: .cancel) {
              showingPairing = false
              pairingCode = ""
              pairingError = nil
              hostManagement.clearPairing()
            }
          }
        }
        .navigationTitle("Pair host")
      }
    }
  }

  private func decodePairingCode() {
    do {
      try hostManagement.presentPairing(fromCode: pairingCode)
      pairingError = nil
    } catch {
      pairingError = "That pairing code could not be read. Check it was copied in full."
    }
  }

  private var connectionSection: some View {
    Section("Connection") {
      LabeledContent("State", value: connectionStateDescription)
      if let summary = compositionSnapshot.connectionSummary {
        LabeledContent("Host", value: summary.hostID.description)
        LabeledContent("Endpoint", value: summary.endpoint.value)
      }
      if let generation = compositionSnapshot.sessionGeneration {
        LabeledContent("Connection generation", value: String(generation))
      }
      switch compositionSnapshot.notice {
      case .none:
        EmptyView()
      case .staleGeneration:
        Label(
          "This surface belongs to an older connection. Reconnect before retrying.",
          systemImage: "arrow.clockwise.circle"
        )
        .font(.footnote)
        .foregroundStyle(.orange)
        .accessibilityIdentifier("connection-stale-generation")
      case .endpointPinFailure:
        Label(
          "The host or endpoint pin changed. Verify the fingerprint and pair again.",
          systemImage: "exclamationmark.shield"
        )
        .font(.footnote)
        .foregroundStyle(.red)
        .accessibilityIdentifier("connection-endpoint-pin-failure")
      }
      if case .failed(let error) = compositionSnapshot.clientState {
        Text(error.localizedDescription)
          .font(.footnote)
          .foregroundStyle(.orange)
          .accessibilityIdentifier("connection-error")
      }
      Button("Connect") {
        connect()
      }
      .disabled(isClientConnected || isClientConnecting)
      .accessibilityIdentifier("connect-host")
      Button("Disconnect") {
        disconnect()
      }
      .disabled(!isClientConnected && !isClientConnecting)
      .accessibilityIdentifier("disconnect-host")
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

  /// N10: the host's live terminal sessions this device may attach to. Each
  /// opens the `MobileTerminal` push screen on the same authenticated channel.
  private var terminalSessionsSection: some View {
    Section("Terminals") {
      if terminalSessions.isEmpty {
        ContentUnavailableView(
          "No terminal sessions",
          systemImage: "terminal",
          description: Text("Connect to a paired host with a running terminal session.")
        )
      }
      ForEach(terminalSessions, id: \.self) { target in
        NavigationLink {
          #if os(iOS)
            ClairMobileTerminalScreen(target: target, composition: composition)
          #endif
        } label: {
          VStack(alignment: .leading) {
            Text(target.scope.sessionID?.description ?? "terminal")
            Text(target.scope.projectID.description)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .accessibilityIdentifier("terminal-session-\(target.scope.sessionID?.description ?? "")")
      }
      Button("Refresh terminal sessions") {
        Task { await refreshTerminalSessions() }
      }
      .disabled(!isClientConnected)
      .accessibilityIdentifier("terminal-sessions-refresh")
      if let terminalSessionsError {
        Label(terminalSessionsError, systemImage: "exclamationmark.triangle")
          .font(.footnote)
          .foregroundStyle(.orange)
          .accessibilityIdentifier("terminal-sessions-error")
      }
    }
  }

  private func refreshTerminalSessions() async {
    do {
      terminalSessions = try await composition.terminalSessions()
      terminalSessionsError = nil
    } catch {
      terminalSessions = []
      terminalSessionsError = error.localizedDescription
    }
  }

  private var navigationSection: some View {
    Section("Navigation") {
      ForEach(ClairMobileDestination.allCases) { destination in
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

  private var isClientConnected: Bool {
    if case .authenticated = compositionSnapshot.clientState { return true }
    return false
  }

  private var isClientConnecting: Bool {
    switch compositionSnapshot.clientState {
    case .connecting, .pairing, .reconnecting:
      true
    case .disconnected, .authenticated, .failed:
      false
    }
  }

  private var connectionStateDescription: String {
    switch compositionSnapshot.status {
    case .disconnected:
      "Disconnected"
    case .connecting:
      "Connecting"
    case .pairing:
      "Pairing"
    case .connected:
      "Connected"
    case .reconnecting:
      "Reconnecting"
    case .staleGeneration:
      "Stale connection generation"
    case .endpointPinFailure:
      "Host or endpoint pin failure"
    case .failed(let error):
      "Failed: \(error.localizedDescription)"
    }
  }

  private func command(for phase: ScenePhase) -> ClairMobileCommand {
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

  private func beginPairing() {
    guard let displayedPairing = hostManagement.pairing,
      displayedPairing.state == .ready,
      !isPairing
    else { return }
    pairingError = nil
    isPairing = true
    compositionSnapshot = ClairMobileCompositionSnapshot(
      clientState: .pairing,
      sessionGeneration: compositionSnapshot.sessionGeneration,
      connectionSummary: compositionSnapshot.connectionSummary
    )
    Task {
      compositionSnapshot = await composition.pair(
        usingCode: pairingCode,
        expectedHostID: displayedPairing.hostID,
        expectedFingerprint: displayedPairing.fingerprint,
        displayName: "Clair Mobile",
        confirmHostFingerprint: true
      )
      isPairing = false
      if isClientConnected {
        hostManagement = await composition.hostManagementState()
        await refreshComposedSurfaces()
        showingPairing = false
        pairingCode = ""
        hostManagement.clearPairing()
      } else if case .failed(let error) = compositionSnapshot.clientState {
        pairingError =
          error == .invalidHandshake
          ? "That pairing code could not be read. Check it was copied in full."
          : error.localizedDescription
      }
    }
  }

  private func connect() {
    compositionSnapshot = ClairMobileCompositionSnapshot(
      clientState: .connecting,
      sessionGeneration: compositionSnapshot.sessionGeneration,
      connectionSummary: compositionSnapshot.connectionSummary
    )
    Task {
      compositionSnapshot = await composition.reconnect()
      hostManagement = await composition.hostManagementState()
      await refreshComposedSurfaces()
    }
  }

  private func disconnect() {
    Task {
      compositionSnapshot = await composition.disconnect()
      hostManagement = await composition.hostManagementState()
      await refreshComposedSurfaces()
    }
  }

  private func refreshComposedSurfaces() async {
    guard let surfaces = await composition.composedSurfaces() else { return }
    conversation = surfaces.conversation
    diffReview = surfaces.diffReview
    reconnectState = await surfaces.reconnect.state
    if let scope = destinationBrowser.selectedScope,
      let generation = compositionSnapshot.sessionGeneration
    {
      _ = await composition.attachReadSurfaces(to: scope, generation: generation)
      if scope.isSessionScope, let deepLink = try? ClairMobileDeepLink(scope: scope) {
        reconnectState = await composition.handle(.launched(deepLink: deepLink))
      }
    }
    await refreshConversation()
    await refreshDiffReview()
    await refreshTerminalSessions()
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
        if let error = error as? ClairMobileConversationError, error == .staleGeneration {
          compositionSnapshot = await composition.markStaleGeneration()
        }
      }
      await refreshConversation()
    }
  }

  private func refreshConversation() async {
    conversationSnapshot = await conversation.state
  }

  /// Wraps one diff review read (refresh changed files, select a file):
  /// clears any previous error, awaits the actor (which owns its own
  /// duplicate/in-flight de-duplication), then refreshes this view's
  /// snapshot. Errors are surfaced, never thrown away.
  private func dispatchDiffReviewCommand(_ action: @escaping () async throws -> Void) {
    diffReviewError = nil
    Task {
      do {
        try await action()
      } catch {
        diffReviewError = error.localizedDescription
        if let error = error as? ClairMobileDiffReviewError, error == .staleGeneration {
          compositionSnapshot = await composition.markStaleGeneration()
        }
      }
      await refreshDiffReview()
    }
  }

  /// Wraps a pure, synchronous hunk-navigation call. It cannot fail or touch
  /// the transport, so it only needs a snapshot refresh afterward.
  private func dispatchDiffReviewNavigation(_ action: @escaping () async -> Void) {
    Task {
      await action()
      await refreshDiffReview()
    }
  }

  private func refreshDiffReview() async {
    diffReviewSnapshot = await diffReview.state
  }

  /// Wraps one scene-lifecycle/deep-link event: clears any previous parse
  /// error, awaits the actor (which owns the typed verify-before-trust state
  /// machine on its own), then refreshes this view's snapshot. The actor's
  /// state is authoritative regardless of how quickly the view redraws.
  private func dispatchReconnectEvent(_ event: ClairMobileSceneEvent) {
    switch event {
    case .launched, .foregrounded:
      compositionSnapshot = ClairMobileCompositionSnapshot(
        clientState: .reconnecting,
        sessionGeneration: compositionSnapshot.sessionGeneration,
        connectionSummary: compositionSnapshot.connectionSummary
      )
    case .backgrounded, .pushWake:
      break
    }
    Task {
      reconnectState = await composition.handle(event)
      compositionSnapshot = await composition.snapshot
      if compositionSnapshot.sessionGeneration != nil {
        await refreshComposedSurfaces()
      }
    }
  }
}

#if os(iOS)
  /// N10: the `MobileTerminal` artboard. A push screen over one host terminal
  /// session: raw PTY bytes rendered by `ClairTerminalView`, a key bar, and a
  /// composer. The viewport is client-local; it never resizes the remote PTY.
  // ponytail: no gap banner or byte counter from the artboard yet; add when the
  // session exposes journal gaps to the view.
  private struct ClairMobileTerminalScreen: View {
    let target: ClairRemoteTerminalSession
    let composition: ClairMobileConnectionComposition
    @State private var terminal: ClairMobileTerminalSession?
    @State private var failure: String?
    @State private var draft = ""

    var body: some View {
      VStack(spacing: 0) {
        HStack(spacing: 7) {
          Text(target.scope.projectID.description)
          Text("·").foregroundStyle(.tertiary)
          Text(target.scope.worktreeID?.description ?? "Project root")
          Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)

        Divider()

        if let terminal {
          ClairTerminalViewRepresentable(
            session: terminal, target: target, composition: composition,
            failure: $failure
          )
          .accessibilityIdentifier("terminal-viewport")
        } else {
          Spacer()
        }

        if let failure {
          Label(failure, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.orange)
            .padding(.horizontal, 16)
            .accessibilityIdentifier("terminal-error")
        }

        Text("表示幅はこの端末だけのもの。PTYのcolumnsは変えない。")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
          .padding(.vertical, 7)

        VStack(spacing: 9) {
          HStack(spacing: 7) {
            keyButton("esc", .escape)
            keyButton("tab", .tab)
            keyButton("^C", .control("c"))
            Spacer()
            keyButton("↑", .up)
            keyButton("↓", .down)
          }
          HStack(spacing: 8) {
            TextField("", text: $draft)
              .font(.system(.body, design: .monospaced))
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .onSubmit(sendDraft)
              .accessibilityIdentifier("terminal-composer")
            Button(action: sendDraft) {
              Image(systemName: "arrow.right")
            }
            .accessibilityLabel("Send")
            .accessibilityIdentifier("terminal-send")
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.thinMaterial)
      }
      .navigationTitle(target.scope.sessionID?.description ?? "terminal")
      .navigationBarTitleDisplayMode(.inline)
      .task {
        guard terminal == nil, let surfaces = await composition.composedSurfaces() else {
          failure = "Not connected to a host."
          return
        }
        do {
          terminal = try ClairMobileTerminalSession(transport: surfaces.terminalTransport)
        } catch {
          failure = error.localizedDescription
        }
      }
      .onDisappear {
        let terminal = terminal
        Task { await terminal?.background() }
      }
    }

    private func keyButton(_ title: String, _ key: ClairTerminalKey) -> some View {
      Button(title) {
        let terminal = terminal
        Task { await terminal?.sendKey(key) }
      }
      .font(.system(.footnote, design: .monospaced))
      .buttonStyle(.bordered)
      .accessibilityIdentifier("terminal-key-\(title)")
    }

    private func sendDraft() {
      let text = draft
      draft = ""
      let terminal = terminal
      Task {
        if !text.isEmpty { await terminal?.sendKey(.text(text)) }
        await terminal?.sendKey(.return)
      }
    }
  }

  /// Hosts the UIKit `ClairTerminalView` and attaches it once the authenticated
  /// connection for the current generation is available.
  private struct ClairTerminalViewRepresentable: UIViewRepresentable {
    let session: ClairMobileTerminalSession
    let target: ClairRemoteTerminalSession
    let composition: ClairMobileConnectionComposition
    @Binding var failure: String?

    func makeUIView(context: Context) -> ClairTerminalView {
      let view = ClairTerminalView(session: session)
      Task { @MainActor in
        guard let authenticated = await composition.authenticatedSession() else {
          failure = "Not connected to a host."
          return
        }
        view.attach(
          scope: target.scope, generation: target.generation, connection: authenticated.connection)
      }
      return view
    }

    func updateUIView(_ view: ClairTerminalView, context: Context) {}
  }
#endif
