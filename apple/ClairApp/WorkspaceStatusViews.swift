import AppKit
import SwiftUI

// MARK: - Status Bar

/// The one status bar, 26px tall. Branch and working-tree state on the left,
/// then the screen's own context, then the tightest agent's quota — which the
/// Settings artboard makes a preference — and the session count.
struct WorkspaceStatusBar: View {
  let workspace: ProjectWorkspaceModel
  let project: Project
  let surface: ProjectSurfaceModel
  @ObservedObject var agentWorkflow: AgentWorkflowCoordinator
  @ObservedObject var agentRateLimits: AgentRateLimitCoordinator
  let onOpenAgents: () -> Void
  @AppStorage("clair.agents.show-rate-limits-v1") private var showRateLimits = true

  var body: some View {
    HStack(spacing: 10) {
      branchState
      screenContext

      Spacer(minLength: 8)

      if showRateLimits {
        AgentRateLimitStrip(coordinator: agentRateLimits)
        separator
      }
      sessionCount
    }
    .padding(.horizontal, 12)
    .frame(
      maxWidth: .infinity,
      minHeight: WorkspaceChrome.Metrics.statusBar,
      maxHeight: WorkspaceChrome.Metrics.statusBar,
      alignment: .leading
    )
    .font(WorkspaceChrome.chromeFont(size: 11))
    .foregroundStyle(WorkspaceChrome.textTertiary)
    .background(WorkspaceChrome.chrome)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(WorkspaceChrome.chromeLine)
        .frame(height: 1)
    }
    .onAppear {
      if showRateLimits {
        agentRateLimits.start()
      }
    }
    .onChange(of: showRateLimits) { _, isEnabled in
      if isEnabled {
        agentRateLimits.start()
      } else {
        agentRateLimits.stop()
      }
    }
    .onDisappear {
      agentRateLimits.stop()
    }
  }

  private var separator: some View {
    Text("·").foregroundStyle(WorkspaceChrome.divider)
  }

  @ViewBuilder
  private var branchState: some View {
    if let gitStatus = surface.gitStatus, gitStatus.isRepository {
      HStack(spacing: 5) {
        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: 11, weight: .medium))
        Text(gitStatus.branch ?? "HEAD")
          .lineLimit(1)
      }
      Text("↓\(gitStatus.behind) ↑\(gitStatus.ahead)")
        .monospaced()
        .font(WorkspaceChrome.chromeFont(size: 10))
        .foregroundStyle(WorkspaceChrome.textMuted)
      Text("\(gitStatus.changes.count) 変更")
    } else {
      Text(project.rootURL.path)
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundStyle(WorkspaceChrome.textQuaternary)
    }
  }

  /// What the current screen contributes: the file in the focused pane, the
  /// file under review in source control, the running agents in activity.
  @ViewBuilder
  private var screenContext: some View {
    switch surface.workspaceActivity {
    case .files, .search, .review:
      if let tab = surface.activeTab(in: surface.focusedPaneID) {
        separator
        Text(tab.title).lineLimit(1).truncationMode(.middle)
      }
    case .git:
      if let diff = surface.selectedGitDiff {
        separator
        Text(diff.change.path)
          .monospaced()
          .font(WorkspaceChrome.chromeFont(size: 10))
          .foregroundStyle(WorkspaceChrome.textMuted)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    case .debug:
      separator
      if let location = surface.debugSession.currentLocation {
        Text("\(URL(fileURLWithPath: location.path).lastPathComponent):\(location.line)")
          .lineLimit(1)
          .truncationMode(.middle)
      } else {
        Text("Debug")
          .lineLimit(1)
      }
    case .activity:
      let live = agentWorkflow.sessions.filter { $0.projectID == project.id && $0.isActive }
        .count
      if live > 0 {
        separator
        Text("\(live) 実行中").foregroundStyle(WorkspaceChrome.success)
      }
    }
  }

  private var sessionCount: some View {
    let sessions = agentWorkflow.sessions.filter { $0.projectID == project.id }
    return Button(action: onOpenAgents) {
      Text("\(sessions.count) セッション")
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(WorkspaceChrome.textTertiary)
    .help("Agent追加画面を開く")
  }
}

struct AgentRateLimitStrip: View {
  @ObservedObject var coordinator: AgentRateLimitCoordinator

  var body: some View {
    HStack(spacing: 8) {
      ForEach(AgentRateLimitProvider.allCases) { provider in
        AgentRateLimitChip(provider: provider, coordinator: coordinator)
      }
    }
  }
}

struct AgentRateLimitChip: View {
  let provider: AgentRateLimitProvider
  @ObservedObject var coordinator: AgentRateLimitCoordinator
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      // The Tokens artboard's QUOTA METER: one line — label, a 34x4 bar, the
      // remaining figure. The full per-window breakdown is in the popover, so
      // the status bar can stay 26px tall.
      HStack(spacing: 6) {
        AgentVendorIcon(provider: provider)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
          .frame(width: 13)

        Text(summaryTitle)
          .font(WorkspaceChrome.chromeFont(size: 10))
          .foregroundStyle(WorkspaceChrome.textMuted)

        if let window = snapshot?.primaryWindow {
          AgentRateLimitMeter(usedPercent: window.usedPercent)
            .frame(width: 34, height: 4)
          Text("残り\(window.remainingPercent)%")
            .font(WorkspaceChrome.chromeFont(size: 10, weight: .semibold))
            .monospaced()
            .foregroundStyle(meterTint(remaining: window.remainingPercent))
        } else if coordinator.phase == .loading, snapshot == nil {
          ProgressView()
            .controlSize(.mini)
            .scaleEffect(0.6)
            .frame(width: 14, height: 14)
        } else {
          Text("—")
            .font(WorkspaceChrome.chromeFont(size: 10))
            .foregroundStyle(summaryDetailColor)
        }
      }
      .padding(.horizontal, 6)
      .frame(height: 20)
      .background(
        isPresented ? WorkspaceChrome.surfaceHover : Color.clear,
        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("\(provider.displayName)の使用量を表示")
    .accessibilityLabel("\(provider.displayName)の使用量")
    .accessibilityValue(summaryDetail)
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      AgentRateLimitPopover(coordinator: coordinator, selectedProvider: provider)
    }
  }

  /// The remaining figure is the one number allowed to carry colour here, and
  /// only once the quota is actually tight.
  private func meterTint(remaining: Int) -> Color {
    if remaining <= 10 {
      return WorkspaceChrome.danger
    }
    if remaining <= 25 {
      return WorkspaceChrome.attention
    }
    return WorkspaceChrome.textSecondary
  }

  private var snapshot: AgentRateLimitSnapshot? {
    coordinator.snapshot(for: provider)
  }

  private var summaryTitle: String {
    provider.shortName
  }

  private var summaryDetail: String {
    if let snapshot, !snapshot.windows.isEmpty {
      return snapshot.windows.prefix(2).map { window in
        "\(window.displayName) 残り\(window.remainingPercent)%"
      }.joined(separator: " · ")
    }
    if let detail = snapshot?.detail ?? snapshot?.planType {
      return detail
    }
    if coordinator.failureMessage(for: provider) != nil {
      return "使用量を取得できません"
    }
    switch coordinator.phase {
    case .idle, .loading:
      return "使用量を取得中…"
    case .loaded:
      return "使用量はありません"
    case .failed:
      return "使用量を取得できません"
    }
  }

  private var summaryDetailColor: Color {
    if coordinator.failureMessage(for: provider) != nil {
      return WorkspaceChrome.attention
    }
    return WorkspaceChrome.textQuaternary
  }
}

struct AgentRateLimitPopover: View {
  @ObservedObject var coordinator: AgentRateLimitCoordinator
  let selectedProvider: AgentRateLimitProvider
  @State private var mode = AgentRateLimitDisplayMode.detail

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("使用量")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.textPrimary)
        Spacer()
        Button {
          coordinator.refresh()
        } label: {
          if coordinator.phase == .loading {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "arrow.clockwise")
          }
        }
        .buttonStyle(.plain)
        .frame(width: 26, height: 26)
        .disabled(coordinator.phase == .loading)
        .help("使用量を更新")
        .accessibilityLabel("使用量を更新")
      }
      .padding(.horizontal, 14)
      .frame(height: 44)

      Picker("表示", selection: $mode) {
        ForEach(AgentRateLimitDisplayMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .controlSize(.small)
      .padding(.horizontal, 12)
      .padding(.bottom, 9)

      Divider().overlay(WorkspaceChrome.border)

      if coordinator.snapshots.isEmpty, coordinator.phase == .loading {
        emptyState
      } else {
        ForEach(AgentRateLimitProvider.allCases) { provider in
          if let snapshot = coordinator.snapshot(for: provider) {
            AgentRateLimitRow(
              snapshot: snapshot,
              mode: mode,
              isSelected: provider == selectedProvider
            )
          } else {
            AgentRateLimitUnavailableRow(
              provider: provider,
              message: coordinator.failureMessage(for: provider) ?? "使用量データはありません",
              isSelected: provider == selectedProvider
            )
          }
          if provider != AgentRateLimitProvider.allCases.last {
            Divider().overlay(WorkspaceChrome.border)
          }
        }
      }

      if let fetchedAt = coordinator.snapshots.map(\.fetchedAt).max() {
        Divider().overlay(WorkspaceChrome.border)
        Text("最終更新 \(fetchedAt.formatted(date: .omitted, time: .shortened))")
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14)
          .frame(height: 34)
      }
    }
    .frame(width: 420)
    .background(WorkspaceChrome.chromeRaised)
    .preferredColorScheme(.dark)
  }

  @ViewBuilder
  private var emptyState: some View {
    VStack(spacing: 10) {
      if coordinator.phase == .loading {
        ProgressView()
          .controlSize(.small)
        Text("Agentから使用量を取得しています…")
          .foregroundStyle(WorkspaceChrome.textTertiary)
      } else if case .failed(let message) = coordinator.phase {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(WorkspaceChrome.attention)
        Text(message)
          .multilineTextAlignment(.center)
          .foregroundStyle(WorkspaceChrome.textTertiary)
        Button("再試行") {
          coordinator.refresh()
        }
        .controlSize(.small)
      } else {
        Text("使用量データはありません")
          .foregroundStyle(WorkspaceChrome.textTertiary)
      }
    }
    .font(.system(size: 11))
    .frame(maxWidth: .infinity, minHeight: 112)
    .padding(16)
  }
}

enum AgentRateLimitDisplayMode: String, CaseIterable, Identifiable {
  case detail
  case compact

  var id: String { rawValue }

  var title: String {
    switch self {
    case .detail: "詳細"
    case .compact: "コンパクト"
    }
  }
}

struct AgentRateLimitRow: View {
  let snapshot: AgentRateLimitSnapshot
  let mode: AgentRateLimitDisplayMode
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 10) {
      ZStack {
        Circle()
          .fill(WorkspaceChrome.surfaceHover)
        Circle()
          .stroke(WorkspaceChrome.border, lineWidth: 1)
        AgentVendorIcon(provider: provider)
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.textSecondary)
      }
      .frame(width: 21, height: 21)

      VStack(alignment: .leading, spacing: 4) {
        Text(snapshot.displayName)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.textPrimary)
          .lineLimit(1)
        if let secondaryText {
          Text(secondaryText)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(WorkspaceChrome.textTertiary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if snapshot.windows.isEmpty {
        Text(snapshot.planType ?? "—")
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
      } else {
        VStack(spacing: 6) {
          ForEach(snapshot.windows) { window in
            HStack(spacing: 6) {
              Text(window.displayName)
                .frame(width: 34, alignment: .leading)
                .foregroundStyle(WorkspaceChrome.textQuaternary)
              AgentRateLimitMeter(usedPercent: window.usedPercent)
                .frame(width: 64, height: 5)
              Text(valueText(for: window))
                .frame(width: 54, alignment: .trailing)
                .foregroundStyle(WorkspaceChrome.textTertiary)
            }
            .font(.system(size: 10, design: .monospaced))
          }
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 11)
    .frame(minHeight: 72)
    .background(isSelected ? WorkspaceChrome.surfaceHover : Color.clear)
  }

  private var provider: AgentRateLimitProvider? {
    AgentRateLimitProvider(rawValue: snapshot.id)
  }

  private var secondaryText: String? {
    snapshot.detail ?? snapshot.primaryWindow?.resetDescription() ?? snapshot.planType
  }

  private func valueText(for window: AgentRateLimitWindow) -> String {
    switch mode {
    case .detail:
      "残り \(window.remainingPercent)%"
    case .compact:
      "\(Int(window.usedPercent.rounded()))%"
    }
  }
}

struct AgentRateLimitUnavailableRow: View {
  let provider: AgentRateLimitProvider
  let message: String
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 10) {
      ZStack {
        Circle()
          .fill(WorkspaceChrome.surfaceHover)
        Circle()
          .stroke(WorkspaceChrome.border, lineWidth: 1)
        AgentVendorIcon(provider: provider)
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.textSecondary)
      }
      .frame(width: 21, height: 21)

      VStack(alignment: .leading, spacing: 4) {
        Text(provider.displayName)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.textPrimary)
        Text(message)
          .font(.system(size: 10))
          .foregroundStyle(WorkspaceChrome.attention)
          .lineLimit(2)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 11)
    .frame(minHeight: 72)
    .background(isSelected ? WorkspaceChrome.surfaceHover : Color.clear)
  }
}

struct AgentRateLimitMeter: View {
  let usedPercent: Double

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(WorkspaceChrome.borderStrong)
        Capsule()
          .fill(meterColor)
          .frame(width: geometry.size.width * usedPercent / 100)
      }
    }
    .accessibilityHidden(true)
  }

  private var meterColor: Color {
    switch usedPercent {
    case 90...:
      WorkspaceChrome.danger
    case 75...:
      WorkspaceChrome.attention
    default:
      WorkspaceChrome.textTertiary
    }
  }
}
