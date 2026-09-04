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
import { bracketMatching, codeFolding, foldGutter, foldKeymap, indentOnInput } from "@codemirror/language";
import { Compartment, EditorState, type Extension } from "@codemirror/state";
import { oneDark } from "@codemirror/theme-one-dark";
import { drawSelection, EditorView, highlightActiveLine, keymap, lineNumbers } from "@codemirror/view";
import { detectLanguageId, loadLanguageExtension } from "./language";

type Selection = { from: number; to: number };

type EditorDocument = { content: string; selection?: Selection | null };

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
      content: string;
      selection: Selection;
      canUndo: boolean;
      canRedo: boolean;
    }
  | { type: "save" };

type NativeBridge = { postMessage(message: NativeMessage): void };

declare global {
  interface Window {
    webkit?: { messageHandlers?: { clairEditor?: NativeBridge } };
    clairEditor: {
      configure(config: Partial<EditorConfig>): void;
      setDocument(document: string | EditorDocument, selection?: Selection | null): void;
      focus(): void;
      undo(): void;
      redo(): void;
      reveal(selection: Selection): void;
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
let languageExtension: Extension = [];

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

function notifyChange(view: EditorView): void {
  if (suppressNativeChanges) return;
  const selection = currentSelection(view);
  post({
    type: "change",
    content: view.state.doc.toString(),
    selection,
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
        ...foldKeymap,
      ]),
      appearanceCompartment.of(appearanceTheme()),
      editabilityCompartment.of(editability()),
      languageCompartment.of(languageExtension),
      EditorView.updateListener.of((update) => {
        if (update.docChanged || update.selectionSet) notifyChange(update.view);
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
  languageExtension = extension ?? [];
  view.dispatch({ effects: languageCompartment.reconfigure(languageExtension) });
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
    void loadLanguage(config.path, config.language);
  },
  setDocument(documentOrContent, selection) {
    const document: EditorDocument = typeof documentOrContent === "string"
      ? { content: documentOrContent, selection }
      : documentOrContent;
    const content = document.content;
    const wasFocused = view.hasFocus;
    suppressNativeChanges = true;
    view.setState(buildState(content));
    if (document.selection) {
      const from = Math.min(document.selection.from, content.length);
      const to = Math.min(document.selection.to, content.length);
      view.dispatch({ selection: { anchor: from, head: to }, scrollIntoView: true });
    }
    suppressNativeChanges = false;
    notifyChange(view);
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
};

post({ type: "ready" });
