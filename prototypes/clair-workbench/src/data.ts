// Mock workspace content. Every string that appears in a screen the design
// canvas draws is copied from that artboard; the extra file bodies below exist
// only so the editor, quick-open and search have something real to work on.

export type FileKind = 'swift' | 'go' | 'md' | 'rust';

export type MockFile = {
  path: string;
  name: string;
  kind: FileKind;
  status?: 'M' | 'A';
  content: string;
};

const projectWorkspace = `import SwiftUI

/// The workspace surface owns one pane tree per project.
struct ProjectWorkspaceView: View {
  @ObservedObject var surface: ProjectSurfaceModel

  var body: some View {
    ProjectPaneLayoutView(surface: surface, node: surface.layout.root)
      .background(Color.clairCanvas)
  }
}

/// Split ratio is owned by the model so the divider can drag it.
private struct ProjectPaneLayoutView: View {
  @ObservedObject var surface: ProjectSurfaceModel
  let node: ProjectPaneNode

  private func splitView(
    orientation: ProjectPaneOrientation,
    ratio: Double,
    first: ProjectPaneNode,
    second: ProjectPaneNode
  ) -> some View {
    GeometryReader { proxy in
      let total = orientation == .horizontal ? proxy.size.width : proxy.size.height
      let firstLength = max(48, total * ratio)

      Group {
        if orientation == .horizontal {
          HStack(spacing: 0) {
            ProjectPaneLayoutView(surface: surface, node: first)
              .frame(width: firstLength)
            PaneDivider(orientation: orientation) { delta in
              surface.updateSplitRatio(nodeID: node.id, ratio: (firstLength + delta) / total)
            }
            ProjectPaneLayoutView(surface: surface, node: second)
          }
        } else {
          VStack(spacing: 0) {
            ProjectPaneLayoutView(surface: surface, node: first)
              .frame(height: firstLength)
            PaneDivider(orientation: orientation) { delta in
              surface.updateSplitRatio(nodeID: node.id, ratio: (firstLength + delta) / total)
            }
            ProjectPaneLayoutView(surface: surface, node: second)
          }
        }
      }
    }
  }

  var body: some View {
    switch node.kind {
    case let .split(orientation, ratio, first, second):
      splitView(orientation: orientation, ratio: ratio, first: first, second: second)
    case let .leaf(pane):
      ProjectPaneView(surface: surface, pane: pane)
    }
  }
}
`;

const contentView = `import SwiftUI

struct ContentView: View {
  @State private var workspace = Workspace.preview

  var body: some View {
    WorkspaceView(workspace: workspace)
      .frame(minWidth: 960, minHeight: 600)
      .onAppear { workspace.restore() }
  }
}
`;

const clairApp = `import SwiftUI

@main
struct ClairApp: App {
  @State private var workspace = Workspace.preview

  var body: some Scene {
    WindowGroup {
      WorkspaceView(workspace: workspace)
    }
  }
}

struct SourceEditorRepresentable: NSViewRepresentable {
  let document: SourceDocument

  func makeNSView(context: Context) -> SourceEditorView {
    let view = SourceEditorView(document: document)
    view.restoreSelection()
    return view
  }
}
`;

const paneSplit = `import SwiftUI

/// A divider the user can drag. Focus moves by geometry, not by pane index.
struct PaneDivider: View {
  let orientation: ProjectPaneOrientation
  let onDrag: (CGFloat) -> Void

  var body: some View {
    Rectangle()
      .fill(Color.clairPaneDivider)
      .frame(
        width: orientation == .horizontal ? 1 : nil,
        height: orientation == .vertical ? 1 : nil
      )
      .gesture(
        DragGesture(minimumDistance: 0).onChanged { value in
          onDrag(orientation == .horizontal ? value.translation.width : value.translation.height)
        }
      )
  }
}
`;

const workspaceChrome = `import SwiftUI

/// Every vertical pixel before code is spent here: 48pt titlebar + 26pt status
/// bar. Panes never add a header row of their own.
struct WorkspaceChrome: View {
  static let titlebarHeight: CGFloat = 48
  static let sidebarStripHeight: CGFloat = 34
  static let statusBarHeight: CGFloat = 26
}
`;

const sessionRail = `import SwiftUI

/// Only facts available from the PTY and the process reach this table.
struct SessionRailView: View {
  let sessions: [TerminalSession]

  var body: some View {
    Table(sessions) {
      TableColumn("AGENT") { SessionAgentCell(session: $0) }
      TableColumn("PROJECT") { Text($0.project.name) }
      TableColumn("経過") { Text($0.elapsed.formatted) }
    }
  }
}
`;

const readme = `# Clair

A native macOS workspace for parallel coding agents.

Clair keeps every agent session, terminal and editor pane for a project in one
window, and never interprets what a TUI draws.
`;

const paneLayoutDoc = `# Pane layout

The pane tree is a binary tree of splits. A split owns its ratio so the divider
can drag it, and focus moves by geometry rather than by pane index.
`;

export const files: MockFile[] = [
  {
    path: 'apple/ClairApp/ProjectWorkspace.swift',
    name: 'ProjectWorkspace.swift',
    kind: 'swift',
    status: 'M',
    content: projectWorkspace,
  },
  { path: 'apple/ClairApp/ContentView.swift', name: 'ContentView.swift', kind: 'swift', status: 'M', content: contentView },
  { path: 'apple/ClairApp/ClairApp.swift', name: 'ClairApp.swift', kind: 'swift', content: clairApp },
  { path: 'apple/ClairApp/PaneSplit.swift', name: 'PaneSplit.swift', kind: 'swift', status: 'A', content: paneSplit },
  {
    path: 'apple/ClairApp/WorkspaceChrome.swift',
    name: 'WorkspaceChrome.swift',
    kind: 'swift',
    content: workspaceChrome,
  },
  { path: 'apple/ClairApp/SessionRail.swift', name: 'SessionRail.swift', kind: 'swift', status: 'A', content: sessionRail },
  { path: 'clair-docs/site/index.md', name: 'index.md', kind: 'md', content: readme },
  { path: 'docs/architecture/pane-layout.md', name: 'pane-layout.md', kind: 'md', content: paneLayoutDoc },
];

export type TreeNode =
  | { type: 'project'; name: string; depth: 0; id: string }
  | { type: 'folder'; name: string; depth: number; id: string; parent: string }
  | { type: 'file'; name: string; depth: number; id: string; parent: string; path: string };

// The tree the Main artboard draws, in its own order.
export const tree: TreeNode[] = [
  { type: 'project', name: 'clair', depth: 0, id: 'clair' },
  { type: 'folder', name: 'apple', depth: 1, id: 'clair/apple', parent: 'clair' },
  { type: 'folder', name: 'ClairApp', depth: 2, id: 'clair/apple/ClairApp', parent: 'clair/apple' },
  {
    type: 'file',
    name: 'ContentView.swift',
    depth: 3,
    id: 'f1',
    parent: 'clair/apple/ClairApp',
    path: 'apple/ClairApp/ContentView.swift',
  },
  {
    type: 'file',
    name: 'ProjectWorkspace.swift',
    depth: 3,
    id: 'f2',
    parent: 'clair/apple/ClairApp',
    path: 'apple/ClairApp/ProjectWorkspace.swift',
  },
  {
    type: 'file',
    name: 'PaneSplit.swift',
    depth: 3,
    id: 'f3',
    parent: 'clair/apple/ClairApp',
    path: 'apple/ClairApp/PaneSplit.swift',
  },
  {
    type: 'file',
    name: 'WorkspaceChrome.swift',
    depth: 3,
    id: 'f4',
    parent: 'clair/apple/ClairApp',
    path: 'apple/ClairApp/WorkspaceChrome.swift',
  },
  {
    type: 'file',
    name: 'SessionRail.swift',
    depth: 3,
    id: 'f5',
    parent: 'clair/apple/ClairApp',
    path: 'apple/ClairApp/SessionRail.swift',
  },
  { type: 'folder', name: 'crates', depth: 1, id: 'clair/crates', parent: 'clair' },
  { type: 'folder', name: 'docs', depth: 1, id: 'clair/docs', parent: 'clair' },
  {
    type: 'file',
    name: 'pane-layout.md',
    depth: 2,
    id: 'f7',
    parent: 'clair/docs',
    path: 'docs/architecture/pane-layout.md',
  },
  { type: 'project', name: 'clair-docs', depth: 0, id: 'clair-docs' },
  { type: 'folder', name: 'site', depth: 1, id: 'clair-docs/site', parent: 'clair-docs' },
  { type: 'file', name: 'index.md', depth: 2, id: 'f6', parent: 'clair-docs/site', path: 'clair-docs/site/index.md' },
];

export type Command = {
  id: string;
  title: string;
  shortcut: string;
  risk: '追加' | '読み取り' | '破壊的';
};

// The catalogue the CommandPalette artboard ships in its own script block.
export const commands: Command[] = [
  { title: 'ペインを右に分割', id: 'clair.pane.split.horizontal', shortcut: '⌃⌘D', risk: '追加' },
  { title: 'ペインを下に分割', id: 'clair.pane.split.vertical', shortcut: '⌃⌘⇧D', risk: '追加' },
  { title: 'ペインのフォーカスを右へ', id: 'clair.pane.focus.right', shortcut: '⌃⌘→', risk: '読み取り' },
  { title: 'ペインを最大化', id: 'clair.pane.maximize', shortcut: '⌃⌘M', risk: '読み取り' },
  { title: '分割を均等化', id: 'clair.pane.equalize', shortcut: '⌃⌘=', risk: '読み取り' },
  { title: 'ペインを閉じる', id: 'clair.pane.close', shortcut: '⌃⌘W', risk: '破壊的' },
  { title: '変更を確認', id: 'clair.review.open', shortcut: '⌃⌘G', risk: '読み取り' },
  { title: 'マージグラフを開く', id: 'clair.graph.open', shortcut: '', risk: '読み取り' },
  { title: 'Agents を開く', id: 'clair.activity.open', shortcut: '', risk: '読み取り' },
  { title: 'セッションを開く', id: 'clair.sessions.open', shortcut: '⌃⌘L', risk: '読み取り' },
  { title: '実行とデバッグ', id: 'clair.debug.open', shortcut: '⇧⌘D', risk: '読み取り' },
  { title: 'Debug + AI統合（検討中）', id: 'clair.debug.agent', shortcut: '', risk: '読み取り' },
  { title: 'Agentを追加', id: 'clair.agent.add', shortcut: '⌃⌘N', risk: '追加' },
  { title: '設定を開く', id: 'clair.settings.open', shortcut: '⌘,', risk: '読み取り' },
];

export type Session = {
  id: string;
  agent: string;
  icon: 'codex' | 'claude' | 'zsh' | 'opencode';
  state: '入力待ち' | '実行中' | '待機' | 'exit 1';
  attention: boolean;
  project: string;
  context: string;
  worktree?: string;
  elapsed: string;
  signal: string;
  signalTime: string;
  quotaPercent?: number;
  quotaLabel?: string;
  quotaTight?: boolean;
  action: '移動 ↵' | '移動' | '再起動';
};

// The rows the SessionRail artboard draws.
export const sessions: Session[] = [
  {
    id: 's1',
    agent: 'codex',
    icon: 'codex',
    state: '入力待ち',
    attention: true,
    project: 'clair',
    context: 'Project root',
    elapsed: '4m 12s',
    signal: 'terminal bell',
    signalTime: '12:04:38',
    action: '移動 ↵',
  },
  {
    id: 's2',
    agent: 'Claude Code',
    icon: 'claude',
    state: '実行中',
    attention: false,
    project: 'clair',
    context: 'worktree',
    worktree: 'pane-split',
    elapsed: '18m 03s',
    signal: '公式hook: PostToolUse',
    signalTime: '12:08:51',
    quotaPercent: 62,
    quotaLabel: '残り38%',
    action: '移動',
  },
  {
    id: 's3',
    agent: 'Claude Code',
    icon: 'claude',
    state: '実行中',
    attention: false,
    project: 'ccedit',
    context: 'worktree',
    worktree: 'retire-rust-core',
    elapsed: '1h 42m',
    signal: '公式hook: Notification',
    signalTime: '11:31:02',
    quotaPercent: 84,
    quotaLabel: '残り16%',
    quotaTight: true,
    action: '移動',
  },
  {
    id: 's4',
    agent: 'zsh',
    icon: 'zsh',
    state: '待機',
    attention: false,
    project: 'clair',
    context: 'Project root',
    elapsed: '3h 06m',
    signal: '—',
    signalTime: '',
    action: '移動',
  },
  {
    id: 's5',
    agent: 'OpenCode',
    icon: 'opencode',
    state: 'exit 1',
    attention: false,
    project: 'clair-releases',
    context: 'Project root',
    elapsed: '—',
    signal: 'exit code 1',
    signalTime: '11:58:14',
    action: '再起動',
  },
];

export type ActivityItem = {
  id: string;
  glyph: string;
  title: string;
  meta: string;
  state: 'running' | 'selected' | 'attention' | 'done';
};

export const activityItems: ActivityItem[] = [
  { id: 'a1', glyph: '◐', title: 'clair のエディタ配置を確認', meta: '変更・たたみ · 1分前', state: 'running' },
  {
    id: 'a2',
    glyph: '◔',
    title: '復元テストの失敗箇所を調査',
    meta: 'WorkspaceRestoreTestsの結果 · 6分前',
    state: 'selected',
  },
  { id: 'a3', glyph: '●', title: '変更を適用する前に承認…', meta: 'エディタの余白の調整 · 2分前', state: 'attention' },
  { id: 'a4', glyph: '✓', title: 'WorkspaceView から参照…', meta: 'Swiftの依存関係を確認 · 11分前', state: 'done' },
];

export type ChatMessage = { id: string; from: 'user' | 'agent'; text: string; time: string };

export const chat: ChatMessage[] = [
  { id: 'm1', from: 'user', text: '保存した terminalPercent が次回起動時に丸められてしまう原因を見て。', time: '09:36' },
  {
    id: 'm2',
    from: 'agent',
    text: 'ccedit の ProjectLayout.restore() までは値が保持されています。UI側の境界値補正を確認します。',
    time: '09:37',
  },
  { id: 'm3', from: 'agent', text: '候補を2つ見つけました。再現条件を確認できたら修正案を適用します。', time: '09:38' },
];

export type ChangedFile = {
  path: string;
  name: string;
  added: number;
  removed: number;
  untracked?: boolean;
};

// Plain working-tree state (like `git status`), not a branch/PR diff — the
// stage/unstage split below is the interesting part; which commits produced
// history is the merge graph's job (see SourceControlModeTabs), not this
// panel's.
export const changedFiles: ChangedFile[] = [
  { path: 'apple/ClairApp/ProjectWorkspace.swift', name: 'ProjectWorkspace.swift', added: 42, removed: 9 },
  { path: 'apple/ClairApp/PaneSplit.swift', name: 'PaneSplit.swift', added: 88, removed: 0 },
  { path: 'apple/ClairApp/ContentView.swift', name: 'ContentView.swift', added: 16, removed: 31 },
  { path: 'apple/ClairApp/WorkspaceChrome.swift', name: 'WorkspaceChrome.swift', added: 7, removed: 0 },
  { path: 'apple/ClairTests/ProjectKernelTests.swift', name: 'ProjectKernelTests.swift', added: 54, removed: 0 },
  { path: 'apple/ClairApp/SessionRail.swift', name: 'SessionRail.swift', added: 0, removed: 0, untracked: true },
];

// Staged by default: the mock's initial "some reviewed, some not" state.
export const initiallyStagedPaths = [
  'apple/ClairApp/ProjectWorkspace.swift',
  'apple/ClairApp/PaneSplit.swift',
  'apple/ClairApp/ContentView.swift',
];

export type DiffLine = { old?: number; New?: number; sign: ' ' | '+' | '-'; text: string };

// The hunk the SourceControl artboard draws, line for line.
const projectWorkspaceDiff: DiffLine[] = [
  { old: 241, New: 241, sign: ' ', text: '  func updateSplitRatio(nodeID: UUID, ratio: Double) {' },
  { New: 242, sign: '+', text: '    let clamped = min(max(ratio, 0.08), 0.92)' },
  { New: 243, sign: '+', text: '    guard layout.ratio(of: nodeID) != clamped else {' },
  { New: 244, sign: '+', text: '      return' },
  { New: 245, sign: '+', text: '    }' },
  { old: 242, sign: '-', text: '    layout = layout.equalized()' },
  { New: 246, sign: '+', text: '    layout = layout.settingRatio(clamped, for: nodeID)' },
  { New: 247, sign: '+', text: '    persistWorkspace()' },
  { old: 243, New: 248, sign: ' ', text: '  }' },
  { old: 244, New: 249, sign: ' ', text: '' },
  { old: 245, New: 250, sign: ' ', text: '  /// Focus moves by geometry, not by pane index.' },
  { New: 251, sign: '+', text: '  func focusPane(direction: PaneDirection) {' },
  { New: 252, sign: '+', text: '    guard let next = layout.neighbor(' },
  { New: 253, sign: '+', text: '      of: focusedPaneID, direction: direction' },
  { New: 254, sign: '+', text: '    ) else { return }' },
  { New: 255, sign: '+', text: '    focusPane(id: next)' },
  { New: 256, sign: '+', text: '  }' },
  { old: 246, New: 257, sign: ' ', text: '}' },
];

const paneSplitDiff: DiffLine[] = [
  { New: 1, sign: '+', text: 'import SwiftUI' },
  { New: 2, sign: '+', text: '' },
  { New: 3, sign: '+', text: '/// A divider the user can drag.' },
  { New: 4, sign: '+', text: 'struct PaneDivider: View {' },
  { New: 5, sign: '+', text: '  let orientation: ProjectPaneOrientation' },
  { New: 6, sign: '+', text: '  let onDrag: (CGFloat) -> Void' },
  { New: 7, sign: '+', text: '}' },
];

const contentViewDiff: DiffLine[] = [
  { old: 4, New: 4, sign: ' ', text: 'struct ContentView: View {' },
  { old: 5, sign: '-', text: '  @State private var workspace = Workspace()' },
  { New: 5, sign: '+', text: '  @State private var workspace = Workspace.preview' },
  { old: 6, New: 6, sign: ' ', text: '' },
  { old: 7, New: 7, sign: ' ', text: '  var body: some View {' },
  { old: 8, sign: '-', text: '    WorkspaceView()' },
  { New: 8, sign: '+', text: '    WorkspaceView(workspace: workspace)' },
  { old: 9, New: 9, sign: ' ', text: '  }' },
];

const chromeDiff: DiffLine[] = [
  { old: 3, New: 3, sign: ' ', text: 'struct WorkspaceChrome: View {' },
  { New: 4, sign: '+', text: '  static let titlebarHeight: CGFloat = 48' },
  { New: 5, sign: '+', text: '  static let statusBarHeight: CGFloat = 26' },
  { old: 4, New: 6, sign: ' ', text: '}' },
];

const testsDiff: DiffLine[] = [
  { New: 12, sign: '+', text: '  func testSplitRatioIsClamped() {' },
  { New: 13, sign: '+', text: '    let kernel = ProjectKernel()' },
  { New: 14, sign: '+', text: '    kernel.updateSplitRatio(nodeID: root, ratio: 4.0)' },
  { New: 15, sign: '+', text: '    XCTAssertEqual(kernel.ratio(of: root), 0.92)' },
  { New: 16, sign: '+', text: '  }' },
];

const railDiff: DiffLine[] = [
  { New: 1, sign: '+', text: 'import SwiftUI' },
  { New: 2, sign: '+', text: '' },
  { New: 3, sign: '+', text: '/// Only facts available from the PTY reach this table.' },
  { New: 4, sign: '+', text: 'struct SessionRailView: View {' },
  { New: 5, sign: '+', text: '  let sessions: [TerminalSession]' },
  { New: 6, sign: '+', text: '}' },
];

export const diffs: Record<string, DiffLine[]> = {
  'apple/ClairApp/ProjectWorkspace.swift': projectWorkspaceDiff,
  'apple/ClairApp/PaneSplit.swift': paneSplitDiff,
  'apple/ClairApp/ContentView.swift': contentViewDiff,
  'apple/ClairApp/WorkspaceChrome.swift': chromeDiff,
  'apple/ClairTests/ProjectKernelTests.swift': testsDiff,
  'apple/ClairApp/SessionRail.swift': railDiff,
};

export type Commit = {
  subject: string;
  branch: 'main' | 'pane-split' | 'docs-update';
  author: string;
  when: string;
  hash: string;
  graph: 'merge' | 'onBranch' | 'branchOff' | 'onDocs' | 'branchOffDocs' | 'root';
};

// The rows the MergeGraph artboard draws.
export const commits: Commit[] = [
  { subject: 'Merge pane-split into main', branch: 'main', author: 'diwamoto', when: '3時間前', hash: 'a4f10c2', graph: 'merge' },
  { subject: 'Add focusPane keyboard nav', branch: 'pane-split', author: 'Claude', when: '5時間前', hash: '7e2c9a1', graph: 'onBranch' },
  { subject: 'Split branch: pane-split', branch: 'main', author: 'diwamoto', when: '1日前', hash: '3b6f0d4', graph: 'branchOff' },
  { subject: 'Update installation guide', branch: 'docs-update', author: 'Claude', when: '2日前', hash: 'c88e1f3', graph: 'onDocs' },
  { subject: 'Split branch: docs-update', branch: 'main', author: 'diwamoto', when: '3日前', hash: '5a2d9b6', graph: 'branchOffDocs' },
  { subject: 'Initial commit', branch: 'main', author: 'diwamoto', when: '2週間前', hash: '000f1a2', graph: 'root' },
];

export const branchColor: Record<Commit['branch'], string> = {
  main: '#5b88f7',
  'pane-split': '#8acb94',
  'docs-update': '#8b6ac8',
};

export const projects = ['clair', 'ccedit', 'clair-releases'] as const;

// The titlebar's non-active tab groups have no real editor content behind
// them (only `clair`'s files are mocked in full), but the group needs
// something to show when expanded. Labels are pulled from what the mock
// already says about each project elsewhere — ccedit's worktree session
// (s3) and the chat mention of `ProjectLayout.restore()` — rather than
// invented outright; `clair-releases` has no such trace, so its one tab is
// a plain placeholder.
export const projectTabs: Record<string, { path: string; name: string; kind: FileKind }[]> = {
  ccedit: [{ path: 'ccedit-core/src/project_layout.rs', name: 'project_layout.rs', kind: 'rust' }],
  'clair-releases': [{ path: 'CHANGELOG.md', name: 'CHANGELOG.md', kind: 'md' }],
};
