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

/// The reconnect controller is created once by `ClairV2MobileApp` (the
/// composition root) rather than locally by this view, so the same instance
/// receives both native push-delegate callbacks (device token, remote
/// notification payloads) and this view's scene-lifecycle/deep-link events.
private struct ClairV2MobileReconnectKey: EnvironmentKey {
  static let defaultValue = ClairV2MobileReconnectController()
}

extension EnvironmentValues {
  var clairV2MobileReconnect: ClairV2MobileReconnectController {
    get { self[ClairV2MobileReconnectKey.self] }
    set { self[ClairV2MobileReconnectKey.self] = newValue }
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
  @State private var pairingError: String?
  @State private var conversation = ClairV2MobileConversationController()
  @State private var conversationSnapshot = ClairV2MobileConversationState()
  @State private var conversationDraft = ""
  @State private var conversationError: String?
  @State private var diffReview = ClairV2MobileDiffReviewController()
  @State private var diffReviewSnapshot = ClairV2MobileDiffReviewState()
  @State private var diffReviewError: String?
  @Environment(\.clairV2MobileReconnect) private var reconnect
  @State private var reconnectState = ClairV2MobileReconnectState.idle
  @State private var reconnectError: String?
  @State private var hasProcessedLaunch = false

  var body: some View {
    NavigationStack {
      List {
        hostSection
        destinationBrowserSection
        conversationSection
        diffReviewSection
        reconnectSection
        connectionSection
        navigationSection
        surfaceSection
        buildSection
      }
      .navigationTitle("Clair v2 Mobile")
    }
    .onAppear {
      store.send(.sceneBecameActive)
      guard !hasProcessedLaunch else { return }
      hasProcessedLaunch = true
      // A cold launch with no deep link still runs through the same typed
      // reconnect state machine as any other foreground: the last cached
      // destination (if any) is re-verified against the host, never trusted
      // silently just because the process just started.
      dispatchReconnectEvent(.launched(deepLink: nil))
    }
    .onOpenURL { url in
      // A deep link handed to an already-running process is processed
      // exactly like a cold launch with that link: it is never trusted
      // without an independent host verification.
      guard let deepLink = try? ClairV2MobileDeepLink(url: url) else {
        reconnectError = ClairV2MobileReconnectError.invalidDeepLink.localizedDescription
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
        _ = await reconnect.registerPendingPushTokenIfNeeded(
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
  /// design. It only ever displays what `ClairV2MobileReconnectController`
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
  private func dispatchReconnectEvent(_ event: ClairV2MobileSceneEvent) {
    Task {
      reconnectState = await reconnect.handle(event)
    }
  }
}
