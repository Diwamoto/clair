import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react';

import { activityItems, chat, files, sessions, type ChatMessage, type Session } from './data';

export type Screen =
  | 'workspace'
  | 'review'
  | 'graph'
  | 'activity'
  | 'debug'
  | 'debugAgent'
  | 'settings'
  | 'sessions';

export type Overlay = 'command' | 'quickOpen' | 'search' | 'addAgent' | null;

export type PaneKind = 'editor' | 'agent' | 'terminal';

export type PaneNode =
  | { id: string; kind: 'leaf'; pane: PaneKind; filePath?: string }
  | { id: string; kind: 'split'; orientation: 'horizontal' | 'vertical'; ratio: number; first: PaneNode; second: PaneNode };

export type Tab = { path: string; dirty: boolean };

export type TerminalLine = { text: string; tone?: 'add' | 'del' | 'dim' | 'accent' };

let uid = 0;
const nextId = () => `n${++uid}`;

// The pane tree the Main artboard draws: editor on the left, agent output over
// a terminal on the right.
const initialLayout = (): PaneNode => ({
  id: nextId(),
  kind: 'split',
  orientation: 'horizontal',
  ratio: 0.62,
  first: { id: nextId(), kind: 'leaf', pane: 'editor', filePath: 'apple/ClairApp/ProjectWorkspace.swift' },
  second: {
    id: nextId(),
    kind: 'split',
    orientation: 'vertical',
    ratio: 0.55,
    first: { id: nextId(), kind: 'leaf', pane: 'agent' },
    second: { id: nextId(), kind: 'leaf', pane: 'terminal' },
  },
});

const initialTerminal: TerminalLine[] = [
  { text: '$ codex exec --profile review', tone: 'dim' },
  { text: '' },
  { text: 'proposed patch  crates/clair-ptyhost/src/pty.rs' },
  { text: '  +18 -4', tone: 'add' },
  { text: '' },
];

const initialAgentLog: TerminalLine[] = [
  { text: '● Update(apple/ClairApp/ProjectWorkspace.swift)', tone: 'accent' },
  { text: '  Updated with 24 additions and 6 removals', tone: 'add' },
  { text: '' },
  { text: '  ** BUILD SUCCEEDED **', tone: 'add' },
];

function findLeaf(node: PaneNode, id: string): Extract<PaneNode, { kind: 'leaf' }> | null {
  if (node.kind === 'leaf') return node.id === id ? node : null;
  return findLeaf(node.first, id) ?? findLeaf(node.second, id);
}

function firstLeaf(node: PaneNode): Extract<PaneNode, { kind: 'leaf' }> {
  return node.kind === 'leaf' ? node : firstLeaf(node.first);
}

function mapNode(node: PaneNode, id: string, fn: (n: PaneNode) => PaneNode): PaneNode {
  if (node.id === id) return fn(node);
  if (node.kind === 'split') {
    return { ...node, first: mapNode(node.first, id, fn), second: mapNode(node.second, id, fn) };
  }
  return node;
}

function removeLeaf(node: PaneNode, id: string): PaneNode | null {
  if (node.kind === 'leaf') return node.id === id ? null : node;
  const first = removeLeaf(node.first, id);
  const second = removeLeaf(node.second, id);
  if (!first) return second;
  if (!second) return first;
  return { ...node, first, second };
}

function equalize(node: PaneNode): PaneNode {
  if (node.kind === 'leaf') return node;
  return { ...node, ratio: 0.5, first: equalize(node.first), second: equalize(node.second) };
}

function leavesInOrder(node: PaneNode, out: Extract<PaneNode, { kind: 'leaf' }>[] = []) {
  if (node.kind === 'leaf') out.push(node);
  else {
    leavesInOrder(node.first, out);
    leavesInOrder(node.second, out);
  }
  return out;
}

export type Workbench = ReturnType<typeof useWorkbenchState>;

function useWorkbenchState() {
  const [screen, setScreen] = useState<Screen>('workspace');
  const [overlay, setOverlay] = useState<Overlay>(null);

  const [tabs, setTabs] = useState<Tab[]>([
    { path: 'apple/ClairApp/ProjectWorkspace.swift', dirty: true },
  ]);
  const [activePath, setActivePath] = useState('apple/ClairApp/ProjectWorkspace.swift');
  const [contents, setContents] = useState<Record<string, string>>(() =>
    Object.fromEntries(files.map((f) => [f.path, f.content])),
  );
  const [collapsed, setCollapsed] = useState<Set<string>>(() => new Set(['clair/crates']));

  const [layout, setLayout] = useState<PaneNode>(initialLayout);
  const [focusedPane, setFocusedPane] = useState<string>(() => firstLeaf(layout).id);
  const [maximized, setMaximized] = useState<string | null>(null);

  const [terminal, setTerminal] = useState<TerminalLine[]>(initialTerminal);
  const [agentLog] = useState<TerminalLine[]>(initialAgentLog);
  const [awaitingApproval, setAwaitingApproval] = useState(true);

  const [cursor, setCursor] = useState({ line: 46, column: 12 });
  const [messages, setMessages] = useState<ChatMessage[]>(chat);
  const [approvalDecision, setApprovalDecision] = useState<null | '拒否' | 'セッション中は許可' | '今回だけ許可'>(null);
  const [activeActivity, setActiveActivity] = useState(activityItems[1].id);
  const [sessionList, setSessionList] = useState<Session[]>(sessions);
  const [activeProject, setActiveProject] = useState('clair');
  const [collapsedProjects, setCollapsedProjects] = useState<Set<string>>(() => new Set());

  const [reviewFile, setReviewFile] = useState('apple/ClairApp/ProjectWorkspace.swift');
  const [reviewFilter, setReviewFilter] = useState<'全差分' | 'commit済み' | '未commit'>('全差分');

  const [settingsSection, setSettingsSection] = useState('一般');
  const [toggles, setToggles] = useState<Record<string, boolean>>({
    restoreLayout: true,
    confirmClose: true,
    showQuota: true,
  });

  const [debugLine, setDebugLine] = useState(9);
  const [breakpoints, setBreakpoints] = useState<number[]>([9]);
  const [debugRunning, setDebugRunning] = useState(false);
  const [debugConsole, setDebugConsole] = useState<string[]>([
    'Debugger attached to Clair · Debug configuration',
    'Breakpoint hit at ClairApp.swift:4',
  ]);

  const layoutRef = useRef(layout);
  layoutRef.current = layout;

  const openFile = useCallback((path: string) => {
    setTabs((current) => (current.some((t) => t.path === path) ? current : [...current, { path, dirty: false }]));
    setActivePath(path);
    setScreen('workspace');
    setOverlay(null);
    setLayout((current) => {
      const leaves = leavesInOrder(current).filter((l) => l.pane === 'editor');
      const target = leaves.find((l) => l.id === focusedPane) ?? leaves[0];
      if (!target) return current;
      return mapNode(current, target.id, (n) => ({ ...n, filePath: path }) as PaneNode);
    });
  }, [focusedPane]);

  const closeTab = useCallback(
    (path: string) => {
      setTabs((current) => {
        const next = current.filter((t) => t.path !== path);
        if (path === activePath && next.length) setActivePath(next[next.length - 1].path);
        return next;
      });
    },
    [activePath],
  );

  const editFile = useCallback((path: string, value: string) => {
    setContents((current) => ({ ...current, [path]: value }));
    setTabs((current) => current.map((t) => (t.path === path ? { ...t, dirty: true } : t)));
  }, []);

  const saveFile = useCallback((path: string) => {
    setTabs((current) => current.map((t) => (t.path === path ? { ...t, dirty: false } : t)));
  }, []);

  const splitPane = useCallback(
    (orientation: 'horizontal' | 'vertical') => {
      setLayout((current) => {
        const leaf = findLeaf(current, focusedPane) ?? firstLeaf(current);
        const cloneId = nextId();
        return mapNode(current, leaf.id, (n) => {
          const original = n as Extract<PaneNode, { kind: 'leaf' }>;
          return {
            id: nextId(),
            kind: 'split',
            orientation,
            ratio: 0.5,
            first: original,
            second: { ...original, id: cloneId },
          };
        });
      });
      setMaximized(null);
    },
    [focusedPane],
  );

  const closePane = useCallback(() => {
    setLayout((current) => {
      if (current.kind === 'leaf') return current;
      const next = removeLeaf(current, focusedPane);
      if (!next) return current;
      setFocusedPane(firstLeaf(next).id);
      return next;
    });
    setMaximized(null);
  }, [focusedPane]);

  const focusDirection = useCallback(() => {
    const leaves = leavesInOrder(layoutRef.current);
    const index = leaves.findIndex((l) => l.id === focusedPane);
    setFocusedPane(leaves[(index + 1) % leaves.length].id);
  }, [focusedPane]);

  const setRatio = useCallback((id: string, ratio: number) => {
    setLayout((current) =>
      mapNode(current, id, (n) =>
        n.kind === 'split' ? { ...n, ratio: Math.min(0.92, Math.max(0.08, ratio)) } : n,
      ),
    );
  }, []);

  const pushTerminal = useCallback((lines: TerminalLine[]) => {
    setTerminal((current) => [...current, ...lines]);
  }, []);

  const runTerminal = useCallback(
    (input: string) => {
      const value = input.trim();
      if (awaitingApproval) {
        if (value.toLowerCase() === 'y') {
          setAwaitingApproval(false);
          pushTerminal([
            { text: 'Apply this change? [y/N] y' },
            { text: '' },
            { text: 'applied  crates/clair-ptyhost/src/pty.rs', tone: 'add' },
            { text: '  +18 -4', tone: 'add' },
            { text: '' },
          ]);
          return;
        }
        if (value.toLowerCase() === 'n' || value === '') {
          setAwaitingApproval(false);
          pushTerminal([{ text: 'Apply this change? [y/N] N' }, { text: '' }, { text: 'skipped', tone: 'del' }, { text: '' }]);
          return;
        }
      }
      if (value === 'clear') {
        setTerminal([]);
        return;
      }
      const echo: TerminalLine[] = [{ text: `$ ${value}`, tone: 'dim' }];
      if (value === 'git status') {
        pushTerminal([
          ...echo,
          { text: 'On branch main' },
          { text: 'Changes not staged for commit:' },
          { text: '  modified:   apple/ClairApp/ProjectWorkspace.swift', tone: 'del' },
          { text: '  new file:   apple/ClairApp/SessionRail.swift', tone: 'add' },
          { text: '' },
        ]);
      } else if (value.startsWith('swift test')) {
        pushTerminal([...echo, { text: 'Test Suite ProjectKernelTests passed', tone: 'add' }, { text: '' }]);
      } else if (value === '') {
        pushTerminal(echo);
      } else {
        pushTerminal([...echo, { text: `zsh: command not found: ${value.split(' ')[0]}`, tone: 'del' }, { text: '' }]);
      }
    },
    [awaitingApproval, pushTerminal],
  );

  const sendMessage = useCallback((text: string) => {
    const stamp = new Date();
    const time = `${String(stamp.getHours()).padStart(2, '0')}:${String(stamp.getMinutes()).padStart(2, '0')}`;
    setMessages((current) => [
      ...current,
      { id: `m${current.length + 1}`, from: 'user', text, time },
      {
        id: `m${current.length + 2}`,
        from: 'agent',
        text: '受け取りました。該当箇所を読み直して、再現条件から確認します。',
        time,
      },
    ]);
  }, []);

  const restartSession = useCallback((id: string) => {
    setSessionList((current) =>
      current.map((s) => (s.id === id ? { ...s, state: '実行中', signal: '再起動', elapsed: '0m 02s', attention: false } : s)),
    );
  }, []);

  const toggleBreakpoint = useCallback((line: number) => {
    setBreakpoints((current) => (current.includes(line) ? current.filter((l) => l !== line) : [...current, line]));
  }, []);

  const debugStep = useCallback(
    (kind: 'continue' | 'over' | 'into' | 'out' | 'restart' | 'stop') => {
      if (kind === 'stop') {
        setDebugRunning(false);
        setDebugConsole((c) => [...c, 'Debug session terminated']);
        return;
      }
      if (kind === 'restart') {
        setDebugLine(9);
        setDebugRunning(true);
        setDebugConsole((c) => [...c, 'Debugger restarted · Breakpoint hit at ClairApp.swift:9']);
        return;
      }
      setDebugRunning(true);
      setDebugLine((line) => {
        const next = kind === 'out' ? Math.max(7, line - 1) : Math.min(11, line + 1);
        setDebugConsole((c) => [...c, `Stepped ${kind} → ClairApp.swift:${next}`]);
        return next;
      });
    },
    [],
  );

  const runCommand = useCallback(
    (id: string) => {
      setOverlay(null);
      switch (id) {
        case 'clair.pane.split.horizontal':
          return splitPane('horizontal');
        case 'clair.pane.split.vertical':
          return splitPane('vertical');
        case 'clair.pane.focus.right':
          return focusDirection();
        case 'clair.pane.maximize':
          return setMaximized((m) => (m ? null : focusedPane));
        case 'clair.pane.equalize':
          return setLayout((current) => equalize(current));
        case 'clair.pane.close':
          return closePane();
        case 'clair.review.open':
          return setScreen('review');
        case 'clair.graph.open':
          return setScreen('graph');
        case 'clair.activity.open':
          return setScreen('activity');
        case 'clair.sessions.open':
          return setScreen('sessions');
        case 'clair.debug.open':
          return setScreen('debug');
        case 'clair.debug.agent':
          return setScreen('debugAgent');
        case 'clair.agent.add':
          return setOverlay('addAgent');
        case 'clair.settings.open':
          return setScreen('settings');
        default:
          return setScreen('workspace');
      }
    },
    [closePane, focusDirection, focusedPane, splitPane],
  );

  const toggleFolder = useCallback((id: string) => {
    setCollapsed((current) => {
      const next = new Set(current);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }, []);

  const toggleProjectCollapsed = useCallback((project: string) => {
    setCollapsedProjects((current) => {
      const next = new Set(current);
      if (next.has(project)) next.delete(project);
      else next.add(project);
      return next;
    });
  }, []);

  const dirtyCount = tabs.filter((t) => t.dirty).length;

  return {
    screen,
    setScreen,
    overlay,
    setOverlay,
    tabs,
    activePath,
    setActivePath,
    contents,
    openFile,
    closeTab,
    editFile,
    saveFile,
    collapsed,
    toggleFolder,
    layout,
    focusedPane,
    setFocusedPane,
    maximized,
    setMaximized,
    setRatio,
    splitPane,
    closePane,
    terminal,
    runTerminal,
    awaitingApproval,
    agentLog,
    cursor,
    setCursor,
    messages,
    sendMessage,
    approvalDecision,
    setApprovalDecision,
    activeActivity,
    setActiveActivity,
    sessions: sessionList,
    restartSession,
    activeProject,
    setActiveProject,
    collapsedProjects,
    toggleProjectCollapsed,
    reviewFile,
    setReviewFile,
    reviewFilter,
    setReviewFilter,
    settingsSection,
    setSettingsSection,
    toggles,
    setToggle: (key: string) => setToggles((current) => ({ ...current, [key]: !current[key] })),
    debugLine,
    breakpoints,
    toggleBreakpoint,
    debugRunning,
    debugConsole,
    debugStep,
    runCommand,
    dirtyCount,
  };
}

const WorkbenchContext = createContext<Workbench | null>(null);

export function WorkbenchProvider({ children }: { children: ReactNode }) {
  const value = useWorkbenchState();
  return <WorkbenchContext.Provider value={value}>{children}</WorkbenchContext.Provider>;
}

export function useWorkbench() {
  const value = useContext(WorkbenchContext);
  if (!value) throw new Error('useWorkbench must be used inside WorkbenchProvider');
  return value;
}

export function useLeaves(node: PaneNode) {
  return useMemo(() => leavesInOrder(node), [node]);
}
