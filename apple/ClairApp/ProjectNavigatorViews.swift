import AppKit
import SwiftUI

struct ProjectFileTreeView: View {
  let surface: ProjectSurfaceModel
  let onOpenProject: () -> Void
  @State private var isProjectsExpanded = true

  var body: some View {
    VStack(spacing: 0) {
      SidebarPanelHeader(title: WorkspaceActivity.files.title) {
        if surface.fileTree.isLoading {
          ProgressView()
            .controlSize(.small)
            .tint(WorkspaceChrome.textTertiary)
            .scaleEffect(0.7)
            .frame(width: 16, height: 16)
            .accessibilityLabel("ファイルを読み込み中")
        }
        ChromeActionButton(width: 20, height: 20, help: "Projectフォルダを開く", action: onOpenProject) {
          Image(systemName: "folder.badge.plus")
            .font(.system(size: 11, weight: .medium))
        }
        ChromeActionButton(width: 20, height: 20, help: "ファイルツリーを更新", action: surface.reload) {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: 11, weight: .medium))
        }
      }

      if isProjectsExpanded {
        if let root = surface.fileTree.root, surface.fileTree.isAvailable {
          ScrollViewReader { proxy in
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visibleRows(from: root)) { row in
                  switch row.kind {
                  case .node:
                    ProjectFileTreeRow(
                      node: row.node,
                      surface: surface,
                      depth: row.depth,
                      isSelected: surface.selectedNodeID == row.node.id,
                      isExpanded: surface.isExpanded(row.node.id)
                    )
                  case .loadMore:
                    Button {
                      surface.loadMoreChildren(for: row.node.id)
                    } label: {
                      Label("さらに読み込む…", systemImage: "ellipsis")
                        .font(WorkspaceChrome.chromeFont(size: 10))
                        .foregroundStyle(WorkspaceChrome.textQuaternary)
                        .padding(.leading, CGFloat(row.depth * 14) + 10)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                  case .loading:
                    ProgressView()
                      .controlSize(.small)
                      .tint(WorkspaceChrome.textTertiary)
                      .scaleEffect(0.7)
                      .padding(.leading, CGFloat(row.depth * 14) + 10)
                      .frame(height: 24)
                  }
                }
              }
              .padding(.vertical, 6)
            }
            .scrollIndicators(.automatic)
            .onChange(of: surface.selectedNodeID, initial: false) { _, nodeID in
              guard let nodeID else { return }
              withAnimation(.easeInOut(duration: 0.15)) {
                proxy.scrollTo(nodeID, anchor: .center)
              }
            }
          }
        } else if surface.fileTree.isLoading {
          ProgressView()
            .controlSize(.small)
            .tint(WorkspaceChrome.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ChromeEmptyState(
            symbol: fileTreeSystemImage,
            title: fileTreeTitle,
            message: fileTreeMessage
          )
          Spacer(minLength: 0)
        }
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .foregroundStyle(WorkspaceChrome.textSecondary)
    .background(WorkspaceChrome.chrome)
  }

  /// The tree as the flat row list the `LazyVStack` can page through: a node
  /// contributes its own row, then its children's only while it is expanded.
  private func visibleRows(from root: ProjectFileTreeNode) -> [ProjectFileTreeVisibleRow] {
    var rows: [ProjectFileTreeVisibleRow] = []
    appendRows(of: root, depth: 0, into: &rows)
    return rows
  }

  private func appendRows(
    of node: ProjectFileTreeNode,
    depth: Int,
    into rows: inout [ProjectFileTreeVisibleRow]
  ) {
    rows.append(ProjectFileTreeVisibleRow(node: node, depth: depth))
    guard node.isDirectory, surface.isExpanded(node.id) else {
      return
    }
    if let children = node.children {
      for child in children {
        appendRows(of: child, depth: depth + 1, into: &rows)
      }
      if node.hasMoreChildren {
        rows.append(
          ProjectFileTreeVisibleRow(node: node, depth: depth + 1, kind: .loadMore)
        )
      }
    } else {
      rows.append(ProjectFileTreeVisibleRow(node: node, depth: depth + 1, kind: .loading))
    }
  }

  private var fileTreeTitle: String {
    switch surface.fileTree.availability {
    case .available:
      "ファイルがありません"
    case .missing:
      "フォルダが見つかりません"
    case .notDirectory:
      "フォルダではありません"
    case .unreadable:
      "フォルダを利用できません"
    }
  }

  private var fileTreeSystemImage: String {
    surface.fileTree.availability == .available
      ? "doc"
      : "exclamationmark.triangle"
  }

  private var fileTreeMessage: String {
    switch surface.fileTree.availability {
    case .available:
      "このProjectフォルダは空です。"
    case .missing:
      "フォルダが移動または削除された可能性があります。戻ってくるとClairが更新します。"
    case .notDirectory:
      "Projectのルートがフォルダではなくなっています。"
    case .unreadable:
      "ClairはこのProjectフォルダを読み込めません。"
    }
  }
}

struct ProjectQuickOpenView: View {
  let surface: ProjectSurfaceModel
  let onDismiss: () -> Void
  @State private var query = ""

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("ファイル名またはパスで検索", text: $query)
          .textFieldStyle(.roundedBorder)
          .onSubmit {
            openFirstResult()
          }
        Button("閉じる", action: onDismiss)
          .buttonStyle(.tactile)
          .foregroundStyle(WorkspaceChrome.textTertiary)
      }
      .padding(12)

      Divider()

      if surface.quickOpenIsLoading {
        ProgressView("ファイルを検索中…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if items.isEmpty {
        ContentUnavailableView(
          query.isEmpty ? "ファイルがありません" : "一致するファイルがありません",
          systemImage: "doc.text.magnifyingglass",
          description: Text(
            query.isEmpty
              ? "このProjectには開けるファイルがありません。"
              : "別のファイル名またはパスを試してください。"
          )
        )
      } else {
        List(items) { item in
          Button {
            surface.openQuickOpenItem(item)
            if surface.lastNavigationErrorMessage == nil {
              onDismiss()
            }
          } label: {
            VStack(alignment: .leading, spacing: 3) {
              Text(item.title)
                .font(.body.weight(.medium))
              Text(item.relativePath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.tactile)
        }
        .listStyle(.inset)
      }
    }
    .frame(minWidth: 480, minHeight: 360)
    .onChange(of: query, initial: true) { _, newValue in
      surface.requestQuickOpenItems(matching: newValue)
    }
  }

  private var items: [ProjectQuickOpenItem] {
    surface.quickOpenResults
  }

  private func openFirstResult() {
    guard let item = items.first else {
      return
    }
    surface.openQuickOpenItem(item)
    if surface.lastNavigationErrorMessage == nil {
      onDismiss()
    }
  }
}

struct ProjectSearchView: View {
  let surface: ProjectSurfaceModel
  let onDismiss: () -> Void
  @State private var query = ""
  @State private var replacement = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SidebarPanelHeader(title: WorkspaceActivity.search.title) {
        Text("⌘⇧F")
          .font(WorkspaceChrome.chromeFont(size: 9, weight: .semibold))
          .monospaced()
          .foregroundStyle(WorkspaceChrome.textQuaternary)
          .padding(.horizontal, 6)
          .frame(height: 18)
          .background(WorkspaceChrome.panel, in: RoundedRectangle(cornerRadius: 3))
      }

      Divider()
        .background(WorkspaceChrome.border)

      VStack(spacing: 8) {
        HStack(spacing: 8) {
          Image(systemName: "text.magnifyingglass")
            .foregroundStyle(WorkspaceChrome.textTertiary)
          TextField("フォルダ内を検索…", text: $query)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
              surface.requestSearch(query: query)
            }
        }

        HStack(spacing: 8) {
          TextField("置換後の文字列", text: $replacement)
            .textFieldStyle(.roundedBorder)
          Button("検索") {
            surface.requestSearch(query: query)
          }
          .disabled(query.isEmpty)
          Button("置換プレビュー") {
            surface.requestReplacementPreview(query: query, replacement: replacement)
          }
          .disabled(query.isEmpty)
        }

        HStack {
          Text(
            query.isEmpty
              ? "UTF-8のテキストファイルを検索し、Projectの監視結果を更新します。"
              : "\(surface.searchResults.count)件の結果"
          )
          .font(WorkspaceChrome.chromeFont(size: 10))
          .foregroundStyle(WorkspaceChrome.textTertiary)
          Spacer()
        }
      }
      .padding(12)

      if let status = surface.lastNavigationStatusMessage {
        Label(status, systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.green)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 12)
          .padding(.bottom, 8)
      }

      if let preview = surface.replacementPreview {
        GroupBox("置換プレビュー") {
          VStack(alignment: .leading, spacing: 8) {
            Text(
              "\(preview.matchCount)件の結果 · \(preview.files.count)ファイル"
            )
            .font(.caption.weight(.semibold))

            ForEach(preview.files) { file in
              HStack {
                Text(file.relativePath)
                  .lineLimit(1)
                Spacer()
                Text("\(file.matchCount)")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
            }

            HStack {
              Spacer()
              Button("エディタバッファに適用") {
                surface.applyReplacement(preview)
              }
              .buttonStyle(.borderedProminent)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
      }

      Divider()

      if query.isEmpty {
        ContentUnavailableView(
          "このProjectを検索",
          systemImage: "text.magnifyingglass",
          description: Text("上の入力欄にテキストを入力して置換をプレビューします。")
        )
      } else if surface.searchIsLoading || surface.replacementIsLoading {
        ProgressView("ファイルを検索中…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if surface.searchResults.isEmpty {
        ContentUnavailableView(
          "結果はありません",
          systemImage: "magnifyingglass",
          description: Text("そのテキストを含むUTF-8ファイルはありません。")
        )
      } else {
        List(surface.searchResults) { match in
          Button {
            surface.openSearchMatch(match)
            if surface.lastNavigationErrorMessage == nil {
              onDismiss()
            }
          } label: {
            VStack(alignment: .leading, spacing: 3) {
              HStack(spacing: 6) {
                Text(match.relativePath)
                  .font(.body.weight(.medium))
                  .lineLimit(1)
                Spacer()
                Text("\(match.line):\(match.column)")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
              Text(match.lineText)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.tactile)
        }
        .listStyle(.inset)
      }
    }
    .frame(minWidth: 0, minHeight: 0)
    .foregroundStyle(WorkspaceChrome.textSecondary)
    .background(WorkspaceChrome.chrome)
    .onChange(of: query, initial: true) { _, newValue in
      surface.requestSearch(query: newValue)
    }
  }
}

enum ProjectActivityFilter: String, CaseIterable, Identifiable {
  case all
  case attention
  case agents

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
    case .all:
      "すべて"
    case .attention:
      "注意"
    case .agents:
      "Agent"
    }
  }
}

struct ProjectActivityView: View {
  let project: Project
  @ObservedObject var workspace: ProjectWorkspaceModel
  let surface: ProjectSurfaceModel
  @ObservedObject var agentWorkflow: AgentWorkflowCoordinator
  let onOpenAgents: () -> Void

  @State private var filter: ProjectActivityFilter = .all
  @State private var query = ""

  private var projectActivities: [AgentActivity] {
    agentWorkflow.activities(for: project.id)
  }

  private var items: [AgentActivity] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

    return projectActivities.filter { activity in
      guard matchesFilter(activity) else {
        return false
      }
      guard !normalizedQuery.isEmpty else {
        return true
      }
      let searchText = [
        activity.source.rawValue,
        activity.kind.rawValue,
        activity.summary ?? "",
      ].joined(separator: " ")
      return searchText.localizedCaseInsensitiveContains(normalizedQuery)
    }
    .sorted { $0.occurredAt > $1.occurredAt }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SidebarPanelHeader(title: WorkspaceActivity.activity.title) {
        Text("\(items.count)")
          .font(WorkspaceChrome.chromeFont(size: 10))
          .foregroundStyle(WorkspaceChrome.textMuted)
        ChromeActionButton(
          width: 20,
          height: 20,
          isActive: agentWorkflow.isMuted(projectID: project.id),
          help: agentWorkflow.isMuted(projectID: project.id)
            ? "Projectの通知をミュート解除" : "Projectの通知をミュート",
          action: {
            agentWorkflow.setMuted(
              !agentWorkflow.isMuted(projectID: project.id),
              projectID: project.id
            )
          },
          label: {
            Image(
              systemName: agentWorkflow.isMuted(projectID: project.id)
                ? "bell.slash" : "bell"
            )
            .font(.system(size: 11, weight: .medium))
          }
        )
      }

      Divider()
        .background(WorkspaceChrome.border)

      HStack(spacing: 8) {
        Picker("絞り込み", selection: $filter) {
          ForEach(ProjectActivityFilter.allCases) { filter in
            Text(filter.title).tag(filter)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .tint(WorkspaceChrome.accent)

        TextField("Agentsを絞り込み", text: $query)
          .textFieldStyle(.roundedBorder)
          .frame(minWidth: 120, idealWidth: 220)
          .accessibilityLabel("Agentsを絞り込み")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      Divider()
        .background(WorkspaceChrome.border)

      if items.isEmpty {
        ContentUnavailableView(
          query.isEmpty && filter == .all ? "アクティビティはまだありません" : "該当するアクティビティはありません",
          systemImage: "bell",
          description: Text(
            query.isEmpty && filter == .all
              ? "このProjectのシグナルがここに表示されます。"
              : "別の絞り込みまたは検索語を試してください。"
          )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 1) {
            ForEach(items) { activity in
              agentRow(activity)
            }
          }
          .padding(8)
        }
        .background(WorkspaceChrome.canvas)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .foregroundStyle(WorkspaceChrome.textSecondary)
    .background(WorkspaceChrome.chrome)
  }

  private func agentRow(_ activity: AgentActivity) -> some View {
    let session = activity.sessionID.flatMap { sessionID in
      agentWorkflow.sessions.first { $0.id == sessionID }
    }
    let isMuted = agentWorkflow.isMuted(
      projectID: activity.projectID,
      sessionID: activity.sessionID
    )

    return HStack(alignment: .top, spacing: 10) {
      Image(systemName: activityIcon(for: activity))
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(activityColor(for: activity))
        .frame(width: 20)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(activityTitle(for: activity))
            .font(WorkspaceChrome.chromeFont(size: 11, weight: .medium))
          Text(activity.kind.displayName)
            .font(WorkspaceChrome.chromeFont(size: 9))
            .foregroundStyle(WorkspaceChrome.textQuaternary)
        }
        Text(activity.occurredAt.formatted(date: .omitted, time: .shortened))
          .font(WorkspaceChrome.chromeFont(size: 9))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
        if let summary = activity.summary {
          Text(summary)
            .font(WorkspaceChrome.chromeFont(size: 10))
            .foregroundStyle(WorkspaceChrome.textTertiary)
            .lineLimit(2)
        }
        if let session {
          Text(sessionDescription(session))
            .font(WorkspaceChrome.chromeFont(size: 9))
            .foregroundStyle(WorkspaceChrome.textQuaternary)
            .lineLimit(1)
        } else if activity.sessionID != nil {
          Text("セッションのメタデータを保持しています。ターミナルは接続されていません")
            .font(WorkspaceChrome.chromeFont(size: 9))
            .foregroundStyle(WorkspaceChrome.textQuaternary)
        } else {
          Text("Projectに紐づくシグナル")
            .font(WorkspaceChrome.chromeFont(size: 9))
            .foregroundStyle(WorkspaceChrome.textQuaternary)
        }
      }

      Spacer(minLength: 8)

      VStack(alignment: .trailing, spacing: 5) {
        if let session {
          Button("ターミナルを表示") {
            workspace.revealTerminal(
              projectID: session.projectID,
              tabID: session.terminalTabID
            )
            surface.workspaceActivity = .files
          }
          .buttonStyle(.tactile)
          .foregroundStyle(WorkspaceChrome.accent)
        } else if activity.sessionID != nil {
          Button("Agentを開く", action: onOpenAgents)
            .buttonStyle(.tactile)
            .foregroundStyle(WorkspaceChrome.textTertiary)
        }

        if let sessionID = activity.sessionID {
          Button(isMuted ? "ミュート解除" : "ミュート") {
            agentWorkflow.setMuted(
              !isMuted,
              projectID: activity.projectID,
              sessionID: sessionID
            )
          }
          .buttonStyle(.tactile)
          .foregroundStyle(isMuted ? WorkspaceChrome.attention : WorkspaceChrome.textQuaternary)
        }
      }
    }
    .padding(9)
    .background(
      activity.shouldNotify
        ? WorkspaceChrome.attention.opacity(0.07) : WorkspaceChrome.surface,
      in: RoundedRectangle(cornerRadius: 5)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 5)
        .stroke(
          activity.shouldNotify
            ? WorkspaceChrome.attention.opacity(0.18) : WorkspaceChrome.border,
          lineWidth: 1
        )
    }
  }

  private func matchesFilter(_ activity: AgentActivity) -> Bool {
    switch filter {
    case .all:
      true
    case .attention:
      activity.shouldNotify
    case .agents:
      true
    }
  }

  private func activityTitle(for activity: AgentActivity) -> String {
    switch activity.source {
    case .bell:
      "ターミナルの注意ベル"
    case .exit:
      activity.exitStatus == 0 ? "Agentが正常終了" : "Agentがエラー終了"
    case .officialHook:
      "公式フック: \(activity.kind.rawValue)"
    }
  }

  private func activityIcon(for activity: AgentActivity) -> String {
    switch activity.source {
    case .bell:
      "bell"
    case .exit:
      activity.exitStatus == 0 ? "checkmark.circle" : "xmark.circle"
    case .officialHook:
      "link"
    }
  }

  private func activityColor(for activity: AgentActivity) -> Color {
    activity.shouldNotify ? WorkspaceChrome.attention : WorkspaceChrome.textTertiary
  }

  private func sessionDescription(_ session: AgentWorkflowSession) -> String {
    switch session.lifecycle {
    case .starting:
      "起動中 · raw terminal · \(session.agent.cwd)"
    case .running:
      "実行中 · raw terminal · \(session.agent.cwd)"
    case .exited(let code):
      "終了 \(code) · raw terminal · \(session.agent.cwd)"
    }
  }
}

/// One row in the flattened tree: a node, plus the two placeholder rows a
/// directory can contribute while its children are still coming.
struct ProjectFileTreeVisibleRow: Identifiable {
  enum Kind {
    case node
    case loadMore
    case loading
  }

  let node: ProjectFileTreeNode
  let depth: Int
  var kind: Kind = .node

  var id: String {
    switch kind {
    case .node:
      node.id
    case .loadMore:
      "\(node.id)#more"
    case .loading:
      "\(node.id)#loading"
    }
  }
}

struct ProjectFileTreeRow: View {
  let node: ProjectFileTreeNode
  /// Deliberately *not* `@ObservedObject`: the row only calls into the surface
  /// on tap, and everything it draws is passed in. Observing it here meant one
  /// subscription per row — hundreds of them in a wide tree, every one woken
  /// by any surface publish, including a plain selection change.
  let surface: ProjectSurfaceModel
  let depth: Int
  let isSelected: Bool
  let isExpanded: Bool

  var body: some View {
    // A selected row is a rounded pill inset from the panel's edges, not a
    // full-bleed band: the inset is what makes it read as one object rather
    // than a stripe across the sidebar.
    HStack(spacing: 6) {
      if node.isDirectory {
        Text(isExpanded ? "▾" : "▸")
          .font(.system(size: 9))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
          .frame(width: 10)
      } else {
        Color.clear.frame(width: 10, height: 1)
      }

      Image(systemName: fileIconSymbol)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(
          isSelected ? WorkspaceChrome.codeBright : WorkspaceChrome.textTertiary
        )
        .frame(width: 12)
        .accessibilityHidden(true)
      Text(node.name)
        .font(WorkspaceChrome.chromeFont(size: 11, weight: isSelected ? .medium : .regular))
        .foregroundStyle(
          isSelected ? WorkspaceChrome.textPrimary : WorkspaceChrome.textTertiary
        )
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 0)
    }
    .padding(.leading, CGFloat(depth * 14) + 10)
    .padding(.trailing, 10)
    .frame(height: isSelected ? 28 : 26)
    .hoverableRow(
      isSelected: isSelected,
      selectedColor: WorkspaceChrome.washSelected,
      cornerRadius: isSelected ? 7 : 0
    )
    .padding(.horizontal, isSelected ? 8 : 0)
    .contentShape(Rectangle())
    .onTapGesture {
      if node.isDirectory {
        surface.toggleExpansion(for: node.id)
      }
      surface.select(nodeID: node.id)
    }
    .id(node.id)
  }

  private var fileIconSymbol: String {
    guard !node.isDirectory else {
      return "folder"
    }

    let fileName = node.name.lowercased()
    switch fileName {
    case "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb":
      return "cube"
    case "dockerfile", "compose.yaml", "compose.yml", "makefile", "cmakelists.txt":
      return "shippingbox"
    case ".env", ".env.local", ".env.development", ".env.production":
      return "gearshape"
    default:
      break
    }

    switch node.url.pathExtension.lowercased() {
    case "jsx", "tsx":
      return "atom"
    case "html", "htm", "xml", "svg", "vue", "svelte", "astro":
      return "chevron.left.forwardslash.chevron.right"
    case "css", "scss", "sass", "less":
      return "paintbrush"
    case "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd":
      return "terminal"
    case "sql":
      return "cylinder"
    case "r":
      return "chart.xyaxis.line"
    case "js", "mjs", "cjs", "ts", "mts", "cts", "swift", "rs", "py", "pyw",
      "c", "cc", "cpp", "cxx", "h", "hh", "hpp", "m", "mm", "java", "kt", "kts",
      "go", "dart", "php", "rb", "rake", "ex", "exs", "erl", "hrl", "fs", "fsx",
      "cs", "vb", "scala", "clj", "cljs", "groovy", "lua", "hs", "lhs", "sol", "zig",
      "nim", "pl", "pm", "asm", "s", "json", "graphql", "gql", "proto":
      return "curlybraces"
    case "md", "markdown", "txt":
      return "doc.plaintext"
    case "yaml", "yml", "toml", "ini", "conf", "config", "properties", "env":
      return "gearshape"
    case "lock":
      return "lock"
    default:
      return "doc.text"
    }
  }
}
