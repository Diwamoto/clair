import Foundation

struct ProjectQuickOpenItem: Identifiable, Equatable, Sendable {
  let id: String
  let filePath: String
  let relativePath: String
  let title: String
}

struct ProjectSearchMatch: Identifiable, Equatable, Sendable {
  let id: String
  let filePath: String
  let relativePath: String
  let line: Int
  let column: Int
  let lineText: String
  let matchLength: Int
}

struct ProjectSearchFileReplacement: Identifiable, Equatable, Sendable {
  let id: String
  let relativePath: String
  let matchCount: Int
  let originalData: Data
  let replacementData: Data
}

struct ProjectSearchReplacementPreview: Equatable, Sendable {
  let query: String
  let replacement: String
  let matches: [ProjectSearchMatch]
  let files: [ProjectSearchFileReplacement]

  var matchCount: Int {
    matches.count
  }
}

enum ProjectNavigationError: Error, Equatable, LocalizedError, Sendable {
  case invalidQuery
  case invalidPath(String)
  case readFailed(path: String, message: String)
  case invalidUTF8(path: String)

  var errorDescription: String? {
    switch self {
    case .invalidQuery:
      "Enter text to search for."
    case .invalidPath(let path):
      "The file path is outside the Project: \(path)"
    case .readFailed(let path, let message):
      "Clair could not read \(path): \(message)"
    case .invalidUTF8(let path):
      "Clair only searches UTF-8 text files: \(path)"
    }
  }
}

enum ProjectNavigation {
  static func quickOpenItems(
    from root: ProjectFileTreeNode,
    rootURL: URL,
    query: String
  ) -> [ProjectQuickOpenItem] {
    var items: [ProjectQuickOpenItem] = []
    appendFiles(from: root, rootURL: rootURL, to: &items)

    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let scoredItems: [(score: Int, item: ProjectQuickOpenItem)] = items.compactMap { item in
      guard let score = quickOpenScore(for: item, query: normalizedQuery) else {
        return nil
      }
      return (score, item)
    }
    return
      scoredItems
      .sorted { lhs, rhs in
        if lhs.0 != rhs.0 {
          return lhs.0 < rhs.0
        }
        if lhs.1.relativePath != rhs.1.relativePath {
          return lhs.1.relativePath < rhs.1.relativePath
        }
        return lhs.1.filePath < rhs.1.filePath
      }
      .map(\.1)
  }

  static func search(
    query: String,
    rootURL: URL,
    fileManager: FileManager = .default
  ) -> [ProjectSearchMatch] {
    guard !query.isEmpty else {
      return []
    }

    return projectFiles(rootURL: rootURL, fileManager: fileManager).flatMap {
      file -> [ProjectSearchMatch] in
      guard
        let data = try? Data(contentsOf: file.url),
        let content = String(data: data, encoding: .utf8)
      else {
        return []
      }
      return matches(
        in: content,
        query: query,
        filePath: file.url.path,
        relativePath: file.relativePath
      )
    }
  }

  static func previewReplacement(
    query: String,
    replacement: String,
    rootURL: URL,
    fileManager: FileManager = .default
  ) throws -> ProjectSearchReplacementPreview {
    guard !query.isEmpty else {
      throw ProjectNavigationError.invalidQuery
    }

    var allMatches: [ProjectSearchMatch] = []
    var files: [ProjectSearchFileReplacement] = []

    for file in projectFiles(rootURL: rootURL, fileManager: fileManager) {
      let data: Data
      do {
        data = try Data(contentsOf: file.url)
      } catch {
        continue
      }
      guard let content = String(data: data, encoding: .utf8) else {
        continue
      }

      let fileMatches = matches(
        in: content,
        query: query,
        filePath: file.url.path,
        relativePath: file.relativePath
      )
      guard !fileMatches.isEmpty else {
        continue
      }

      let replacementContent = replacing(
        in: content,
        query: query,
        with: replacement
      )
      allMatches.append(contentsOf: fileMatches)
      files.append(
        ProjectSearchFileReplacement(
          id: file.url.path,
          relativePath: file.relativePath,
          matchCount: fileMatches.count,
          originalData: data,
          replacementData: Data(replacementContent.utf8)
        )
      )
    }

    return ProjectSearchReplacementPreview(
      query: query,
      replacement: replacement,
      matches: allMatches,
      files: files
    )
  }

  static func fileURL(for relativePath: String, rootURL: URL) -> URL? {
    guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
      return nil
    }

    let root = rootURL.standardizedFileURL
    let candidate =
      root
      .appendingPathComponent(relativePath, isDirectory: false)
      .standardizedFileURL
    let rootPath = root.path
    let prefix = rootPath == "/" ? "/" : rootPath + "/"
    guard candidate.path.hasPrefix(prefix), candidate.path != rootPath else {
      return nil
    }
    return candidate
  }

  private static func appendFiles(
    from node: ProjectFileTreeNode,
    rootURL: URL,
    to items: inout [ProjectQuickOpenItem]
  ) {
    if node.isDirectory {
      for child in node.children ?? [] {
        appendFiles(from: child, rootURL: rootURL, to: &items)
      }
      return
    }

    let relativePath = relativePath(for: node.url, rootURL: rootURL)
    items.append(
      ProjectQuickOpenItem(
        id: node.id,
        filePath: node.id,
        relativePath: relativePath,
        title: node.name
      )
    )
  }

  private static func quickOpenScore(
    for item: ProjectQuickOpenItem,
    query: String
  ) -> Int? {
    guard !query.isEmpty else {
      return 0
    }

    let title = item.title.lowercased()
    let path = item.relativePath.lowercased()
    if title == query {
      return 0
    }
    if title.hasPrefix(query) {
      return 1
    }
    if path.hasPrefix(query) {
      return 2
    }
    if path.contains(query) {
      return 3
    }
    guard let fuzzyScore = subsequenceScore(query: query, candidate: path) else {
      return nil
    }
    return 10 + fuzzyScore
  }

  private static func subsequenceScore(query: String, candidate: String) -> Int? {
    let queryCharacters = Array(query)
    let candidateCharacters = Array(candidate)
    guard !queryCharacters.isEmpty else {
      return 0
    }

    var queryIndex = 0
    var lastMatchIndex: Int?
    var gapScore = 0
    for (candidateIndex, character) in candidateCharacters.enumerated() {
      guard character == queryCharacters[queryIndex] else {
        continue
      }
      if let lastMatchIndex {
        gapScore += candidateIndex - lastMatchIndex - 1
      }
      lastMatchIndex = candidateIndex
      queryIndex += 1
      if queryIndex == queryCharacters.count {
        return gapScore
      }
    }
    return nil
  }

  private static func projectFiles(
    rootURL: URL,
    fileManager: FileManager
  ) -> [(url: URL, relativePath: String)] {
    let root = rootURL.standardizedFileURL
    var isDirectory = ObjCBool(false)
    guard
      fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
        options: [.skipsPackageDescendants]
      )
    else {
      return []
    }

    var files: [(url: URL, relativePath: String)] = []
    for case let url as URL in enumerator {
      if url.lastPathComponent == ".git" {
        enumerator.skipDescendants()
        continue
      }

      guard
        let values = try? url.resourceValues(
          forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        )
      else {
        continue
      }

      if values.isSymbolicLink == true {
        if values.isDirectory == true {
          enumerator.skipDescendants()
        }
        continue
      }
      if values.isDirectory == true {
        continue
      }
      guard values.isRegularFile == true else {
        continue
      }

      let standardizedURL = url.standardizedFileURL
      guard fileURL(for: relativePath(for: standardizedURL, rootURL: root), rootURL: root) != nil
      else {
        continue
      }
      files.append(
        (
          url: standardizedURL,
          relativePath: relativePath(for: standardizedURL, rootURL: root)
        )
      )
    }

    return files.sorted { lhs, rhs in
      if lhs.relativePath != rhs.relativePath {
        return lhs.relativePath < rhs.relativePath
      }
      return lhs.url.path < rhs.url.path
    }
  }

  private static func matches(
    in content: String,
    query: String,
    filePath: String,
    relativePath: String
  ) -> [ProjectSearchMatch] {
    guard !query.isEmpty else {
      return []
    }

    var results: [ProjectSearchMatch] = []
    var lineStart = content.startIndex
    var lineNumber = 1

    while lineStart < content.endIndex {
      let lineEnd = content[lineStart...].firstIndex(of: "\n") ?? content.endIndex
      let line = String(content[lineStart..<lineEnd])
      var searchStart = line.startIndex

      while searchStart < line.endIndex,
        let range = line.range(
          of: query,
          options: [.caseInsensitive],
          range: searchStart..<line.endIndex
        )
      {
        let column = line.distance(from: line.startIndex, to: range.lowerBound) + 1
        let matchLength = line.distance(from: range.lowerBound, to: range.upperBound)
        results.append(
          ProjectSearchMatch(
            id: "\(filePath):\(lineNumber):\(column)",
            filePath: filePath,
            relativePath: relativePath,
            line: lineNumber,
            column: column,
            lineText: line,
            matchLength: matchLength
          )
        )
        guard range.upperBound < line.endIndex else {
          break
        }
        searchStart = range.upperBound
      }

      guard lineEnd < content.endIndex else {
        break
      }
      lineStart = content.index(after: lineEnd)
      lineNumber += 1
    }

    return results
  }

  private static func replacing(
    in content: String,
    query: String,
    with replacement: String
  ) -> String {
    var result = String()
    var cursor = content.startIndex
    var searchStart = content.startIndex

    while searchStart < content.endIndex,
      let range = content.range(
        of: query,
        options: [.caseInsensitive],
        range: searchStart..<content.endIndex
      )
    {
      result.append(contentsOf: content[cursor..<range.lowerBound])
      result.append(contentsOf: replacement)
      cursor = range.upperBound
      guard range.upperBound < content.endIndex else {
        break
      }
      searchStart = range.upperBound
    }
    result.append(contentsOf: content[cursor..<content.endIndex])
    return result
  }

  private static func relativePath(for fileURL: URL, rootURL: URL) -> String {
    let rootPath = rootURL.standardizedFileURL.path
    let filePath = fileURL.standardizedFileURL.path
    let prefix = rootPath == "/" ? "/" : rootPath + "/"
    guard filePath.hasPrefix(prefix) else {
      return filePath
    }
    return String(filePath.dropFirst(prefix.count))
  }
}

extension ProjectLocalHistoryStore {
  func entries(for projectID: UUID) throws -> [ProjectLocalHistoryEntry] {
    try load().entries
      .filter { $0.projectID == projectID }
      .sorted { lhs, rhs in
        if lhs.createdAt != rhs.createdAt {
          return lhs.createdAt > rhs.createdAt
        }
        if lhs.filePath != rhs.filePath {
          return lhs.filePath < rhs.filePath
        }
        return lhs.id.uuidString > rhs.id.uuidString
      }
  }
}
