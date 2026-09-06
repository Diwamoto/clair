import AppKit
import CoreImage
import SwiftUI

enum WorkspaceSettingsSection: String, CaseIterable, Identifiable {
  case general
  case agents
  case editor
  case terminal
  case mobile
  case updates

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general:
      "一般"
    case .agents:
      "AIプロバイダー"
    case .editor:
      "エディタ"
    case .terminal:
      "ターミナル"
    case .mobile:
      "モバイル"
    case .updates:
      "アップデート"
    }
  }

  var description: String {
    switch self {
    case .general:
      "ワークスペースの基本動作とアプリ全体の表示を設定します。"
    case .agents:
      "エージェントの既定値、モデル、接続先を管理します。"
    case .editor:
      "コードの編集、検索、差分表示に関する設定です。"
    case .terminal:
      "ターミナルの配置、シェル、セッションの扱いを設定します。"
    case .mobile:
      "モバイル端末からワークスペースへ接続するための設定です。"
    case .updates:
      "Clair とエージェント連携の更新を確認します。"
    }
  }

  var symbolName: String {
    switch self {
    case .general:
      "slider.horizontal.3"
    case .agents:
      "sparkles"
    case .editor:
      "chevron.left.forwardslash.chevron.right"
    case .terminal:
      "terminal"
    case .mobile:
      "iphone"
    case .updates:
      "arrow.triangle.2.circlepath"
    }
  }

  var searchText: String {
    "\(title) \(description)"
  }
}

struct WorkspaceSettingsView: View {
  @ObservedObject var workspace: ProjectWorkspaceModel
  @ObservedObject var agentWorkflow: AgentWorkflowCoordinator
  @ObservedObject var mobileBridge: MobileControlRuntimeBridge
  @ObservedObject var updater: ClairUpdateCoordinator
  let onDismiss: () -> Void

  @State private var section: WorkspaceSettingsSection = .general
  @State private var query = ""

  @AppStorage("clair.general.language-v1") private var language = "ja-JP"
  @AppStorage("clair.general.theme-v1") private var theme = "one-dark"
  @AppStorage("clair.workspace.restore-layout-v1") private var restoreLayout = true
  @AppStorage("clair.workspace.confirm-close-v1") private var confirmClose = true
  @AppStorage("clair.workspace.status-footer-v1") private var showStatusFooter = true
  @AppStorage("clair.agents.default-agent-v1") private var defaultAgent = "codex"
  @AppStorage("clair.agents.codex-model-v1") private var codexModel = "gpt-5.6"
  @AppStorage("clair.agents.claude-command-v1") private var claudeCommand = "claude"
  @AppStorage("clair.agents.opencode-command-v1") private var opencodeCommand = "opencode"
  @AppStorage("clair.agents.show-rate-limits-v1") private var showRateLimits = true
  @AppStorage("clair.editor.font-size-v2") private var editorFontSize = 13.0
  @AppStorage("clair.editor.line-height-v1") private var editorLineHeight = 1.8
  @AppStorage("clair.editor.word-wrap-v1") private var wordWrap = false
  @AppStorage("clair.editor.minimap-v1") private var showMinimap = false
  @AppStorage("clair.editor.format-on-save-v1") private var formatOnSave = true
  @AppStorage("clair.editor.inline-diff-v1") private var inlineDiff = true
  @AppStorage("clair.terminal.default-shell-v1") private var defaultShell = "claude"
  @AppStorage("clair.terminal.position-v1") private var terminalPosition = "right"
  @AppStorage("clair.terminal.font-size-v1") private var terminalFontSize = 13.0
  @AppStorage("clair.terminal.preserve-sessions-v1") private var preserveSessions = true
  @AppStorage("clair.terminal.confirm-destructive-v1") private var confirmDestructiveCommands = true
  @AppStorage("clair.mobile.display-name-v1") private var mobileDisplayName = "Daiki の Clair"
  @AppStorage("clair.mobile.notifications-v1") private var mobileNotifications = true
  @AppStorage("clair.mobile.cellular-v1") private var mobileCellular = false
  @AppStorage("clair.mobile.show-agent-status-v1") private var mobileShowsAgentStatus = true
  @AppStorage("clair.mobile.allow-terminal-input-v1") private var mobileAllowsTerminalInput = false
  @AppStorage("clair.updates.automatic-checks-v1") private var automaticUpdateChecks = true
  @AppStorage("clair.updates.channel-v1") private var updateChannel = "stable"
  @AppStorage("clair.updates.agent-previews-v1") private var includeAgentPreviews = false

  private var visibleSections: [WorkspaceSettingsSection] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedQuery.isEmpty else {
      return WorkspaceSettingsSection.allCases
    }
    return WorkspaceSettingsSection.allCases.filter {
      $0.searchText.localizedCaseInsensitiveContains(normalizedQuery)
    }
  }

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Rectangle()
        .fill(WorkspaceChrome.border)
        .frame(width: 1)
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(WorkspaceChrome.canvas)
    .foregroundStyle(WorkspaceChrome.textPrimary)
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: onDismiss) {
        HStack(spacing: 6) {
          Image(systemName: "chevron.left")
            .font(.system(size: 10, weight: .semibold))
          Text("エディタに戻る")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.tactile)
      .foregroundStyle(WorkspaceChrome.textTertiary)
      .accessibilityLabel("エディタに戻る")

      TextField("設定を検索", text: $query)
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .padding(.top, 24)
        .accessibilityLabel("設定を検索")

      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 3) {
          Text("ワークスペース")
            .font(WorkspaceChrome.chromeFont(size: 11, weight: .medium))
            .foregroundStyle(WorkspaceChrome.textQuaternary)
            .padding(.horizontal, 10)
            .padding(.top, 22)
            .padding(.bottom, 5)

          ForEach(visibleSections) { item in
            Button {
              section = item
            } label: {
              HStack(spacing: 9) {
                Image(systemName: item.symbolName)
                  .font(.system(size: 11, weight: .medium))
                  .frame(width: 16)
                  .foregroundStyle(
                    section == item ? WorkspaceChrome.textSecondary : WorkspaceChrome.textQuaternary
                  )
                Text(item.title)
                  .font(WorkspaceChrome.chromeFont(size: 13))
                  .foregroundStyle(
                    section == item ? WorkspaceChrome.textPrimary : WorkspaceChrome.textSecondary
                  )
                Spacer(minLength: 0)
              }
              .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
              .padding(.horizontal, 10)
              .background(
                section == item ? WorkspaceChrome.surfaceActive : .clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
              )
              .overlay {
                if section == item {
                  RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(WorkspaceChrome.border, lineWidth: 1)
                }
              }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(section == item ? .isSelected : [])
          }

          if visibleSections.isEmpty {
            Text("設定が見つかりません")
              .font(WorkspaceChrome.chromeFont(size: 11))
              .foregroundStyle(WorkspaceChrome.textQuaternary)
              .padding(10)
          }
        }
      }
      .padding(.top, 1)

      Spacer(minLength: 18)

      VStack(alignment: .leading, spacing: 4) {
        Text("Clair")
          .font(WorkspaceChrome.chromeFont(size: 12, weight: .medium))
          .foregroundStyle(WorkspaceChrome.textSecondary)
        Text("ワークスペースの設定")
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 10)
      .padding(.top, 16)
      .overlay(alignment: .top) {
        Rectangle()
          .fill(WorkspaceChrome.border)
          .frame(height: 1)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 18)
    .frame(width: 218)
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .background(WorkspaceChrome.surface)
  }

  private var content: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 0) {
          Text("設定")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(WorkspaceChrome.textQuaternary)
            .padding(.bottom, 8)
          Text(section.title)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(WorkspaceChrome.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
          Text(section.description)
            .font(WorkspaceChrome.chromeFont(size: 13))
            .foregroundStyle(WorkspaceChrome.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 9)
        }
        .frame(maxWidth: 820, alignment: .leading)
        .padding(.bottom, 28)

        sectionContent
          .frame(maxWidth: 820, alignment: .leading)
      }
      .frame(maxWidth: 820, alignment: .topLeading)
      .frame(maxWidth: .infinity, alignment: .top)
      .padding(.horizontal, 40)
      .padding(.top, 42)
      .padding(.bottom, 54)
    }
    .background(WorkspaceChrome.canvas)
  }

  @ViewBuilder
  private var sectionContent: some View {
    switch section {
    case .general:
      generalContent
    case .agents:
      agentsContent
    case .editor:
      editorContent
    case .terminal:
      terminalContent
    case .mobile:
      mobileContent
    case .updates:
      updatesContent
    }
  }

  private var generalContent: some View {
    VStack(spacing: 18) {
      ClairSettingsCard(
        title: "ワークスペース",
        description: "Projectを開くときに使う基本設定です。"
      ) {
        ClairSettingsRow(
          label: "ワークスペースのディレクトリ",
          description: "Projectをまとめて管理するフォルダです。"
        ) {
          TextField("ワークスペースのディレクトリ", text: .constant(workspaceDirectoryDisplay))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(width: 220)
            .disabled(true)
            .accessibilityLabel("ワークスペースのディレクトリ")
        }
        ClairSettingsRow(
          label: "前回のレイアウトを復元",
          description: "Projectごとのファイル、ターミナル、分割位置を再現します。"
        ) {
          ClairSettingsToggle(label: "前回のレイアウトを復元", isOn: $restoreLayout)
        }
        ClairSettingsRow(
          label: "閉じる前に確認",
          description: "実行中のターミナルや未保存のエディタを閉じる前に確認します。"
        ) {
          ClairSettingsToggle(label: "閉じる前に確認", isOn: $confirmClose)
        }
      }

      ClairSettingsCard(
        title: "インターフェース",
        description: "ワークスペースを静かで集中しやすい表示にします。"
      ) {
        ClairSettingsRow(
          label: "表示言語",
          description: "Clair のメニューと補助テキストに使用する言語です。"
        ) {
          Picker("表示言語", selection: $language) {
            Text("日本語").tag("ja-JP")
            Text("英語").tag("en-US")
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .controlSize(.small)
        }
        ClairSettingsRow(
          label: "外観",
          description: "エディタとサイドバーに適用するカラーテーマです。"
        ) {
          Picker("外観", selection: $theme) {
            Text("One Dark").tag("one-dark")
            Text("システムに合わせる").tag("system")
            Text("ライト").tag("light")
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .controlSize(.small)
        }
        ClairSettingsRow(
          label: "ステータスフッターを表示",
          description: "ブランチ、同期状態、Agentの使用量をすべての画面で表示します。"
        ) {
          ClairSettingsToggle(label: "ステータスフッターを表示", isOn: $showStatusFooter)
        }
      }
    }
  }

  private var agentsContent: some View {
    VStack(spacing: 18) {
      ClairSettingsCard(
        title: "接続済みのAgent",
        description: "各Agentは専用ターミナルで実行し、ここにアクティビティを報告します。"
      ) {
        VStack(spacing: 0) {
          ForEach(settingsAgentProfiles) { profile in
            ClairAgentSettingsRow(
              profile: profile,
              activeSessionCount: activeSessionCount(for: profile)
            )
          }
        }
      }

      ClairSettingsCard(
        title: "Agentの既定値",
        description: "新しいセッションをワークスペースに追加する方法を設定します。"
      ) {
        ClairSettingsRow(
          label: "既定のエージェント",
          description: "新しいターミナルを開いたときに選択されるエージェントです。"
        ) {
          Picker("既定のエージェント", selection: $defaultAgent) {
            Text("Codex").tag("codex")
            Text("Claude Code").tag("claude-code")
            Text("OpenCode").tag("opencode")
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .controlSize(.small)
        }
        ClairSettingsRow(
          label: "Codex モデル",
          description: "Codex セッションで優先して使用するモデルです。"
        ) {
          Picker("Codex モデル", selection: $codexModel) {
            Text("GPT-5.6").tag("gpt-5.6")
            Text("GPT-5.5").tag("gpt-5.5")
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .controlSize(.small)
        }
        ClairSettingsRow(
          label: "Claude Code のコマンド",
          description: "ターミナルから Claude Code を起動するときのコマンドです。"
        ) {
          TextField("Claude Code のコマンド", text: $claudeCommand)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(width: 150)
            .accessibilityLabel("Claude Code のコマンド")
        }
        ClairSettingsRow(
          label: "OpenCode のコマンド",
          description: "ターミナルから OpenCode を起動するときのコマンドです。"
        ) {
          TextField("OpenCode のコマンド", text: $opencodeCommand)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(width: 150)
            .accessibilityLabel("OpenCode のコマンド")
        }
        ClairSettingsRow(
          label: "レート制限を表示",
          description: "エージェントごとの使用量ポップオーバーを有効にします。"
        ) {
          ClairSettingsToggle(label: "レート制限を表示", isOn: $showRateLimits)
        }
      }
    }
  }

  private var editorContent: some View {
    VStack(spacing: 18) {
      ClairSettingsCard(
        title: "エディタ",
        description: "文字組みとソース編集の設定です。"
      ) {
        ClairSettingsRow(
          label: "フォントサイズ",
          description: "すべてのProjectのエディタに適用する文字サイズです。"
        ) {
          Picker("フォントサイズ", selection: $editorFontSize) {
            ForEach([11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 17.0], id: \.self) { value in
              Text("\(value, specifier: value == floor(value) ? "%.0f" : "%.1f") px")
                .tag(value)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .controlSize(.small)
        }
        ClairSettingsRow(
          label: "行間",
          description: "コードの行同士の間隔です。"
        ) {
          Picker("行間", selection: $editorLineHeight) {
            ForEach([1.2, 1.4, 1.6, 1.8, 2.0, 2.2, 2.4], id: \.self) { value in
              Text("\(value, specifier: "%.1f")")
                .tag(value)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .controlSize(.small)
        }
        ClairSettingsRow(
          label: "行の折り返し",
          description: "長い行をエディタの幅に合わせて折り返します。"
        ) {
          ClairSettingsToggle(label: "行の折り返し", isOn: $wordWrap)
        }
        ClairSettingsRow(
          label: "ミニマップを表示",
          description: "ファイル全体の縮小プレビューを右端に表示します。"
        ) {
          ClairSettingsToggle(label: "ミニマップを表示", isOn: $showMinimap)
        }
        ClairSettingsRow(
          label: "保存時にフォーマット",
          description: "保存時に選択中の言語フォーマッターを実行します。"
        ) {
          ClairSettingsToggle(label: "保存時にフォーマット", isOn: $formatOnSave)
        }
        ClairSettingsRow(
          label: "インライン差分を表示",
          description: "変更された行の横に追加・削除の情報を表示します。"
        ) {
          ClairSettingsToggle(label: "インライン差分を表示", isOn: $inlineDiff)
        }
      }
    }
  }

  private var terminalContent: some View {
    VStack(spacing: 18) {
      ClairSettingsCard(
        title: "ターミナル",
        description: "シェルセッションとProjectの状態を管理します。"
      ) {
        ClairSettingsRow(
          label: "既定のシェル",
          description: "新しく作成するターミナルで使用するシェルです。"
        ) {
          Picker("既定のシェル", selection: $defaultShell) {
            Text("Claude Code").tag("claude")
            Text("zsh").tag("zsh")
            Text("OpenCode").tag("opencode")
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .controlSize(.small)
        }
        ClairSettingsRow(
          label: "パネルの位置",
          description: "ターミナルをエディタの下または右に表示します。"
        ) {
          ClairSettingsSegmentedControl(
            selection: $terminalPosition,
            options: [("bottom", "下"), ("right", "右")]
          )
        }
        ClairSettingsRow(
          label: "フォントサイズ",
          description: "ターミナル本文で使用する文字サイズです。"
        ) {
          Picker("ターミナルのフォントサイズ", selection: $terminalFontSize) {
            ForEach([11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 18.0, 20.0], id: \.self) { value in
              Text("\(value, specifier: "%.0f") px").tag(value)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .controlSize(.small)
        }
        ClairSettingsRow(
          label: "セッションを保持",
          description: "プロジェクトを切り替えてもターミナルの状態を保持します。"
        ) {
          ClairSettingsToggle(label: "セッションを保持", isOn: $preserveSessions)
        }
        ClairSettingsRow(
          label: "破壊的なコマンドを確認",
          description: "削除や強制上書きを行うコマンドの前に確認を表示します。"
        ) {
          ClairSettingsToggle(
            label: "破壊的なコマンドを確認",
            isOn: $confirmDestructiveCommands
          )
        }
      }
    }
  }

  private var mobileContent: some View {
    ClairMobileSettingsContent(mobileBridge: mobileBridge)
  }

  private var updatesContent: some View {
    VStack(spacing: 18) {
      ClairSettingsCard(
        title: "Clairのアップデート",
        description: "最新のプレビュー版を利用できるようにします。"
      ) {
        HStack(alignment: .center, spacing: 18) {
          VStack(alignment: .leading, spacing: 6) {
            Text("現在のバージョン")
              .font(.system(size: 10, design: .monospaced))
              .foregroundStyle(WorkspaceChrome.textQuaternary)
            Text("Clair \(updater.configuration.currentVersion)")
              .font(WorkspaceChrome.chromeFont(size: 15, weight: .semibold))
            Text("このアプリの現在のバージョンです。")
              .font(WorkspaceChrome.chromeFont(size: 11))
              .foregroundStyle(WorkspaceChrome.textTertiary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          VStack(alignment: .trailing, spacing: 8) {
            Button(updateButtonTitle) {
              updater.check(manual: true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!canStartManualUpdate)
            if let availableUpdate {
              Button("\(availableUpdate.version) をインストール") {
                updater.installAvailable()
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
            }
          }
        }
        Text(updateStatusMessage)
          .font(WorkspaceChrome.chromeFont(size: 11))
          .foregroundStyle(updateStatusColor)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 12)
      }

      ClairSettingsCard(
        title: "更新チャンネル",
        description: "明示的に確認したときだけアップデートを確認します。"
      ) {
        ClairSettingsRow(
          label: "リリースチャンネル",
          description: "このワークスペースで受け取る更新の種類です。"
        ) {
          Picker("リリースチャンネル", selection: $updateChannel) {
            Text("安定版").tag("stable")
            Text("プレビュー版").tag("preview")
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .controlSize(.small)
        }
        ClairSettingsRow(
          label: "アップデートを自動確認",
          description: "起動時と1日1回、利用可能な更新を確認します。"
        ) {
          ClairSettingsToggle(label: "アップデートを自動確認", isOn: $automaticUpdateChecks)
        }
        ClairSettingsRow(
          label: "エージェントの先行更新を含める",
          description: "Codex、Claude Code、OpenCode のプレビュー版を対象にします。"
        ) {
          ClairSettingsToggle(label: "エージェントの先行更新を含める", isOn: $includeAgentPreviews)
        }
      }

      VStack(alignment: .leading, spacing: 5) {
        Text("次回のプレビュー")
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
        Text("0.7.2 · ワークスペースの見やすさ")
          .font(WorkspaceChrome.chromeFont(size: 13, weight: .medium))
        Text("使用量フッター、アクティビティチャット、ブランチグラフを改善します。")
          .font(WorkspaceChrome.chromeFont(size: 11))
          .foregroundStyle(WorkspaceChrome.textTertiary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(18)
      .background(WorkspaceChrome.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
      .overlay {
        RoundedRectangle(cornerRadius: 6)
          .stroke(WorkspaceChrome.border, lineWidth: 1)
      }
    }
  }

  private var workspaceDirectoryDisplay: String {
    let fallback = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Projects", isDirectory: true)
    let directory = workspace.projects.first?.rootURL.deletingLastPathComponent() ?? fallback
    return abbreviatedPath(directory.path)
  }

  private func abbreviatedPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    guard path.hasPrefix(home) else {
      return path
    }
    return "~" + path.dropFirst(home.count)
  }

  private var settingsAgentProfiles: [AgentLaunchProfile] {
    [.codex, .claudeCode, .openCode]
  }

  private func activeSessionCount(for profile: AgentLaunchProfile) -> Int {
    agentWorkflow.sessions.filter { session in
      session.agent.profileID == profile.stableID && session.isActive
    }.count
  }

  private var availableUpdate: ClairUpdate? {
    guard case .available(let update) = updater.state else {
      return nil
    }
    return update
  }

  private var canStartManualUpdate: Bool {
    updater.profile.channel == .stable && !updater.state.isBusy
  }

  private var updateButtonTitle: String {
    updater.state.isBusy ? "確認中…" : "アップデートを確認"
  }

  private var updateStatusMessage: String {
    switch updater.state {
    case .disabled:
      "このDevビルドではStableの更新確認を利用できません。"
    case .idle:
      "利用可能な更新があるか確認できます。"
    case .checking:
      "アップデートを確認しています…"
    case .available(let update):
      "Clair \(update.version) が利用できます。"
    case .downloading:
      "アップデートをダウンロードしています…"
    case .installing:
      "アップデートをインストールしています…"
    case .failed(let message):
      message
    }
  }

  private var updateStatusColor: Color {
    switch updater.state {
    case .available:
      WorkspaceChrome.success
    case .failed:
      WorkspaceChrome.attention
    default:
      WorkspaceChrome.textTertiary
    }
  }
}

private struct ClairSettingsCard<Content: View>: View {
  let title: String
  let description: String
  let content: Content

  init(
    title: String,
    description: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.description = description
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text(title)
          .font(WorkspaceChrome.chromeFont(size: 15, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.textPrimary)
        Text(description)
          .font(WorkspaceChrome.chromeFont(size: 12.5))
          .foregroundStyle(WorkspaceChrome.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.bottom, 22)

      content
    }
    .padding(.horizontal, 26)
    .padding(.vertical, 24)
    .background(WorkspaceChrome.surface.opacity(0.68), in: RoundedRectangle(cornerRadius: 6))
    .overlay {
      RoundedRectangle(cornerRadius: 6)
        .stroke(WorkspaceChrome.borderStrong, lineWidth: 1)
    }
  }
}

private struct ClairSettingsRow<Control: View>: View {
  let label: String
  let description: String
  let control: Control

  init(
    label: String,
    description: String,
    @ViewBuilder control: () -> Control
  ) {
    self.label = label
    self.description = description
    self.control = control()
  }

  var body: some View {
    HStack(alignment: .center, spacing: 22) {
      VStack(alignment: .leading, spacing: 5) {
        Text(label)
          .font(WorkspaceChrome.chromeFont(size: 13, weight: .medium))
          .foregroundStyle(WorkspaceChrome.textSecondary)
        Text(description)
          .font(WorkspaceChrome.chromeFont(size: 11.5))
          .foregroundStyle(WorkspaceChrome.textTertiary)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      control
        .frame(minWidth: 150, alignment: .trailing)
    }
    .padding(.vertical, 13)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(WorkspaceChrome.border)
        .frame(height: 1)
    }
  }
}

private struct ClairSettingsToggle: View {
  let label: String
  @Binding var isOn: Bool

  var body: some View {
    Toggle(label, isOn: $isOn)
      .labelsHidden()
      .toggleStyle(.switch)
      .controlSize(.small)
      .accessibilityLabel(label)
  }
}

private struct ClairSettingsSegmentedControl: View {
  @Binding var selection: String
  let options: [(String, String)]

  var body: some View {
    HStack(spacing: 2) {
      ForEach(options, id: \.0) { option in
        Button {
          selection = option.0
        } label: {
          Text(option.1)
            .font(WorkspaceChrome.chromeFont(size: 11))
            .foregroundStyle(
              selection == option.0 ? WorkspaceChrome.textPrimary : WorkspaceChrome.textTertiary
            )
            .frame(minWidth: 42, minHeight: 27)
            .background(
              selection == option.0 ? WorkspaceChrome.surfaceActive : .clear,
              in: RoundedRectangle(cornerRadius: 3, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == option.0 ? .isSelected : [])
      }
    }
    .padding(2)
    .background(WorkspaceChrome.chrome, in: RoundedRectangle(cornerRadius: 5))
    .overlay {
      RoundedRectangle(cornerRadius: 5)
        .stroke(WorkspaceChrome.borderStrong, lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
  }
}

private struct ClairAgentSettingsRow: View {
  let profile: AgentLaunchProfile
  let activeSessionCount: Int

  var body: some View {
    HStack(spacing: 12) {
      AgentVendorIcon(provider: AgentRateLimitProvider(rawValue: profile.stableID))
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .foregroundStyle(profile.settingsColor)
        .frame(width: 24, height: 24)
        .background(profile.settingsColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
        .overlay {
          RoundedRectangle(cornerRadius: 5)
            .stroke(profile.settingsColor.opacity(0.42), lineWidth: 1)
        }

      VStack(alignment: .leading, spacing: 4) {
        Text(profile.displayName)
          .font(WorkspaceChrome.chromeFont(size: 13, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.textPrimary)
        Text(
          activeSessionCount == 0
            ? "利用可能"
            : "\(activeSessionCount)件のセッションが実行中"
        )
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(WorkspaceChrome.textTertiary)
      }

      Spacer(minLength: 12)

      Text(activeSessionCount == 0 ? "接続済み" : "使用中")
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(WorkspaceChrome.textTertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(WorkspaceChrome.canvas, in: RoundedRectangle(cornerRadius: 4))
        .overlay {
          RoundedRectangle(cornerRadius: 4)
            .stroke(WorkspaceChrome.border, lineWidth: 1)
        }
    }
    .frame(minHeight: 62)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(WorkspaceChrome.border)
        .frame(height: 1)
    }
  }
}

extension AgentLaunchProfile {
  fileprivate var settingsColor: Color {
    switch self {
    case .codex:
      WorkspaceChrome.accent
    case .claudeCode:
      WorkspaceChrome.attention
    case .openCode:
      WorkspaceChrome.success
    }
  }
}

private struct ClairMobileSettingsContent: View {
  @ObservedObject var mobileBridge: MobileControlRuntimeBridge
  @State private var didCopyPairingLink = false

  @AppStorage("clair.mobile.display-name-v1") private var mobileDisplayName = "Daiki の Clair"
  @AppStorage("clair.mobile.notifications-v1") private var mobileNotifications = true
  @AppStorage("clair.mobile.cellular-v1") private var mobileCellular = false
  @AppStorage("clair.mobile.show-agent-status-v1") private var mobileShowsAgentStatus = true
  @AppStorage("clair.mobile.allow-terminal-input-v1") private var mobileAllowsTerminalInput = false

  var body: some View {
    VStack(spacing: 18) {
      ClairSettingsCard(
        title: "モバイル接続",
        description: "モバイル端末をペアリングし、Agentの状態確認や簡単な指示を送信します。"
      ) {
        VStack(alignment: .leading, spacing: 18) {
          statusRow

          ClairSettingsRow(
            label: "接続先の表示名",
            description: "モバイルアプリに表示する、このワークスペースの名前です。"
          ) {
            TextField("接続先の表示名", text: $mobileDisplayName)
              .textFieldStyle(.roundedBorder)
              .controlSize(.small)
              .frame(width: 180)
              .accessibilityLabel("接続先の表示名")
          }

          if mobileBridge.isEnabled {
            VStack(alignment: .leading, spacing: 8) {
              ClairMobileValueRow(title: "ローカル endpoint", value: mobileBridge.endpointDescription)
              ClairMobileValueRow(
                title: "ホスト fingerprint",
                value: mobileBridge.hostIdentity?.fingerprint ?? "未生成"
              )
              Text("Cloudflare / Tailscale の private route をこの endpoint に向けてから、モバイルと接続してください。")
                .font(WorkspaceChrome.chromeFont(size: 11))
                .foregroundStyle(WorkspaceChrome.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
              Button("QRリンクを生成") {
                mobileBridge.createPairingLink()
              }
              .buttonStyle(.borderedProminent)
              .controlSize(.small)
              if mobileBridge.pairingLink != nil {
                Button("閉じる") {
                  mobileBridge.clearPairingLink()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
              }
            }

            if let pairingURL = mobileBridge.pairingURLString {
              pairingLinkView(pairingURL)
            }
          } else {
            Text("QRコードまたは一度限りのリンクで端末を接続できます。接続を有効にすると、ここにホスト情報が表示されます。")
              .font(WorkspaceChrome.chromeFont(size: 11))
              .foregroundStyle(WorkspaceChrome.textTertiary)
              .fixedSize(horizontal: false, vertical: true)
          }

          if mobileBridge.isEnabled {
            Button("モバイル接続を無効化") {
              mobileBridge.setEnabled(false)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          } else {
            Button("モバイル接続を有効化") {
              mobileBridge.setEnabled(true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
          }

          if !mobileBridge.devices.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
              Text("ペアリング済み端末")
                .font(WorkspaceChrome.chromeFont(size: 12, weight: .medium))
                .padding(.bottom, 7)
              ForEach(mobileBridge.devices) { device in
                HStack(spacing: 10) {
                  Image(systemName: "iphone")
                    .font(.system(size: 13))
                    .foregroundStyle(WorkspaceChrome.textTertiary)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(device.displayName)
                      .font(WorkspaceChrome.chromeFont(size: 12, weight: .medium))
                    Text(device.scopes.map(\.rawValue).sorted().joined(separator: " / "))
                      .font(.system(size: 10, design: .monospaced))
                      .foregroundStyle(WorkspaceChrome.textQuaternary)
                  }
                  Spacer(minLength: 8)
                  Button("解除") {
                    mobileBridge.revoke(device)
                  }
                  .buttonStyle(.tactile)
                  .controlSize(.small)
                  .foregroundStyle(WorkspaceChrome.danger)
                }
                .frame(minHeight: 48)
                .overlay(alignment: .top) {
                  Rectangle()
                    .fill(WorkspaceChrome.border)
                    .frame(height: 1)
                }
              }
            }
            .padding(.top, 3)
          }

          if let error = mobileBridge.lastErrorMessage {
            Text(error)
              .font(WorkspaceChrome.chromeFont(size: 11))
              .foregroundStyle(WorkspaceChrome.attention)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }

      ClairSettingsCard(
        title: "モバイルの権限",
        description: "ペアリング済みの端末に表示・操作を許可する内容です。"
      ) {
        ClairSettingsRow(
          label: "Agentの状態と使用量",
          description: "アクティビティと残りのレート制限を表示します。"
        ) {
          ClairSettingsToggle(label: "Agentの状態と使用量", isOn: $mobileShowsAgentStatus)
        }
        ClairSettingsRow(
          label: "通知を同期",
          description: "エージェントの完了や入力待ちをモバイルに通知します。"
        ) {
          ClairSettingsToggle(label: "通知を同期", isOn: $mobileNotifications)
        }
        ClairSettingsRow(
          label: "ターミナルコマンドを送信",
          description: "ペアリング済みの端末から簡単なコマンドを送信できます。"
        ) {
          ClairSettingsToggle(label: "ターミナルコマンドを送信", isOn: $mobileAllowsTerminalInput)
        }
        ClairSettingsRow(
          label: "モバイルデータ通信を許可",
          description: "Wi-Fi 接続がない場合も同期を続けます。"
        ) {
          ClairSettingsToggle(label: "モバイルデータ通信を許可", isOn: $mobileCellular)
        }
      }
    }
    .onChange(of: mobileBridge.pairingLink) { _, newValue in
      if newValue == nil {
        didCopyPairingLink = false
      }
    }
  }

  private var statusRow: some View {
    HStack(alignment: .center, spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 6)
          .fill(WorkspaceChrome.canvas)
        Image(systemName: "iphone")
          .font(.system(size: 17))
          .foregroundStyle(WorkspaceChrome.textSecondary)
      }
      .frame(width: 34, height: 44)
      .overlay {
        RoundedRectangle(cornerRadius: 6)
          .stroke(WorkspaceChrome.borderStrong, lineWidth: 1)
      }

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 6) {
          Circle()
            .fill(mobileBridge.isEnabled ? WorkspaceChrome.success : WorkspaceChrome.textQuaternary)
            .frame(width: 7, height: 7)
          Text(
            mobileBridge.isEnabled
              ? "Clair Mobileに接続可能"
              : "接続中の端末はありません"
          )
          .font(WorkspaceChrome.chromeFont(size: 13, weight: .semibold))
        }
        Text(
          mobileBridge.isEnabled
            ? "このワークスペースをペアリング済みの端末で利用できます。"
            : "モバイル端末からワークスペースを確認できます。"
        )
        .font(WorkspaceChrome.chromeFont(size: 11.5))
        .foregroundStyle(WorkspaceChrome.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(14)
    .background(WorkspaceChrome.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
    .overlay {
      RoundedRectangle(cornerRadius: 5)
        .stroke(WorkspaceChrome.border, lineWidth: 1)
    }
  }

  private func pairingLinkView(_ pairingURL: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      ClairSettingsPairingCodeView(payload: pairingURL)
        .frame(width: 132, height: 132)
        .background(.white, in: RoundedRectangle(cornerRadius: 6))

      VStack(alignment: .leading, spacing: 8) {
        Text("1回限りのペアリングリンク")
          .font(WorkspaceChrome.chromeFont(size: 12, weight: .medium))
        Text(pairingURL)
          .font(.system(size: 9, design: .monospaced))
          .foregroundStyle(WorkspaceChrome.textTertiary)
          .lineLimit(5)
          .truncationMode(.middle)
          .textSelection(.enabled)
        if let expiresAt = mobileBridge.pairingLink?.expiresAt {
          Text("有効期限 \(expiresAt, style: .time)")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(WorkspaceChrome.textQuaternary)
        }
        Button(didCopyPairingLink ? "コピーしました" : "リンクをコピー") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(pairingURL, forType: .string)
          didCopyPairingLink = true
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(12)
    .background(WorkspaceChrome.canvas, in: RoundedRectangle(cornerRadius: 6))
    .overlay {
      RoundedRectangle(cornerRadius: 6)
        .stroke(WorkspaceChrome.border, lineWidth: 1)
    }
  }
}

private struct ClairMobileValueRow: View {
  let title: String
  let value: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title)
        .font(WorkspaceChrome.chromeFont(size: 11))
        .foregroundStyle(WorkspaceChrome.textQuaternary)
      Spacer(minLength: 8)
      Text(value)
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(WorkspaceChrome.textTertiary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }
}

private struct ClairSettingsPairingCodeView: View {
  let payload: String

  var body: some View {
    if let image = Self.makeImage(payload: payload) {
      Image(nsImage: image)
        .resizable()
        .interpolation(.none)
        .antialiased(false)
        .scaledToFit()
        .padding(8)
    } else {
      Image(systemName: "qrcode")
        .font(.system(size: 42))
        .foregroundStyle(.black)
    }
  }

  private static func makeImage(payload: String) -> NSImage? {
    guard
      let data = payload.data(using: .utf8),
      let filter = CIFilter(name: "CIQRCodeGenerator")
    else {
      return nil
    }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else {
      return nil
    }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    let representation = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: representation.size)
    image.addRepresentation(representation)
    return image
  }
}

/// Vendor artwork shared by usage indicators and agent settings.
struct AgentVendorIcon: View {
  let provider: AgentRateLimitProvider?

  var body: some View {
    Group {
      switch provider {
      case .codex:
        Image("VendorCodex")
          .resizable()
          .scaledToFit()
          .foregroundStyle(WorkspaceChrome.textPrimary)
      case .claudeCode:
        Image("VendorClaude")
          .resizable()
          .scaledToFit()
      case .openCode:
        Image("VendorOpenCode")
          .resizable()
          .scaledToFit()
          .padding(3)
      case nil:
        Image(systemName: "sparkles")
      }
    }
    .frame(width: 19, height: 19)
    .accessibilityHidden(true)
  }
}
