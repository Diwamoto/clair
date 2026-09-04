import { foldService, StreamLanguage, type StringStream } from "@codemirror/language";
import type { EditorState } from "@codemirror/state";

type SwiftState = {
  blockCommentDepth: number;
  stringEnd: string | null;
  stringAllowsNewline: boolean;
  expectFunctionName: boolean;
  expectTypeName: boolean;
};

const keywords = new Set([
  "associatedtype",
  "as",
  "async",
  "await",
  "break",
  "case",
  "catch",
  "class",
  "continue",
  "convenience",
  "defer",
  "deinit",
  "didSet",
  "do",
  "else",
  "enum",
  "extension",
  "fallthrough",
  "fileprivate",
  "final",
  "for",
  "func",
  "get",
  "guard",
  "if",
  "import",
  "indirect",
  "infix",
  "init",
  "inout",
  "internal",
  "is",
  "isolated",
  "let",
  "macro",
  "mutating",
  "nonisolated",
  "nonmutating",
  "open",
  "operator",
  "override",
  "package",
  "postfix",
  "precedencegroup",
  "prefix",
  "private",
  "protocol",
  "public",
  "repeat",
  "required",
  "rethrows",
  "return",
  "set",
  "some",
  "static",
  "struct",
  "subscript",
  "super",
  "throws",
  "throw",
  "try",
  "typealias",
  "var",
  "where",
  "while",
  "willSet",
  "actor",
  "borrowing",
  "consuming",
  "each",
  "repeat",
  "pack",
  "sending",
]);

const declarationKeywords = new Set([
  "actor",
  "class",
  "enum",
  "protocol",
  "struct",
  "typealias",
]);

const builtinTypes = new Set([
  "Any",
  "AnyObject",
  "Array",
  "Bool",
  "Character",
  "Dictionary",
  "Double",
  "Error",
  "Float",
  "Int",
  "Never",
  "ObjectIdentifier",
  "Optional",
  "Result",
  "Set",
  "String",
  "Substring",
  "UInt",
  "Void",
]);

const constants = new Set(["false", "nil", "true", "Self"]);

function isIdentifierStart(value: string | undefined): boolean {
  return value !== undefined && /[A-Za-z_$\u0080-\uFFFF]/.test(value);
}

function isIdentifierPart(value: string | undefined): boolean {
  return value !== undefined && /[A-Za-z0-9_$\u0080-\uFFFF]/.test(value);
}

function consumeString(stream: StringStream, state: SwiftState): string {
  const end = state.stringEnd;
  let escaped = false;
  while (!stream.eol()) {
    const value = stream.next();
    if (end && stream.string.slice(Math.max(0, stream.pos - end.length), stream.pos) === end) {
      state.stringEnd = null;
      state.stringAllowsNewline = false;
      return "string";
    }
    if (!end && !state.stringAllowsNewline && value === "\n") {
      state.stringEnd = null;
      return "string";
    }
    if (escaped) {
      escaped = false;
    } else if (value === "\\") {
      escaped = true;
    }
  }
  return "string";
}

function readHashCount(stream: StringStream): number {
  let count = 0;
  while (stream.peek() === "#") {
    stream.next();
    count += 1;
  }
  return count;
}

const swiftParser = {
  startState(): SwiftState {
    return {
      blockCommentDepth: 0,
      stringEnd: null,
      stringAllowsNewline: false,
      expectFunctionName: false,
      expectTypeName: false,
    };
  },

  copyState(state: SwiftState): SwiftState {
    return { ...state };
  },

  token(stream: StringStream, state: SwiftState): string | null {
    if (state.blockCommentDepth > 0) {
      while (!stream.eol()) {
        if (stream.match("/*")) {
          state.blockCommentDepth += 1;
        } else if (stream.match("*/")) {
          state.blockCommentDepth -= 1;
          if (state.blockCommentDepth === 0) break;
        } else {
          stream.next();
        }
      }
      return "comment";
    }

    if (state.stringEnd) return consumeString(stream, state);
    if (stream.eatSpace()) return null;
    if (stream.match("//")) {
      stream.skipToEnd();
      return "comment";
    }
    if (stream.match("/*")) {
      state.blockCommentDepth = 1;
      return "comment";
    }

    const first = stream.peek();
    if (first === "@") {
      stream.next();
      stream.eatWhile(isIdentifierPart);
      return "attribute";
    }

    if (first === "#") {
      const hashCount = readHashCount(stream);
      if (stream.peek() === '"') {
        stream.next();
        const closing = `"${"#".repeat(hashCount)}`;
        state.stringEnd = closing;
        state.stringAllowsNewline = true;
        return consumeString(stream, state);
      }
      stream.eatWhile(isIdentifierPart);
      return "meta";
    }

    if (first === '"' || first === "'") {
      const quote = stream.next() ?? "";
      const triple = quote === '"' && stream.match('""') === true;
      state.stringEnd = triple ? '"""' : quote;
      state.stringAllowsNewline = triple;
      return consumeString(stream, state);
    }

    if (first && /[0-9]/.test(first)) {
      stream.next();
      stream.eatWhile(/[A-Za-z0-9_.]/);
      return "number";
    }

    if (isIdentifierStart(first)) {
      let word = stream.next() ?? "";
      while (isIdentifierPart(stream.peek())) word += stream.next() ?? "";
      if (state.expectFunctionName) {
        state.expectFunctionName = false;
        return "variableName.function";
      }
      if (state.expectTypeName) {
        state.expectTypeName = false;
        return "typeName.definition";
      }
      if (keywords.has(word)) {
        state.expectFunctionName = word === "func" || word === "init" || word === "deinit";
        state.expectTypeName = declarationKeywords.has(word);
        return "keyword";
      }
      if (constants.has(word)) return "bool";
      if (builtinTypes.has(word) || /^[A-Z]/.test(word)) return "typeName";
      if (stream.peek() === "(") return "variableName.function";
      return null;
    }

    stream.next();
    return /[+\-*\/%=<>!&|^~?:]/.test(first ?? "") ? "operator" : null;
  },

  blankLine(state: SwiftState): void {
    if (!state.stringAllowsNewline) state.expectFunctionName = false;
  },
};

export const swift = StreamLanguage.define(swiftParser);

type BraceRange = { from: number; to: number };

function braceRanges(source: string): BraceRange[] {
  const stack: number[] = [];
  const ranges: BraceRange[] = [];
  let quote: string | null = null;
  let escaped = false;
  let lineComment = false;
  let blockCommentDepth = 0;

  for (let index = 0; index < source.length; index += 1) {
    const current = source[index];
    const next = source[index + 1];
    if (lineComment) {
      if (current === "\n") lineComment = false;
      continue;
    }
    if (blockCommentDepth > 0) {
      if (current === "/" && next === "*") {
        blockCommentDepth += 1;
        index += 1;
      } else if (current === "*" && next === "/") {
        blockCommentDepth -= 1;
        index += 1;
      }
      continue;
    }
    if (quote) {
      if (escaped) {
        escaped = false;
      } else if (current === "\\") {
        escaped = true;
      } else if (source.startsWith(quote, index)) {
        index += quote.length - 1;
        quote = null;
      }
      continue;
    }
    if (current === "/" && next === "/") {
      lineComment = true;
      index += 1;
    } else if (current === "/" && next === "*") {
      blockCommentDepth = 1;
      index += 1;
    } else if (current === '"' || current === "'") {
      const triple = current === '"' && source.startsWith('"""', index);
      quote = triple ? '"""' : current;
      if (triple) index += 2;
    } else if (current === "{") {
      stack.push(index);
    } else if (current === "}" && stack.length > 0) {
      const from = stack.pop();
      if (from !== undefined) ranges.push({ from, to: index });
    }
  }
  return ranges;
}

function lineNumberAt(state: EditorState, position: number): number {
  return state.doc.lineAt(position).number;
}

export const swiftFoldService = foldService.of((state, lineStart) => {
  const line = state.doc.lineAt(lineStart);
  const ranges = braceRanges(state.doc.toString());
  const range = ranges
    .filter((candidate) => candidate.from >= line.from && candidate.from <= line.to)
    .sort((left, right) => left.to - left.from - (right.to - right.from))[0];
  if (!range || lineNumberAt(state, range.to) <= line.number) return null;
  const closingLine = state.doc.lineAt(range.to);
  return { from: line.to, to: closingLine.from };
});
