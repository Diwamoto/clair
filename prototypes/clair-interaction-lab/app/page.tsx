/* eslint-disable react-hooks/refs, @next/next/no-img-element */
'use client';

import { useEffect, useMemo, useRef, useState, type CSSProperties, type FormEvent, type PointerEvent as ReactPointerEvent } from 'react';

import { SourceSearchPanel, type SourceSearchMatch } from './SourceSearchPanel';
import {
  activityThreads as mockActivityThreads,
  agentUsage as mockAgentUsage,
  branchDiffs as mockBranchDiffs,
  debugSteps as mockDebugSteps,
  settingsSections as mockSettingsSections,
  sourceGraph as mockSourceGraph,
} from './mock-data';

type MainView = 'workspace' | 'search' | 'source-control' | 'activity' | 'debug' | 'settings';
type SurfaceKind = 'editor' | 'terminal';
type TerminalPosition = 'bottom' | 'right';
type TerminalSplit = 'columns' | 'rows';
type TerminalShell = 'claude' | 'zsh';
type GitChangeKind = 'modified' | 'added' | 'deleted';
type GitView = 'inline' | 'split' | 'graph';
type SettingsSectionId = 'general' | 'agents' | 'editor' | 'terminal' | 'mobile' | 'updates';
type ChatRole = 'agent' | 'user' | 'system';
type ApprovalDecision = 'pending' | 'allowed' | 'session' | 'denied';
type MobileReviewTab = 'overview' | 'sessions' | 'activity' | 'settings';
type MobileSessionFixture = { id: string; projectId: string; label: string; profile: string; model: string; status: 'running' | 'attention' | 'idle' | 'exited'; cwd: string; branch: string; lines: string[] };

type TerminalSession = {
  id: string;
  label: string;
  shell: TerminalShell;
  cwd: string;
  lines: string[];
  input: string;
};

type ProjectGroup = {
  id: string;
  name: string;
  root: string;
  color: string;
  collapsed: boolean;
  activeFile: string;
  terminalVisible: boolean;
  terminalPosition: TerminalPosition;
  terminalPercent: number;
  activeTerminalId: string;
  terminalSplit: TerminalSplit;
  terminals: TerminalSession[];
};

type GitChange = { path: string; kind: GitChangeKind; staged: boolean };
type GitProjectState = { branch: string; ahead: number; behind: number; commitMessage: string; changes: GitChange[] };
type DiffLine = { old: number | null; next: number | null; kind: 'context' | 'add' | 'remove'; text: string };
type ActivityMessage = { id: string; role: ChatRole; text: string; time: string };
type ActivityApproval = { id: string; tool: string; title: string; command: string; cwd: string; reason: string; risk: string; decision: ApprovalDecision };
type ActivityThread = { id: string; agentId: string; agentName: string; provider: string; projectId: string; terminalId: string; status: 'working' | 'waiting' | 'done'; title: string; summary: string; updatedAt: string; messages: ActivityMessage[]; review?: ActivityChangeReview; approval?: ActivityApproval };
type AgentUsage = { id: string; name: string; shortName: string; color: string; reset5h: string; reset7d: string; used5h: number; used7d: number; remaining5h: number; remaining7d: number };
type SettingCatalog = { id: SettingsSectionId; label: string; description: string };
type BranchFile = { path: string; kind: GitChangeKind; additions: number; deletions: number; diff: DiffLine[] };
type BranchDiff = { branch: string; base: string; summary: string; files: BranchFile[] };
type ActivityChangeReview = { summary: string; files: BranchFile[] };
type ActivityReviewComment = { id: string; filePath: string; lineIndex: number; old: number | null; next: number | null; kind: DiffLine['kind']; text: string };
type AgentLaunchTarget = 'terminal' | 'activity';
type WorktreeMode = 'current' | 'new';
type AddAgentRequest = { agentId: string; modelId: string; launchTarget: AgentLaunchTarget; worktree: string; profile: 'review' | 'implement' | 'debug'; confirmChanges: boolean };
type GraphNode = { id: string; label: string; detail: string; kind: 'file' | 'type' | 'entry'; x: number; y: number };
type GraphEdge = { from: string; to: string };
type DebugStep = { id: string; line: number; label: string; source: string; code: string; locals: Array<{ name: string; value: string; type: string }> };
type ToastState = { title: string; detail: string; action?: string };

const groupColors = ['#d9b76d', '#83b58d', '#7b9dd8'];
const branchOptions = ['main', 'feature/native-workspace', 'design/git-shell'];
const customModelChoice = '__custom';
const defaultModelChoice = '__default';
const agentModelCatalog: Record<string, Array<{ id: string; label: string }>> = {
  codex: [{ id: 'gpt-5.6', label: 'GPT-5.6' }, { id: 'gpt-5.5', label: 'GPT-5.5' }],
  'claude-code': [{ id: 'sonnet', label: 'Sonnet' }, { id: 'opus', label: 'Opus' }, { id: 'haiku', label: 'Haiku' }],
  opencode: [],
};

const fileTree = [
  { folder: 'App', files: ['ClairApp.swift', 'WorkspaceView.swift'] },
  { folder: 'Editor', files: ['EditorPane.swift'] },
  { folder: 'Tests', files: ['WorkspaceRestoreTests.swift'] },
  { folder: '', files: ['README.md'] },
];
const allFileNames = fileTree.flatMap((folder) => folder.files);

const samples: Record<string, string> = {
  'ClairApp.swift': ['import SwiftUI', '', '@main', 'struct ClairApp: App {', '    @State private var workspace = Workspace.preview', '', '    var body: some Scene {', '        WindowGroup {', '            WorkspaceView(workspace: workspace)', '                .frame(minWidth: 920, minHeight: 620)', '        }', '        .windowStyle(.hiddenTitleBar)', '    }', '}'].join('\n'),
  'WorkspaceView.swift': ['import SwiftUI', '', 'struct WorkspaceView: View {', '    let workspace: Workspace', '', '    var body: some View {', '        NavigationSplitView {', '            FileTree(workspace: workspace)', '        } detail: {', '            EditorPane(document: workspace.activeDocument)', '        }', '    }', '}'].join('\n'),
  'EditorPane.swift': ['import AppKit', 'import SwiftUI', '', 'struct EditorPane: NSViewRepresentable {', '    let document: SourceDocument', '', '    func makeNSView(context: Context) -> SourceEditorView {', '        let view = SourceEditorView(document: document)', '        view.restoreSelection()', '        return view', '    }', '', '    func updateNSView(_ view: SourceEditorView, context: Context) {', '        view.open(document)', '    }', '}'].join('\n'),
  'WorkspaceRestoreTests.swift': ['import Testing', '@testable import Clair', '', '@Test func restoresProjectLayout() {', '    #expect(ProjectLayout.restore().terminalPosition == .right)', '}'].join('\n'),
  'README.md': ['# Clair', '', 'A native macOS workspace for focused coding.', '', '## First slice', '', '- Native source editor', '- Familiar project hierarchy', '- Terminal when you need it'].join('\n'),
};

const sourcePaths: Record<string, string> = {
  'ClairApp.swift': 'App/ClairApp.swift',
  'WorkspaceView.swift': 'App/WorkspaceView.swift',
  'EditorPane.swift': 'Editor/EditorPane.swift',
  'WorkspaceRestoreTests.swift': 'Tests/WorkspaceRestoreTests.swift',
  'README.md': 'README.md',
};

function createTerminalSession(id: string, index: number, shell: TerminalShell = 'claude', cwd = '~/Projects/clair'): TerminalSession {
  return {
    id,
    label: index === 1 ? 'ターミナル · ' + shell : 'ターミナル ' + index + ' · ' + shell,
    shell,
    cwd,
    lines: shell === 'claude' ? ['Claude Code · Opus 4.1', 'Project: ' + cwd, '', '● ワークスペースの状態を読み込み中…', '  ✓ Projectの構成を確認', '  ⟷ Projectごとの分割レイアウトを保持', '', '実行中…  escで中断'] : ['zsh', '作業ディレクトリ: ' + cwd, '', 'コマンド入力待ち。'],
    input: '',
  };
}

const initialProjectGroups: ProjectGroup[] = [
  { id: 'clair', name: 'clair', root: '~/Projects/clair', color: groupColors[0], collapsed: false, activeFile: 'ClairApp.swift', terminalVisible: true, terminalPosition: 'right', terminalPercent: 36, activeTerminalId: 'clair-terminal', terminalSplit: 'columns', terminals: [createTerminalSession('clair-terminal', 1)] },
  { id: 'ccedit', name: 'ccedit', root: '~/Projects/ccedit', color: groupColors[1], collapsed: true, activeFile: 'WorkspaceView.swift', terminalVisible: true, terminalPosition: 'bottom', terminalPercent: 40, activeTerminalId: 'ccedit-terminal', terminalSplit: 'columns', terminals: [createTerminalSession('ccedit-terminal', 1, 'claude', '~/Projects/ccedit')] },
  { id: 'clair-releases', name: 'clair-releases', root: '~/Projects/clair-releases', color: groupColors[2], collapsed: true, activeFile: 'README.md', terminalVisible: false, terminalPosition: 'bottom', terminalPercent: 34, activeTerminalId: 'releases-terminal', terminalSplit: 'columns', terminals: [createTerminalSession('releases-terminal', 1, 'zsh', '~/Projects/clair-releases')] },
];

const initialGitStates: Record<string, GitProjectState> = {
  clair: { branch: 'feature/native-workspace', ahead: 2, behind: 1, commitMessage: '', changes: [{ path: 'App/EditorPane.swift', kind: 'modified', staged: true }, { path: 'App/WorkspaceView.swift', kind: 'modified', staged: false }, { path: 'Tests/WorkspaceRestoreTests.swift', kind: 'added', staged: false }] },
  ccedit: { branch: 'main', ahead: 0, behind: 0, commitMessage: '', changes: [{ path: 'src/components/Sidebar/GitPanel.tsx', kind: 'modified', staged: false }, { path: 'src-tauri/src/git/ops.rs', kind: 'modified', staged: false }] },
  'clair-releases': { branch: 'main', ahead: 0, behind: 0, commitMessage: '', changes: [] },
};

const gitDiffs: Record<string, DiffLine[]> = {
  'App/EditorPane.swift': [
    { old: 7, next: 7, kind: 'context', text: '    func makeNSView(context: Context) -> SourceEditorView {' },
    { old: 8, next: null, kind: 'remove', text: '        SourceEditorView(document: document)' },
    { old: null, next: 8, kind: 'add', text: '        let view = SourceEditorView(document: document)' },
    { old: null, next: 9, kind: 'add', text: '        view.restoreSelection()' },
    { old: null, next: 10, kind: 'add', text: '        return view' },
    { old: 9, next: 11, kind: 'context', text: '    }' },
  ],
  'App/WorkspaceView.swift': [
    { old: 7, next: 7, kind: 'context', text: '        NavigationSplitView {' },
    { old: 8, next: null, kind: 'remove', text: '            FileTree(workspace: workspace)' },
    { old: null, next: 8, kind: 'add', text: '            ProjectSidebar(project: workspace.project)' },
    { old: 9, next: 9, kind: 'context', text: '        } detail: {' },
    { old: 10, next: 10, kind: 'context', text: '            EditorPane(document: workspace.activeDocument)' },
  ],
  'Tests/WorkspaceRestoreTests.swift': [
    { old: null, next: 1, kind: 'add', text: 'import Testing' },
    { old: null, next: 2, kind: 'add', text: '@testable import Clair' },
    { old: null, next: 3, kind: 'add', text: '' },
    { old: null, next: 4, kind: 'add', text: '@Test func restoresProjectLayout() {' },
    { old: null, next: 5, kind: 'add', text: '    #expect(ProjectLayout.restore().terminalPosition == .right)' },
    { old: null, next: 6, kind: 'add', text: '}' },
  ],
  'src/components/Sidebar/GitPanel.tsx': [
    { old: 42, next: 42, kind: 'context', text: 'export function GitPanel({ project }: GitPanelProps) {' },
    { old: 43, next: null, kind: 'remove', text: '  return <Panel project={project} />' },
    { old: null, next: 43, kind: 'add', text: '  return <Panel project={project} showBranchGraph />' },
    { old: 44, next: 44, kind: 'context', text: '}' },
  ],
  'src-tauri/src/git/ops.rs': [
    { old: 18, next: 18, kind: 'context', text: 'pub fn current_branch(repo: &Repository) -> Result<String> {' },
    { old: 19, next: null, kind: 'remove', text: '    repo.head()?.shorthand().unwrap_or("HEAD")' },
    { old: null, next: 19, kind: 'add', text: '    repo.head()?.name().unwrap_or("HEAD").to_string()' },
  ],
};

const fallbackAgentUsage: AgentUsage[] = [
  { id: 'codex', name: 'Codex', shortName: 'Codex', color: '#8f9bab', reset5h: '4h 54m', reset7d: '6d 13h', used5h: 0, used7d: 7, remaining5h: 100, remaining7d: 93 },
  { id: 'claude-code', name: 'Claude Code', shortName: 'Claude', color: '#c78f6a', reset5h: '2h 12m', reset7d: '5d 08h', used5h: 18, used7d: 34, remaining5h: 82, remaining7d: 66 },
  { id: 'opencode', name: 'OpenCode', shortName: 'OpenCode', color: '#7d9bd2', reset5h: '1h 38m', reset7d: '4d 21h', used5h: 9, used7d: 21, remaining5h: 91, remaining7d: 79 },
];

const fallbackClaudeApproval: ActivityApproval = {
  id: 'approval-claude-edit',
  tool: 'Bash',
  title: '変更を適用してテストを実行しますか？',
  command: 'git diff --check && swift test --package-path packages/ClairMobileKit',
  cwd: '~/Projects/ccedit',
  reason: 'Claude Codeがワークツリーを検証し、変更後のテストを実行しようとしています。',
  risk: 'ローカルのテストコマンドを実行',
  decision: 'pending',
};

const fallbackActivityThreads: ActivityThread[] = [
  { id: 'thread-codex', agentId: 'codex', agentName: 'Codex', provider: 'Codex', projectId: 'clair', terminalId: 'clair-terminal', status: 'working', title: 'ワークスペースのレイアウトを確認', summary: 'エディタの表示密度を整え、Projectごとのターミナル配置を復元しています。', updatedAt: 'たった今', messages: [{ id: 'codex-1', role: 'agent', text: '現在のProject構成を確認し、各ターミナルの配置をProjectごとに保持しました。', time: '09:42' }, { id: 'codex-2', role: 'agent', text: 'ナビゲーションと使用量フッターを確認できる状態にしました。', time: '09:44' }] },
  { id: 'thread-claude', agentId: 'claude-code', agentName: 'Claude Code', provider: 'Claude Code', projectId: 'ccedit', terminalId: 'ccedit-terminal', status: 'waiting', title: 'Gitパネルを確認', summary: '変更を適用する前に承認が必要です。', updatedAt: '4分前', messages: [{ id: 'claude-1', role: 'agent', text: 'cceditで2件のワークツリー変更と、表示すべきブランチ比較を1件見つけました。', time: '09:38' }, { id: 'claude-2', role: 'system', text: 'Claude Codeが承認を待っています。内容を確認して選択してください。', time: '09:39' }], approval: fallbackClaudeApproval },
  { id: 'thread-opencode', agentId: 'opencode', agentName: 'OpenCode', provider: 'OpenCode', projectId: 'clair-releases', terminalId: 'releases-terminal', status: 'done', title: 'リリースノートを確認', summary: 'リリース用Projectを確認し、問題なく終了しました。', updatedAt: '18分前', messages: [{ id: 'open-1', role: 'agent', text: 'リリースノートは現在のmainブランチと整合しています。', time: '09:24' }, { id: 'open-2', role: 'system', text: 'プロセスはコード0で終了しました。', time: '09:25' }] },
];

const fallbackSettings: SettingCatalog[] = [
  { id: 'general', label: '一般', description: 'ワークスペースの基本動作とアプリ全体の表示を設定します。' },
  { id: 'agents', label: 'AIプロバイダー', description: '接続しているコーディングAgentとアカウントを管理します。' },
  { id: 'editor', label: 'エディタ', description: '文字組み、折り返し、ソース編集の設定です。' },
  { id: 'terminal', label: 'ターミナル', description: 'シェルセッションとパネルの配置を設定します。' },
  { id: 'mobile', label: 'モバイル接続', description: 'このワークスペースにモバイル端末を接続します。' },
  { id: 'updates', label: 'アップデート', description: 'リリースチャンネルと更新確認を設定します。' },
];

const fallbackBranchDiffs: BranchDiff[] = [
  { branch: 'feature/native-workspace', base: 'main', summary: '3ファイル変更 · +8 −2', files: [{ path: 'App/EditorPane.swift', kind: 'modified', additions: 3, deletions: 1, diff: gitDiffs['App/EditorPane.swift'] }, { path: 'App/WorkspaceView.swift', kind: 'modified', additions: 1, deletions: 1, diff: gitDiffs['App/WorkspaceView.swift'] }, { path: 'Tests/WorkspaceRestoreTests.swift', kind: 'added', additions: 4, deletions: 0, diff: gitDiffs['Tests/WorkspaceRestoreTests.swift'] }] },
  { branch: 'design/git-shell', base: 'main', summary: '2ファイル変更 · +2 −2', files: [{ path: 'src/components/Sidebar/GitPanel.tsx', kind: 'modified', additions: 1, deletions: 1, diff: gitDiffs['src/components/Sidebar/GitPanel.tsx'] }, { path: 'src-tauri/src/git/ops.rs', kind: 'modified', additions: 1, deletions: 1, diff: gitDiffs['src-tauri/src/git/ops.rs'] }] },
];

const fallbackActivityReviews: Record<string, ActivityChangeReview> = {
  'thread-codex-workspace': { summary: fallbackBranchDiffs[0].summary, files: fallbackBranchDiffs[0].files },
  'thread-claude-editor': { summary: fallbackBranchDiffs[1].summary, files: fallbackBranchDiffs[1].files },
  'thread-codex': { summary: fallbackBranchDiffs[0].summary, files: fallbackBranchDiffs[0].files },
  'thread-claude': { summary: fallbackBranchDiffs[1].summary, files: fallbackBranchDiffs[1].files },
};

const fallbackGraph = { nodes: [{ id: 'app', label: 'ClairApp', detail: 'アプリの入口', kind: 'entry' as const, x: 9, y: 16 }, { id: 'workspace', label: 'WorkspaceView', detail: 'SwiftUIビュー', kind: 'type' as const, x: 35, y: 44 }, { id: 'editor', label: 'EditorPane', detail: 'NSViewRepresentable', kind: 'type' as const, x: 65, y: 44 }, { id: 'restore', label: 'ProjectLayout', detail: 'テスト', kind: 'file' as const, x: 46, y: 77 }], edges: [{ from: 'app', to: 'workspace' }, { from: 'workspace', to: 'editor' }, { from: 'workspace', to: 'restore' }] };

const fallbackDebugSteps: DebugStep[] = [
  { id: 'debug-1', line: 4, label: 'ClairAppを作成', source: 'ClairApp.swift', code: 'struct ClairApp: App {', locals: [{ name: 'workspace', value: 'Workspace.preview', type: 'Workspace' }] },
  { id: 'debug-2', line: 8, label: 'シーンを構築', source: 'ClairApp.swift', code: 'WindowGroup {', locals: [{ name: 'workspace', value: 'Workspace.preview', type: 'Workspace' }, { name: 'scene', value: 'WindowGroup', type: 'Scene' }] },
  { id: 'debug-3', line: 9, label: 'ワークスペースを開く', source: 'ClairApp.swift', code: 'WorkspaceView(workspace: workspace)', locals: [{ name: 'workspace', value: 'Workspace.preview', type: 'Workspace' }, { name: 'activeDocument', value: 'ClairApp.swift', type: 'SourceDocument' }] },
  { id: 'debug-4', line: 10, label: 'フレームを適用', source: 'ClairApp.swift', code: '.frame(minWidth: 920, minHeight: 620)', locals: [{ name: 'minWidth', value: '920', type: 'CGFloat' }, { name: 'minHeight', value: '620', type: 'CGFloat' }] },
];

// Go + AIエージェント統合のデバッグシナリオ。DAP (set_breakpoint/continue/get_state/evaluate) を
// Agentが自律的に叩いて nil ポインタ参照を診断し、修正パッチを提案する一連の流れを固定データで再現する。
const goAgentDebugScenario = {
  file: 'main.go',
  breakpointLine: 40,
  callStack: [
    { label: 'handleGetUser', location: 'main.go:40', active: true },
    { label: 'ServeHTTP', location: 'mux.go:114', active: false },
    { label: 'main', location: 'main.go:18', active: false },
  ],
  variables: [
    { name: 'user', value: '*User · nil', danger: true },
    { name: 'id', value: 'string · "u_9921"', danger: false },
    { name: 'r.Method', value: 'string · "GET"', danger: false },
  ],
  code: [
    { line: 34, text: 'func (s *Server) handleGetUser(w http.ResponseWriter, r *http.Request) {' },
    { line: 35, text: '    id := r.URL.Query().Get("id")' },
    { line: 36, text: '    user := s.store.Find(id)' },
    { line: 37, text: '' },
    { line: 38, text: '    w.Header().Set("Content-Type", "application/json")' },
    { line: 39, text: '    json.NewEncoder(w).Encode(map[string]string{' },
    { line: 40, text: '        "name": user.Name,', current: true },
    { line: 41, text: '    })' },
    { line: 42, text: '}' },
  ],
  transcript: [
    { tool: 'dap.set_breakpoint(main.go:40)', detail: 'breakpoint id=1 を設定' },
    { tool: 'dap.continue()', detail: 'stopped: breakpoint main.go:40' },
    { tool: 'dap.get_state()', detail: 'frame handleGetUser · user = nil · id = "u_9921"' },
    { tool: 'dap.evaluate("s.store.Find(id)")', detail: '→ (nil, false)' },
  ],
  diagnosis: 'user が nil のまま Name にアクセスしています。Find() は未検出時に nil を返す実装なので、呼び出し側に nil チェックが必要です。修正案を作成しました。',
  patch: {
    removed: ['"name": user.Name,'],
    added: ['if user == nil {', '    http.Error(w, "not found", http.StatusNotFound)', '    return', '}', '"name": user.Name,'],
  },
};

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null ? value as Record<string, unknown> : null;
}
function stringValue(value: unknown, fallback: string) { return typeof value === 'string' && value ? value : fallback; }
function numberValue(value: unknown, fallback: number) { return typeof value === 'number' && Number.isFinite(value) ? value : fallback; }
function safeArray(value: unknown) { return Array.isArray(value) ? value : []; }

function normalizeAgentUsage(value: unknown): AgentUsage[] {
  const record = asRecord(value);
  const source = Array.isArray(value) ? value : Object.values(record ?? {});
  const result = source.map((raw, index) => {
    const item = asRecord(raw) ?? {};
    const five = asRecord(item.fiveHour ?? item.five_h ?? item.five) ?? {};
    const seven = asRecord(item.sevenDay ?? item.seven_day ?? item.week) ?? {};
    const used5h = numberValue(item.used5h ?? item.used_5h ?? five.usedPercent ?? item.usedPercent, fallbackAgentUsage[index]?.used5h ?? 0);
    const used7d = numberValue(item.used7d ?? item.used_7d ?? seven.usedPercent, fallbackAgentUsage[index]?.used7d ?? 0);
    const name = stringValue(item.name ?? item.label, fallbackAgentUsage[index]?.name ?? 'Agent');
    return { id: stringValue(item.id, fallbackAgentUsage[index]?.id ?? 'agent-' + index), name, shortName: stringValue(item.shortName, name === 'Claude Code' ? 'Claude' : name), color: stringValue(item.color, fallbackAgentUsage[index]?.color ?? groupColors[index % groupColors.length]), reset5h: stringValue(item.reset5h ?? five.reset, fallbackAgentUsage[index]?.reset5h ?? '4h 54m'), reset7d: stringValue(item.reset7d ?? seven.reset, fallbackAgentUsage[index]?.reset7d ?? '6d 13h'), used5h, used7d, remaining5h: numberValue(item.remaining5h ?? five.remainingPercent, 100 - used5h), remaining7d: numberValue(item.remaining7d ?? seven.remainingPercent, 100 - used7d) };
  });
  return result.length ? result : fallbackAgentUsage;
}

function normalizeDiffLines(value: unknown): DiffLine[] {
  return safeArray(value).map((rawLine) => {
    const line = asRecord(rawLine) ?? {};
    const left = asRecord(line.left);
    const right = asRecord(line.right);
    const kind = line.kind === 'add' ? 'add' : line.kind === 'remove' ? 'remove' : 'context';
    return { old: typeof line.old === 'number' ? line.old : typeof left?.line === 'number' ? left.line : null, next: typeof line.next === 'number' ? line.next : typeof right?.line === 'number' ? right.line : null, kind, text: stringValue(line.text ?? right?.text ?? left?.text, '') } as DiffLine;
  });
}

function normalizeActivityReview(value: unknown, fallback?: ActivityChangeReview): ActivityChangeReview | undefined {
  const record = asRecord(value);
  const source = Array.isArray(value) ? value : safeArray(record?.files ?? record?.changes);
  const files = source.map((rawFile, index) => {
    const file = asRecord(rawFile) ?? {};
    const fileFallback = fallback?.files[index] ?? fallback?.files[0];
    const directLines = safeArray(file.diff ?? file.lines);
    const hunkLines = safeArray(file.hunks).flatMap((rawHunk) => safeArray(asRecord(rawHunk)?.lines));
    const diff = normalizeDiffLines(directLines.length ? directLines : hunkLines);
    const status = file.status ?? file.kind;
    const kind: GitChangeKind = status === 'added' ? 'added' : status === 'deleted' ? 'deleted' : 'modified';
    return { path: stringValue(file.path, fileFallback?.path ?? `変更されたファイル ${index + 1}`), kind, additions: numberValue(file.additions, fileFallback?.additions ?? 0), deletions: numberValue(file.deletions, fileFallback?.deletions ?? 0), diff: diff.length ? diff : fileFallback?.diff ?? [] };
  });
  if (!files.length) return fallback;
  const summaryRecord = asRecord(record?.summary);
  const additions = files.reduce((total, file) => total + file.additions, 0);
  const deletions = files.reduce((total, file) => total + file.deletions, 0);
  const summary = stringValue(record?.summary, typeof summaryRecord === 'object' ? `${numberValue(summaryRecord.filesChanged, files.length)}ファイル変更 · +${numberValue(summaryRecord.additions, additions)} −${numberValue(summaryRecord.deletions, deletions)}` : fallback?.summary ?? `${files.length}ファイル変更 · +${additions} −${deletions}`);
  return { summary, files };
}

function normalizeActivityApproval(value: unknown, fallback?: ActivityApproval): ActivityApproval | undefined {
  const item = asRecord(value);
  if (!item && !fallback) return undefined;
  const source = item ?? {};
  const rawDecision = source.decision;
  const decision: ApprovalDecision = rawDecision === 'allowed' || rawDecision === 'session' || rawDecision === 'denied' ? rawDecision : fallback?.decision ?? 'pending';
  return {
    id: stringValue(source.id, fallback?.id ?? 'approval-request'),
    tool: stringValue(source.tool ?? source.toolName, fallback?.tool ?? 'Bash'),
    title: stringValue(source.title, fallback?.title ?? 'Agentの操作を確認してください'),
    command: stringValue(source.command ?? source.input, fallback?.command ?? 'コマンドの内容を確認してください'),
    cwd: stringValue(source.cwd ?? source.workingDirectory, fallback?.cwd ?? '~/Projects/clair'),
    reason: stringValue(source.reason ?? source.description, fallback?.reason ?? 'Agentが実行前の確認を求めています。'),
    risk: stringValue(source.risk, fallback?.risk ?? 'ローカルの操作'),
    decision,
  };
}

function normalizeActivityThreads(value: unknown): ActivityThread[] {
  const result = safeArray(value).map((raw, index) => {
    const item = asRecord(raw) ?? {};
    const fallback = fallbackActivityThreads[index] ?? fallbackActivityThreads[0];
    const id = stringValue(item.id, fallback.id);
    const projectId = stringValue(item.projectId ?? item.project, fallback.projectId);
    const messages = safeArray(item.messages).map((rawMessage, messageIndex) => {
      const message = asRecord(rawMessage) ?? {};
      const role = message.role === 'user' ? 'user' : message.role === 'system' ? 'system' : 'agent';
      return { id: stringValue(message.id, `${stringValue(item.id, fallback.id)}-${messageIndex}`), role, text: stringValue(message.text ?? message.content, 'Agentからの更新です。'), time: stringValue(message.time ?? message.timestamp, '') };
    });
    const status = item.status === 'waiting' ? 'waiting' : item.status === 'done' || item.status === 'completed' ? 'done' : 'working';
    return { id, agentId: stringValue(item.agentId ?? item.agent, fallback.agentId), agentName: stringValue(item.agentName ?? item.agentLabel ?? item.name, fallback.agentName), provider: stringValue(item.provider, fallback.provider), projectId, terminalId: stringValue(item.terminalId, `${projectId}-terminal`), status, title: stringValue(item.title, fallback.title), summary: stringValue(item.summary, fallback.summary), updatedAt: stringValue(item.updatedAt, fallback.updatedAt), messages: messages.length ? messages : fallback.messages, review: normalizeActivityReview(item.review ?? item.changes, fallbackActivityReviews[id]), approval: normalizeActivityApproval(item.approval, fallback.approval) };
  });
  return result.length ? result : fallbackActivityThreads;
}

function normalizeSettings(value: unknown): SettingCatalog[] {
  const result = safeArray(value).map((raw, index) => {
    const item = asRecord(raw) ?? {};
    const fallback = fallbackSettings[index] ?? fallbackSettings[0];
    const rawId = stringValue(item.id, fallback.id);
    const id = ({ 'ai-providers': 'agents', 'AI Providers': 'agents', 'Mobile': 'mobile', 'Editor': 'editor', 'Terminal': 'terminal', 'Updates': 'updates', '一般': 'general' } as Record<string, string>)[rawId] ?? rawId as SettingsSectionId;
    return { id, label: stringValue(item.label ?? item.name, fallback.label), description: stringValue(item.description, fallback.description) };
  }).filter((section) => fallbackSettings.some((item) => item.id === section.id));
  const unique = Array.from(new Map(result.map((section) => [section.id, section])).values());
  return unique.length ? fallbackSettings.map((fallback) => unique.find((section) => section.id === fallback.id) ?? fallback) : fallbackSettings;
}

function normalizeBranchDiffs(value: unknown): BranchDiff[] {
  const record = asRecord(value);
  const source = Array.isArray(value) ? value : Object.entries(record ?? {}).map(([key, branch]) => ({ ...(asRecord(branch) ?? {}), branch: stringValue(asRecord(branch)?.branch ?? asRecord(branch)?.compareBranch, key) }));
  const result = source.map((raw, index) => {
    const item = asRecord(raw) ?? {};
    const fallback = fallbackBranchDiffs[index] ?? fallbackBranchDiffs[0];
    const files = safeArray(item.files).map((rawFile, fileIndex) => {
      const file = asRecord(rawFile) ?? {};
      const fileFallback = fallback.files[fileIndex] ?? fallback.files[0];
      const directLines = safeArray(file.diff ?? file.lines);
      const hunkLines = safeArray(file.hunks).flatMap((rawHunk) => safeArray(asRecord(rawHunk)?.lines));
      const diff = (directLines.length ? directLines : hunkLines).map((rawLine) => {
        const line = asRecord(rawLine) ?? {};
        const left = asRecord(line.left);
        const right = asRecord(line.right);
        const kind = line.kind === 'add' ? 'add' : line.kind === 'remove' ? 'remove' : 'context';
        return { old: typeof line.old === 'number' ? line.old : typeof left?.line === 'number' ? left.line : null, next: typeof line.next === 'number' ? line.next : typeof right?.line === 'number' ? right.line : null, kind, text: stringValue(line.text ?? right?.text ?? left?.text, '') } as DiffLine;
      });
      const status = file.status ?? file.kind;
      return { path: stringValue(file.path, fileFallback.path), kind: status === 'added' || status === 'deleted' ? status : 'modified', additions: numberValue(file.additions, fileFallback.additions), deletions: numberValue(file.deletions, fileFallback.deletions), diff: diff.length ? diff : fileFallback.diff };
    });
    const summary = asRecord(item.summary);
    const summaryText = typeof item.summary === 'string' ? item.summary : `${numberValue(summary?.filesChanged, files.length)}ファイル変更 · +${numberValue(summary?.additions, 0)} −${numberValue(summary?.deletions, 0)}`;
    return { branch: stringValue(item.branch ?? item.compareBranch, fallback.branch), base: stringValue(item.base ?? item.baseBranch, fallback.base), summary: summaryText, files: files.length ? files : fallback.files };
  });
  return result.length ? result : fallbackBranchDiffs;
}

function normalizeGraph(value: unknown) {
  const item = asRecord(value) ?? {};
  const nodes = safeArray(item.nodes).map((raw, index) => {
    const node = asRecord(raw) ?? {};
    const fallback = fallbackGraph.nodes[index] ?? fallbackGraph.nodes[0];
    const kind = node.type === 'file' ? 'file' : node.kind === 'entry' ? 'entry' : node.kind === 'file' || node.kind === 'type' ? node.kind : fallback.kind;
    return { id: stringValue(node.id, fallback.id), label: stringValue(node.label ?? node.name, fallback.label), detail: stringValue(node.detail ?? (typeof node.file === 'string' ? `${node.file}:${numberValue(node.line, 0)}` : null), fallback.detail), kind, x: numberValue(node.x, 12 + (index % 3) * 34), y: numberValue(node.y, 16 + Math.floor(index / 3) * 25) } as GraphNode;
  });
  const edges = safeArray(item.edges).map((raw) => { const edge = asRecord(raw) ?? {}; return { from: stringValue(edge.from ?? edge.source, ''), to: stringValue(edge.to ?? edge.target, '') }; }).filter((edge) => edge.from && edge.to);
  return { nodes: nodes.length ? nodes : fallbackGraph.nodes, edges: edges.length ? edges : fallbackGraph.edges };
}

function normalizeDebugSteps(value: unknown): DebugStep[] {
  const record = asRecord(value);
  const source = Array.isArray(value) ? value : safeArray(record?.trace);
  const variables = safeArray(record?.variables);
  const result = source.map((raw, index) => {
    const item = asRecord(raw) ?? {};
    const fallback = fallbackDebugSteps[index] ?? fallbackDebugSteps[0];
    const locals = safeArray(item.locals ?? variables).map((rawLocal) => { const local = asRecord(rawLocal) ?? {}; return { name: stringValue(local.name, 'value'), value: stringValue(local.value, '—'), type: stringValue(local.type, 'Any') }; });
    const file = stringValue(item.file ?? item.source, fallback.source);
    return { id: stringValue(item.id, fallback.id), line: numberValue(item.line, fallback.line), label: stringValue(item.label, fallback.label), source: file.split('/').pop() ?? file, code: stringValue(item.code, fallback.code), locals: locals.length ? locals.slice(0, 6) : fallback.locals };
  });
  return result.length ? result : fallbackDebugSteps;
}

const agentUsage = normalizeAgentUsage(mockAgentUsage);
const activityThreads = normalizeActivityThreads(mockActivityThreads);
const settingsCatalog = normalizeSettings(mockSettingsSections);
const branchDiffs = Array.from(new Map([...fallbackBranchDiffs, ...normalizeBranchDiffs(mockBranchDiffs)].map((branch) => [branch.branch, branch])).values());
const sourceGraph = normalizeGraph(mockSourceGraph);
const debugSteps = normalizeDebugSteps(mockDebugSteps);
const defaultDebugStepIndex = Math.max(0, Math.min(debugSteps.length - 1, numberValue(asRecord(mockDebugSteps)?.currentStep, 1) - 1));

function commandResult(command: string, branch: string, cwd: string) {
  const normalized = command.trim();
  if (normalized === 'pwd') return [cwd];
  if (normalized === 'git status') return ['ブランチ ' + branch + ' 上', 'コミットする変更はありません。ワークツリーはクリーンです。'];
  if (normalized === 'swift --version') return ['Swift バージョン 6.2 (swift-6.2-RELEASE)'];
  if (normalized === 'clear') return [];
  if (!normalized) return [];
  return ['zsh: コマンドが見つかりません: ' + normalized];
}

type DebugAgentPatchDecision = 'pending' | 'applied' | 'rejected';

function DebugAgentPatchCard({ decision, patch, onDecide }: { decision: DebugAgentPatchDecision; patch: { removed: string[]; added: string[] }; onDecide: (decision: Exclude<DebugAgentPatchDecision, 'pending'>) => void }) {
  const isPending = decision === 'pending';
  return <section className={'activity-approval-card debug-agent-patch ' + (isPending ? 'is-pending' : decision === 'applied' ? 'is-allowed' : 'is-denied')} aria-label="修正パッチの承認">
    <header className="activity-approval-header">
      <span className="activity-approval-mark">!</span>
      <div><strong>修正を適用しますか？</strong><small>main.go</small></div>
      <span className="activity-approval-state">{isPending ? '承認待ち' : decision === 'applied' ? '適用済み' : '却下'}</span>
    </header>
    <div className="debug-agent-diff">
      {patch.removed.map((line, index) => <div className="debug-agent-diff-line is-removed" key={'removed-' + index}>- {line}</div>)}
      {patch.added.map((line, index) => <div className="debug-agent-diff-line is-added" key={'added-' + index}>+ {line}</div>)}
    </div>
    {isPending ? <div className="activity-approval-actions"><button type="button" className="activity-approval-deny" onClick={() => onDecide('rejected')}>却下</button><button type="button" className="activity-approval-allow" onClick={() => onDecide('applied')}>適用してテスト</button></div> : <span className={'activity-approval-result ' + (decision === 'applied' ? 'allowed' : 'denied')}>{decision === 'applied' ? '適用済み' : '却下'}</span>}
  </section>;
}

function UsageBar({ value }: { value: number }) {
  return <span className="usage-meter"><i style={{ width: `${Math.max(0, Math.min(100, value))}%` }} /></span>;
}

function VendorIcon({ agentId, className = '' }: { agentId: string; className?: string }) {
  const normalized = agentId.toLowerCase();
  const vendor = normalized.includes('claude') ? 'claude' : normalized.includes('open') ? 'opencode' : 'codex';
  const asset = vendor === 'claude' ? { src: '/vendor-claude.png' } : vendor === 'opencode' ? { src: '/vendor-opencode.svg' } : { src: '/vendor-codex.svg' };
  return <span className={'vendor-icon vendor-icon-' + vendor + (className ? ' ' + className : '')} aria-hidden="true"><img src={asset.src} alt="" draggable="false" /></span>;
}

function SurfaceIcon({ kind }: { kind: SurfaceKind }) {
  if (kind === 'editor') {
    return <svg className="surface-icon surface-icon-editor" viewBox="0 0 16 18" aria-hidden="true" focusable="false"><path d="M3.25 1.5h6.1l3.4 3.4v11.6H3.25z" /><path d="M9.25 1.5v3.6h3.5" /><path d="M5.5 9.2h4.9M5.5 12h3.6" /></svg>;
  }
  return <svg className="surface-icon surface-icon-terminal" viewBox="0 0 18 16" aria-hidden="true" focusable="false"><rect x="1.5" y="1.5" width="15" height="13" rx="2" /><path d="m4.5 5.1 2.5 2.3-2.5 2.3M9.5 10h3.7" /></svg>;
}

function Toggle({ on, onToggle, label }: { on: boolean; onToggle: () => void; label: string }) {
  return <button type="button" className={'setting-switch ' + (on ? 'is-on' : '')} onClick={onToggle} aria-pressed={on} aria-label={label}><i /></button>;
}

function UsagePopover({ agents, selectedId, onClose, onRefresh, onSelect }: { agents: AgentUsage[]; selectedId: string; onClose: () => void; onRefresh: () => void; onSelect: (id: string) => void }) {
  const [mode, setMode] = useState<'detail' | 'compact'>('detail');
  return <section className="usage-popover" role="dialog" aria-label="Agentの使用量の詳細">
    <header className="usage-popover-header"><h2>使用量</h2><div><button type="button" onClick={onClose}>全Agent</button><button type="button" onClick={onRefresh} aria-label="使用量を更新" title="更新">↻</button></div></header>
    <div className="usage-tabs"><button type="button" className={mode === 'detail' ? 'is-active' : ''} onClick={() => setMode('detail')}>詳細</button><button type="button" className={mode === 'compact' ? 'is-active' : ''} onClick={() => setMode('compact')}>コンパクト</button></div>
    <div className="usage-agent-list">{agents.map((agent) => <button type="button" className={'usage-agent-row ' + (selectedId === agent.id ? 'is-active' : '')} key={agent.id} onClick={() => onSelect(agent.id)}>
      <span className="usage-agent-avatar" style={{ '--agent-color': agent.color } as CSSProperties}><VendorIcon agentId={agent.id} /></span>
      <span className="usage-agent-copy"><strong>{agent.name}</strong><small>リセットまで {agent.reset5h}</small></span>
      <span className="usage-agent-metrics"><span><b>5時間</b><UsageBar value={agent.used5h} /><em>{mode === 'detail' ? `残り ${agent.remaining5h}%` : `${agent.used5h}%`}</em></span><span><b>7日間</b><UsageBar value={agent.used7d} /><em>{mode === 'detail' ? `残り ${agent.remaining7d}%` : `${agent.used7d}%`}</em></span></span><span className="usage-chevron">›</span>
    </button>)}</div>
    <button type="button" className="usage-link">使用量の詳細と履歴<span>›</span></button>
    <button type="button" className="usage-link">アカウントを管理…<span>›</span></button>
  </section>;
}

function ActivityApprovalCard({ approval, onDecide }: { approval: ActivityApproval; onDecide: (decision: Exclude<ApprovalDecision, 'pending'>) => void }) {
  const decisionLabel: Record<Exclude<ApprovalDecision, 'pending'>, string> = {
    allowed: '今回だけ許可しました',
    session: 'このセッション中は許可しました',
    denied: '拒否してAgentへ返しました',
  };
  const isPending = approval.decision === 'pending';
  return <section className={'activity-approval-card ' + (isPending ? 'is-pending' : 'is-' + approval.decision)} aria-label={isPending ? '承認待ちの操作' : '承認結果'}>
    <header className="activity-approval-header">
      <span className="activity-approval-mark">!</span>
      <div><strong>{approval.title}</strong><small>PermissionRequest · {approval.tool}</small></div>
      <span className="activity-approval-state">{isPending ? '承認待ち' : decisionLabel[approval.decision]}</span>
    </header>
    <div className="activity-approval-command"><span>実行内容</span><code>{approval.command}</code></div>
    <div className="activity-approval-meta"><span><small>作業ディレクトリ</small><code>{approval.cwd}</code></span><span><small>リスク</small><strong>{approval.risk}</strong></span></div>
    <p className="activity-approval-reason">{approval.reason}</p>
    <footer className="activity-approval-footer">
      {isPending ? <div className="activity-approval-actions"><button type="button" className="activity-approval-deny" onClick={() => onDecide('denied')}>拒否</button><button type="button" onClick={() => onDecide('session')}>セッション中は許可</button><button type="button" className="activity-approval-allow" onClick={() => onDecide('allowed')}>今回だけ許可</button></div> : <span className={'activity-approval-result ' + approval.decision}>{decisionLabel[approval.decision]}</span>}
    </footer>
  </section>;
}

function MobileReviewShell({ projectGroups, activeGroupId, currentProject, currentGit, agents, threads, agentWindowOpen, onProjectChange, onOpenDesktop, onOpenAddAgent, onCloseAddAgent, onStartAgent, onSendMessage, onSendReviewComments, onDecideApproval }: { projectGroups: ProjectGroup[]; activeGroupId: string; currentProject: ProjectGroup; currentGit: GitProjectState; agents: AgentUsage[]; threads: ActivityThread[]; agentWindowOpen: boolean; onProjectChange: (id: string) => void; onOpenDesktop: () => void; onOpenAddAgent: () => void; onCloseAddAgent: () => void; onStartAgent: (request: AddAgentRequest) => void; onSendMessage: (threadId: string, message: string) => void; onSendReviewComments: (threadId: string, comments: ActivityReviewComment[]) => void; onDecideApproval: (threadId: string, decision: Exclude<ApprovalDecision, 'pending'>) => void }) {
  const [tab, setTab] = useState<MobileReviewTab>('overview');
  const [activityDetailId, setActivityDetailId] = useState<string | null>(null);
  const [navigationDirection, setNavigationDirection] = useState<'forward' | 'back'>('forward');
  const [messageInput, setMessageInput] = useState('');
  const [projectPickerOpen, setProjectPickerOpen] = useState(false);
  const [reviewOpen, setReviewOpen] = useState(false);
  const [selectedSessionId, setSelectedSessionId] = useState(currentProject.activeTerminalId);
  const [showSessionList, setShowSessionList] = useState(true);
  const [terminalInput, setTerminalInput] = useState('');
  const [terminalLines, setTerminalLines] = useState<Record<string, string[]>>({});
  const [mobileNotice, setMobileNotice] = useState<ToastState | null>(null);
  const [remoteEnabled, setRemoteEnabled] = useState(true);
  const [pairingOpen, setPairingOpen] = useState(false);
  const [pairedDevice, setPairedDevice] = useState(true);
  const mobileNoticeTimerRef = useRef<number | null>(null);
  const mobileMainRef = useRef<HTMLDivElement>(null);
  const swipeStart = useRef<{ x: number; y: number } | null>(null);
  const selectedThread = activityDetailId ? threads.find((thread) => thread.id === activityDetailId) : undefined;
  const reviewThreads = threads.filter((thread) => thread.review);
  const mobileSessions = useMemo<MobileSessionFixture[]>(() => projectGroups.flatMap((group) => group.terminals.map((terminal, index) => ({
    id: terminal.id,
    projectId: group.id,
    label: terminal.label,
    profile: terminal.shell === 'claude' ? 'Claude Code' : 'zsh',
    model: terminal.shell === 'claude' ? 'opus' : 'shell',
    status: group.id === 'clair' && index === 0 ? 'running' : group.id === 'ccedit' ? 'attention' : 'idle',
    cwd: terminal.cwd,
    branch: group.id === activeGroupId ? currentGit.branch : 'main',
    lines: terminal.lines.slice(-14),
  }))), [activeGroupId, currentGit.branch, projectGroups]);
  const selectedSession = mobileSessions.find((session) => session.id === selectedSessionId) ?? mobileSessions[0];
  const selectedTerminalLines = selectedSession ? terminalLines[selectedSession.id] ?? selectedSession.lines : [];
  const attentionSessionCount = mobileSessions.filter((session) => session.status === 'attention').length;
  const tabOrder: MobileReviewTab[] = ['overview', 'sessions', 'activity', 'settings'];
  const navItems: Array<{ id: MobileReviewTab; label: string; icon: string }> = [
    { id: 'overview', label: '概要', icon: '⌂' },
    { id: 'sessions', label: 'セッション', icon: '⌁' },
    { id: 'activity', label: 'アクティビティ', icon: '◌' },
    { id: 'settings', label: '設定', icon: '⚙︎' },
  ];

  function showMobileNotice(title: string, detail: string) {
    if (mobileNoticeTimerRef.current) window.clearTimeout(mobileNoticeTimerRef.current);
    setMobileNotice({ title, detail });
    mobileNoticeTimerRef.current = window.setTimeout(() => setMobileNotice(null), 3600);
  }

  useEffect(() => {
    mobileMainRef.current?.scrollTo({ top: 0, behavior: 'auto' });
  }, [showSessionList, tab, activityDetailId]);

  function navigateTo(nextTab: MobileReviewTab, direction?: 'forward' | 'back') {
    if (nextTab === 'activity' && tab === 'activity' && activityDetailId) {
      setActivityDetailId(null);
      setReviewOpen(false);
      setNavigationDirection('back');
      return;
    }
    if (nextTab === 'sessions' && tab === 'sessions' && !showSessionList) {
      setShowSessionList(true);
      setNavigationDirection('back');
      return;
    }
    if (nextTab === tab) return;
    const currentIndex = tabOrder.indexOf(tab);
    const nextIndex = tabOrder.indexOf(nextTab);
    setNavigationDirection(direction ?? (nextIndex >= currentIndex ? 'forward' : 'back'));
    setTab(nextTab);
    if (nextTab === 'sessions') {
      setShowSessionList(true);
    }
    if (nextTab !== 'activity') {
      setActivityDetailId(null);
      setReviewOpen(false);
    }
  }

  function goBackFromSwipe() {
    if (activityDetailId) {
      setActivityDetailId(null);
      setReviewOpen(false);
      setNavigationDirection('back');
      return;
    }
    if (tab === 'sessions' && !showSessionList) {
      setShowSessionList(true);
      setNavigationDirection('back');
      return;
    }
    if (tab !== 'overview') {
      navigateTo('overview', 'back');
    }
  }

  function handleSwipeStart(event: ReactPointerEvent<HTMLDivElement>) {
    if (event.pointerType === 'mouse') return;
    const target = event.target;
    if (target instanceof HTMLElement && target.closest('.mobile-review-code, .mobile-control-terminal, .mobile-review-diff-scroll, .activity-change-review-diff, .activity-review-diff')) return;
    swipeStart.current = { x: event.clientX, y: event.clientY };
  }

  function handleSwipeEnd(event: ReactPointerEvent<HTMLDivElement>) {
    const start = swipeStart.current;
    swipeStart.current = null;
    if (!start || event.pointerType === 'mouse') return;
    const deltaX = event.clientX - start.x;
    const deltaY = event.clientY - start.y;
    if (deltaX <= -64 && Math.abs(deltaX) > Math.abs(deltaY) * 1.25) goBackFromSwipe();
  }

  function selectProject(id: string) {
    onProjectChange(id);
    setProjectPickerOpen(false);
  }

  function openActivity(threadId: string) {
    setActivityDetailId(threadId);
    setReviewOpen(false);
    setNavigationDirection('forward');
    setTab('activity');
  }

  function openSession(sessionId: string) {
    setSelectedSessionId(sessionId);
    setShowSessionList(false);
    setNavigationDirection('forward');
    setTab('sessions');
  }

  function submitTerminalInput(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const input = terminalInput.trim();
    if (!input || !selectedSession || !remoteEnabled) return;
    setTerminalLines((current) => ({ ...current, [selectedSession.id]: [...(current[selectedSession.id] ?? selectedSession.lines), '$ ' + input, '  ↳ Enter付きでPTYへ送信'] }));
    setTerminalInput('');
    showMobileNotice('入力を送信しました', `${selectedSession.label} · デスクトップのPTYへ到着順で送信`);
  }

  function sendTerminalCommand(command: string) {
    if (!selectedSession || !remoteEnabled) return;
    setTerminalLines((current) => ({ ...current, [selectedSession.id]: [...(current[selectedSession.id] ?? selectedSession.lines), '$ ' + command, command.includes('model') ? '  ↳ CLIのモデル選択を開きました' : '  ↳ Agentの状態を要求しました'] }));
    showMobileNotice('コマンドを送信しました', `${command} ↵ · ${selectedSession.label}`);
  }

  function interruptSelectedSession() {
    if (!selectedSession || !remoteEnabled) return;
    setTerminalLines((current) => ({ ...current, [selectedSession.id]: [...(current[selectedSession.id] ?? selectedSession.lines), '^C', '  ↳ 割り込みを送信'] }));
    showMobileNotice('割り込みを送信しました', selectedSession.label);
  }

  function copyPairingCode() {
    const pairingCode = 'CL-7H4K-92';
    void navigator.clipboard?.writeText(pairingCode);
    showMobileNotice('ペアリングコードをコピーしました', 'このコードは一度だけ使えます。');
  }

  function submitMessage(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const message = messageInput.trim();
    if (!message || !selectedThread) return;
    onSendMessage(selectedThread.id, message);
    setMessageInput('');
  }

  function submitReviewComments(comments: ActivityReviewComment[]) {
    if (!selectedThread) return;
    onSendReviewComments(selectedThread.id, comments);
    setReviewOpen(false);
  }

  const renderOverview = () => <div className="mobile-review-stack">
    <section className="mobile-review-intro">
      <span className="mobile-review-kicker">操作 / 確認モード</span>
      <h1>ワークスペースの概要</h1>
      <p>作業の状態を見渡し、必要なときだけセッションへ指示を送れます。</p>
    </section>
    <section className="mobile-review-summary-grid">
      <button type="button" className="mobile-review-summary" onClick={() => navigateTo('sessions')}><strong>{mobileSessions.length}</strong><span>接続中のセッション</span><small>ターミナルを開く</small></button>
      <button type="button" className="mobile-review-summary" onClick={() => navigateTo('activity')}><strong>{attentionSessionCount}</strong><span>注意が必要</span><small>{reviewThreads.length}件の変更も確認</small></button>
    </section>
    <section className="mobile-review-panel mobile-control-session-panel">
      <header className="mobile-review-panel-header"><div><span className="mobile-review-kicker">Project / session</span><h2>セッション</h2></div><button type="button" onClick={() => navigateTo('sessions')}>すべて表示</button></header>
      <div className="mobile-control-session-list">{mobileSessions.slice(0, 3).map((session) => <button type="button" className="mobile-control-session-row" key={session.id} onClick={() => openSession(session.id)}><span className={'mobile-control-session-dot ' + session.status} /><span><strong>{session.label}</strong><small>{session.projectId} · {session.profile} · {session.cwd}</small></span><em>{session.status === 'running' ? '実行中' : session.status === 'attention' ? '注意' : '待機'}</em><span className="mobile-review-agent-chevron">›</span></button>)}</div>
    </section>
    <section className="mobile-review-panel">
      <header className="mobile-review-panel-header"><div><span className="mobile-review-kicker">Agentの状態</span><h2>使用量と上限</h2></div><button type="button" onClick={() => navigateTo('settings')}>設定</button></header>
      <div className="mobile-review-agent-list">{agents.map((agent) => <button type="button" className="mobile-review-agent" key={agent.id} onClick={() => navigateTo('activity')}><span className="mobile-review-agent-avatar" style={{ '--agent-color': agent.color } as CSSProperties}><VendorIcon agentId={agent.id} /></span><span className="mobile-review-agent-copy"><strong>{agent.name}</strong><small>5時間 残り{agent.remaining5h}% · 7日間 残り{agent.remaining7d}%</small><UsageBar value={agent.used5h} /></span><span className="mobile-review-agent-chevron">›</span></button>)}</div>
    </section>
    <section className="mobile-review-panel">
      <header className="mobile-review-panel-header"><div><span className="mobile-review-kicker">最近のアクティビティ</span><h2>アクティビティ</h2></div><button type="button" onClick={() => navigateTo('activity')}>すべて表示</button></header>
      <div className="mobile-review-activity-list">{threads.slice(0, 3).map((thread) => <button type="button" className="mobile-review-activity-row" key={thread.id} onClick={() => openActivity(thread.id)}><span className={'mobile-review-activity-icon ' + thread.status}><VendorIcon agentId={thread.agentId} /></span><span><strong>{thread.summary}</strong><small>{thread.title} · {thread.projectId}</small></span><time>{thread.approval?.decision === 'pending' ? '承認待ち · ' : thread.approval ? '応答済み · ' : thread.review ? '変更 · ' : ''}{thread.updatedAt}</time></button>)}</div>
    </section>
  </div>;

  const renderSessions = () => showSessionList ? <div className="mobile-review-stack">
    <section className="mobile-review-intro">
      <span className="mobile-review-kicker">Project / session</span>
      <h1>セッション</h1>
      <p>Projectごとの実行状態を確認し、必要なときだけ raw terminal を操作します。</p>
      <button type="button" className="mobile-review-action mobile-review-add-agent-button" onClick={onOpenAddAgent}>Agentを追加 <span>＋</span></button>
    </section>
    <section className="mobile-review-panel mobile-control-session-panel">
      <header className="mobile-review-panel-header"><div><span className="mobile-review-kicker">接続中</span><h2>{mobileSessions.length} セッション</h2></div><span className="mobile-control-session-retention">保持範囲 256 KB</span></header>
      <div className="mobile-control-session-list">{mobileSessions.map((session) => <button type="button" className="mobile-control-session-row is-large" key={session.id} onClick={() => openSession(session.id)}><span className={'mobile-control-session-dot ' + session.status} /><span><strong>{session.label}</strong><small>{session.projectId} · {session.profile} · {session.model}</small><small className="mobile-control-session-path">{session.cwd} · {session.branch}</small></span><em>{session.status === 'running' ? '実行中' : session.status === 'attention' ? '注意' : session.status === 'exited' ? '終了' : '待機'}</em><span className="mobile-review-agent-chevron">›</span></button>)}</div>
    </section>
    <section className="mobile-review-panel mobile-control-safety-panel"><div><span className="mobile-review-kicker">操作の境界</span><h2>PTYサイズはMac側で保持</h2><p>モバイルの viewport は表示だけに使い、デスクトップのセッションを resize しません。</p></div><span className="mobile-control-lock">⌁</span></section>
  </div> : <div className="mobile-review-stack mobile-review-detail-stack">
    <section className="mobile-review-panel mobile-control-terminal-panel">
      <header className="mobile-review-chat-header"><div className="mobile-review-chat-agent"><button type="button" className="mobile-control-back-button" onClick={() => setShowSessionList(true)} aria-label="セッション一覧に戻る">‹</button><span className={'mobile-control-session-dot ' + (selectedSession?.status ?? 'idle')} /><div><strong>{selectedSession?.label ?? 'セッション'}</strong><small>{selectedSession?.projectId ?? currentProject.name} · {selectedSession?.profile ?? 'terminal'}</small></div></div><span className={'mobile-review-state ' + (selectedSession?.status ?? 'idle')}>{selectedSession?.status === 'running' ? '実行中' : selectedSession?.status === 'attention' ? '注意' : '待機'}</span></header>
      {selectedSession && <><div className="mobile-control-terminal-meta"><span>{selectedSession.cwd}</span><span>⑂ {selectedSession.branch}</span><span>{selectedSession.model}</span><span>raw terminal</span></div><pre className="mobile-control-terminal" aria-label={selectedSession.label + ' のターミナル出力'}>{selectedTerminalLines.map((line, index) => <code key={selectedSession.id + '-' + index}>{line || ' '}{'\n'}</code>)}</pre><div className="mobile-control-terminal-footer"><span>保持範囲 256 KB · cursor同期</span><button type="button" onClick={() => showMobileNotice('最新位置へ移動しました', '表示だけを末尾へ移動。PTYはresizeしません。')}>下部へ</button></div><div className="mobile-control-command-row"><span>コマンド</span><button type="button" onClick={() => sendTerminalCommand(selectedSession.profile === 'OpenCode' ? '/models' : '/model')} disabled={!remoteEnabled}>モデル</button><button type="button" onClick={() => sendTerminalCommand('/status')} disabled={!remoteEnabled}>状態</button></div><form className="mobile-control-input" onSubmit={submitTerminalInput}><input value={terminalInput} onChange={(event) => setTerminalInput(event.target.value)} placeholder="コマンドまたは指示を入力…" aria-label="ターミナル入力" disabled={!remoteEnabled} autoComplete="off" spellCheck={false} /><button type="submit" disabled={!terminalInput.trim() || !remoteEnabled}>送信 ↵</button></form><div className="mobile-control-action-row"><button type="button" className="mobile-control-interrupt" onClick={interruptSelectedSession} disabled={!remoteEnabled}>割り込み</button><button type="button" onClick={() => showMobileNotice('セッションを監視中', '接続が切れてもカーソル位置から再同期します。')}>監視を続ける</button></div></>}
    </section>
    <section className="mobile-review-panel mobile-control-session-detail-card"><header className="mobile-review-panel-header"><div><span className="mobile-review-kicker">Agent / session</span><h2>状態と権限</h2></div><span className="mobile-control-scope-badge">view · steer</span></header><div className="mobile-control-detail-grid"><span><small>Project</small><strong>{selectedSession?.projectId ?? currentProject.name}</strong></span><span><small>Profile</small><strong>{selectedSession?.profile ?? 'terminal'}</strong></span><span><small>Model</small><strong>{selectedSession?.model ?? 'default'}</strong></span><span><small>Input</small><strong>{remoteEnabled ? '許可' : '停止中'}</strong></span></div></section>
  </div>;

  const renderActivity = () => selectedThread ? <div className="mobile-review-stack mobile-review-detail-stack">
    <section className="mobile-review-panel mobile-review-chat-panel">
      <header className="mobile-review-chat-header"><div className="mobile-review-chat-agent"><span className="mobile-review-chat-avatar" style={{ '--agent-color': agents.find((agent) => agent.id === selectedThread.agentId)?.color } as CSSProperties}><VendorIcon agentId={selectedThread.agentId} /></span><div><strong>{selectedThread.summary}</strong><small>{selectedThread.title} · {selectedThread.projectId} · {selectedThread.agentId === 'claude-code' ? 'Opus 4.1 · ローカル認証' : selectedThread.provider}</small></div></div><span className={'mobile-review-state ' + selectedThread.status}>{selectedThread.status === 'working' ? '実行中' : selectedThread.status === 'waiting' ? '入力待ち' : '完了'}</span></header>
      {selectedThread.review && <div className="mobile-review-chat-actions"><button type="button" className="mobile-review-review-button" onClick={() => setReviewOpen(true)}><span>⑂</span><span><strong>Diff review</strong><small>{selectedThread.review.summary}</small></span><span>›</span></button></div>}
      <div className="mobile-review-messages">{selectedThread.messages.map((message) => <article className={'mobile-review-message ' + message.role} key={message.id}>{message.role === 'agent' && <span className="mobile-review-message-avatar" style={{ '--agent-color': agents.find((agent) => agent.id === selectedThread.agentId)?.color } as CSSProperties}><VendorIcon agentId={selectedThread.agentId} /></span>}<div className="mobile-review-message-body"><header>{message.role !== 'agent' && <strong>{message.role === 'user' ? 'あなた' : 'システム'}</strong>}<time>{message.time}</time></header><p>{message.text}</p></div></article>)}{selectedThread.approval && <ActivityApprovalCard approval={selectedThread.approval} onDecide={(decision) => onDecideApproval(selectedThread.id, decision)} />}</div>
      <form className="mobile-review-composer" onSubmit={submitMessage}><input value={messageInput} onChange={(event) => setMessageInput(event.target.value)} placeholder="Agentにメッセージ…" aria-label="Agentにメッセージ" /><button type="submit" disabled={!messageInput.trim()} aria-label="メッセージを送信">↗</button></form>
    </section>
    {selectedThread.review && <ActivityChangeReviewPanel key={selectedThread.id} review={selectedThread.review} open={reviewOpen} onClose={() => setReviewOpen(false)} onSubmit={submitReviewComments} className="activity-review-overlay activity-review-overlay-mobile" />}
  </div> : <div className="mobile-review-stack">
    <section className="mobile-review-intro">
      <span className="mobile-review-kicker">通知 / 履歴</span>
      <h1>Agentアクティビティ</h1>
      <p>検出したAgentごとの会話と、関連するProjectを確認できます。</p>
      <button type="button" className="mobile-review-action mobile-review-add-agent-button" onClick={onOpenAddAgent}>Agentを追加 <span>＋</span></button>
    </section>
    <section className="mobile-review-panel mobile-review-thread-panel">
      <div className="mobile-review-thread-list">{threads.map((thread) => <button type="button" className="mobile-review-thread-row" key={thread.id} onClick={() => openActivity(thread.id)}><span className={'mobile-review-activity-icon ' + thread.status}><VendorIcon agentId={thread.agentId} /></span><span><strong>{thread.summary}</strong><small>{thread.title} · {thread.projectId}</small></span><time>{thread.approval?.decision === 'pending' ? '承認待ち · ' : thread.approval ? '応答済み · ' : thread.review ? '変更 · ' : ''}{thread.updatedAt}</time></button>)}</div>
    </section>
  </div>;

  const renderSettings = () => <div className="mobile-review-stack">
    <section className="mobile-review-intro">
      <span className="mobile-review-kicker">設定</span>
      <h1>モバイル操作</h1>
      <p>接続の境界と、ペアリング済み端末の権限を確認します。</p>
    </section>
    <section className="mobile-review-panel mobile-control-settings-panel">
      <header className="mobile-review-panel-header"><div><span className="mobile-review-kicker">private network</span><h2>モバイル接続</h2></div><span className={'mobile-control-enabled-badge ' + (remoteEnabled ? 'is-enabled' : '')}>{remoteEnabled ? '有効' : '停止中'}</span></header>
      <div className="mobile-control-settings-row"><span><strong>このMacを接続可能にする</strong><small>アプリを閉じても、ユーザーがQuitするまでホストを維持します。</small></span><Toggle on={remoteEnabled} onToggle={() => setRemoteEnabled((enabled) => !enabled)} label="モバイル接続" /></div>
      <div className="mobile-control-settings-facts"><span><small>Host fingerprint</small><code>7A:E1:4C:9B:2D:70</code></span><span><small>Route</small><code>private only</code></span></div>
      {pairedDevice ? <div className="mobile-control-paired-device"><span className="mobile-control-device-icon">⌁</span><span><strong>Daiki iPhone</strong><small>view · steer · 最終接続 たった今</small></span><button type="button" onClick={() => { setPairedDevice(false); showMobileNotice('端末を解除しました', '次回は新しいペアリングが必要です。'); }}>解除</button></div> : <div className="mobile-control-empty-device"><span>ペアリング済み端末はありません</span><small>QR / deep link から一度だけ接続できます。</small></div>}
      <button type="button" className="mobile-review-action mobile-control-pairing-button" onClick={() => setPairingOpen(true)} disabled={!remoteEnabled}>QR / deep linkを表示 <span>↗</span></button>
    </section>
    <section className="mobile-review-panel mobile-review-settings-list"><button type="button" className="mobile-review-setting-row" onClick={() => showMobileNotice('表示設定', 'モバイルでは raw terminal と履歴を優先表示します。')}><span><strong>コンパクト表示</strong><small>Project、セッション、アクティビティを優先します。</small></span><span>有効</span></button><button type="button" className="mobile-review-setting-row" onClick={onOpenDesktop}><span><strong>デスクトップ版エディタ</strong><small>編集可能なワークスペースとターミナルに戻ります。</small></span><span>↗</span></button></section>
    <section className="mobile-review-panel mobile-review-update-panel"><div><span className="mobile-review-kicker">アップデート</span><h2>プレビュー版</h2><p>新しいプレビュー版が利用できるか確認します。</p></div><button type="button" className="mobile-review-action" onClick={() => showMobileNotice('アップデートがあります', 'Clair 0.7.2 がプレビュー版で利用できます。')}>アップデートを確認</button></section>
    {pairingOpen && <div className="mobile-control-pairing-scrim" role="presentation" onClick={() => setPairingOpen(false)}><section className="mobile-control-pairing-sheet" role="dialog" aria-modal="true" aria-label="モバイルのペアリング" onClick={(event) => event.stopPropagation()}><header><div><span className="mobile-review-kicker">一度だけ有効</span><h2>モバイルをペアリング</h2></div><button type="button" onClick={() => setPairingOpen(false)} aria-label="ペアリングを閉じる">×</button></header><div className="mobile-control-pairing-body"><div className="mobile-control-qr-grid" aria-label="ペアリングQRコード">{Array.from({ length: 81 }, (_, index) => <i className={(index * 11 + index * index) % 7 < 3 ? 'is-filled' : ''} key={index} />)}</div><div><strong>CL-7H4K-92</strong><small>このコードは一度だけ使えます · 09:42まで</small><button type="button" onClick={copyPairingCode}>コードをコピー</button></div></div><p className="mobile-control-pairing-note">リンクには host identity と短期 bootstrap だけを含めます。ターミナル出力、プロンプト、cwd は含めません。</p><footer><button type="button" onClick={() => setPairingOpen(false)}>閉じる</button><button type="button" className="mobile-control-primary-button" onClick={() => { setPairingOpen(false); showMobileNotice('ペアリング待機中', '端末からの接続を待っています。'); }}>接続を待機</button></footer></section></div>}
  </div>;

  const content = tab === 'sessions' ? renderSessions() : tab === 'activity' ? renderActivity() : tab === 'settings' ? renderSettings() : renderOverview();
  const screenKey = tab + (activityDetailId ? ':' + activityDetailId : '') + (selectedSessionId ? ':' + selectedSessionId : '') + (showSessionList ? ':list' : ':detail');
  return <main className="mobile-review-app">
    <header className="mobile-review-topbar"><div className="mobile-review-brand"><span className="mobile-review-brand-mark" aria-hidden="true">C</span><span><strong>Clair</strong><small>モバイル確認</small></span></div><button type="button" className="mobile-review-desktop-button" onClick={onOpenDesktop}>デスクトップ表示 <span>↗</span></button></header>
    <div className="mobile-review-projectbar"><button type="button" className="mobile-review-project-trigger" onClick={() => setProjectPickerOpen((open) => !open)} aria-expanded={projectPickerOpen} aria-controls="mobile-project-picker" aria-label={'Projectを切り替えます。現在のProject: ' + currentProject.name}><span className="mobile-review-project-trigger-icon" style={{ '--project-color': currentProject.color } as CSSProperties} /><span className="mobile-review-project-trigger-copy"><small>Project</small><strong>{currentProject.name}</strong></span><span className="mobile-review-project-trigger-chevron" aria-hidden="true">{projectPickerOpen ? '⌃' : '⌄'}</span></button><span className="mobile-review-branch">⑂ {currentGit.branch}</span></div>
    {projectPickerOpen && <div className="mobile-review-project-scrim" role="presentation" onClick={() => setProjectPickerOpen(false)}><section id="mobile-project-picker" className="mobile-review-project-picker" role="dialog" aria-modal="true" aria-label="Projectを選択" onClick={(event) => event.stopPropagation()}><header className="mobile-review-project-picker-header"><div><span className="mobile-review-kicker">ワークスペース</span><h2>Projectを切り替え</h2></div><button type="button" onClick={() => setProjectPickerOpen(false)} aria-label="Project選択を閉じる">×</button></header><div className="mobile-review-project-options">{projectGroups.map((group) => <button type="button" className={'mobile-review-project-option ' + (group.id === activeGroupId ? 'is-active' : '')} key={group.id} onClick={() => selectProject(group.id)}><span className="mobile-review-project-option-mark" style={{ '--project-color': group.color } as CSSProperties} /><span><strong>{group.name}</strong><small>{group.root}</small></span>{group.id === activeGroupId && <span className="mobile-review-project-option-check" aria-hidden="true">✓</span>}</button>)}</div></section></div>}
    <div className="mobile-review-main" ref={mobileMainRef} onPointerDown={handleSwipeStart} onPointerUp={handleSwipeEnd} onPointerCancel={() => { swipeStart.current = null; }}><div className={'mobile-review-page-transition is-' + navigationDirection} key={screenKey}>{content}</div></div>
    <nav className="mobile-review-nav" aria-label="モバイル確認のセクション">{navItems.map((item) => <button type="button" className={tab === item.id && !(item.id === 'activity' && activityDetailId) ? 'is-active' : ''} key={item.id} onClick={() => navigateTo(item.id)}><span>{item.icon}</span><small>{item.label}</small></button>)}</nav>
    {mobileNotice && <div className="mobile-control-notice" role="status"><span>✓</span><div><strong>{mobileNotice.title}</strong><small>{mobileNotice.detail}</small></div><button type="button" onClick={() => setMobileNotice(null)} aria-label="通知を閉じる">×</button></div>}
    {agentWindowOpen && <AddAgentWindow currentProject={currentProject} agents={agents} onClose={onCloseAddAgent} onStart={onStartAgent} />}
  </main>;
}

function SettingsPage({ section, onSectionChange, onBack, catalog, agents, fontSize, setFontSize, wordWrap, setWordWrap, mobileConnected, setMobileConnected, onCheckUpdate }: { section: SettingsSectionId; onSectionChange: (section: SettingsSectionId) => void; onBack: () => void; catalog: SettingCatalog[]; agents: AgentUsage[]; fontSize: number; setFontSize: (value: number) => void; wordWrap: boolean; setWordWrap: (value: boolean) => void; mobileConnected: boolean; setMobileConnected: (value: boolean) => void; onCheckUpdate: () => void }) {
  const [query, setQuery] = useState('');
  const [restoreLayout, setRestoreLayout] = useState(true);
  const [confirmClose, setConfirmClose] = useState(true);
  const [minimap, setMinimap] = useState(false);
  const [terminalPosition, setTerminalPosition] = useState('Right');
  const visibleCatalog = catalog.filter((item) => !query.trim() || `${item.label} ${item.description}`.toLowerCase().includes(query.toLowerCase()));
  const current = catalog.find((item) => item.id === section) ?? fallbackSettings[0];
  return <section className="settings-page">
    <aside className="settings-sidebar"><button type="button" className="settings-back" onClick={onBack}><span>‹</span> エディタに戻る</button><label className="settings-search"><span>⌕</span><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="設定を検索" aria-label="設定を検索" /></label><nav className="settings-nav"><span className="settings-nav-heading">ワークスペース</span>{visibleCatalog.map((item) => <button type="button" key={item.id} className={item.id === section ? 'is-active' : ''} onClick={() => onSectionChange(item.id)}><span className={'settings-nav-icon settings-icon-' + item.id} />{item.label}</button>)}</nav><div className="settings-sidebar-footer"><span>Clair</span><small>ワークスペースの設定</small></div></aside>
    <main className="settings-content"><header className="settings-page-header"><span className="settings-kicker">設定</span><h1>{current.label}</h1><p>{current.description}</p></header><div className="settings-section-content">
      {section === 'general' && <><SettingCard title="ワークスペース" description="Projectを開くときに使う基本設定です。"><SettingRow label="ワークスペースのディレクトリ" description="Projectをまとめて管理するフォルダです。"><input className="setting-input" value="~/Projects" readOnly aria-label="ワークスペースのディレクトリ" /></SettingRow><SettingRow label="前回のレイアウトを復元" description="Projectごとのファイル、ターミナル、分割位置を再現します。"><Toggle on={restoreLayout} onToggle={() => setRestoreLayout((value) => !value)} label="前回のレイアウトを復元" /></SettingRow><SettingRow label="閉じる前に確認" description="実行中のターミナルや未保存のエディタを閉じる前に確認します。"><Toggle on={confirmClose} onToggle={() => setConfirmClose((value) => !value)} label="閉じる前に確認" /></SettingRow></SettingCard><SettingCard title="インターフェース" description="ワークスペースを静かで集中しやすい表示にします。"><SettingRow label="ステータスフッターを表示" description="ブランチ、同期状態、Agentの使用量をすべての画面で表示します。"><Toggle on={true} onToggle={() => undefined} label="ステータスフッターを表示" /></SettingRow></SettingCard></>}
      {section === 'agents' && <><SettingCard title="接続済みのAgent" description="各Agentは専用ターミナルで実行し、ここにアクティビティを報告します。">{agents.map((agent) => <div className="agent-setting-row" key={agent.id}><span className="usage-agent-avatar" style={{ '--agent-color': agent.color } as CSSProperties}><VendorIcon agentId={agent.id} /></span><div><strong>{agent.name}</strong><small>接続済み · 5時間 残り{agent.remaining5h}%</small></div><span className="connection-state">接続済み</span></div>)}</SettingCard><SettingCard title="Agentの既定値" description="新しいセッションをワークスペースに追加する方法を設定します。"><SettingRow label="新しいセッションを開く場所" description="新しいAgentセッションを表示する場所です。"><select className="setting-select" defaultValue="terminal"><option value="terminal">ターミナル</option><option value="activity">アクティビティ</option></select></SettingRow></SettingCard></>}
      {section === 'editor' && <><SettingCard title="エディタ" description="文字組みとソース編集の設定です。"><SettingRow label="フォントサイズ" description="すべてのProjectのエディタに適用する文字サイズです。"><select className="setting-select" value={fontSize} onChange={(event) => setFontSize(Number(event.target.value))}><option value="13">13 px</option><option value="14">14 px</option><option value="14.5">14.5 px</option><option value="15">15 px</option><option value="16">16 px</option><option value="17">17 px</option></select></SettingRow><SettingRow label="行の折り返し" description="長い行をエディタの幅に合わせて折り返します。"><Toggle on={wordWrap} onToggle={() => setWordWrap(!wordWrap)} label="行の折り返し" /></SettingRow><SettingRow label="ミニマップ" description="ソース全体の見通しを保つため、既定では非表示です。"><Toggle on={minimap} onToggle={() => setMinimap((value) => !value)} label="ミニマップ" /></SettingRow></SettingCard><SettingCard title="編集動作" description="このモックでは変更をローカルに保存します。"><SettingRow label="フォーカスが外れたら保存" description="エディタの保存操作は明示的なボタンで行います。"><Toggle on={false} onToggle={() => undefined} label="フォーカスが外れたら保存" /></SettingRow></SettingCard></>}
      {section === 'terminal' && <><SettingCard title="ターミナル" description="シェルセッションとProjectの状態を管理します。"><SettingRow label="既定のシェル" description="新しく作成するターミナルで使用するシェルです。"><select className="setting-select" defaultValue="claude"><option value="claude">Claude Code</option><option value="zsh">zsh</option></select></SettingRow><SettingRow label="パネルの位置" description="ワークスペース内でターミナルを開く位置を選択します。"><div className="segmented-control"><button type="button" className={terminalPosition === 'Bottom' ? 'is-active' : ''} onClick={() => setTerminalPosition('Bottom')}>下</button><button type="button" className={terminalPosition === 'Right' ? 'is-active' : ''} onClick={() => setTerminalPosition('Right')}>右</button></div></SettingRow><SettingRow label="ターミナルセッションを復元" description="Projectを切り替えてもコマンドと分割配置を保持します。"><Toggle on={true} onToggle={() => undefined} label="ターミナルセッションを復元" /></SettingRow></SettingCard></>}
      {section === 'mobile' && <><SettingCard title="モバイル接続" description="モバイル端末をペアリングし、Agentの状態確認や簡単な指示を送信します。"><div className="mobile-connection"><div className={'mobile-status ' + (mobileConnected ? 'is-connected' : '')}><span className="mobile-device-icon">⌁</span><div><strong>{mobileConnected ? 'Clair Mobileに接続済み' : '接続中の端末はありません'}</strong><small>{mobileConnected ? 'このワークスペースをペアリング済みの端末で利用できます。' : 'QRコードを読み取るか、Clair Mobileでペアリングコードを入力してください。'}</small></div></div><div className="qr-panel" aria-label="モバイルのペアリングコード"><div className="qr-grid">{Array.from({ length: 49 }, (_, index) => <i className={(index * 7 + index * index) % 5 < 2 ? 'is-filled' : ''} key={index} />)}</div><div><span>ペアリングコード</span><strong>CL-7H4K-92</strong><small>09:42後に期限切れ</small></div></div><button type="button" className="setting-primary" onClick={() => setMobileConnected(!mobileConnected)}>{mobileConnected ? '端末の接続を解除' : '端末を接続'}</button></div></SettingCard><SettingCard title="モバイルの権限" description="ペアリング済みの端末に表示・操作を許可する内容です。"><SettingRow label="Agentの状態と使用量" description="アクティビティと残りのレート制限を表示します。"><Toggle on={true} onToggle={() => undefined} label="Agentの状態と使用量" /></SettingRow><SettingRow label="ターミナルコマンドを送信" description="ペアリング済みの端末から簡単なコマンドを送信できます。"><Toggle on={false} onToggle={() => undefined} label="ターミナルコマンドを送信" /></SettingRow></SettingCard></>}
      {section === 'updates' && <><SettingCard title="Clairのアップデート" description="最新のプレビュー版を利用できるようにします。"><div className="update-summary"><div><span className="update-badge">現在のバージョン</span><strong>Clair 0.7.1</strong><small>プレビュー版からインストールされています。</small></div><button type="button" className="setting-primary" onClick={onCheckUpdate}>アップデートを確認</button></div></SettingCard><SettingCard title="更新チャンネル" description="明示的に確認したときだけアップデートを確認します。"><SettingRow label="リリースチャンネル" description="このワークスペースで受け取る更新の種類です。"><select className="setting-select" defaultValue="stable"><option value="stable">安定版</option><option value="preview">プレビュー版</option></select></SettingRow><SettingRow label="自動確認" description="このモックではバックグラウンド確認は行いません。"><Toggle on={false} onToggle={() => undefined} label="自動確認" /></SettingRow></SettingCard><div className="release-note"><span>次回のプレビュー</span><strong>0.7.2 · ワークスペースの見やすさ</strong><p>使用量フッター、アクティビティチャット、ブランチグラフを改善します。</p></div></>}
    </div></main>
  </section>;
}

function SettingCard({ title, description, children }: { title: string; description: string; children: React.ReactNode }) {
  return <section className="settings-card"><header><div><h2>{title}</h2><p>{description}</p></div></header><div className="settings-card-body">{children}</div></section>;
}

function SettingRow({ label, description, children }: { label: string; description: string; children: React.ReactNode }) {
  return <div className="setting-row"><div><strong>{label}</strong><small>{description}</small></div>{children}</div>;
}

function InlineDiff({ diff }: { diff: DiffLine[] }) {
  return <div className="diff-lines" role="table" aria-label="インライン差分">{diff.map((line, index) => <div className={'diff-line ' + line.kind} role="row" key={line.kind + '-' + index}><span>{line.old ?? ''}</span><span>{line.next ?? ''}</span><i>{line.kind === 'add' ? '+' : line.kind === 'remove' ? '−' : ' '}</i><code>{line.text || ' '}</code></div>)}</div>;
}

function ActivityReviewDiff({ file, comments, onSaveComment, onRemoveComment }: { file: BranchFile; comments: ActivityReviewComment[]; onSaveComment: (comment: ActivityReviewComment) => void; onRemoveComment: (id: string) => void }) {
  const [activeLineId, setActiveLineId] = useState<string | null>(null);
  const [draft, setDraft] = useState('');

  function beginComment(index: number) {
    const id = `${file.path}:${index}`;
    const existing = comments.find((comment) => comment.id === id);
    setActiveLineId(id);
    setDraft(existing?.text ?? '');
  }

  function cancelComment() {
    setActiveLineId(null);
    setDraft('');
  }

  function saveComment(event: FormEvent<HTMLFormElement>, index: number, line: DiffLine) {
    event.preventDefault();
    const text = draft.trim();
    if (!text) return;
    onSaveComment({
      id: `${file.path}:${index}`,
      filePath: file.path,
      lineIndex: index,
      old: line.old,
      next: line.next,
      kind: line.kind,
      text,
    });
    cancelComment();
  }

  return <div className="activity-review-diff">
    {file.diff.length ? file.diff.map((line, index) => {
      const id = `${file.path}:${index}`;
      const comment = comments.find((item) => item.id === id);
      return <div className={'activity-review-line ' + line.kind} key={id}>
        <div className="activity-review-line-main">
          <span className="activity-review-line-number">{line.old ?? ''}</span>
          <span className="activity-review-line-number">{line.next ?? ''}</span>
          <i>{line.kind === 'add' ? '+' : line.kind === 'remove' ? '−' : ' '}</i>
          <code>{line.text || ' '}</code>
          <button type="button" className={'activity-review-line-comment ' + (comment ? 'has-comment' : '')} onClick={() => beginComment(index)} aria-label={(comment ? '行コメントを編集' : '行コメントを追加') + ' ' + (line.next ?? line.old ?? index + 1) + '行目'}>{comment ? '編集' : '＋ コメント'}</button>
        </div>
        {comment && activeLineId !== id && <div className="activity-review-comment"><span>コメント</span><p>{comment.text}</p><button type="button" onClick={() => onRemoveComment(id)} aria-label="行コメントを削除">×</button></div>}
        {activeLineId === id && <form className="activity-review-comment-editor" onSubmit={(event) => saveComment(event, index, line)}><textarea autoFocus value={draft} onChange={(event) => setDraft(event.target.value)} placeholder="この行へのフィードバックを入力…" aria-label={'行コメント ' + (line.next ?? line.old ?? index + 1) + '行目'} /><div><button type="button" onClick={cancelComment}>キャンセル</button><button type="submit" disabled={!draft.trim()}>コメントを保存</button></div></form>}
      </div>;
    }) : <p className="activity-review-empty">このプレビューにインライン差分はありません。</p>}
  </div>;
}

function ActivityChangeReviewPanel({ review, className, open, onClose, onSubmit }: { review: ActivityChangeReview; className: string; open: boolean; onClose: () => void; onSubmit: (comments: ActivityReviewComment[]) => void }) {
  const [comments, setComments] = useState<ActivityReviewComment[]>([]);

  function saveComment(comment: ActivityReviewComment) {
    setComments((current) => [...current.filter((item) => item.id !== comment.id), comment]);
  }

  function removeComment(id: string) {
    setComments((current) => current.filter((comment) => comment.id !== id));
  }

  function submitComments() {
    if (!comments.length) return;
    onSubmit(comments);
    setComments([]);
  }

  return <div className={className + ' ' + (open ? 'is-open' : '')} role="presentation" aria-hidden={!open} onClick={onClose}>
    <section className="activity-review-window" role="dialog" aria-modal="true" aria-labelledby="activity-review-title" onClick={(event) => event.stopPropagation()}>
      <header className="activity-review-window-header"><div><span className="activity-review-kicker">Agentの変更</span><h2 id="activity-review-title">Diff review</h2><p>{review.summary}</p></div><button type="button" className="activity-review-close" onClick={onClose} aria-label="Diff reviewを閉じる">×</button></header>
      <div className="activity-review-window-body"><div className="activity-review-guidance">各行の <strong>＋ コメント</strong> からAgentへのフィードバックを追加できます。</div><div className="activity-review-files">{review.files.map((file, index) => <details className="activity-review-file" key={file.path} open={index === 0}><summary><span className={'activity-review-file-kind ' + file.kind}>{file.kind === 'added' ? '+' : file.kind === 'deleted' ? '−' : '•'}</span><span className="activity-review-file-copy"><strong>{file.path}</strong><small>+{file.additions} −{file.deletions}</small></span><span className="activity-review-file-chevron" aria-hidden="true">⌄</span></summary><ActivityReviewDiff file={file} comments={comments} onSaveComment={saveComment} onRemoveComment={removeComment} /></details>)}</div></div>
      <footer className="activity-review-window-footer"><span>{comments.length ? `${comments.length}件の行コメントを送信できます` : '行コメントはまだありません'}</span><div><button type="button" className="activity-review-cancel" onClick={onClose}>閉じる</button><button type="button" className="activity-review-submit" disabled={!comments.length} onClick={submitComments}>Agentへ送信 <span>↗</span></button></div></footer>
    </section>
  </div>;
}

function AddAgentWindow({ currentProject, agents, onClose, onStart }: { currentProject: ProjectGroup; agents: AgentUsage[]; onClose: () => void; onStart: (request: AddAgentRequest) => void }) {
  const recommendedAgent = agents.reduce<AgentUsage | undefined>((best, agent) => {
    if (!best) return agent;
    const score = agent.remaining5h * .7 + agent.remaining7d * .3;
    const bestScore = best.remaining5h * .7 + best.remaining7d * .3;
    return score > bestScore ? agent : best;
  }, undefined);
  const [agentId, setAgentId] = useState(recommendedAgent?.id ?? '');
  const [modelChoice, setModelChoice] = useState(defaultModelChoice);
  const [customModelId, setCustomModelId] = useState('');
  const [launchTarget, setLaunchTarget] = useState<AgentLaunchTarget>('terminal');
  const [worktreeMode, setWorktreeMode] = useState<WorktreeMode>('new');
  const [worktreeName, setWorktreeName] = useState('agent-session');
  const [profile, setProfile] = useState<'review' | 'implement' | 'debug'>('implement');
  const [confirmChanges, setConfirmChanges] = useState(true);

  if (!recommendedAgent) return null;
  const selectedAgent = agents.find((agent) => agent.id === agentId) ?? recommendedAgent;
  const modelOptions = agentModelCatalog[selectedAgent.id] ?? [];
  const modelId = modelChoice === defaultModelChoice ? '' : modelChoice === customModelChoice ? customModelId.trim() : modelChoice;
  const modelLabel = modelId || '設定済みのデフォルト';
  const worktree = worktreeMode === 'current' ? currentProject.root : `${currentProject.root}/.worktrees/${worktreeName.trim() || 'agent-session'}`;

  function selectAgent(id: string) {
    setAgentId(id);
    setModelChoice(defaultModelChoice);
    setCustomModelId('');
  }

  return <div className="add-agent-overlay" role="presentation" onClick={onClose}>
    <section className="add-agent-window" role="dialog" aria-modal="true" aria-labelledby="add-agent-title" onClick={(event) => event.stopPropagation()}>
      <header className="add-agent-header"><div><span className="add-agent-kicker">新しいセッション</span><h2 id="add-agent-title">Agentを追加</h2><p>Agent、起動モデル、セッションの場所を選択します。</p></div><button type="button" onClick={onClose} aria-label="Agent追加画面を閉じる">×</button></header>
      <div className="add-agent-body">
        <section className="agent-recommendation"><span className="agent-recommendation-avatar" style={{ '--agent-color': recommendedAgent.color } as CSSProperties}><VendorIcon agentId={recommendedAgent.id} /></span><div><span className="add-agent-kicker">おすすめ · 残り使用量が多いAgent</span><strong>{recommendedAgent.name}</strong><small>5時間 残り{recommendedAgent.remaining5h}% · 7日間 残り{recommendedAgent.remaining7d}%</small></div><button type="button" onClick={() => selectAgent(recommendedAgent.id)}>このAgentを使う</button></section>
        <section className="add-agent-section"><header><strong>Agent</strong><small>このセッションで使う接続済みのAgentを選択します。</small></header><div className="add-agent-options" role="radiogroup" aria-label="Agentを選択">{agents.map((agent) => <button type="button" className={'add-agent-option ' + (selectedAgent.id === agent.id ? 'is-active' : '')} key={agent.id} onClick={() => selectAgent(agent.id)} role="radio" aria-checked={selectedAgent.id === agent.id}><span className="add-agent-option-avatar" style={{ '--agent-color': agent.color } as CSSProperties}><VendorIcon agentId={agent.id} /></span><span><strong>{agent.name}</strong><small>5時間 残り{agent.remaining5h}% · リセットまで {agent.reset5h}</small></span><i>{selectedAgent.id === agent.id ? '✓' : ''}</i></button>)}</div></section>
        <section className="add-agent-section"><header><strong>モデル</strong><small>未指定ならAgent側の設定を使います。起動後もターミナルのモデルコマンドで変更できます。</small></header><div className="add-agent-model-row"><label><span>起動モデル</span><select value={modelChoice} onChange={(event) => setModelChoice(event.target.value)}><option value={defaultModelChoice}>設定済みのデフォルト</option>{modelOptions.map((model) => <option value={model.id} key={model.id}>{model.label}</option>)}<option value={customModelChoice}>カスタムmodel ID…</option></select></label>{modelChoice === customModelChoice && <label><span>model ID</span><input value={customModelId} onChange={(event) => setCustomModelId(event.target.value)} placeholder={selectedAgent.id === 'opencode' ? 'provider/model' : 'model ID'} autoComplete="off" spellCheck={false} /></label>}</div></section>
        <section className="add-agent-section"><header><strong>起動場所</strong><small>新しいセッションを、続けて作業しやすい場所で開きます。</small></header><div className="add-agent-segmented" role="group" aria-label="Agentの起動場所"><button type="button" className={launchTarget === 'terminal' ? 'is-active' : ''} onClick={() => setLaunchTarget('terminal')}><span>⌁</span><span><strong>ターミナル</strong><small>ワークスペースの隣で実行</small></span></button><button type="button" className={launchTarget === 'activity' ? 'is-active' : ''} onClick={() => setLaunchTarget('activity')}><span>◌</span><span><strong>アクティビティ</strong><small>会話画面を開く</small></span></button></div></section>
        <section className="add-agent-section"><header><strong>worktree</strong><small>変更を分離するか、現在のProjectに紐づけます。</small></header><div className="add-agent-worktree-options"><label className={worktreeMode === 'current' ? 'is-active' : ''}><input type="radio" name="worktree-mode" checked={worktreeMode === 'current'} onChange={() => setWorktreeMode('current')} /><span><strong>現在のProject</strong><small>{currentProject.root}</small></span></label><label className={worktreeMode === 'new' ? 'is-active' : ''}><input type="radio" name="worktree-mode" checked={worktreeMode === 'new'} onChange={() => setWorktreeMode('new')} /><span><strong>新しいworktree</strong><small>{currentProject.root}/.worktrees/</small></span></label></div><label className="add-agent-input-label" htmlFor="agent-worktree-name">worktree名</label><input id="agent-worktree-name" className="add-agent-input" value={worktreeName} disabled={worktreeMode === 'current'} onChange={(event) => setWorktreeName(event.target.value)} placeholder="agent-session" /><small className="add-agent-path-preview">{worktree}</small></section>
        <section className="add-agent-options-row"><label><span>セッションモード</span><select value={profile} onChange={(event) => setProfile(event.target.value as 'review' | 'implement' | 'debug')}><option value="implement">実装</option><option value="review">変更を確認</option><option value="debug">デバッグ</option></select></label><label className="add-agent-check"><input type="checkbox" checked={confirmChanges} onChange={(event) => setConfirmChanges(event.target.checked)} /><span>変更を適用する前に確認</span></label></section>
      </div>
      <footer className="add-agent-footer"><span className="add-agent-launch-summary"><VendorIcon agentId={selectedAgent.id} />{selectedAgent.name} · {modelLabel} · {launchTarget === 'terminal' ? 'ターミナル' : 'アクティビティ'} · {worktreeMode === 'current' ? '現在のProject' : '新しいworktree'}</span><div><button type="button" className="add-agent-cancel" onClick={onClose}>キャンセル</button><button type="button" className="add-agent-primary" disabled={modelChoice === customModelChoice && !modelId} onClick={() => onStart({ agentId: selectedAgent.id, modelId, launchTarget, worktree, profile, confirmChanges })}>Agentを起動 <span>↗</span></button></div></footer>
    </section>
  </div>;
}

function SideBySideDiff({ diff }: { diff: DiffLine[] }) {
  const oldLines = diff.filter((line) => line.kind !== 'add');
  const newLines = diff.filter((line) => line.kind !== 'remove');
  const length = Math.max(oldLines.length, newLines.length);
  return <div className="diff-two-column" role="table" aria-label="左右比較の差分"><div className="diff-column"><header><span>main</span><small>変更前</small></header>{Array.from({ length }, (_, index) => { const line = oldLines[index]; return <div className={'diff-column-line ' + (line?.kind ?? 'empty')} key={'old-' + index}><span>{line?.old ?? ''}</span><code>{line?.text ?? ' '}</code></div>; })}</div><div className="diff-column"><header><span>feature/native-workspace</span><small>変更後</small></header>{Array.from({ length }, (_, index) => { const line = newLines[index]; return <div className={'diff-column-line ' + (line?.kind ?? 'empty')} key={'new-' + index}><span>{line?.next ?? ''}</span><code>{line?.text ?? ' '}</code></div>; })}</div></div>;
}

function SourceGraphView({ graph }: { graph: { nodes: GraphNode[]; edges: GraphEdge[] } }) {
  const nodeById = new Map(graph.nodes.map((node) => [node.id, node]));
  return <div className="source-graph"><header className="graph-toolbar"><div><strong>ソースグラフ</strong><small>アクティブなワークスペースの依存関係</small></div><span>{graph.nodes.length}ノード · {graph.edges.length}エッジ</span></header><div className="graph-canvas"><svg viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true">{graph.edges.map((edge) => { const from = nodeById.get(edge.from); const to = nodeById.get(edge.to); return from && to ? <line key={edge.from + '-' + edge.to} x1={from.x} y1={from.y} x2={to.x} y2={to.y} /> : null; })}</svg>{graph.nodes.map((node) => <div className={'graph-node graph-node-' + node.kind} style={{ left: `${node.x}%`, top: `${node.y}%` }} key={node.id}><span>{node.kind === 'entry' ? '⌂' : node.kind === 'type' ? '◇' : '□'}</span><div><strong>{node.label}</strong><small>{node.detail}</small></div></div>)}</div></div>;
}

export default function Home() {
  const [projectGroups, setProjectGroups] = useState<ProjectGroup[]>(initialProjectGroups);
  const [gitStates, setGitStates] = useState<Record<string, GitProjectState>>(initialGitStates);
  const [activeGroupId, setActiveGroupId] = useState('clair');
  const [mainView, setMainView] = useState<MainView>('workspace');
  const [activeSurface, setActiveSurface] = useState<SurfaceKind>('editor');
  const [sidebarHidden, setSidebarHidden] = useState(false);
  const [projectsExpanded, setProjectsExpanded] = useState(true);
  const [projectRootExpanded, setProjectRootExpanded] = useState(true);
  const [expandedFolders, setExpandedFolders] = useState<Record<string, boolean>>({ App: true, Editor: true, Tests: true });
  const [commandOpen, setCommandOpen] = useState(false);
  const [commandQuery, setCommandQuery] = useState('');
  const [paletteMode, setPaletteMode] = useState<'command' | 'quickOpen'>('command');
  const [paletteIndex, setPaletteIndex] = useState(0);
  const [findOpen, setFindOpen] = useState(false);
  const [findQuery, setFindQuery] = useState('');
  const [selectedGitPath, setSelectedGitPath] = useState('App/EditorPane.swift');
  const [gitView, setGitView] = useState<GitView>('inline');
  const [activitySelection, setActivitySelection] = useState(activityThreads.find((thread) => thread.approval)?.id ?? activityThreads[0]?.id ?? '');
  const [activityQuery, setActivityQuery] = useState('');
  const [activityAgentFilter, setActivityAgentFilter] = useState('all');
  const [activityReviewOpen, setActivityReviewOpen] = useState(false);
  const [threadMessages, setThreadMessages] = useState<Record<string, ActivityMessage[]>>(() => Object.fromEntries(activityThreads.map((thread) => [thread.id, thread.messages])));
  const [approvalDecisions, setApprovalDecisions] = useState<Record<string, Exclude<ApprovalDecision, 'pending'>>>({});
  const [threadStatusOverrides, setThreadStatusOverrides] = useState<Record<string, ActivityThread['status']>>({});
  const [chatInput, setChatInput] = useState('');
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [codeDraft, setCodeDraft] = useState(samples['ClairApp.swift']);
  const [isDirty, setIsDirty] = useState(false);
  const [fontSize, setFontSize] = useState(14.5);
  const [wordWrap, setWordWrap] = useState(false);
  const [settingsSection, setSettingsSection] = useState<SettingsSectionId>('general');
  const [mobileConnected, setMobileConnected] = useState(false);
  const [usageAgentId, setUsageAgentId] = useState<string | null>(null);
  const [toast, setToast] = useState<ToastState | null>(null);
  const [mobileReviewMode, setMobileReviewMode] = useState(false);
  const [agentWindowOpen, setAgentWindowOpen] = useState(false);
  const [debugStepIndex, setDebugStepIndex] = useState(defaultDebugStepIndex);
  const [debugRunning, setDebugRunning] = useState(false);
  const [debugLog, setDebugLog] = useState<string[]>(['Debugger attached to Clair · Debug configuration', 'Breakpoint hit at ClairApp.swift:4']);
  const [agentDebugMode, setAgentDebugMode] = useState(false);
  const [agentPatchDecision, setAgentPatchDecision] = useState<DebugAgentPatchDecision>('pending');
  const [agentTranscriptExtra, setAgentTranscriptExtra] = useState<string[]>([]);
  const [hydrated, setHydrated] = useState(false);
  const [isResizing, setIsResizing] = useState(false);
  const resizeRef = useRef<{ start: number; percent: number; position: TerminalPosition } | null>(null);
  const terminalSequenceRef = useRef(0);
  const messageSequenceRef = useRef(0);
  const terminalInputRef = useRef<HTMLInputElement>(null);
  const workAreaRef = useRef<HTMLDivElement>(null);
  const toastTimerRef = useRef<number | null>(null);

  const currentProject = projectGroups.find((group) => group.id === activeGroupId) ?? projectGroups[0] ?? initialProjectGroups[0];
  const currentTerminal = currentProject.terminals.find((terminal) => terminal.id === currentProject.activeTerminalId) ?? currentProject.terminals[0] ?? createTerminalSession(activeGroupId + '-terminal', 1, 'claude', currentProject.root);
  const currentGit = gitStates[activeGroupId] ?? { branch: 'main', ahead: 0, behind: 0, commitMessage: '', changes: [] };
  const activeFile = currentProject.activeFile;
  const codeKey = activeGroupId + ':' + activeFile;
  const stagedChanges = currentGit.changes.filter((change) => change.staged);
  const workingChanges = currentGit.changes.filter((change) => !change.staged);
  const selectedGitChange = currentGit.changes.find((change) => change.path === selectedGitPath) ?? currentGit.changes[0] ?? null;
  const selectedBranch = branchDiffs.find((branch) => branch.branch === currentGit.branch) ?? branchDiffs[0];
  const selectedBranchFile = selectedBranch?.files.find((file) => file.path === selectedGitPath) ?? selectedBranch?.files[0];
  const selectedDiff = selectedBranchFile?.diff ?? (selectedGitChange ? gitDiffs[selectedGitChange.path] ?? [] : []);
  const displayThreads = activityThreads.map((thread) => thread.approval ? { ...thread, status: threadStatusOverrides[thread.id] ?? thread.status, approval: { ...thread.approval, decision: approvalDecisions[thread.id] ?? thread.approval.decision } } : { ...thread, status: threadStatusOverrides[thread.id] ?? thread.status });
  const selectedThread = displayThreads.find((thread) => thread.id === activitySelection) ?? displayThreads[0];
  const visibleThreads = displayThreads.filter((thread) => { const query = activityQuery.trim().toLowerCase(); const matchesQuery = !query || `${thread.agentName} ${thread.title} ${thread.summary} ${thread.projectId}`.toLowerCase().includes(query); const matchesAgent = activityAgentFilter === 'all' || thread.agentId === activityAgentFilter; return matchesQuery && matchesAgent; });
  const currentDebugStep = debugSteps[debugStepIndex] ?? debugSteps[0];
  const findMatches = findQuery.trim() ? codeDraft.split('\n').reduce((count, line) => count + (line.toLowerCase().includes(findQuery.toLowerCase()) ? 1 : 0), 0) : 0;
  const commandItems = [{ id: 'add-agent', label: 'Agentを追加…', shortcut: '' }, { id: 'agent-model', label: 'Agentのモデルを変更…', shortcut: '' }, { id: 'new-terminal', label: '新しいターミナル', shortcut: '⌘D' }, { id: 'find-in-files', label: 'ファイル内を検索', shortcut: '⌘⇧F' }, { id: 'source-control', label: 'ソース管理を開く', shortcut: '' }, { id: 'activity', label: 'アクティビティを開く', shortcut: '' }, { id: 'debug', label: '実行とデバッグを開く', shortcut: '⌘⇧D' }, { id: 'toggle-sidebar', label: 'サイドバーを切り替え', shortcut: '⌘B' }, { id: 'save', label: 'ファイルを保存', shortcut: '⌘S' }, { id: 'mobile-review', label: 'モバイル確認を開く', shortcut: '' }, { id: 'settings', label: '設定を開く', shortcut: '' }].map((item) => ({ ...item, detail: 'clair.' + item.id.replace(/-/g, '.') })).filter((item) => item.label.toLowerCase().includes(commandQuery.toLowerCase()));
  const quickOpenItems = allFileNames.map((name) => ({ id: 'open:' + name, label: name, shortcut: '', detail: sourcePaths[name] ?? name })).filter((item) => item.label.toLowerCase().includes(commandQuery.toLowerCase()));
  const paletteItems = paletteMode === 'command' ? commandItems : quickOpenItems;
  const paletteIndexClamped = paletteItems.length ? Math.min(paletteIndex, paletteItems.length - 1) : 0;

  const updateCurrentProject = (updater: (group: ProjectGroup) => ProjectGroup) => setProjectGroups((groups) => groups.map((group) => group.id === activeGroupId ? updater(group) : group));
  const showToast = (title: string, detail: string, action?: string) => { if (toastTimerRef.current) window.clearTimeout(toastTimerRef.current); setToast({ title, detail, action }); toastTimerRef.current = window.setTimeout(() => setToast(null), 4200); };
  const setReviewMode = (enabled: boolean) => { setMobileReviewMode(enabled); if (typeof window === 'undefined') return; const nextUrl = new URL(window.location.href); if (enabled) nextUrl.searchParams.set('review', 'mobile'); else nextUrl.searchParams.delete('review'); window.history.replaceState({}, '', nextUrl.pathname + nextUrl.search + nextUrl.hash); };
  const codeFor = (groupId: string, fileName: string) => drafts[groupId + ':' + fileName] ?? samples[fileName] ?? '';

  function openView(view: MainView) { setMainView(view); setCommandOpen(false); setFindOpen(false); setActiveSurface('editor'); if (view !== 'workspace') setSidebarHidden(false); }
  function openSettings() { setMainView('settings'); setSettingsSection('general'); setCommandOpen(false); setFindOpen(false); setSidebarHidden(false); }
  function activateProject(groupId: string) { const group = projectGroups.find((item) => item.id === groupId); if (!group) return; setActiveGroupId(groupId); setProjectGroups((groups) => groups.map((item) => ({ ...item, collapsed: item.id !== groupId }))); setProjectRootExpanded(true); setExpandedFolders({ App: true, Editor: true, Tests: true }); setMainView('workspace'); setActiveSurface('editor'); setCodeDraft(codeFor(groupId, group.activeFile)); setIsDirty(false); setSelectedGitPath((gitStates[groupId] ?? initialGitStates[groupId])?.changes[0]?.path ?? ''); setCommandOpen(false); }
  function toggleFolder(folder: string) { setExpandedFolders((folders) => ({ ...folders, [folder]: !folders[folder] })); }
  function collapseProjectTree() { setProjectRootExpanded(false); setExpandedFolders({ App: false, Editor: false, Tests: false }); }
  function refreshProjectTree() { showToast('ファイルツリーを更新しました', `${currentProject.name} の一覧は最新です。`); }
  function showTreeAction(title: string, detail: string) { showToast(title, detail); }
  function openFile(fileName: string) { updateCurrentProject((group) => ({ ...group, activeFile: fileName })); setCodeDraft(codeFor(activeGroupId, fileName)); setActiveSurface('editor'); setMainView('workspace'); setIsDirty(false); }
  function openSearchMatch(match: SourceSearchMatch) { updateCurrentProject((group) => ({ ...group, activeFile: match.fileName })); setCodeDraft(codeFor(activeGroupId, match.fileName)); setActiveSurface('editor'); setMainView('workspace'); setIsDirty(false); }
  function openTerminal(terminalId = currentProject.activeTerminalId, groupId = activeGroupId) { setProjectGroups((groups) => groups.map((group) => group.id === groupId ? { ...group, terminalVisible: true, activeTerminalId: terminalId } : group)); setActiveSurface('terminal'); setMainView('workspace'); window.setTimeout(() => terminalInputRef.current?.focus(), 0); }
  function selectSurface(kind: SurfaceKind, terminalId?: string, groupId = activeGroupId) { if (groupId !== activeGroupId) activateProject(groupId); if (kind === 'terminal') openTerminal(terminalId, groupId); else { setActiveSurface('editor'); setMainView('workspace'); } }
  function closeTerminal(terminalId: string) { if (currentProject.terminals.length === 1) { updateCurrentProject((group) => ({ ...group, terminalVisible: false })); setActiveSurface('editor'); return; } const nextTerminal = currentProject.terminals.find((terminal) => terminal.id !== terminalId); updateCurrentProject((group) => ({ ...group, terminals: group.terminals.filter((terminal) => terminal.id !== terminalId), activeTerminalId: nextTerminal?.id ?? group.activeTerminalId })); }
  function splitTerminal() { terminalSequenceRef.current += 1; const nextId = activeGroupId + '-terminal-' + terminalSequenceRef.current; const nextTerminal = createTerminalSession(nextId, currentProject.terminals.length + 1, currentTerminal.shell, currentTerminal.cwd); updateCurrentProject((group) => ({ ...group, terminals: [...group.terminals, nextTerminal], activeTerminalId: nextTerminal.id, terminalVisible: true })); setActiveSurface('terminal'); setMainView('workspace'); window.setTimeout(() => terminalInputRef.current?.focus(), 0); }
  function beginResize(event: ReactPointerEvent<HTMLDivElement>) { event.preventDefault(); resizeRef.current = { start: currentProject.terminalPosition === 'bottom' ? event.clientY : event.clientX, percent: currentProject.terminalPercent, position: currentProject.terminalPosition }; setIsResizing(true); }
  function runCommand(event: FormEvent<HTMLFormElement>, terminalId: string) { event.preventDefault(); const terminal = currentProject.terminals.find((item) => item.id === terminalId); if (!terminal) return; const command = terminal.input.trim(); const result = commandResult(command, currentGit.branch, terminal.cwd); updateCurrentProject((group) => ({ ...group, terminals: group.terminals.map((item) => item.id === terminalId ? { ...item, lines: command === 'clear' ? [] : [...item.lines, '$ ' + command, ...result], input: '' } : item) })); }
  function saveFile() { setDrafts((current) => ({ ...current, [codeKey]: codeDraft })); setIsDirty(false); showToast('保存しました', `${currentProject.name} の ${activeFile} を保存しました`); }
  function updateGit(updater: (state: GitProjectState) => GitProjectState) { setGitStates((states) => ({ ...states, [activeGroupId]: updater(states[activeGroupId] ?? initialGitStates[activeGroupId]) })); }
  function setGitStaged(path: string, staged: boolean) { updateGit((state) => ({ ...state, changes: state.changes.map((change) => change.path === path ? { ...change, staged } : change) })); showToast(staged ? '変更をステージしました' : 'ワークツリーへ戻しました', path); }
  function discardGitChange(path: string) { updateGit((state) => ({ ...state, changes: state.changes.filter((change) => change.path !== path) })); setSelectedGitPath(''); showToast('変更を削除しました', path); }
  function commitChanges() { if (!currentGit.commitMessage.trim() || stagedChanges.length === 0) return; updateGit((state) => ({ ...state, changes: state.changes.filter((change) => !change.staged), commitMessage: '' })); showToast('変更をコミットしました', `${stagedChanges.length}件のファイルをコミットしました`); }
  function runCommandItem(id: string) { if (id.startsWith('open:')) { setCommandOpen(false); setCommandQuery(''); openFile(id.slice(5)); return; } setCommandOpen(false); setCommandQuery(''); if (id === 'add-agent') setAgentWindowOpen(true); if (id === 'agent-model') { updateCurrentProject((group) => ({ ...group, terminals: group.terminals.map((terminal) => terminal.id === group.activeTerminalId ? { ...terminal, lines: [...terminal.lines, '$ /model', '  ↳ Agentのネイティブモデルpickerを表示'] } : terminal) })); openTerminal(); showToast('モデル選択コマンドを送信しました', '/model ↵ · Agentのネイティブpickerを開きます'); } if (id === 'new-terminal') splitTerminal(); if (id === 'find-in-files') openView('search'); if (id === 'source-control') openView('source-control'); if (id === 'activity') openView('activity'); if (id === 'debug') openView('debug'); if (id === 'toggle-sidebar') setSidebarHidden((hidden) => !hidden); if (id === 'save') saveFile(); if (id === 'mobile-review') setReviewMode(true); if (id === 'settings') openSettings(); }
  function showActivityTerminal(thread: ActivityThread) { activateProject(thread.projectId); openTerminal(thread.terminalId, thread.projectId); }
  function queueChatMessage(threadId: string, message: string) { const thread = activityThreads.find((item) => item.id === threadId); if (!thread) return; setThreadMessages((current) => ({ ...current, [thread.id]: [...(current[thread.id] ?? thread.messages), { id: `${thread.id}-${Date.now()}`, role: 'user', text: message, time: '今' }] })); showToast('メッセージを送信待ちにしました', `${thread.projectId} のアクティブなセッションに送信します`); }
  function queueReviewComments(threadId: string, comments: ActivityReviewComment[]) { const thread = activityThreads.find((item) => item.id === threadId); if (!thread || comments.length === 0) return; messageSequenceRef.current += 1; const reviewMessage: ActivityMessage = { id: `${thread.id}-review-${messageSequenceRef.current}`, role: 'user', text: `Diff reviewのフィードバック\n${comments.map((comment) => `${comment.filePath}:${comment.next ?? comment.old ?? '行'}行目 — ${comment.text}`).join('\n')}`, time: '今' }; setThreadMessages((current) => ({ ...current, [thread.id]: [...(current[thread.id] ?? thread.messages), reviewMessage] })); showToast('レビューをAgentへ送信しました', `${comments.length}件の行コメントをアクティブなセッションへ送信しました`); }
  function decideApproval(threadId: string, decision: Exclude<ApprovalDecision, 'pending'>) { const thread = activityThreads.find((item) => item.id === threadId); const approval = thread?.approval; if (!approval || (approvalDecisions[threadId] ?? approval.decision) !== 'pending') return; const decisionLabel = decision === 'allowed' ? '今回だけ許可' : decision === 'session' ? 'セッション中は許可' : '拒否'; messageSequenceRef.current += 1; const userMessage: ActivityMessage = { id: `${threadId}-approval-choice-${messageSequenceRef.current}`, role: 'user', text: `承認: ${decisionLabel}`, time: '今' }; const agentMessage: ActivityMessage = { id: `${threadId}-approval-reply-${messageSequenceRef.current}`, role: 'agent', text: decision === 'denied' ? '拒否を受け取りました。この操作は実行せず、別の方針を検討します。' : '許可を受け取りました。Claude Codeの同じセッションで操作を続けます。', time: '今' }; setApprovalDecisions((current) => ({ ...current, [threadId]: decision })); setThreadStatusOverrides((current) => ({ ...current, [threadId]: 'working' })); setThreadMessages((current) => ({ ...current, [threadId]: [...(current[threadId] ?? thread.messages), userMessage, agentMessage] })); showToast(decision === 'denied' ? '操作を拒否しました' : '操作を許可しました', `${thread.agentName} · ${approval.tool} · ${decisionLabel}`); }
  function startAgentSession(request: AddAgentRequest) { const agent = agentUsage.find((item) => item.id === request.agentId); if (!agent) return; setAgentWindowOpen(false); const target = request.launchTarget === 'terminal' ? 'ターミナル' : 'アクティビティ'; const profileLabel = request.profile === 'review' ? '変更を確認' : request.profile === 'debug' ? 'デバッグ' : '実装'; const modelLabel = request.modelId || 'デフォルトモデル'; showToast('Agentセッションを開始しました', `${agent.name} · ${modelLabel} · ${profileLabel} · ${target} · ${request.worktree}`); if (request.launchTarget === 'activity') openView('activity'); else openTerminal(); }
  function sendChat(event: FormEvent<HTMLFormElement>) { event.preventDefault(); const message = chatInput.trim(); if (!message || !selectedThread) return; queueChatMessage(selectedThread.id, message); setChatInput(''); }
  function runDebugAction(action: 'continue' | 'over' | 'into' | 'out' | 'restart') { if (action === 'restart') { setDebugStepIndex(0); setDebugRunning(false); setDebugLog((lines) => [...lines, 'デバッガーを ClairApp.swift:4 で再起動しました']); showToast('デバッグセッションを再起動しました', 'ClairApp.swift:4 のブレークポイントで停止します'); return; } const next = action === 'continue' ? Math.min(debugSteps.length - 1, debugStepIndex + 2) : action === 'out' ? Math.max(0, debugStepIndex - 1) : Math.min(debugSteps.length - 1, debugStepIndex + 1); setDebugStepIndex(next); setDebugRunning(action === 'continue'); setDebugLog((lines) => [...lines, `${action === 'continue' ? '続行' : action === 'over' ? 'ステップオーバー' : action === 'into' ? 'ステップイン' : 'ステップアウト'} · ${debugSteps[next].source}:${debugSteps[next].line}`]); }
  function openDebugAgentMode() { setAgentDebugMode(true); setAgentPatchDecision('pending'); setAgentTranscriptExtra([]); }
  function decideDebugAgentPatch(decision: Exclude<DebugAgentPatchDecision, 'pending'>) { if (agentPatchDecision !== 'pending') return; setAgentPatchDecision(decision); if (decision === 'applied') { setAgentTranscriptExtra((lines) => [...lines, '● dap.apply_patch(main.go) を適用しました', 'go test ./... 実行中 · PASS']); showToast('パッチを適用しました', 'main.go · nil チェックを追加してテストを実行します'); } else { setAgentTranscriptExtra((lines) => [...lines, '却下されました。別の修正案を検討します']); showToast('修正を却下しました', 'main.go の変更は適用されません'); } }

  const sourceFiles = useMemo(() => allFileNames.map((name) => ({ name, path: sourcePaths[name] ?? name, content: drafts[activeGroupId + ':' + name] ?? samples[name] ?? '' })), [activeGroupId, drafts]);
  const paneStyle = { '--terminal-percent': currentProject.terminalPercent + '%', '--editor-font-size': fontSize + 'px' } as CSSProperties;

  useEffect(() => { const timer = window.setTimeout(() => setMobileReviewMode(new URLSearchParams(window.location.search).get('review') === 'mobile'), 0); return () => window.clearTimeout(timer); }, []);
  useEffect(() => { const timer = window.setTimeout(() => { try { const savedGroups = window.localStorage.getItem('clair-project-groups'); const restoredGroups = savedGroups ? normalizeGroups(JSON.parse(savedGroups)) : initialProjectGroups; const savedActiveGroup = window.localStorage.getItem('clair-active-project-group'); const nextActiveGroup = savedActiveGroup && restoredGroups.some((group) => group.id === savedActiveGroup) ? savedActiveGroup : restoredGroups[0].id; const savedDrafts = window.localStorage.getItem('clair-editor-drafts-v1'); const restoredDrafts = savedDrafts ? JSON.parse(savedDrafts) as Record<string, string> : {}; setProjectGroups(restoredGroups.map((group) => ({ ...group, collapsed: group.id !== nextActiveGroup }))); setActiveGroupId(nextActiveGroup); setDrafts(restoredDrafts); const restoredFile = restoredGroups.find((group) => group.id === nextActiveGroup)?.activeFile ?? 'ClairApp.swift'; setCodeDraft(restoredDrafts[nextActiveGroup + ':' + restoredFile] ?? samples[restoredFile] ?? ''); const savedGit = window.localStorage.getItem('clair-editor-git-v1') ?? window.localStorage.getItem('clair-git-review-state-v1'); if (savedGit) setGitStates({ ...initialGitStates, ...JSON.parse(savedGit) }); const savedFontSize = Number(window.localStorage.getItem('clair-editor-font-size-v1')); if (Number.isFinite(savedFontSize) && savedFontSize >= 13 && savedFontSize <= 18) setFontSize(savedFontSize); setWordWrap(window.localStorage.getItem('clair-editor-word-wrap-v1') === 'true'); setSidebarHidden(window.localStorage.getItem('clair-sidebar-hidden-v1') === 'true'); } catch { setProjectGroups(initialProjectGroups); setActiveGroupId(initialProjectGroups[0].id); setCodeDraft(samples['ClairApp.swift']); } setHydrated(true); }, 0); return () => window.clearTimeout(timer); }, []);
  useEffect(() => { if (!hydrated) return; window.localStorage.setItem('clair-project-groups', JSON.stringify(projectGroups)); window.localStorage.setItem('clair-active-project-group', activeGroupId); window.localStorage.setItem('clair-editor-git-v1', JSON.stringify(gitStates)); window.localStorage.setItem('clair-editor-drafts-v1', JSON.stringify(drafts)); window.localStorage.setItem('clair-editor-font-size-v1', String(fontSize)); window.localStorage.setItem('clair-editor-word-wrap-v1', String(wordWrap)); window.localStorage.setItem('clair-sidebar-hidden-v1', String(sidebarHidden)); }, [activeGroupId, drafts, fontSize, gitStates, hydrated, projectGroups, sidebarHidden, wordWrap]);
  useEffect(() => { const onKeyDown = (event: KeyboardEvent) => { const modifier = event.metaKey || event.ctrlKey; if (modifier && event.key.toLowerCase() === 's') { event.preventDefault(); saveFile(); } else if (modifier && event.key.toLowerCase() === 'b') { event.preventDefault(); setSidebarHidden((hidden) => !hidden); } else if (modifier && event.key.toLowerCase() === 'j') { event.preventDefault(); if (currentProject.terminalVisible) setActiveSurface((surface) => surface === 'terminal' ? 'editor' : 'terminal'); else openTerminal(); } else if (modifier && event.key.toLowerCase() === 'p') { event.preventDefault(); setCommandOpen(true); setCommandQuery(''); setPaletteMode('command'); setPaletteIndex(0); } else if (modifier && event.shiftKey && event.key.toLowerCase() === 'f') { event.preventDefault(); openView('search'); } else if (modifier && event.shiftKey && event.key.toLowerCase() === 'd') { event.preventDefault(); openView('debug'); } else if (event.key === 'Escape') { setCommandOpen(false); setFindOpen(false); setUsageAgentId(null); } }; window.addEventListener('keydown', onKeyDown); return () => window.removeEventListener('keydown', onKeyDown);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeGroupId, activeFile, codeDraft, currentProject.terminalVisible]);
  useEffect(() => { if (!isResizing) return; const onPointerMove = (event: PointerEvent) => { const area = workAreaRef.current; const resize = resizeRef.current; if (!area || !resize) return; const rect = area.getBoundingClientRect(); const delta = resize.position === 'bottom' ? event.clientY - resize.start : event.clientX - resize.start; const total = resize.position === 'bottom' ? rect.height : rect.width; const nextPercent = resize.percent - (delta / total) * 100; updateCurrentProject((group) => ({ ...group, terminalPercent: Math.min(64, Math.max(24, Math.round(nextPercent))) })); }; const onPointerUp = () => { resizeRef.current = null; setIsResizing(false); }; window.addEventListener('pointermove', onPointerMove); window.addEventListener('pointerup', onPointerUp); return () => { window.removeEventListener('pointermove', onPointerMove); window.removeEventListener('pointerup', onPointerUp); }; // Resizing reads the mounted work area.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isResizing]);

  if (mobileReviewMode) return <MobileReviewShell projectGroups={projectGroups} activeGroupId={activeGroupId} currentProject={currentProject} currentGit={currentGit} agents={agentUsage} threads={displayThreads.map((thread) => ({ ...thread, messages: threadMessages[thread.id] ?? thread.messages }))} agentWindowOpen={agentWindowOpen} onProjectChange={activateProject} onOpenDesktop={() => setReviewMode(false)} onOpenAddAgent={() => setAgentWindowOpen(true)} onCloseAddAgent={() => setAgentWindowOpen(false)} onStartAgent={startAgentSession} onSendMessage={queueChatMessage} onSendReviewComments={queueReviewComments} onDecideApproval={decideApproval} />;

  const fileSidebar = <aside className="file-sidebar" aria-label="Projectエクスプローラー"><header className="sidebar-header projects-header"><button type="button" className="projects-heading" onClick={() => setProjectsExpanded((expanded) => !expanded)} aria-expanded={projectsExpanded} aria-label="Project一覧"><span className="tree-chevron">{projectsExpanded ? '⌄' : '›'}</span><h2>PROJECTS</h2></button><div className="sidebar-actions"><button type="button" className="sidebar-action" onClick={() => showTreeAction('新しいファイル', 'このモックでは既存のProjectファイルをプレビューしています。')} aria-label="新しいファイル" title="新しいファイル"><span className="sidebar-action-mark new-file-mark" /></button><button type="button" className="sidebar-action" onClick={() => showTreeAction('新しいフォルダー', 'Projectルートのフォルダー操作をここから行えます。')} aria-label="新しいフォルダー" title="新しいフォルダー"><span className="sidebar-action-mark new-folder-mark" /></button><button type="button" className="sidebar-action" onClick={refreshProjectTree} aria-label="ファイルツリーを更新" title="更新"><span className="sidebar-action-mark refresh-mark">↻</span></button><button type="button" className="sidebar-action" onClick={collapseProjectTree} aria-label="ファイルツリーを折りたたむ" title="すべて折りたたむ"><span className="sidebar-action-mark collapse-mark">⌃</span></button></div></header>{projectsExpanded && <><button type="button" className="workspace-root" onClick={() => setProjectRootExpanded((expanded) => !expanded)} aria-expanded={projectRootExpanded} title={currentProject.root}><span className="root-chevron">{projectRootExpanded ? '⌄' : '›'}</span><span className="folder-icon root-folder-icon" /><span className="root-copy"><strong>{currentProject.name}</strong><small>{currentProject.root}</small></span></button>{projectRootExpanded && <div className="file-tree">{fileTree.map((folder) => <section className={'tree-section ' + (folder.folder && expandedFolders[folder.folder] === false ? 'is-collapsed' : '')} key={folder.folder || 'root'}>{folder.folder ? <button type="button" className="tree-folder" onClick={() => toggleFolder(folder.folder)} aria-expanded={expandedFolders[folder.folder] !== false}><span className="tree-chevron">{expandedFolders[folder.folder] === false ? '›' : '⌄'}</span><span className="folder-icon" />{folder.folder}</button> : null}{(!folder.folder || expandedFolders[folder.folder] !== false) && folder.files.map((file) => <button type="button" className={'tree-file ' + (file === activeFile ? 'is-active' : '')} key={file} onClick={() => openFile(file)}><span className={'file-type ' + (file.endsWith('.md') ? 'markdown' : file.endsWith('.swift') ? 'swift' : 'plain')}>{file.endsWith('.md') ? 'M' : file.endsWith('.swift') ? 'S' : '·'}</span><span>{file}</span>{file === activeFile && isDirty && <i className="dirty-dot" />}</button>)}</section>)}</div>}</>}<div className="sidebar-footer"><span className="status-dot is-live" />{currentProject.name}<span className="sidebar-footer-path">{currentGit.branch}</span></div></aside>;

  const gitSidebar = <aside className="source-control-sidebar" aria-label="ソース管理"><header className="sidebar-header"><h2>ソース管理</h2><span className="change-count">{currentGit.changes.length}</span></header><div className="branch-picker"><span className="branch-icon">⑂</span><select value={currentGit.branch} onChange={(event) => updateGit((state) => ({ ...state, branch: event.target.value }))} aria-label="現在のブランチ">{Array.from(new Set([currentGit.branch, ...branchOptions])).map((branch) => <option value={branch} key={branch}>{branch}</option>)}</select></div><div className="change-list"><section className="change-section"><header><span>ステージ済みの変更</span><b>{stagedChanges.length}</b></header>{stagedChanges.map((change) => <button type="button" className={'change-row ' + (selectedGitPath === change.path ? 'is-active' : '')} key={change.path} onClick={() => setSelectedGitPath(change.path)}><span className={'change-kind ' + change.kind}>{change.kind[0].toUpperCase()}</span><span>{change.path}</span><i onClick={(event) => { event.stopPropagation(); setGitStaged(change.path, false); }}>−</i></button>)}{stagedChanges.length === 0 && <p className="change-empty">ステージ済みの変更はありません</p>}</section><section className="change-section"><header><span>変更</span><b>{workingChanges.length}</b></header>{workingChanges.map((change) => <button type="button" className={'change-row ' + (selectedGitPath === change.path ? 'is-active' : '')} key={change.path} onClick={() => setSelectedGitPath(change.path)}><span className={'change-kind ' + change.kind}>{change.kind[0].toUpperCase()}</span><span>{change.path}</span><i onClick={(event) => { event.stopPropagation(); setGitStaged(change.path, true); }}>＋</i></button>)}{workingChanges.length === 0 && <p className="change-empty">ワークツリーはクリーンです</p>}</section></div><form className="commit-form" onSubmit={(event) => { event.preventDefault(); commitChanges(); }}><textarea value={currentGit.commitMessage} onChange={(event) => updateGit((state) => ({ ...state, commitMessage: event.target.value }))} placeholder="コミットメッセージ" rows={2} aria-label="コミットメッセージ" /><button type="submit" disabled={!currentGit.commitMessage.trim() || stagedChanges.length === 0}>コミット {stagedChanges.length ? stagedChanges.length + '件' : ''}<kbd>⌘↵</kbd></button></form></aside>;

  const activitySidebar = <aside className="activity-sidebar" aria-label="アクティビティ"><header className="sidebar-header"><h2>アクティビティ</h2><span className="activity-live-count">{activityThreads.length}</span></header><label className="activity-search"><span>⌕</span><input value={activityQuery} onChange={(event) => setActivityQuery(event.target.value)} placeholder="アクティビティを絞り込み" aria-label="アクティビティを絞り込み" /></label><div className="activity-project-filter" aria-label="Agentで絞り込み"><button type="button" className={activityAgentFilter === 'all' ? 'is-active' : ''} onClick={() => setActivityAgentFilter('all')}>すべて</button>{agentUsage.map((agent) => <button type="button" className={activityAgentFilter === agent.id ? 'is-active' : ''} key={agent.id} onClick={() => setActivityAgentFilter(agent.id)} aria-label={agent.name + 'で絞り込み'} title={agent.name}><VendorIcon agentId={agent.id} /></button>)}</div><div className="activity-list">{visibleThreads.map((thread) => <button type="button" key={thread.id} className={'activity-row ' + (thread.id === activitySelection ? 'is-active' : '')} onClick={() => { setActivitySelection(thread.id); setActivityReviewOpen(false); }}><span className={'activity-icon ' + thread.status}><VendorIcon agentId={thread.agentId} /></span><span><strong>{thread.summary}</strong><small>{thread.title} · {thread.projectId}</small></span><time>{thread.approval?.decision === 'pending' ? '承認待ち · ' : thread.approval ? '応答済み · ' : thread.review ? '変更 · ' : ''}{thread.updatedAt}</time></button>)}{visibleThreads.length === 0 && <p className="activity-empty">該当するアクティビティはありません</p>}</div></aside>;

  const debugSidebar = <aside className="debug-sidebar" aria-label="デバッグの詳細"><header className="sidebar-header"><h2>実行とデバッグ</h2><span className={'debug-state ' + (debugRunning ? 'is-running' : '')}>{debugRunning ? '実行中' : '停止中'}</span></header><section className="debug-section"><header><span>ブレークポイント</span><b>1</b></header><button type="button" className="debug-breakpoint is-active" onClick={() => setDebugStepIndex(0)}><i />ClairApp.swift<small>4行目</small></button></section><section className="debug-section"><header><span>コールスタック</span></header>{debugSteps.slice(0, 3).map((step, index) => <button type="button" className={'debug-stack-row ' + (index === debugStepIndex ? 'is-active' : '')} key={step.id} onClick={() => setDebugStepIndex(index)}><span>{index === 0 ? '▾' : '›'}</span>{step.label}<small>{step.source}:{step.line}行目</small></button>)}</section><section className="debug-section"><header><span>変数</span></header>{currentDebugStep.locals.map((local) => <div className="debug-variable" key={local.name}><span>{local.name}</span><code>{local.value}</code><small>{local.type}</small></div>)}</section></aside>;

  const debugSidebarAgent = <aside className="debug-sidebar" aria-label="デバッグの詳細（Agent）"><header className="sidebar-header"><h2>実行とデバッグ</h2><span className="debug-state is-running">実行中</span></header><section className="debug-section"><header><span>ブレークポイント</span><b>1</b></header><button type="button" className="debug-breakpoint is-active"><i />{goAgentDebugScenario.file}<small>{goAgentDebugScenario.breakpointLine}行目</small></button></section><section className="debug-section"><header><span>コールスタック</span></header>{goAgentDebugScenario.callStack.map((frame) => <button type="button" className={'debug-stack-row ' + (frame.active ? 'is-active' : '')} key={frame.label}><span>{frame.active ? '▾' : '›'}</span>{frame.label}<small>{frame.location}</small></button>)}</section><section className="debug-section"><header><span>変数</span></header>{goAgentDebugScenario.variables.map((local) => <div className={'debug-variable' + (local.danger ? ' is-danger' : '')} key={local.name}><span>{local.name}</span><code>{local.value}</code></div>)}</section></aside>;

  const renderGitSurface = () => <div className="diff-viewer"><header className="content-header diff-header"><div><span className="content-leading-icon">⑂</span><div><h1>ソース管理</h1><p>{currentGit.branch} → {selectedBranch?.base ?? 'main'} · {selectedBranch?.summary ?? 'ワークツリー'}</p></div></div><div className="content-actions"><div className="git-view-switcher" role="tablist" aria-label="差分表示"><button type="button" className={gitView === 'inline' ? 'is-active' : ''} onClick={() => setGitView('inline')}>インライン</button><button type="button" className={gitView === 'split' ? 'is-active' : ''} onClick={() => setGitView('split')}>左右比較</button><button type="button" className={gitView === 'graph' ? 'is-active' : ''} onClick={() => setGitView('graph')}>グラフ</button></div></div></header>{gitView === 'graph' ? <SourceGraphView graph={sourceGraph} /> : selectedGitChange ? <><div className="diff-file-toolbar"><div><strong>{selectedGitChange.path}</strong><span>{selectedGitChange.staged ? 'ステージ済み' : 'ワークツリー'} · {selectedBranch?.base ?? 'main'} → {currentGit.branch}</span></div><div>{selectedGitChange.staged ? <button type="button" onClick={() => setGitStaged(selectedGitChange.path, false)}>ステージ解除</button> : <><button type="button" onClick={() => discardGitChange(selectedGitChange.path)}>破棄</button><button type="button" className="primary-action" onClick={() => setGitStaged(selectedGitChange.path, true)}>ステージ</button></>}</div></div><div className="diff-context"><span>@@ -7,3 +7,5 @@</span><b>{selectedGitChange.staged ? 'ステージ済み' : 'ワークツリー'}</b></div>{gitView === 'split' ? <SideBySideDiff diff={selectedDiff} /> : <InlineDiff diff={selectedDiff} />}</> : <div className="empty-view"><span>✓</span><h1>ワークツリーはクリーンです</h1><p>{currentProject.name} に変更はありません。</p></div>}</div>;

  const renderActivitySurface = () => {
    const messages = selectedThread ? threadMessages[selectedThread.id] ?? selectedThread.messages : [];
    return <div className="activity-view">
      <header className="content-header activity-content-header">
        <div><div className="activity-heading"><span className={'large-activity-icon ' + (selectedThread?.status ?? 'waiting')}>{selectedThread ? <VendorIcon agentId={selectedThread.agentId} /> : '◌'}</span><div><h1>{selectedThread?.summary ?? 'アクティビティ'}</h1><p>{selectedThread ? `${selectedThread.title} · ${selectedThread.projectId}` : 'Agentの会話'}</p></div></div></div>
        <div className="activity-header-actions">{selectedThread?.review && <button type="button" className="content-action-button" onClick={() => setActivityReviewOpen(true)}>Diff review <span>↗</span></button>}<button type="button" className="content-action-button" onClick={() => setAgentWindowOpen(true)}>Agentを追加 <span>＋</span></button><button type="button" className="content-action-button" onClick={() => selectedThread && showActivityTerminal(selectedThread)}>ターミナルを開く <span>↗</span></button></div>
      </header>
      {selectedThread && <div className="activity-chat">
        <div className="chat-context"><span className={'status-dot ' + (selectedThread.status === 'waiting' ? 'is-attention' : 'is-live')} /><div><strong>{selectedThread.title}</strong><small>{selectedThread.projectId} · {selectedThread.agentId === 'claude-code' ? 'Claude Code · Opus 4.1 · ローカル認証' : selectedThread.provider} · {selectedThread.updatedAt}</small></div><span className="chat-context-state">{selectedThread.status === 'working' ? '実行中' : selectedThread.status === 'waiting' ? '入力待ち' : '完了'}</span></div>
        <div className="chat-messages">{messages.map((message) => <div className={'chat-message ' + message.role} key={message.id}><span className="chat-message-author">{message.role === 'agent' ? <VendorIcon agentId={selectedThread.agentId} /> : message.role === 'user' ? 'あなた' : 'システム'}</span><p>{message.text}</p><time>{message.time}</time></div>)}{selectedThread.approval && <ActivityApprovalCard approval={selectedThread.approval} onDecide={(decision) => decideApproval(selectedThread.id, decision)} />}</div>
        <form className="chat-composer" onSubmit={sendChat}><input value={chatInput} onChange={(event) => setChatInput(event.target.value)} placeholder="Agentにメッセージ…" aria-label="Agentにメッセージ" /><button type="submit" disabled={!chatInput.trim()} aria-label="メッセージを送信">↗</button></form>
      </div>}
      {selectedThread?.review && <ActivityChangeReviewPanel key={selectedThread.id} review={selectedThread.review} open={activityReviewOpen} onClose={() => setActivityReviewOpen(false)} onSubmit={(comments) => { queueReviewComments(selectedThread.id, comments); setActivityReviewOpen(false); }} className="activity-review-overlay" />}
    </div>;
  };

  const renderDebugAgentSurface = () => <div className="debug-view debug-agent-view"><header className="content-header debug-content-header"><div><div className="debug-heading"><span className="debug-heading-icon">▷</span><div><h1>実行とデバッグ</h1><p>{goAgentDebugScenario.file}:{goAgentDebugScenario.breakpointLine} · Agent が操作中</p></div></div></div><div className="debug-toolbar"><span className="debug-agent-badge">✦ Agent が操作中 · dap-go</span><button type="button" className="debug-agent-toggle" onClick={() => setAgentDebugMode(false)}>Swiftのデバッグに戻る</button></div></header><div className="debug-main"><section className="debug-source"><header><strong>{goAgentDebugScenario.file}</strong><span>{goAgentDebugScenario.breakpointLine}行目で停止中</span></header><div className="debug-code debug-agent-code">{goAgentDebugScenario.code.map((row) => <div className={'debug-code-line' + (row.current ? ' is-current' : '')} key={row.line}><span>{row.line}</span><code>{row.text || ' '}</code></div>)}</div></section><section className="debug-agent-panel" aria-label="AIエージェント"><header><span>AIエージェント</span><span>go debug session</span></header><div className="debug-agent-transcript">
    <div className="debug-agent-prompt">$ clair debug run ./cmd/api --agent</div>
    {goAgentDebugScenario.transcript.map((item, index) => <div className="debug-agent-tool" key={index}><strong>● {item.tool}</strong><small>{item.detail}</small></div>)}
    {agentTranscriptExtra.map((line, index) => <div className="debug-agent-tool" key={'extra-' + index}><small>{line}</small></div>)}
    <p className="debug-agent-diagnosis">{goAgentDebugScenario.diagnosis}</p>
    <DebugAgentPatchCard decision={agentPatchDecision} patch={goAgentDebugScenario.patch} onDecide={decideDebugAgentPatch} />
  </div></section></div></div>;

  const renderDebugSurface = () => agentDebugMode ? renderDebugAgentSurface() : <div className="debug-view"><header className="content-header debug-content-header"><div><div className="debug-heading"><span className="debug-heading-icon">▷</span><div><h1>実行とデバッグ</h1><p>{currentDebugStep.source}:{currentDebugStep.line} · {currentDebugStep.label}</p></div></div></div><div className="debug-toolbar"><button type="button" onClick={() => runDebugAction('restart')} title="再起動">↻</button><button type="button" className="debug-continue" onClick={() => runDebugAction('continue')} title="続行">▶ 続行</button><button type="button" onClick={() => runDebugAction('over')} title="ステップオーバー">↷</button><button type="button" onClick={() => runDebugAction('into')} title="ステップイン">↓</button><button type="button" onClick={() => runDebugAction('out')} title="ステップアウト">↑</button><button type="button" className="debug-agent-toggle" onClick={openDebugAgentMode}>Go + Agent統合を見る</button></div></header><div className="debug-main"><section className="debug-source"><header><strong>{currentDebugStep.source}</strong><span>{currentDebugStep.line}行目で停止中</span></header><div className="debug-code"><div className="debug-code-line"><span>{currentDebugStep.line}</span><code>{currentDebugStep.code}</code></div><div className="debug-code-ghost"><span>{currentDebugStep.line + 1}</span><code>{'    // ステップ実行のプレビュー'}</code></div></div><section className="debug-step-list"><header><strong>ステップ実行</strong><span>{debugStepIndex + 1} / {debugSteps.length}</span></header>{debugSteps.map((step, index) => <button type="button" className={'debug-step-row ' + (index === debugStepIndex ? 'is-active' : '')} key={step.id} onClick={() => setDebugStepIndex(index)}><span className="debug-step-index">{index < debugStepIndex ? '✓' : index === debugStepIndex ? '▶' : index + 1}</span><span><strong>{step.label}</strong><small>{step.source}:{step.line} · {step.code}</small></span><i>{index === debugStepIndex ? '停止中' : index < debugStepIndex ? '完了' : '待機中'}</i></button>)}</section></section><section className="debug-console"><header><span>デバッグコンソール</span><span>変数</span></header><div className="debug-console-log">{debugLog.map((line, index) => <div key={index}>{line}</div>)}<div className="debug-console-caret">▸ <span>デバッガーコマンドを入力できます</span></div></div><div className="debug-watch"><header><strong>ブレークポイント時のローカル値</strong><span>{currentDebugStep.locals.length}件</span></header>{currentDebugStep.locals.map((local) => <div className="debug-watch-row" key={local.name}><span>{local.name}</span><code>{local.value}</code><small>{local.type}</small></div>)}</div></section></div></div>;

  const renderWorkspaceSurface = () => <div className={'work-area ' + (currentProject.terminalVisible ? 'has-terminal terminal-' + currentProject.terminalPosition : '') + (wordWrap ? ' is-wrapped' : '')} style={paneStyle} ref={workAreaRef}><section className={'editor-pane ' + (activeSurface === 'editor' ? 'is-focused' : '')}><header className="editor-header"><div className="breadcrumbs"><span>{currentProject.name}</span><b>/</b><span>{sourcePaths[activeFile]?.split('/').slice(0, -1).join('/') || 'root'}</span><b>/</b><strong>{activeFile}</strong>{isDirty && <i className="dirty-dot" />}</div><div className="editor-actions"><button type="button" onClick={() => setFindOpen((open) => !open)} className={findOpen ? 'is-active' : ''}><span>⌕</span>検索</button><button type="button" className="save-action" onClick={saveFile} disabled={!isDirty}><span>✓</span>保存</button></div></header><div className="editor-canvas">{findOpen && <div className="find-widget"><span>⌕</span><input autoFocus value={findQuery} onChange={(event) => setFindQuery(event.target.value)} placeholder="ファイル内を検索" aria-label="ファイル内を検索" /><b>{findQuery ? findMatches + '件' : ''}</b><button type="button" onClick={() => setFindOpen(false)} aria-label="検索を閉じる">×</button></div>}<div className="code-editor-shell"><div className="code-gutter" aria-hidden="true">{codeDraft.split('\n').map((_, index) => <span key={index}>{index + 1}</span>)}</div><textarea className="code-editor" value={codeDraft} onFocus={() => setActiveSurface('editor')} onChange={(event) => { setCodeDraft(event.target.value); setIsDirty(true); }} spellCheck={false} wrap={wordWrap ? 'soft' : 'off'} aria-label={activeFile + ' エディタ'} /></div></div></section>{currentProject.terminalVisible && <><div className="pane-resizer" onPointerDown={beginResize} role="separator" aria-label="ターミナルのサイズを変更" /><div className={'terminal-grid is-' + currentProject.terminalSplit}>{currentProject.terminals.map((terminal) => <section className={'terminal-pane ' + (activeSurface === 'terminal' && terminal.id === currentProject.activeTerminalId ? 'is-focused' : '')} key={terminal.id} onClick={() => setActiveSurface('terminal')}><header className="terminal-header"><div><span className="terminal-status" /><strong>{terminal.label}</strong><small>{terminal.shell === 'claude' ? 'Claude Code' : 'zsh'}</small></div><div className="terminal-actions"><button type="button" onClick={splitTerminal} title="ターミナルを分割">＋</button><button type="button" onClick={() => updateCurrentProject((group) => ({ ...group, terminalSplit: group.terminalSplit === 'columns' ? 'rows' : 'columns' }))} title="分割方向を変更">{currentProject.terminalSplit === 'columns' ? '↕' : '↔'}</button><button type="button" onClick={() => updateCurrentProject((group) => ({ ...group, terminalPosition: group.terminalPosition === 'bottom' ? 'right' : 'bottom' }))} title="ターミナルの位置を変更">{currentProject.terminalPosition === 'bottom' ? '⇥' : '⇣'}</button><button type="button" onClick={() => closeTerminal(terminal.id)} title="ターミナルを閉じる">×</button></div></header><div className="terminal-body" onClick={() => { setActiveSurface('terminal'); if (terminal.id === currentProject.activeTerminalId) terminalInputRef.current?.focus(); }}>{terminal.lines.map((line, index) => <div className={line.startsWith('$') ? 'terminal-command' : ''} key={line + '-' + index}>{line || '\u00a0'}</div>)}<form onSubmit={(event) => runCommand(event, terminal.id)}><span>{currentProject.name}</span><b> · </b><span>{currentGit.branch}</span><b> ❯ </b><input ref={terminal.id === currentProject.activeTerminalId ? terminalInputRef : undefined} value={terminal.input} onChange={(event) => updateCurrentProject((group) => ({ ...group, terminals: group.terminals.map((item) => item.id === terminal.id ? { ...item, input: event.target.value } : item) }))} aria-label={terminal.label + ' のコマンド'} autoComplete="off" spellCheck={false} /></form></div></section>)}</div></>}</div>;

  return <main className="editor-app"><section className={'mac-window ' + (isResizing ? 'is-resizing' : '')}><header className="titlebar"><div className="traffic-lights" aria-hidden="true"><span /><span /><span /></div><nav className="project-tabstrip" aria-label="開いているエディタとターミナル">{projectGroups.map((group) => { const isActive = group.id === activeGroupId; return <div className={'project-group ' + (isActive ? 'is-active' : '')} style={{ '--group-color': group.color } as CSSProperties} key={group.id}><button type="button" className="project-group-label" onClick={() => activateProject(group.id)} title={group.name + ' · ' + group.root} aria-current={isActive ? 'page' : undefined}><span className="group-label-name">{group.name}</span></button><div className="project-surfaces" aria-label={group.name + ' のタブ'}><button type="button" className={'surface-tab surface-tab-editor ' + (isActive && activeSurface === 'editor' && mainView === 'workspace' ? 'is-active' : '')} onClick={() => selectSurface('editor', undefined, group.id)} title={group.activeFile}><SurfaceIcon kind="editor" /><span className="surface-tab-label">{group.activeFile}</span>{isActive && isDirty && <i className="tab-dirty-dot" />}</button>{group.terminals.map((terminal) => <button type="button" className={'surface-tab surface-tab-terminal ' + (isActive && activeSurface === 'terminal' && group.activeTerminalId === terminal.id && mainView === 'workspace' ? 'is-active' : '')} onClick={() => selectSurface('terminal', terminal.id, group.id)} title={terminal.label} key={terminal.id}><SurfaceIcon kind="terminal" /><span className="surface-tab-label">{terminal.label}</span></button>)}</div></div>; })}</nav><div className="title-actions"><button type="button" className={commandOpen ? 'is-active' : ''} onClick={() => { setCommandOpen((open) => !open); setCommandQuery(''); setPaletteMode('command'); setPaletteIndex(0); }} aria-label="コマンドウィンドウを開く" title="コマンドウィンドウ"><span aria-hidden="true">⌘</span></button><button type="button" className={mainView === 'settings' ? 'is-active' : ''} onClick={openSettings} aria-label="設定を開く" title="設定"><span aria-hidden="true">⚙︎</span></button></div></header>
    {commandOpen && <div className="window-overlay" onClick={() => setCommandOpen(false)}><section className="command-window" role="dialog" aria-modal="true" aria-label="コマンドウィンドウ" onClick={(event) => event.stopPropagation()}><header className="overlay-header"><div><span className="overlay-icon">{paletteMode === 'command' ? '⌘' : <SurfaceIcon kind="editor" />}</span><div><strong>{paletteMode === 'command' ? 'コマンド' : 'ファイルへ移動'}</strong><small>{paletteMode === 'command' ? 'Command Registryの全操作' : 'Project内のファイル'}</small></div></div><kbd>Esc</kbd></header><label className="command-search"><span>⌕</span><input autoFocus value={commandQuery} onChange={(event) => { setCommandQuery(event.target.value); setPaletteIndex(0); }} onKeyDown={(event) => { if (event.key === 'ArrowDown') { event.preventDefault(); setPaletteIndex((index) => Math.min(paletteItems.length - 1, index + 1)); } else if (event.key === 'ArrowUp') { event.preventDefault(); setPaletteIndex((index) => Math.max(0, index - 1)); } else if (event.key === 'Enter') { event.preventDefault(); const item = paletteItems[paletteIndexClamped]; if (item) runCommandItem(item.id); } }} placeholder={paletteMode === 'command' ? 'コマンドを検索' : 'ファイル名で検索'} aria-label={paletteMode === 'command' ? 'コマンドを検索' : 'ファイルを検索'} /><span className="command-count">{paletteItems.length}件</span></label><div className="command-list">{paletteItems.map((item, index) => <button type="button" key={item.id} className={index === paletteIndexClamped ? 'is-active' : ''} onMouseEnter={() => setPaletteIndex(index)} onClick={() => runCommandItem(item.id)}><span className="command-item-text"><strong>{item.label}</strong><small>{item.detail}</small></span>{item.shortcut && <kbd>{item.shortcut}</kbd>}</button>)}{paletteItems.length === 0 && <p>{paletteMode === 'command' ? 'コマンドが見つかりません' : 'ファイルが見つかりません'}</p>}</div><footer><button type="button" className={'palette-mode-tab ' + (paletteMode === 'command' ? 'is-active' : '')} onClick={() => { setPaletteMode('command'); setPaletteIndex(0); }}>コマンド</button><button type="button" className={'palette-mode-tab ' + (paletteMode === 'quickOpen' ? 'is-active' : '')} onClick={() => { setPaletteMode('quickOpen'); setPaletteIndex(0); }}>ファイルへ移動</button><span className="palette-divider" /><button type="button" className="palette-move" onClick={() => setPaletteIndex((index) => Math.max(0, index - 1))} aria-label="前を選択">↑</button><button type="button" className="palette-move" onClick={() => setPaletteIndex((index) => Math.min(paletteItems.length - 1, index + 1))} aria-label="次を選択">↓</button><span>↵ 選択中を実行</span><div style={{ flex: 1 }} /><span>⌘P</span></footer></section></div>}
    {agentWindowOpen && <AddAgentWindow currentProject={currentProject} agents={agentUsage} onClose={() => setAgentWindowOpen(false)} onStart={startAgentSession} />}
    <div className={'app-layout ' + (sidebarHidden ? 'is-sidebar-hidden ' : '') + 'view-' + mainView}>{mainView !== 'settings' && <nav className="activity-bar" aria-label="ワークスペースのビュー"><button type="button" className={mainView === 'workspace' ? 'is-active' : ''} onClick={() => { setSidebarHidden(false); openView('workspace'); }} aria-label="エクスプローラー" title="エクスプローラー"><span className="activity-glyph explorer-glyph" /></button><button type="button" className={mainView === 'search' ? 'is-active' : ''} onClick={() => openView('search')} aria-label="検索" title="検索"><span className="activity-glyph search-glyph" /></button><button type="button" className={mainView === 'source-control' ? 'is-active' : ''} onClick={() => openView('source-control')} aria-label="ソース管理" title="ソース管理"><span className="activity-glyph source-glyph">⑂</span>{currentGit.changes.length > 0 && <em>{currentGit.changes.length}</em>}</button><button type="button" className={mainView === 'activity' ? 'is-active' : ''} onClick={() => openView('activity')} aria-label="アクティビティ" title="アクティビティ"><span className="activity-glyph activity-glyph-mark">◌</span><em>{activityThreads.length}</em></button><button type="button" className={mainView === 'debug' ? 'is-active' : ''} onClick={() => openView('debug')} aria-label="実行とデバッグ" title="実行とデバッグ"><span className="activity-glyph debug-glyph">▷</span></button></nav>}{!sidebarHidden && mainView === 'workspace' && fileSidebar}{!sidebarHidden && mainView === 'search' && <SourceSearchPanel projectName={currentProject.name} files={sourceFiles} onOpenMatch={openSearchMatch} />}{!sidebarHidden && mainView === 'source-control' && gitSidebar}{!sidebarHidden && mainView === 'activity' && activitySidebar}{!sidebarHidden && mainView === 'debug' && (agentDebugMode ? debugSidebarAgent : debugSidebar)}<section className="editor-shell">{mainView === 'settings' ? <SettingsPage section={settingsSection} onSectionChange={setSettingsSection} onBack={() => openView('workspace')} catalog={settingsCatalog} agents={agentUsage} fontSize={fontSize} setFontSize={setFontSize} wordWrap={wordWrap} setWordWrap={setWordWrap} mobileConnected={mobileConnected} setMobileConnected={setMobileConnected} onCheckUpdate={() => showToast('アップデートがあります', 'Clair 0.7.2 がプレビュー版で利用できます。', 'インストール')} /> : mainView === 'source-control' ? renderGitSurface() : mainView === 'activity' ? renderActivitySurface() : mainView === 'debug' ? renderDebugSurface() : renderWorkspaceSurface()}</section></div>
    <div className="footer-region"><footer className="usage-footer"><div className="footer-context"><button type="button" onClick={() => openView('source-control')}><span>⑂</span>{currentGit.branch}</button><span className="footer-separator" /><span>↓{currentGit.behind} ↑{currentGit.ahead}</span><span className="footer-muted">{isDirty ? '未保存の変更' : '保存済み'}</span></div><div className="agent-usage-strip" aria-label="Agentの使用量">{agentUsage.map((agent) => <button type="button" className={'usage-chip ' + (usageAgentId === agent.id ? 'is-active' : '')} key={agent.id} onClick={() => setUsageAgentId((current) => current === agent.id ? null : agent.id)}><span className="usage-chip-avatar" style={{ '--agent-color': agent.color } as CSSProperties}><VendorIcon agentId={agent.id} /></span><span><strong>{agent.shortName}</strong><small>5時間 残り{agent.remaining5h}% · 7日間 残り{agent.remaining7d}%</small></span><UsageBar value={agent.used5h} /></button>)}</div><div className="footer-actions"><span>UTF-8</span><span>{activeFile.endsWith('.md') ? 'Markdown' : 'Swift'}</span></div></footer>{usageAgentId && <UsagePopover agents={agentUsage} selectedId={usageAgentId} onClose={() => setUsageAgentId(null)} onSelect={setUsageAgentId} onRefresh={() => showToast('使用量を更新しました', 'レート制限は最新です。')} />}</div>
    {toast && <div className="toast" role="status"><span className="toast-mark">✓</span><div><strong>{toast.title}</strong><small>{toast.detail}</small></div>{toast.action && <button type="button" onClick={() => { setToast(null); showToast('アップデートを予約しました', 'Clairを再起動すると次のプレビュー版がインストールされます。'); }}>{toast.action}</button>}<button type="button" className="toast-close" onClick={() => setToast(null)} aria-label="通知を閉じる">×</button></div>}
  </section></main>;
}

function normalizeGroups(value: unknown): ProjectGroup[] {
  if (!Array.isArray(value)) return initialProjectGroups;
  const groups = value.flatMap((raw, index) => { const item = asRecord(raw); if (!item) return []; const layout = asRecord(item.layout); const id = stringValue(item.id, 'project-' + (index + 1)); const root = stringValue(item.root, '~/Projects/' + id); const rawTerminals = safeArray(item.terminals); const terminals = rawTerminals.flatMap((rawTerminal, terminalIndex) => { const source = asRecord(rawTerminal); if (!source) return []; const terminalId = stringValue(source.id, id + '-terminal-' + (terminalIndex + 1)); const shell: TerminalShell = source.shell === 'zsh' ? 'zsh' : 'claude'; const fallback = createTerminalSession(terminalId, terminalIndex + 1, shell, root); return [{ ...fallback, label: stringValue(source.label, fallback.label), cwd: stringValue(source.cwd, root), lines: safeArray(source.lines).filter((line): line is string => typeof line === 'string'), input: typeof source.input === 'string' ? source.input : '' }]; }); const normalizedTerminals = terminals.length ? terminals : [createTerminalSession(id + '-terminal', 1, 'claude', root)]; const activeTerminalId = stringValue(item.activeTerminalId ?? layout?.activeTerminalId, normalizedTerminals[0].id); const defaultFile = id === 'ccedit' ? 'WorkspaceView.swift' : id === 'clair-releases' ? 'README.md' : 'ClairApp.swift'; const activeFile = stringValue(item.activeFile ?? layout?.activeFile, defaultFile); const position: TerminalPosition = item.terminalPosition === 'right' || layout?.terminalPosition === 'right' ? 'right' : 'bottom'; const split: TerminalSplit = item.terminalSplit === 'rows' || layout?.terminalSplit === 'rows' ? 'rows' : 'columns'; const visible = typeof item.terminalVisible === 'boolean' ? item.terminalVisible : typeof layout?.terminalVisible === 'boolean' ? layout.terminalVisible : false; return [{ id, name: stringValue(item.name, id), root, color: stringValue(item.color, groupColors[index % groupColors.length]), collapsed: true, activeFile: allFileNames.includes(activeFile) ? activeFile : 'ClairApp.swift', terminalVisible: visible, terminalPosition: position, terminalPercent: Math.min(64, Math.max(24, numberValue(item.terminalPercent ?? layout?.terminalPercent, 36))), activeTerminalId: normalizedTerminals.some((terminal) => terminal.id === activeTerminalId) ? activeTerminalId : normalizedTerminals[0].id, terminalSplit: split, terminals: normalizedTerminals }]; }); return groups.length ? groups : initialProjectGroups;
}
