import "./style.css";

import {
  defaultKeymap,
  history,
  historyKeymap,
  indentWithTab,
  redo,
  redoDepth,
  undo,
  undoDepth,
} from "@codemirror/commands";
import { searchKeymap } from "@codemirror/search";
import { bracketMatching, codeFolding, foldGutter, foldKeymap, indentOnInput } from "@codemirror/language";
import { Compartment, EditorState, type Extension } from "@codemirror/state";
import { oneDark } from "@codemirror/theme-one-dark";
import { drawSelection, EditorView, highlightActiveLine, keymap, lineNumbers, type ViewUpdate } from "@codemirror/view";
import { detectLanguageId, loadLanguageExtension } from "./language";
import type { NativeBridge } from "./native-bridge";

type Selection = { from: number; to: number };

type EditorDocument = {
  content: string;
  revision?: number;
  selection?: Selection | null;
  scrollTop?: number | null;
};
type EditorChange = { from: number; to: number; insert: string };

type EditorConfig = {
  path: string;
  language?: string;
  fontFamily: string;
  fontSize: number;
  background: string;
  textColor: string;
  wordWrap: boolean;
  readOnly: boolean;
};

type NativeMessage =
  | { type: "ready" }
  | {
      type: "change";
      baseRevision: number;
      changes: EditorChange[];
      selection: Selection;
      scrollTop: number;
      canUndo: boolean;
      canRedo: boolean;
    }
  | {
      type: "selection";
      selection: Selection;
      scrollTop: number;
      canUndo: boolean;
      canRedo: boolean;
    }
  | { type: "save" };

declare global {
  interface Window {
    clairEditor: {
      configure(config: Partial<EditorConfig>): void;
      setDocument(document: string | EditorDocument, selection?: Selection | null): void;
      focus(): void;
      undo(): void;
      redo(): void;
      reveal(selection: Selection): void;
      releaseDocument(path: string): void;
    };
  }
}

const host = document.querySelector<HTMLDivElement>("#editor");
if (!host) throw new Error("Clair editor host was not found");

const languageCompartment = new Compartment();
const appearanceCompartment = new Compartment();
const editabilityCompartment = new Compartment();
let config: EditorConfig = {
  path: "",
  fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
  fontSize: 13,
  background: "#121416",
  textColor: "#f1f3ef",
  wordWrap: false,
  readOnly: false,
};
let languageRequest = 0;
let suppressNativeChanges = false;
let viewportNotificationPending = false;
let languageExtension: Extension = [];
let currentPath = "";
let documentRevision = 0;

type CachedDocument = { state: EditorState; content: string; revision: number };

const MAX_CACHED_DOCUMENTS = 24;
const documentStateCache = new Map<string, CachedDocument>();

function rememberDocumentState(path: string, state: EditorState, content: string): void {
  if (!path) return;
  documentStateCache.delete(path);
  documentStateCache.set(path, { state, content, revision: documentRevision });
  if (documentStateCache.size > MAX_CACHED_DOCUMENTS) {
    const oldestPath = documentStateCache.keys().next().value;
    if (oldestPath !== undefined) documentStateCache.delete(oldestPath);
  }
}

function bridge(): NativeBridge | null {
  return window.webkit?.messageHandlers?.clairEditor ?? null;
}

function post(message: NativeMessage): void {
  bridge()?.postMessage(message);
}

function appearanceTheme(): Extension {
  const wrap = config.wordWrap ? "break-word" : "nowrap";
  return EditorView.theme({
    "&": {
      height: "100%",
      backgroundColor: `${config.background} !important`,
      color: config.textColor,
    },
    ".cm-scroller": {
      fontFamily: config.fontFamily,
      fontSize: `${config.fontSize}px`,
      overflowX: config.wordWrap ? "hidden" : "auto",
    },
    ".cm-content": {
      caretColor: config.textColor,
      whiteSpace: wrap,
      paddingTop: "6px",
      paddingBottom: "6px",
    },
    ".cm-line": {
      paddingTop: "0",
      paddingBottom: "0",
    },
    ".cm-gutters": {
      backgroundColor: `${config.background} !important`,
    },
  });
}

function editability(): Extension {
  return [EditorState.readOnly.of(config.readOnly), EditorView.editable.of(!config.readOnly)];
}

function currentSelection(view: EditorView): Selection {
  const selection = view.state.selection.main;
  return { from: selection.from, to: selection.to };
}

function currentScrollTop(view: EditorView): number {
  return Math.max(0, Math.round(view.scrollDOM.scrollTop));
}

function notifySelection(view: EditorView): void {
  if (suppressNativeChanges) return;
  const selection = currentSelection(view);
  post({
    type: "selection",
    selection,
    scrollTop: currentScrollTop(view),
    canUndo: undoDepth(view.state) > 0,
    canRedo: redoDepth(view.state) > 0,
  });
}

function scheduleViewportNotification(view: EditorView): void {
  if (viewportNotificationPending) return;
  viewportNotificationPending = true;
  requestAnimationFrame(() => {
    viewportNotificationPending = false;
    notifySelection(view);
  });
}

function notifyChange(update: ViewUpdate): void {
  const view = update.view;
  if (suppressNativeChanges) return;
  const changes: EditorChange[] = [];
  update.changes.iterChanges((from, to, _fromB, _toB, inserted) => {
    changes.push({ from, to, insert: inserted.toString() });
  });
  if (changes.length === 0) {
    notifySelection(view);
    return;
  }

  const baseRevision = documentRevision;
  documentRevision += 1;
  post({
    type: "change",
    baseRevision,
    changes,
    selection: currentSelection(view),
    scrollTop: currentScrollTop(view),
    canUndo: undoDepth(view.state) > 0,
    canRedo: redoDepth(view.state) > 0,
  });
}

function buildState(doc = ""): EditorState {
  return EditorState.create({
    doc,
    extensions: [
      lineNumbers(),
      foldGutter({ openText: "⌄", closedText: "›" }),
      highlightActiveLine(),
      drawSelection(),
      history(),
      indentOnInput(),
      bracketMatching(),
      codeFolding(),
      oneDark,
      keymap.of([
        { key: "Mod-s", run: () => { post({ type: "save" }); return true; } },
        indentWithTab,
        ...defaultKeymap,
        ...historyKeymap,
        ...searchKeymap,
        ...foldKeymap,
      ]),
      appearanceCompartment.of(appearanceTheme()),
      editabilityCompartment.of(editability()),
      languageCompartment.of(languageExtension),
      EditorView.updateListener.of((update) => {
        if (update.docChanged) notifyChange(update);
        else if (update.selectionSet) notifySelection(update.view);
      }),
      EditorView.domEventHandlers({
        scroll: (_event, view) => {
          scheduleViewportNotification(view);
          return false;
        },
      }),
    ],
  });
}

const view = new EditorView({ state: buildState(), parent: host });

async function loadLanguage(path: string, requestedID?: string): Promise<void> {
  const request = ++languageRequest;
  const id = requestedID || detectLanguageId(path);
  const extension = await loadLanguageExtension(id);
  if (request !== languageRequest) return;
  const resolvedExtension = extension ?? [];

  if (currentPath === path) {
    languageExtension = resolvedExtension;
    view.dispatch({ effects: languageCompartment.reconfigure(resolvedExtension) });
    rememberDocumentState(path, view.state, view.state.doc.toString());
    return;
  }
  // The user already switched away from `path` while its language was
  // loading. Patch the cached (inactive) state so it carries the right
  // highlighting when the tab is revisited, without touching the live view.
  const cachedForPath = documentStateCache.get(path);
  if (cachedForPath) {
    const nextState = cachedForPath.state.update({
      effects: languageCompartment.reconfigure(resolvedExtension),
    }).state;
    documentStateCache.set(path, {
      state: nextState,
      content: cachedForPath.content,
      revision: cachedForPath.revision,
    });
  }
}

window.clairEditor = {
  configure(nextConfig) {
    config = { ...config, ...nextConfig };
    document.documentElement.style.background = config.background;
    document.body.style.background = config.background;
    view.dispatch({
      effects: [
        appearanceCompartment.reconfigure(appearanceTheme()),
        editabilityCompartment.reconfigure(editability()),
      ],
    });
  },
  setDocument(documentOrContent, selection) {
    const document: EditorDocument = typeof documentOrContent === "string"
      ? { content: documentOrContent, selection }
      : documentOrContent;
    const content = document.content;
    const path = config.path;
    const wasFocused = view.hasFocus;
    suppressNativeChanges = true;

    if (currentPath && currentPath !== path) {
      rememberDocumentState(currentPath, view.state, view.state.doc.toString());
    }
    documentRevision = document.revision ?? documentRevision;

    // Revisiting an already-opened tab is the common case (tab switching)
    // and should not pay for a full document re-parse/re-highlight: reuse
    // the EditorState we kept from last time instead of rebuilding it.
    const cached = documentStateCache.get(path);
    if (cached && cached.content === content && cached.revision === documentRevision) {
      view.setState(cached.state);
    } else {
      view.setState(buildState(content));
      void loadLanguage(path, config.language);
    }

    // Global appearance/editability settings may have changed while this
    // document's cached state sat inactive; re-apply them (cheap facet
    // updates, no re-highlighting) so they can't go stale.
    view.dispatch({
      effects: [
        appearanceCompartment.reconfigure(appearanceTheme()),
        editabilityCompartment.reconfigure(editability()),
      ],
    });

    currentPath = path;

    if (document.selection) {
      const from = Math.min(document.selection.from, content.length);
      const to = Math.min(document.selection.to, content.length);
      view.dispatch({ selection: { anchor: from, head: to }, scrollIntoView: true });
    }
    // Store the post-selection state. If this is done before applying the
    // selection, revisiting a tab would restore the previous caret instead.
    rememberDocumentState(path, view.state, content);
    if (document.scrollTop != null && Number.isFinite(document.scrollTop)) {
      const scrollTop = Math.max(0, document.scrollTop);
      requestAnimationFrame(() => {
        view.scrollDOM.scrollTop = scrollTop;
      });
    }
    suppressNativeChanges = false;
    notifySelection(view);
    if (wasFocused) view.focus();
  },
  focus() {
    view.focus();
  },
  undo() {
    undo(view);
  },
  redo() {
    redo(view);
  },
  reveal(selection) {
    const from = Math.min(selection.from, view.state.doc.length);
    const to = Math.min(selection.to, view.state.doc.length);
    view.dispatch({ selection: { anchor: from, head: to }, scrollIntoView: true });
    view.focus();
  },
  releaseDocument(path: string) {
    documentStateCache.delete(path);
    if (path === currentPath) {
      currentPath = "";
      documentRevision = 0;
    }
  },
};

post({ type: "ready" });
