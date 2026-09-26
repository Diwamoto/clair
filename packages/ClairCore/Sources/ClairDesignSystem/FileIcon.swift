import SwiftUI

/// The one table that maps a file name to its icon and tint (spec §5.11,
/// 2026-09-26 owner decision). File tree, editor tab, search results, quick
/// open and review file rows all read it. Tints reuse the editor syntax
/// palette so they follow the colour scheme (`E18`).
// ponytail: SF Symbols only; bundle single-colour SVGs if a language needs a real logo.
public struct FileIcon: Equatable, Sendable {
  public let symbol: String
  public let tint: SwiftUI.Color?  // nil = caller's neutral ink

  /// The icon at `size`, tinted, or in `ink` when the kind has no tint.
  public func image(size: CGFloat, ink: SwiftUI.Color) -> some View {
    Image(systemName: symbol).font(.system(size: size)).foregroundStyle(tint ?? ink)
  }

  public static let generic = FileIcon(symbol: "doc.text", tint: nil)

  public static func folder(open: Bool) -> FileIcon {
    FileIcon(symbol: open ? "folder" : "folder.fill", tint: nil)
  }

  public static func forPath(_ path: String) -> FileIcon {
    let name = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
    if let hit = byName[name] { return hit }
    if name.hasPrefix("dockerfile") || name.hasSuffix(".dockerfile") { return docker }
    // Longest compound extension first: `a.d.ts` → `d.ts`, then `ts`.
    let parts = name.split(separator: ".", omittingEmptySubsequences: false).dropFirst()
    for i in parts.indices {
      if let hit = byExtension[parts[i...].joined(separator: ".")] { return hit }
    }
    return generic
  }

  private typealias C = DesignTokens.Color
  private static let docker = FileIcon(symbol: "shippingbox", tint: C.codeFunc)
  private static let gear = FileIcon(symbol: "gearshape", tint: C.codeComment)
  private static let json = FileIcon(symbol: "curlybraces", tint: C.codeType)

  private static let byName: [String: FileIcon] = [
    "makefile": FileIcon(symbol: "hammer", tint: C.codeNumber),
    "go.mod": FileIcon(symbol: "g.circle", tint: C.codeFunc),
    "go.sum": FileIcon(symbol: "g.circle", tint: C.codeFunc),
    "package.json": FileIcon(symbol: "shippingbox", tint: C.codeString),
    ".gitignore": gear, ".gitattributes": gear, ".editorconfig": gear, ".env": gear,
  ]

  private static let byExtension: [String: FileIcon] = [
    "go": FileIcon(symbol: "g.circle", tint: C.codeFunc),
    "swift": FileIcon(symbol: "swift", tint: C.codeNumber),
    "ts": FileIcon(symbol: "t.square", tint: C.codeFunc), "tsx": FileIcon(symbol: "t.square", tint: C.codeFunc),
    "d.ts": FileIcon(symbol: "t.square", tint: C.codeComment),
    "js": FileIcon(symbol: "j.square", tint: C.codeType), "jsx": FileIcon(symbol: "j.square", tint: C.codeType),
    "mjs": FileIcon(symbol: "j.square", tint: C.codeType), "cjs": FileIcon(symbol: "j.square", tint: C.codeType),
    "py": FileIcon(symbol: "p.circle", tint: C.codeType),
    "rs": FileIcon(symbol: "r.circle", tint: C.codeNumber),
    "md": FileIcon(symbol: "text.alignleft", tint: C.codeFunc), "markdown": FileIcon(symbol: "text.alignleft", tint: C.codeFunc),
    "json": json, "jsonc": json,
    "yaml": FileIcon(symbol: "list.bullet.indent", tint: C.codeKeyword), "yml": FileIcon(symbol: "list.bullet.indent", tint: C.codeKeyword),
    "toml": FileIcon(symbol: "list.bullet.indent", tint: C.codeNumber),
    "html": FileIcon(symbol: "chevron.left.forwardslash.chevron.right", tint: C.codeNumber),
    "css": FileIcon(symbol: "number", tint: C.codeKeyword),
    "sh": FileIcon(symbol: "terminal", tint: C.codeString), "bash": FileIcon(symbol: "terminal", tint: C.codeString),
    "zsh": FileIcon(symbol: "terminal", tint: C.codeString),
    "dockerfile": docker,
  ]
}
