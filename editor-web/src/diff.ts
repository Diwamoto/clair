export type DiffLineKind = "context" | "add" | "remove" | "hunk";

export type DiffLine = {
  oldLine: number | null;
  newLine: number | null;
  kind: DiffLineKind;
  text: string;
};

const HUNK_HEADER = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@.*$/;
const SKIPPED_HEADER_PREFIXES = [
  "diff --git",
  "index ",
  "--- ",
  "+++ ",
  "old mode",
  "new mode",
  "similarity index",
  "dissimilarity index",
  "rename from",
  "rename to",
  "copy from",
  "copy to",
  "new file mode",
  "deleted file mode",
  "Binary files",
];

export function parseUnifiedDiff(patch: string): DiffLine[] {
  const lines: DiffLine[] = [];
  let oldLine = 0;
  let newLine = 0;
  let inHunk = false;

  for (const raw of patch.split("\n")) {
    if (!inHunk && SKIPPED_HEADER_PREFIXES.some((prefix) => raw.startsWith(prefix))) {
      continue;
    }

    const hunkMatch = HUNK_HEADER.exec(raw);
    if (hunkMatch) {
      oldLine = parseInt(hunkMatch[1], 10);
      newLine = parseInt(hunkMatch[2], 10);
      inHunk = true;
      lines.push({ oldLine: null, newLine: null, kind: "hunk", text: raw });
      continue;
    }

    if (!inHunk) continue;
    if (raw.startsWith("\\")) continue; // "\ No newline at end of file"
    if (raw.length === 0) continue; // trailing artifact from the final split("\n")

    const marker = raw[0];
    const text = raw.slice(1);
    if (marker === "+") {
      lines.push({ oldLine: null, newLine, kind: "add", text });
      newLine += 1;
    } else if (marker === "-") {
      lines.push({ oldLine, newLine: null, kind: "remove", text });
      oldLine += 1;
    } else {
      lines.push({ oldLine, newLine, kind: "context", text });
      oldLine += 1;
      newLine += 1;
    }
  }

  return lines;
}
