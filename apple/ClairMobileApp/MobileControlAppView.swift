import SwiftUI
import ClairMobileKit

private enum MobileAppTab: Hashable {
  case overview
  case sessions
  case activity
  case settings
}

struct MobileControlAppView: View {
  @ObservedObject var model: MobileControlAppModel
  @State private var selectedTab: MobileAppTab = .overview

  var body: some View {
    TabView(selection: $selectedTab) {
      NavigationStack {
        overview
      }
      .tabItem { Label("概要", systemImage: "rectangle.3.group") }
      .tag(MobileAppTab.overview)

      NavigationStack {
        sessions
      }
      .tabItem { Label("セッション", systemImage: "terminal") }
      .tag(MobileAppTab.sessions)

      NavigationStack {
        activity
      }
      .tabItem { Label("アクティビティ", systemImage: "waveform.path.ecg") }
      .tag(MobileAppTab.activity)

      NavigationStack {
        settings
      }
      .tabItem { Label("設定", systemImage: "gearshape") }
      .tag(MobileAppTab.settings)
    }
    .tint(MobileAppPalette.accent)
    .preferredColorScheme(.dark)
    .background(MobileAppPalette.canvas)
    .onOpenURL { model.receiveDeepLink($0) }
    .sheet(item: $model.pendingPairingLink) { link in
      PairingConfirmationView(model: model, link: link)
        .presentationDetents([.medium, .large])
    }
  }

  private var overview: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        MobilePageHeader(
          eyebrow: "PRIVATE NETWORK",
          title: "モバイル操作",
          subtitle: "Mac上のProjectとraw terminalを、同じsession identityで確認します。"
        )
        ConnectionStatusCard(model: model)
        if model.hosts.isEmpty {
          EmptyStateCard(
            icon: "qrcode.viewfinder",
            title: "Macからpairing linkを開く",
            message: "Clairの設定でQR / deep linkを生成し、このiPhoneまたはiPadで開いてください。"
          )
        } else {
          sessionSummary
          if model.canSpawnSession && !model.profiles.isEmpty && !model.projectOptions.isEmpty {
            AgentLaunchCard(model: model)
          }
          attentionAgents
        }
      }
      .padding(16)
    }
    .background(MobileAppPalette.canvas)
    .navigationTitle("概要")
    .toolbarBackground(MobileAppPalette.canvas, for: .navigationBar)
  }

  private var sessionSummary: some View {
    Button {
      selectedTab = .sessions
    } label: {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("セッション")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
          Text("Project / terminal catalog")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(MobileAppPalette.muted)
        }
        Spacer()
        Text("\(model.sessions.count)")
          .font(.system(size: 28, weight: .medium, design: .monospaced))
          .foregroundStyle(MobileAppPalette.accent)
        Image(systemName: "chevron.right")
          .foregroundStyle(MobileAppPalette.muted)
      }
      .mobileCard()
    }
    .buttonStyle(.plain)
  }

  private var attentionAgents: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("ATTENTION")
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundStyle(MobileAppPalette.muted)
      if model.agents.filter(\.attention).isEmpty {
        Text("現在、attention中のagentはありません。")
          .font(.system(size: 12))
          .foregroundStyle(MobileAppPalette.secondary)
          .mobileCard()
      } else {
        ForEach(model.agents.filter(\.attention)) { agent in
          AgentRow(model: model, agent: agent)
        }
      }
    }
  }

  private var sessions: some View {
    Group {
      if let selected = model.selectedSession {
        MobileTerminalView(model: model, session: selected)
      } else {
        sessionList
      }
    }
    .background(MobileAppPalette.canvas)
    .navigationTitle(model.selectedSession == nil ? "セッション" : "ターミナル")
    .toolbarBackground(MobileAppPalette.canvas, for: .navigationBar)
    .toolbar {
      if model.selectedSession != nil {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            model.disconnectSelectedSession()
          } label: {
            Image(systemName: "chevron.left")
          }
          .accessibilityLabel("セッション一覧に戻る")
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
          .disabled(!model.isConnected)
          .accessibilityLabel("更新")
      }
    }
  }

  private var sessionList: some View {
    Group {
      if model.sessions.isEmpty {
        EmptyStateCard(
          icon: "terminal",
          title: model.isConnected ? "セッションはありません" : "Macに接続してください",
          message: "接続後、Clairに表示されているterminal sessionがここに並びます。"
        )
        .padding(16)
      } else {
        List {
          ForEach(model.sessions) { session in
            Button { model.selectSession(session) } label: {
              SessionRow(session: session)
            }
            .buttonStyle(.plain)
            .listRowBackground(MobileAppPalette.canvas)
          }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
      }
    }
  }

  private var activity: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        MobilePageHeader(
          eyebrow: "ARRIVAL ORDER",
          title: "アクティビティ",
          subtitle: "terminal outputはbounded bufferに保持し、session終了後のtranscriptは保存しません。"
        )
        if let message = model.lastActivityMessage {
          ActivityEventRow(message: message, tone: .accent)
        }
        ForEach(model.agents) { agent in
          AgentRow(model: model, agent: agent)
        }
        if model.agents.isEmpty && model.lastActivityMessage == nil {
          EmptyStateCard(
            icon: "waveform.path.ecg",
            title: "まだイベントはありません",
            message: "session output、agent attention、操作結果がここに表示されます。"
          )
        }
      }
      .padding(16)
    }
    .background(MobileAppPalette.canvas)
    .navigationTitle("アクティビティ")
    .toolbarBackground(MobileAppPalette.canvas, for: .navigationBar)
  }

  private var settings: some View {
    List {
      Section {
        HStack {
          Circle()
            .fill(model.isConnected ? MobileAppPalette.green : MobileAppPalette.muted)
            .frame(width: 8, height: 8)
          VStack(alignment: .leading, spacing: 3) {
            Text("モバイル接続")
              .font(.system(size: 14, weight: .semibold))
            Text(model.connectionPhase.title)
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(MobileAppPalette.secondary)
          }
          Spacer()
          if model.isConnected {
            Button("切断") { model.disconnect() }
              .buttonStyle(.bordered)
          }
        }
        if let fingerprint = model.hostFingerprint {
          LabeledContent("Host fingerprint", value: fingerprint)
            .font(.system(size: 11, design: .monospaced))
        }
        if let endpoint = model.endpointDescription {
          LabeledContent("Endpoint", value: endpoint)
            .font(.system(size: 11, design: .monospaced))
        }
        Text("Cloudflare / Tailscaleのprivate routeは、この認証済みendpointの外側に置かれます。viewportはMacのPTY resizeへ送りません。")
          .font(.system(size: 11))
          .foregroundStyle(MobileAppPalette.secondary)
      } header: {
        Text("接続")
      }
      .listRowBackground(MobileAppPalette.surface)

      Section {
        ForEach(model.hosts) { host in
          SavedHostRow(model: model, host: host)
        }
        if model.hosts.isEmpty {
          Text("保存済みhostはありません")
            .foregroundStyle(MobileAppPalette.secondary)
        }
      } header: {
        Text("保存済み Mac")
      }
      .listRowBackground(MobileAppPalette.surface)

      Section {
        ScopeRow(scopes: model.grantedScopes)
      } header: {
        Text("権限")
      }
      .listRowBackground(MobileAppPalette.surface)

      if let error = model.lastErrorMessage {
        Section {
          Text(error)
            .font(.system(size: 11))
            .foregroundStyle(MobileAppPalette.orange)
        } header: {
          Text("STATUS")
        }
        .listRowBackground(MobileAppPalette.surface)
      }
    }
    .scrollContentBackground(.hidden)
    .background(MobileAppPalette.canvas)
    .navigationTitle("設定")
    .toolbarBackground(MobileAppPalette.canvas, for: .navigationBar)
  }
}

private struct PairingConfirmationView: View {
  @ObservedObject var model: MobileControlAppModel
  let link: MobilePairingLink

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          MobilePageHeader(
            eyebrow: "ONE-TIME PAIRING",
            title: "このMacをペアリング",
            subtitle: "秘密情報は表示せず、host fingerprintだけを確認して接続します。"
          )
          VStack(alignment: .leading, spacing: 12) {
            PairingValueRow(title: "Endpoint", value: link.endpoint)
            PairingValueRow(title: "Host fingerprint", value: link.hostIdentity.fingerprint)
            PairingValueRow(title: "Transport", value: link.transport.rawValue)
            Text("期限 \(link.expiresAt.formatted(date: .omitted, time: .shortened))")
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(MobileAppPalette.muted)
          }
          .mobileCard()

          VStack(alignment: .leading, spacing: 8) {
            Text("このfingerprintがMac側の表示と一致することを確認")
              .font(.system(size: 13, weight: .medium))
            Toggle("確認しました", isOn: $model.pairingConfirmedFingerprint)
              .tint(MobileAppPalette.accent)
          }
          .mobileCard()

          TextField("端末名", text: $model.pairingDisplayName)
            .textInputAutocapitalization(.words)
            .textFieldStyle(.roundedBorder)

          Button {
            model.pairPendingHost()
          } label: {
            Label("接続してpair", systemImage: "link.badge.plus")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .disabled(!model.pairingConfirmedFingerprint || model.connectionPhase == .connecting)
        }
        .padding(20)
      }
      .background(MobileAppPalette.canvas)
      .navigationTitle("Pairing")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("キャンセル") { model.cancelPairing() }
        }
      }
    }
  }
}

private struct MobileTerminalView: View {
  @ObservedObject var model: MobileControlAppModel
  let session: MobileSessionDescriptor
  @State private var input = ""

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text(session.title)
          .font(.system(size: 14, weight: .semibold))
        HStack(spacing: 8) {
          Text(session.lifecycle.rawValue.uppercased())
            .foregroundStyle(session.lifecycle == .running ? MobileAppPalette.green : MobileAppPalette.orange)
          Text(session.cwd)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(MobileAppPalette.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(MobileAppPalette.surface)

      ScrollView {
        Text(model.selectedTerminalText.isEmpty ? "接続を待っています…" : model.selectedTerminalText)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(MobileAppPalette.terminalText)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(14)
      }
      .background(Color.black.opacity(0.32))
      .overlay(alignment: .topLeading) {
        if model.selectedHasGap {
          Label("gap: 再接続して再同期", systemImage: "exclamationmark.triangle")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(MobileAppPalette.orange)
            .padding(8)
        }
      }

      VStack(spacing: 8) {
        if let profileID = session.agentProfileID {
          HStack(spacing: 8) {
            Text("コマンド")
              .font(.system(size: 10, design: .monospaced))
              .foregroundStyle(MobileAppPalette.secondary)
            Button("モデル") {
              model.sendInput(profileID == "opencode" ? "/models" : "/model")
            }
            .buttonStyle(.bordered)
            Button("状態") { model.sendInput("/status") }
              .buttonStyle(.bordered)
            Spacer()
          }
          .disabled(!model.canWriteTerminal || model.selectedExited)
        }
        HStack(alignment: .bottom, spacing: 8) {
          TextField("ターミナル入力", text: $input, axis: .vertical)
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
            .disabled(!model.canWriteTerminal || model.selectedExited)
          Button("送信") {
            model.sendInput(input)
            input = ""
          }
          .buttonStyle(.borderedProminent)
          .disabled(input.isEmpty || !model.canWriteTerminal || model.selectedExited)
        }
        HStack {
          Label("cursor \(model.selectedCursor)", systemImage: "arrow.right")
          Spacer()
          Text(model.canWriteTerminal ? "write enabled" : "view only")
          Button("割り込み") { model.interruptSelectedSession() }
            .buttonStyle(.bordered)
            .disabled(!model.canSignal || model.selectedExited)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(MobileAppPalette.secondary)
      }
      .padding(12)
      .background(MobileAppPalette.surface)
    }
    .background(MobileAppPalette.canvas)
  }
}

private struct ConnectionStatusCard: View {
  @ObservedObject var model: MobileControlAppModel

  var body: some View {
    HStack(spacing: 12) {
      Circle()
        .fill(model.isConnected ? MobileAppPalette.green : MobileAppPalette.muted)
        .frame(width: 10, height: 10)
      VStack(alignment: .leading, spacing: 3) {
        Text(model.connectionPhase.title)
          .font(.system(size: 13, weight: .semibold))
        Text(model.endpointDescription ?? "QR / deep linkから接続を開始")
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(MobileAppPalette.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      if model.isConnected {
        Image(systemName: "lock.fill")
          .foregroundStyle(MobileAppPalette.green)
          .accessibilityLabel("認証済み")
      }
    }
    .mobileCard()
  }
}

private struct SessionRow: View {
  let session: MobileSessionDescriptor

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: session.agentProfileID == nil ? "terminal" : "cpu")
        .foregroundStyle(MobileAppPalette.accent)
      VStack(alignment: .leading, spacing: 4) {
        Text(session.title)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(MobileAppPalette.primary)
        Text(session.cwd)
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(MobileAppPalette.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      Text(session.lifecycle.rawValue)
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(session.lifecycle == .running ? MobileAppPalette.green : MobileAppPalette.orange)
    }
    .padding(.vertical, 7)
  }
}

private struct AgentRow: View {
  @ObservedObject var model: MobileControlAppModel
  let agent: MobileAgentDescriptor

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: agent.attention ? "bell.badge" : "cpu")
          .foregroundStyle(agent.attention ? MobileAppPalette.orange : MobileAppPalette.accent)
        VStack(alignment: .leading, spacing: 3) {
          Text(agent.title)
            .font(.system(size: 13, weight: .medium))
          Text(
            [agent.state.rawValue, agent.profileID, agent.modelID]
              .compactMap { $0 }
              .joined(separator: " · ")
          )
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(MobileAppPalette.secondary)
        }
        Spacer()
        if agent.attention {
          Text("attention")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(MobileAppPalette.orange)
        }
      }
      HStack {
        Text(agent.cwd)
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(MobileAppPalette.muted)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        if model.canSteerAgent {
          Menu("コマンド") {
            Button("モデルを変更…") {
              model.sendAgentCommand(agent.profileID == "opencode" ? "/models" : "/model", to: agent)
            }
            Button("状態を表示") {
              model.sendAgentCommand("/status", to: agent)
            }
          }
        }
        if model.grantedScopes.contains(.signal) {
          Button("割り込み") { model.controlAgent(agent, action: .interrupt) }
            .buttonStyle(.borderless)
        }
        if model.grantedScopes.contains(.terminate) {
          Button("停止") { model.controlAgent(agent, action: .stop) }
            .buttonStyle(.borderless)
            .foregroundStyle(MobileAppPalette.orange)
        }
      }
    }
    .mobileCard()
  }
}

private struct AgentLaunchCard: View {
  @ObservedObject var model: MobileControlAppModel
  @State private var selectedProfileID: String?
  @State private var selectedProjectID: UUID?
  @State private var selectedModelChoice = "__default"
  @State private var customModelID = ""

  private static let defaultModelChoice = "__default"
  private static let customModelChoice = "__custom"

  private var selectedProfile: MobileAgentProfileDescriptor? {
    guard let selectedProfileID else { return nil }
    return model.profiles.first { $0.id == selectedProfileID }
  }

  private var selectedModelID: String? {
    switch selectedModelChoice {
    case Self.defaultModelChoice:
      return nil
    case Self.customModelChoice:
      let value = customModelID.trimmingCharacters(in: .whitespacesAndNewlines)
      return value.isEmpty ? nil : value
    default:
      return selectedModelChoice
    }
  }

  private var hasValidModelSelection: Bool {
    selectedModelChoice != Self.customModelChoice || selectedModelID != nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("REGISTERED AGENT")
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundStyle(MobileAppPalette.accent)
      Text("新しいsessionを起動")
        .font(.system(size: 14, weight: .semibold))
      Text("Mac側に登録されたprofileだけを選択できます。")
        .font(.system(size: 11))
        .foregroundStyle(MobileAppPalette.secondary)

      Picker("profile", selection: $selectedProfileID) {
        Text("profileを選択").tag(String?.none)
        ForEach(model.profiles) { profile in
          Text(profile.title).tag(Optional(profile.id))
        }
      }
      .pickerStyle(.menu)

      if let selectedProfile {
        Picker("model", selection: $selectedModelChoice) {
          Text("設定済みのデフォルト").tag(Self.defaultModelChoice)
          ForEach(selectedProfile.models) { model in
            Text(model.title).tag(model.id)
          }
          Text("カスタムmodel ID…").tag(Self.customModelChoice)
        }
        .pickerStyle(.menu)

        if selectedModelChoice == Self.customModelChoice {
          TextField("provider/model または model ID", text: $customModelID)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
      }

      Picker("project", selection: $selectedProjectID) {
        Text("projectを選択").tag(UUID?.none)
        ForEach(model.projectOptions) { project in
          Text(project.title).tag(Optional(project.id))
        }
      }
      .pickerStyle(.menu)

      Button {
        guard let selectedProfile, let selectedProjectID else { return }
        model.launch(
          profile: selectedProfile,
          modelID: selectedModelID,
          projectID: selectedProjectID
        )
      } label: {
        Label("起動を要求", systemImage: "play.fill")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .disabled(selectedProfile == nil || selectedProjectID == nil || !hasValidModelSelection)
    }
    .mobileCard()
    .onAppear(perform: synchronizeSelection)
    .onChange(of: model.profiles) { _, _ in synchronizeSelection() }
    .onChange(of: selectedProfileID) { _, _ in
      selectedModelChoice = Self.defaultModelChoice
      customModelID = ""
    }
    .onChange(of: model.projectOptions) { _, _ in synchronizeSelection() }
  }

  private func synchronizeSelection() {
    if selectedProfile == nil {
      selectedProfileID = model.profiles.first?.id
    }
    if selectedProjectID == nil || !model.projectOptions.contains(where: { $0.id == selectedProjectID }) {
      selectedProjectID = model.projectOptions.first?.id
    }
  }
}

private struct SavedHostRow: View {
  @ObservedObject var model: MobileControlAppModel
  let host: MobileClientHostRecord

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(host.hostIdentity.fingerprint)
            .font(.system(size: 11, design: .monospaced))
          Text(host.endpoint.address)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(MobileAppPalette.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Spacer()
        if model.connectedHost?.hostIdentity.hostID == host.hostIdentity.hostID {
          Text("active")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(MobileAppPalette.green)
        }
      }
      HStack {
        Text(host.credential.scopes.map(\.rawValue).sorted().joined(separator: " / "))
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(MobileAppPalette.muted)
        Spacer()
        Button("接続") { model.connect(to: host) }
          .buttonStyle(.borderless)
          .disabled(model.connectionPhase == .connecting)
        Button("削除") { model.forget(host) }
          .buttonStyle(.borderless)
          .foregroundStyle(MobileAppPalette.orange)
      }
    }
  }
}

private struct ScopeRow: View {
  let scopes: Set<MobileControlScope>

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(scopes.isEmpty ? "未接続" : scopes.map(\.rawValue).sorted().joined(separator: " / "))
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(MobileAppPalette.secondary)
      Text("scopeはMac側のdevice grantで管理されます。デフォルトはviewのみです。")
        .font(.system(size: 11))
        .foregroundStyle(MobileAppPalette.muted)
    }
  }
}

private struct ActivityEventRow: View {
  enum Tone { case accent }
  let message: String
  let tone: Tone

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Circle()
        .fill(tone == .accent ? MobileAppPalette.accent : MobileAppPalette.muted)
        .frame(width: 7, height: 7)
        .padding(.top, 4)
      Text(message)
        .font(.system(size: 12))
        .foregroundStyle(MobileAppPalette.primary)
      Spacer()
    }
    .mobileCard()
  }
}

private struct PairingValueRow: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title.uppercased())
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(MobileAppPalette.muted)
      Text(value)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(MobileAppPalette.primary)
        .textSelection(.enabled)
    }
  }
}

private struct MobilePageHeader: View {
  let eyebrow: String
  let title: String
  let subtitle: String

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(eyebrow)
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundStyle(MobileAppPalette.accent)
      Text(title)
        .font(.system(size: 27, weight: .semibold, design: .rounded))
        .foregroundStyle(MobileAppPalette.primary)
      Text(subtitle)
        .font(.system(size: 12))
        .foregroundStyle(MobileAppPalette.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct EmptyStateCard: View {
  let icon: String
  let title: String
  let message: String

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Image(systemName: icon)
        .font(.system(size: 22))
        .foregroundStyle(MobileAppPalette.accent)
      Text(title)
        .font(.system(size: 14, weight: .semibold))
      Text(message)
        .font(.system(size: 12))
        .foregroundStyle(MobileAppPalette.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .mobileCard()
  }
}

private enum MobileAppPalette {
  static let canvas = Color(red: 0.055, green: 0.059, blue: 0.071)
  static let surface = Color(red: 0.095, green: 0.102, blue: 0.121)
  static let primary = Color(red: 0.91, green: 0.92, blue: 0.94)
  static let secondary = Color(red: 0.60, green: 0.63, blue: 0.68)
  static let muted = Color(red: 0.38, green: 0.41, blue: 0.47)
  static let terminalText = Color(red: 0.80, green: 0.84, blue: 0.86)
  static let accent = Color(red: 0.47, green: 0.72, blue: 0.98)
  static let green = Color(red: 0.35, green: 0.82, blue: 0.58)
  static let orange = Color(red: 0.95, green: 0.61, blue: 0.34)
}

private extension View {
  func mobileCard() -> some View {
    padding(13)
      .background(MobileAppPalette.surface, in: RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .stroke(Color.white.opacity(0.08), lineWidth: 1)
      }
  }
}
