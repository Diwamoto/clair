import SwiftUI

/// The one table that maps a file name to its icon and tint (spec §5.11,
/// 2026-09-26 owner decision). File tree, editor tab, search results, quick
/// open and review file rows all read it. Monochrome: languages get their
/// Simple Icons logo, everything else an SF Symbol, all in the caller's ink.
public struct FileIcon: Equatable, Sendable {
  /// A `SimpleIcons` slug when one exists, otherwise an SF Symbol name.
  public let symbol: String

  /// The icon at `size` in `ink`.
  @ViewBuilder public func image(size: CGFloat, ink: SwiftUI.Color) -> some View {
    if let logo = SimpleIcons.paths[symbol] {
      // Logos fill their whole 24×24 box; SF Symbols at the same point size read larger.
      let side = size * 1.3
      logo.applying(CGAffineTransform(scaleX: side / 24, y: side / 24)).fill(ink).frame(width: side, height: side)
    } else {
      Image(systemName: symbol).font(.system(size: size)).foregroundStyle(ink)
    }
  }

  public static let generic = FileIcon(symbol: "doc.text")

  public static func folder(open: Bool) -> FileIcon {
    FileIcon(symbol: open ? "folder" : "folder.fill")
  }

  public static func forPath(_ path: String) -> FileIcon {
    let name = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
    if let hit = byName[name] { return FileIcon(symbol: hit) }
    if name.hasPrefix("dockerfile") || name.hasSuffix(".dockerfile") { return FileIcon(symbol: "docker") }
    // Longest compound extension first: `a.d.ts` → `d.ts`, then `ts`.
    let parts = name.split(separator: ".", omittingEmptySubsequences: false).dropFirst()
    for i in parts.indices {
      if let hit = byExtension[parts[i...].joined(separator: ".")] { return FileIcon(symbol: hit) }
    }
    return generic
  }

  private static let byName: [String: String] = [
    "makefile": "hammer", "go.mod": "go", "go.sum": "go", "package.json": "npm",
    ".gitignore": "git", ".gitattributes": "git", ".editorconfig": "gearshape", ".env": "gearshape",
  ]

  private static let byExtension: [String: String] = [
    "go": "go", "swift": "swift", "ts": "typescript", "tsx": "typescript",
    "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
    "py": "python", "rs": "rust", "md": "markdown", "markdown": "markdown", "json": "json", "jsonc": "json",
    "yaml": "yaml", "yml": "yaml", "toml": "toml", "html": "html5", "css": "css",
    "sh": "gnubash", "bash": "gnubash", "zsh": "gnubash", "dockerfile": "docker",
  ]
}
