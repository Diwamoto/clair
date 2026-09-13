import Foundation

struct ProjectQuickOpenItem: Identifiable, Equatable, Sendable {
  let id: String
  let filePath: String
  let relativePath: String
  let title: String
}

struct ProjectNavigationFile: Equatable, Sendable {
  let url: URL
  let relativePath: String

  var title: String {
    url.lastPathComponent
  }
}

struct ProjectNavigationFileIndex: Equatable, Sendable {
  let files: [ProjectNavigationFile]
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

enum ProjectNavigationLimits {
  static let maximumFiles = 50_000
  static let maximumMatches = 20_000
  static let maximumQuickOpenResults = 200
}

/// Shares the expensive file walk between Quick Open and in-Project search.
/// Search content is cached only for the lifetime of a surface and is bounded
/// so a large Project cannot grow the app's memory without limit.
final class ProjectNavigationSearchIndex: @unchecked Sendable {
  private static let maximumCachedFileBytes = 4 * 1024 * 1024
  private static let maximumCachedContentBytes = 64 * 1024 * 1024

  private let files: [ProjectNavigationFile]
  private var contentCache: [String: String] = [:]
  private var cachedContentBytes = 0
  private let lock = NSLock()

  init(files: [ProjectNavigationFile]) {
    self.files = files
  }

  func search(query: String) -> [ProjectSearchMatch] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedQuery.isEmpty else {
      return []
    }

    var results: [ProjectSearchMatch] = []
    for file in files {
      guard !Task.isCancelled, results.count < ProjectNavigationLimits.maximumMatches else {
        break
      }
      guard let content = content(for: file) else {
        continue
      }
      results.append(
        contentsOf: ProjectNavigation.matches(
          in: content,
          query: normalizedQuery,
          filePath: file.url.path,
          relativePath: file.relativePath,
          maximumResults: ProjectNavigationLimits.maximumMatches - results.count
        )
      )
    }
    return results
  }

  private func content(for file: ProjectNavigationFile) -> String? {
    lock.lock()
    if let cached = contentCache[file.url.path] {
      lock.unlock()
      return cached
    }
    lock.unlock()
    guard
      let data = try? Data(contentsOf: file.url),
      let content = String(data: data, encoding: .utf8)
    else {
      return nil
    }

    let byteCount = data.count
    if byteCount <= Self.maximumCachedFileBytes,
      byteCount <= Self.maximumCachedContentBytes
    {
      lock.lock()
      defer { lock.unlock() }
      if let cached = contentCache[file.url.path] {
        return cached
      }
      if cachedContentBytes + byteCount <= Self.maximumCachedContentBytes {
        contentCache[file.url.path] = content
        cachedContentBytes += byteCount
      }
    }
    return content
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
      .prefix(ProjectNavigationLimits.maximumQuickOpenResults)
      .map(\.1)
  }

  static func quickOpenItems(
    query: String,
    rootURL: URL,
    fileManager: FileManager = .default
  ) -> [ProjectQuickOpenItem] {
    quickOpenItems(
      query: query,
      index: fileIndex(
        rootURL: rootURL,
        fileManager: fileManager
      )
    )
  }

  static func quickOpenItems(
    query: String,
    index: ProjectNavigationFileIndex
  ) -> [ProjectQuickOpenItem] {
    let items = index.files.map { file in
      ProjectQuickOpenItem(
        id: file.url.path,
        filePath: file.url.path,
        relativePath: file.relativePath,
        title: file.title
      )
    }
    return rankedQuickOpenItems(items, query: query)
  }

  static func fileIndex(
    rootURL: URL,
    fileManager: FileManager = .default
  ) -> ProjectNavigationFileIndex {
    ProjectNavigationFileIndex(
      files: projectFiles(
        rootURL: rootURL,
        fileManager: fileManager,
        maximumFiles: ProjectNavigationLimits.maximumFiles
      )
    )
  }

  static func fileIndexAsync(rootURL: URL) async -> ProjectNavigationFileIndex {
    let task = Task.detached(priority: .utility) {
      fileIndex(
        rootURL: rootURL,
        fileManager: FileManager()
      )
    }
    return await withTaskCancellationHandler(
      operation: {
        await task.value
      },
      onCancel: {
        task.cancel()
      })
  }

  static func quickOpenItemsAsync(
    query: String,
    rootURL: URL
  ) async -> [ProjectQuickOpenItem] {
    let index = await fileIndexAsync(rootURL: rootURL)
    guard !Task.isCancelled else {
      return []
    }
    return await quickOpenItemsAsync(query: query, index: index)
  }

  static func quickOpenItemsAsync(
    query: String,
    index: ProjectNavigationFileIndex
  ) async -> [ProjectQuickOpenItem] {
    let task = Task.detached(priority: .userInitiated) {
      quickOpenItems(query: query, index: index)
    }
    return await withTaskCancellationHandler(
      operation: {
        await task.value
      },
      onCancel: {
        task.cancel()
      })
  }

  static func search(
    query: String,
    rootURL: URL,
    fileManager: FileManager = .default
  ) -> [ProjectSearchMatch] {
    search(
      query: query,
      index: fileIndex(rootURL: rootURL, fileManager: fileManager),
      fileManager: fileManager
    )
  }

  static func search(
    query: String,
    index: ProjectNavigationFileIndex,
    fileManager: FileManager = .default
  ) -> [ProjectSearchMatch] {
    guard !query.isEmpty else {
      return []
    }

    var results: [ProjectSearchMatch] = []
    for file in index.files {
      if Task.isCancelled || results.count >= ProjectNavigationLimits.maximumMatches {
        break
      }
      guard
        let data = try? Data(contentsOf: file.url),
        let content = String(data: data, encoding: .utf8)
      else {
        continue
      }
      results.append(
        contentsOf: matches(
          in: content,
          query: query,
          filePath: file.url.path,
          relativePath: file.relativePath,
          maximumResults: ProjectNavigationLimits.maximumMatches - results.count
        ))
    }
    return results
  }

  static func searchAsync(
    query: String,
    rootURL: URL
  ) async -> [ProjectSearchMatch] {
    let index = await fileIndexAsync(rootURL: rootURL)
    guard !Task.isCancelled else {
      return []
    }
    return await searchAsync(query: query, index: index)
  }

  static func searchAsync(
    query: String,
    index: ProjectNavigationFileIndex
  ) async -> [ProjectSearchMatch] {
    let task = Task.detached(priority: .userInitiated) {
      search(query: query, index: index, fileManager: FileManager())
    }
    return await withTaskCancellationHandler(
      operation: {
        await task.value
      },
      onCancel: {
        task.cancel()
      })
  }

  static func searchAsync(
    query: String,
    index: ProjectNavigationSearchIndex
  ) async -> [ProjectSearchMatch] {
    let task = Task.detached(priority: .userInitiated) {
      index.search(query: query)
    }
    return await withTaskCancellationHandler(
      operation: {
        await task.value
      },
      onCancel: {
        task.cancel()
      })
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

    for file in projectFiles(
      rootURL: rootURL,
      fileManager: fileManager,
      maximumFiles: ProjectNavigationLimits.maximumFiles
    ) {
      if Task.isCancelled || allMatches.count >= ProjectNavigationLimits.maximumMatches {
        break
      }
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
        relativePath: file.relativePath,
        maximumResults: ProjectNavigationLimits.maximumMatches - allMatches.count
      )
      guard !fileMatches.isEmpty else {
        continue
      }

      let replacementContent = replacing(
        in: content,
        query: query,
        with: replacement
      )
      let remainingMatches = ProjectNavigationLimits.maximumMatches - allMatches.count
      allMatches.append(contentsOf: fileMatches.prefix(remainingMatches))
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

  static func previewReplacementAsync(
    query: String,
    replacement: String,
    rootURL: URL
  ) async throws -> ProjectSearchReplacementPreview {
    let task = Task.detached(priority: .userInitiated) {
      try previewReplacement(
        query: query,
        replacement: replacement,
        rootURL: rootURL,
        fileManager: FileManager()
      )
    }
    return try await withTaskCancellationHandler(
      operation: {
        try await task.value
      },
      onCancel: {
        task.cancel()
      })
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

  private static func rankedQuickOpenItems(
    _ items: [ProjectQuickOpenItem],
    query: String
  ) -> [ProjectQuickOpenItem] {
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
      .prefix(ProjectNavigationLimits.maximumQuickOpenResults)
      .map(\.1)
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
    fileManager: FileManager,
    maximumFiles: Int
  ) -> [ProjectNavigationFile] {
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

    var files: [ProjectNavigationFile] = []
    for case let url as URL in enumerator {
      if Task.isCancelled {
        break
      }

      guard
        let values = try? url.resourceValues(
          forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        )
      else {
        continue
      }

      if values.isDirectory == true,
        ProjectFileTreeScanner.shouldIgnoreDirectory(named: url.lastPathComponent)
      {
        enumerator.skipDescendants()
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

      if files.count >= maximumFiles {
        break
      }

      let standardizedURL = url.standardizedFileURL
      guard fileURL(for: relativePath(for: standardizedURL, rootURL: root), rootURL: root) != nil
      else {
        continue
      }
      files.append(
        ProjectNavigationFile(
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

  fileprivate static func matches(
    in content: String,
    query: String,
    filePath: String,
    relativePath: String,
    maximumResults: Int = ProjectNavigationLimits.maximumMatches
  ) -> [ProjectSearchMatch] {
    guard !query.isEmpty else {
      return []
    }

    var results: [ProjectSearchMatch] = []
    var lineStart = content.startIndex
    var lineNumber = 1

    while lineStart < content.endIndex,
      results.count < maximumResults,
      !Task.isCancelled
    {
      let lineEnd = content[lineStart...].firstIndex(of: "\n") ?? content.endIndex
      let line = String(content[lineStart..<lineEnd])
      var searchStart = line.startIndex

      while searchStart < line.endIndex,
        results.count < maximumResults,
        !Task.isCancelled,
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
      !Task.isCancelled,
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
