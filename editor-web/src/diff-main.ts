import "./style.css";
import "./diff-style.css";

import { Compartment, EditorState, Text, RangeSetBuilder, type Extension } from "@codemirror/state";
import { oneDark } from "@codemirror/theme-one-dark";
import {
  Decoration,
  type DecorationSet,
  drawSelection,
  EditorView,
  gutter,
  GutterMarker,
  highlightActiveLine,
} from "@codemirror/view";
import { type DiffLine, type DiffLineKind, parseUnifiedDiff } from "./diff";
import { detectLanguageId, loadLanguageExtension } from "./language";
import type { NativeBridge } from "./native-bridge";

type DiffConfig = {
  path: string;
  language?: string;
  fontFamily: string;
  fontSize: number;
  background: string;
  textColor: string;
  wordWrap: boolean;
};

type NativeMessage = { type: "ready" };

declare global {
  interface Window {
    clairDiffViewer: {
      configure(config: Partial<DiffConfig>): void;
      setDiff(patch: string): void;
    };
  }
}

const host = document.querySelector<HTMLDivElement>("#diff-editor");
if (!host) throw new Error("Clair diff viewer host was not found");

function bridge(): NativeBridge | null {
  return window.webkit?.messageHandlers?.clairDiffViewer ?? null;
}

function post(message: NativeMessage): void {
  bridge()?.postMessage(message);
}

let config: DiffConfig = {
  path: "",
  fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
  fontSize: 13,
  background: "#282c34",
  textColor: "#f1f3ef",
  wordWrap: false,
};
let meta: DiffLine[] = [];
let lastPatch = "";
let languageRequest = 0;
let languageExtension: Extension = [];

const appearanceCompartment = new Compartment();
const languageCompartment = new Compartment();
const decorationsCompartment = new Compartment();

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

function markerClassFor(kind: DiffLineKind): string {
  switch (kind) {
    case "add":
      return "cm-diff-marker-add";
    case "remove":
      return "cm-diff-marker-remove";
    case "hunk":
      return "cm-diff-marker-hunk";
    default:
      return "";
  }
}

class TextGutterMarker extends GutterMarker {
  constructor(
    private readonly label: string,
    private readonly className: string
  ) {
    super();
  }

  toDOM(): Node {
    const span = document.createElement("span");
    span.className = this.className;
    span.textContent = this.label;
    return span;
  }
}

function numberGutter(side: "old" | "new"): Extension {
  return gutter({
    lineMarker(view, line) {
      const number = view.state.doc.lineAt(line.from).number;
      const info = meta[number - 1];
      if (!info) return null;
      const value = side === "old" ? info.oldLine : info.newLine;
      const label = value != null ? String(value) : "";
      return new TextGutterMarker(
        label,
        `cm-diff-gutter-${side} ${markerClassFor(info.kind)}`
      );
    },
  });
}

function markerGutter(): Extension {
  return gutter({
    lineMarker(view, line) {
      const number = view.state.doc.lineAt(line.from).number;
      const info = meta[number - 1];
      if (!info) return null;
      const label = info.kind === "add" ? "+" : info.kind === "remove" ? "−" : "";
      return new TextGutterMarker(
        label,
        `cm-diff-gutter-marker ${markerClassFor(info.kind)}`
      );
    },
  });
}

function buildLineDecorations(parsed: DiffLine[], doc: Text): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  for (let index = 0; index < parsed.length; index += 1) {
    const kind = parsed[index].kind;
    const className =
      kind === "add"
        ? "cm-diff-add-line"
        : kind === "remove"
          ? "cm-diff-remove-line"
          : kind === "hunk"
            ? "cm-diff-hunk-line"
            : null;
    if (!className) continue;
    const line = doc.line(index + 1);
    builder.add(line.from, line.from, Decoration.line({ class: className }));
  }
  return builder.finish();
}

function buildDiffState(patch: string): EditorState {
  const parsed = parseUnifiedDiff(patch);
  meta = parsed;
  const doc = Text.of(parsed.length ? parsed.map((line) => line.text) : [""]);
  return EditorState.create({
    doc,
    extensions: [
      oneDark,
      EditorState.readOnly.of(true),
      EditorView.editable.of(false),
      drawSelection(),
      highlightActiveLine(),
      numberGutter("old"),
      numberGutter("new"),
      markerGutter(),
      appearanceCompartment.of(appearanceTheme()),
      languageCompartment.of(languageExtension),
      decorationsCompartment.of(EditorView.decorations.of(buildLineDecorations(parsed, doc))),
    ],
  });
}

const view = new EditorView({ state: buildDiffState(""), parent: host });

async function loadLanguage(path: string, requestedID?: string): Promise<void> {
  const request = (languageRequest += 1);
  const id = requestedID || detectLanguageId(path);
  const extension = await loadLanguageExtension(id);
  if (request !== languageRequest) return;
  languageExtension = extension ?? [];
  view.dispatch({ effects: languageCompartment.reconfigure(languageExtension) });
}

window.clairDiffViewer = {
  configure(nextConfig) {
    config = { ...config, ...nextConfig };
    document.documentElement.style.background = config.background;
    document.body.style.background = config.background;
    view.dispatch({ effects: appearanceCompartment.reconfigure(appearanceTheme()) });
    void loadLanguage(config.path, config.language);
  },
  setDiff(patch) {
    if (patch === lastPatch) return;
    lastPatch = patch;
    view.setState(buildDiffState(patch));
  },
};

post({ type: "ready" });
