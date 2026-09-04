import type { Extension } from "@codemirror/state";

export type LanguageDef = {
  id: string;
  label: string;
  extensions: string[];
  filenames?: string[];
  load: () => Promise<Extension | null>;
};

async function loadShell(): Promise<Extension> {
  const [{ StreamLanguage }, { shell }] = await Promise.all([
    import("@codemirror/language"),
    import("@codemirror/legacy-modes/mode/shell"),
  ]);
  return StreamLanguage.define(shell);
}

async function loadXml(variant: "xml" | "html"): Promise<Extension> {
  const [{ StreamLanguage }, mod] = await Promise.all([
    import("@codemirror/language"),
    import("@codemirror/legacy-modes/mode/xml"),
  ]);
  return StreamLanguage.define(variant === "xml" ? mod.xml : mod.html);
}

async function loadCss(variant: "css" | "scss" | "less"): Promise<Extension> {
  const [{ StreamLanguage }, mod] = await Promise.all([
    import("@codemirror/language"),
    import("@codemirror/legacy-modes/mode/css"),
  ]);
  const parser = variant === "scss" ? mod.sCSS : variant === "less" ? mod.less : mod.css;
  return StreamLanguage.define(parser);
}

export const LANGUAGES: LanguageDef[] = [
  {
    id: "plaintext",
    label: "Plain Text",
    extensions: ["txt", "log"],
    load: async () => null,
  },
  {
    id: "swift",
    label: "Swift",
    extensions: ["swift"],
    load: async () => {
      const [{ LanguageSupport }, { swift, swiftFoldService }] = await Promise.all([
        import("@codemirror/language"),
        import("./swift"),
      ]);
      return new LanguageSupport(swift, [swiftFoldService]);
    },
  },
  {
    id: "javascript",
    label: "JavaScript",
    extensions: ["js", "jsx", "mjs", "cjs"],
    load: async () => {
      const m = await import("@codemirror/lang-javascript");
      return m.javascript({ jsx: true });
    },
  },
  {
    id: "typescript",
    label: "TypeScript",
    extensions: ["ts", "tsx"],
    load: async () => {
      const m = await import("@codemirror/lang-javascript");
      return m.javascript({ typescript: true, jsx: true });
    },
  },
  {
    id: "rust",
    label: "Rust",
    extensions: ["rs"],
    load: async () => {
      const m = await import("@codemirror/lang-rust");
      return m.rust();
    },
  },
  {
    id: "python",
    label: "Python",
    extensions: ["py", "pyi", "pyw"],
    load: async () => {
      const m = await import("@codemirror/lang-python");
      return m.python();
    },
  },
  {
    id: "go",
    label: "Go",
    extensions: ["go"],
    load: async () => {
      const m = await import("@codemirror/lang-go");
      return m.go();
    },
  },
  {
    id: "shell",
    label: "Shell Script",
    extensions: ["sh", "bash", "zsh", "ksh"],
    filenames: [".bashrc", ".bash_profile", ".zshrc", ".profile", ".zshenv"],
    load: loadShell,
  },
  {
    id: "hcl",
    label: "HCL / Terraform",
    extensions: ["tf", "tfvars", "hcl"],
    load: async () => {
      const m = await import("codemirror-lang-hcl");
      return m.hcl();
    },
  },
  {
    id: "json",
    label: "JSON",
    extensions: ["json", "jsonc"],
    load: async () => {
      const m = await import("@codemirror/lang-json");
      return m.json();
    },
  },
  {
    id: "markdown",
    label: "Markdown",
    extensions: ["md", "markdown", "mdx"],
    load: async () => {
      const m = await import("@codemirror/lang-markdown");
      return m.markdown();
    },
  },
  {
    id: "yaml",
    label: "YAML",
    extensions: ["yml", "yaml"],
    load: async () => {
      const [{ StreamLanguage, foldService, LanguageSupport }, { yaml }] = await Promise.all([
        import("@codemirror/language"),
        import("@codemirror/legacy-modes/mode/yaml"),
      ]);
      const lang = StreamLanguage.define(yaml);
      const yamlFold = foldService.of((state, lineStart) => {
        const line = state.doc.lineAt(lineStart);
        if (line.text.trim() === "") return null;
        const indent = (line.text.match(/^(\s*)/) ?? ["", ""])[1].length;
        let foldEnd = line.to;
        let position = line.to + 1;
        while (position <= state.doc.length) {
          const next = state.doc.lineAt(position);
          if (next.text.trim() !== "") {
            const nextIndent = (next.text.match(/^(\s*)/) ?? ["", ""])[1].length;
            if (nextIndent <= indent) break;
            foldEnd = next.to;
          }
          if (next.to >= state.doc.length) break;
          position = next.to + 1;
        }
        return foldEnd > line.to ? { from: line.to, to: foldEnd } : null;
      });
      return new LanguageSupport(lang, [yamlFold]);
    },
  },
  {
    id: "ruby",
    label: "Ruby",
    extensions: ["rb", "rake", "gemspec"],
    filenames: ["gemfile", "rakefile"],
    load: async () => {
      const [{ StreamLanguage }, { ruby }] = await Promise.all([
        import("@codemirror/language"),
        import("@codemirror/legacy-modes/mode/ruby"),
      ]);
      return StreamLanguage.define(ruby);
    },
  },
  {
    id: "html",
    label: "HTML",
    extensions: ["html", "htm", "erb"],
    load: () => loadXml("html"),
  },
  {
    id: "xml",
    label: "XML",
    extensions: ["xml", "svg"],
    load: () => loadXml("xml"),
  },
  {
    id: "sql",
    label: "SQL",
    extensions: ["sql"],
    load: async () => {
      const [{ StreamLanguage }, { standardSQL }] = await Promise.all([
        import("@codemirror/language"),
        import("@codemirror/legacy-modes/mode/sql"),
      ]);
      return StreamLanguage.define(standardSQL);
    },
  },
  {
    id: "css",
    label: "CSS",
    extensions: ["css"],
    load: () => loadCss("css"),
  },
  {
    id: "scss",
    label: "SCSS",
    extensions: ["scss"],
    load: () => loadCss("scss"),
  },
  {
    id: "less",
    label: "Less",
    extensions: ["less"],
    load: () => loadCss("less"),
  },
  {
    id: "dockerfile",
    label: "Dockerfile",
    extensions: ["dockerfile"],
    filenames: ["dockerfile"],
    load: async () => {
      const [{ StreamLanguage }, { dockerFile }] = await Promise.all([
        import("@codemirror/language"),
        import("@codemirror/legacy-modes/mode/dockerfile"),
      ]);
      return StreamLanguage.define(dockerFile);
    },
  },
];

const LANG_BY_ID = new Map<string, LanguageDef>(LANGUAGES.map((language) => [language.id, language]));

function basename(path: string): string {
  const index = Math.max(path.lastIndexOf("/"), path.lastIndexOf("\\"));
  return index >= 0 ? path.slice(index + 1) : path;
}

function extensionOf(name: string): string {
  return name.includes(".") ? name.split(".").pop() ?? "" : "";
}

export function detectLanguageId(path: string): string {
  const name = basename(path).toLowerCase();
  const extension = extensionOf(name);
  if (name === "dockerfile" || name.startsWith("dockerfile.") || extension === "dockerfile") {
    return "dockerfile";
  }
  for (const language of LANGUAGES) {
    if (language.filenames?.includes(name)) return language.id;
  }
  for (const language of LANGUAGES) {
    if (language.extensions.includes(extension)) return language.id;
  }
  return "plaintext";
}

export async function loadLanguageExtension(id: string): Promise<Extension | null> {
  return LANG_BY_ID.get(id)?.load() ?? null;
}
