import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

enum ProjectEditorError: Error, Equatable, LocalizedError, Sendable {
  case fileMissing(path: String)
  case invalidUTF8(path: String)
  case readFailed(path: String, message: String)
  case writeFailed(path: String, message: String)
  case externalChangeDetected(path: String)
  case historyUnavailable
  case historyMalformed
  case historyIO(String)
  case historyEntryNotFound(UUID)

  var errorDescription: String? {
    switch self {
    case .fileMissing(let path):
      "The editor file is missing: \(path)"
    case .invalidUTF8(let path):
      "The editor only supports UTF-8 text files: \(path)"
    case .readFailed(let path, let message):
      "Clair could not read \(path): \(message)"
    case .writeFailed(let path, let message):
      "Clair could not save \(path): \(message)"
    case .externalChangeDetected(let path):
      "The file changed on disk while it was open: \(path)"
    case .historyUnavailable:
      "Clair's local editor history is unavailable. The file was not overwritten."
    case .historyMalformed:
      "Clair's local editor history is malformed. The file was not overwritten."
    case .historyIO(let message):
      "Clair could not update local editor history: \(message)"
    case .historyEntryNotFound(let id):
      "The local editor history entry \(id.uuidString) was not found."
    }
  }
}

struct ProjectEditorSelection: Equatable, Sendable {
  let line: Int
  let column: Int
  let length: Int
}

enum ProjectLocalHistoryReason: String, Codable, CaseIterable, Sendable {
  case save
  case externalChange
  case externalDeletion

  var displayName: String {
    switch self {
    case .save:
      "保存前"
    case .externalChange:
      "ディスク再読み込み前"
    case .externalDeletion:
      "ファイル削除前"
    }
  }
}

struct ProjectLocalHistoryEntry: Identifiable, Codable, Equatable, Sendable {
  let id: UUID
  let projectID: UUID
  let filePath: String
  let createdAt: Date
  let reason: ProjectLocalHistoryReason
  let content: String

  var displayLabel: String {
    "\(reason.displayName) · \(createdAt.formatted(date: .abbreviated, time: .shortened))"
  }
}

struct ProjectLocalHistorySnapshot: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  var schemaVersion: Int
  var entries: [ProjectLocalHistoryEntry]

  static var empty: ProjectLocalHistorySnapshot {
    ProjectLocalHistorySnapshot(
      schemaVersion: currentSchemaVersion,
      entries: []
    )
  }
}

@MainActor
final class ProjectLocalHistoryStore {
  static let currentSchemaVersion = ProjectLocalHistorySnapshot.currentSchemaVersion
  static let maximumEntriesPerFile = 100

  let fileURL: URL?

  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(fileURL: URL?, fileManager: FileManager = .default) {
    self.fileURL = fileURL
    self.fileManager = fileManager

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    self.encoder = encoder

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  static func makeDefault(
    for profile: ClairRuntimeProfile,
    fileManager: FileManager = .default
  ) -> ProjectLocalHistoryStore {
    let baseDirectory = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first
    let dataDirectory = baseDirectory.map(profile.applicationSupportURL)
    let fileURL = dataDirectory?.appendingPathComponent(
      "editor-history-v1.json",
      isDirectory: false
    )
    return ProjectLocalHistoryStore(fileURL: fileURL, fileManager: fileManager)
  }

  func load() throws -> ProjectLocalHistorySnapshot {
    guard let fileURL else {
      throw ProjectEditorError.historyUnavailable
    }
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return .empty
    }

    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      throw ProjectEditorError.historyIO(error.localizedDescription)
    }

    let snapshot: ProjectLocalHistorySnapshot
    do {
      snapshot = try decoder.decode(ProjectLocalHistorySnapshot.self, from: data)
    } catch {
      throw ProjectEditorError.historyMalformed
    }

    guard snapshot.schemaVersion == ProjectLocalHistorySnapshot.currentSchemaVersion else {
      throw ProjectEditorError.historyMalformed
    }
    return snapshot
  }

  func entries(
    for projectID: UUID,
    fileURL: URL,
    rootURL: URL
  ) throws -> [ProjectLocalHistoryEntry] {
    let filePath = Self.relativePath(for: fileURL, rootURL: rootURL)
    return try load().entries
      .filter { $0.projectID == projectID && $0.filePath == filePath }
      .sorted {
        if $0.createdAt == $1.createdAt {
          return $0.id.uuidString > $1.id.uuidString
        }
        return $0.createdAt > $1.createdAt
      }
  }

  @discardableResult
  func record(
    projectID: UUID,
    fileURL: URL,
    rootURL: URL,
    content: String,
    reason: ProjectLocalHistoryReason,
    createdAt: Date = Date()
  ) throws -> ProjectLocalHistoryEntry {
    var snapshot = try load()
    let entry = ProjectLocalHistoryEntry(
      id: UUID(),
      projectID: projectID,
      filePath: Self.relativePath(for: fileURL, rootURL: rootURL),
      createdAt: createdAt,
      reason: reason,
      content: content
    )
    snapshot.entries.append(entry)

    let filePath = entry.filePath
    let matchingEntries = snapshot.entries
      .filter { $0.projectID == projectID && $0.filePath == filePath }
      .sorted {
        if $0.createdAt == $1.createdAt {
          return $0.id.uuidString < $1.id.uuidString
        }
        return $0.createdAt < $1.createdAt
      }
    if matchingEntries.count > Self.maximumEntriesPerFile {
      let removedIDs = Set(
        matchingEntries
          .prefix(matchingEntries.count - Self.maximumEntriesPerFile)
          .map(\.id)
      )
      snapshot.entries.removeAll { removedIDs.contains($0.id) }
    }

    try save(snapshot)
    return entry
  }

  private func save(_ snapshot: ProjectLocalHistorySnapshot) throws {
    guard let fileURL else {
      throw ProjectEditorError.historyUnavailable
    }

    do {
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: nil
      )
      let data = try encoder.encode(snapshot)
      try data.write(to: fileURL, options: [.atomic])
    } catch let error as ProjectEditorError {
      throw error
    } catch {
      throw ProjectEditorError.historyIO(error.localizedDescription)
    }
  }

  private static func relativePath(for fileURL: URL, rootURL: URL) -> String {
    let rootPath = rootURL.standardizedFileURL.path
    let filePath = fileURL.standardizedFileURL.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    if filePath.hasPrefix(prefix) {
      return String(filePath.dropFirst(prefix.count))
    }
    return filePath
  }
}

final class ProjectEditorFileWatcher: @unchecked Sendable {
  private let fileURL: URL
  private let queue: DispatchQueue
  private let onChange: @Sendable () -> Void
  private var source: DispatchSourceFileSystemObject?
  private var isStarted = false

  init(fileURL: URL, onChange: @escaping @Sendable () -> Void) {
    self.fileURL = fileURL
    self.onChange = onChange
    self.queue = DispatchQueue(
      label: "com.diwamoto.clair.editor-file-watcher.\(UUID().uuidString)"
    )
  }

  func start() {
    queue.sync {
      guard !isStarted else {
        return
      }
      isStarted = true
      installSource()
    }
  }

  func stop() {
    queue.sync {
      guard isStarted else {
        return
      }
      isStarted = false
      source?.cancel()
      source = nil
    }
  }

  private func installSource() {
    guard isStarted else {
      return
    }
    let descriptor = Darwin.open(fileURL.path, O_EVTONLY)
    guard descriptor >= 0 else {
      return
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .delete, .rename, .revoke],
      queue: queue
    )
    source.setEventHandler { [weak self] in
      self?.handleEvent()
    }
    source.setCancelHandler {
      Darwin.close(descriptor)
    }
    self.source = source
    source.resume()
  }

  private func handleEvent() {
    guard isStarted else {
      return
    }
    source?.cancel()
    source = nil
    installSource()
    onChange()
  }
}

@MainActor
final class ProjectEditorTab: ObservableObject, Identifiable {
  let id: String
  let url: URL
  let title: String

  @Published private(set) var content: String
  @Published private(set) var isDirty = false
  @Published private(set) var isMissing = false
  @Published private(set) var isReadOnly = false
  @Published private(set) var canUndo = false
  @Published private(set) var canRedo = false
  @Published private(set) var historyEntries: [ProjectLocalHistoryEntry] = []
  @Published private(set) var lastErrorMessage: String?
  @Published private(set) var loadError: ProjectEditorError?
  @Published private(set) var selectionRequest: ProjectEditorSelection?

  let projectID: UUID
  let rootURL: URL

  private let fileManager: FileManager
  private let historyStore: ProjectLocalHistoryStore
  private let undoManager = UndoManager()
  private var baselineContent: String
  private var diskData: Data?
  private var fileWatcher: ProjectEditorFileWatcher?

  init(
    projectID: UUID,
    rootURL: URL,
    url: URL,
    historyStore: ProjectLocalHistoryStore,
    fileManager: FileManager = .default
  ) {
    let canonicalURL = url.standardizedFileURL
    self.id = canonicalURL.path
    self.url = canonicalURL
    self.title = canonicalURL.lastPathComponent
    self.projectID = projectID
    self.rootURL = rootURL.standardizedFileURL
    self.fileManager = fileManager
    self.historyStore = historyStore

    let loadResult: Result<(content: String, data: Data), ProjectEditorError>
    do {
      let data = try Data(contentsOf: canonicalURL)
      if let content = String(data: data, encoding: .utf8) {
        loadResult = .success((content, data))
      } else {
        loadResult = .failure(.invalidUTF8(path: canonicalURL.path))
      }
    } catch CocoaError.fileReadNoSuchFile {
      loadResult = .failure(.fileMissing(path: canonicalURL.path))
    } catch {
      loadResult = .failure(
        .readFailed(path: canonicalURL.path, message: error.localizedDescription)
      )
    }

    switch loadResult {
    case .success((let content, let data)):
      self.content = content
      self.baselineContent = content
      self.diskData = data
      self.loadError = nil
      self.isReadOnly = false
      self.isMissing = false
      self.historyEntries =
        (try? historyStore.entries(
          for: projectID,
          fileURL: canonicalURL,
          rootURL: rootURL
        )) ?? []

      let fileWatcher = ProjectEditorFileWatcher(fileURL: canonicalURL) { [weak self] in
        Task { @MainActor [weak self] in
          guard let self else {
            return
          }
          do {
            _ = try self.refreshFromDisk()
          } catch {
            self.lastErrorMessage = error.localizedDescription
          }
        }
      }
      self.fileWatcher = fileWatcher
      fileWatcher.start()
    case .failure(.fileMissing):
      self.content = ""
      self.baselineContent = ""
      self.diskData = nil
      self.loadError = nil
      self.isReadOnly = false
      self.isMissing = true
      self.historyEntries = []
      self.fileWatcher = nil
    case .failure(let error):
      let errorContent = Self.errorContent(for: error)
      self.content = errorContent
      self.baselineContent = errorContent
      self.diskData = nil
      self.loadError = error
      self.isReadOnly = true
      self.isMissing = false
      self.historyEntries = []
      self.fileWatcher = nil
    }
  }

  deinit {
    fileWatcher?.stop()
  }

  var hasRecoveryHistory: Bool {
    !historyEntries.isEmpty
  }

  func dismissError() {
    lastErrorMessage = nil
  }

  func requestSelection(line: Int, column: Int, length: Int) {
    guard line > 0, column > 0, length >= 0 else {
      return
    }
    selectionRequest = ProjectEditorSelection(
      line: line,
      column: column,
      length: length
    )
  }

  func clearSelectionRequest() {
    selectionRequest = nil
  }

  func selectionRange(for selection: ProjectEditorSelection) -> NSRange? {
    guard selection.line > 0, selection.column > 0, selection.length >= 0 else {
      return nil
    }

    var lineStart = content.startIndex
    var lineNumber = 1
    while lineNumber < selection.line {
      guard
        let lineEnd = content[lineStart...].firstIndex(of: "\n"),
        lineEnd < content.endIndex
      else {
        return nil
      }
      lineStart = content.index(after: lineEnd)
      lineNumber += 1
    }

    let lineEnd = content[lineStart...].firstIndex(of: "\n") ?? content.endIndex
    let line = String(content[lineStart..<lineEnd])
    guard
      let start = line.index(
        line.startIndex,
        offsetBy: selection.column - 1,
        limitedBy: line.endIndex
      )
    else {
      return nil
    }
    let end =
      line.index(
        start,
        offsetBy: selection.length,
        limitedBy: line.endIndex
      ) ?? line.endIndex
    let contentOffset = content.utf16.distance(from: content.startIndex, to: lineStart)
    let lineOffset = line.utf16.distance(from: line.startIndex, to: start)
    let length = line.utf16.distance(from: start, to: end)
    return NSRange(
      location: contentOffset + lineOffset,
      length: length
    )
  }

  var displayTitle: String {
    isDirty ? "\(title) •" : title
  }

  func editorUndoManager() -> UndoManager {
    undoManager
  }

  private static func errorContent(for error: ProjectEditorError) -> String {
    let message = error.localizedDescription
    return """
      The editor could not open this file.

      \(message)
      """
  }

  func updateFromEditor(_ newContent: String) {
    guard !isReadOnly, newContent != content else {
      refreshUndoState()
      return
    }
    content = newContent
    isDirty = newContent != baselineContent || isMissing
    refreshUndoState()
  }

  func replaceContent(_ newContent: String, actionName: String = "Edit") {
    guard !isReadOnly, newContent != content else {
      return
    }
    applyContent(newContent, registerUndo: true, actionName: actionName)
  }

  func undo() {
    guard undoManager.canUndo else {
      return
    }
    undoManager.undo()
    refreshUndoState()
  }

  func redo() {
    guard undoManager.canRedo else {
      return
    }
    undoManager.redo()
    refreshUndoState()
  }

  func save() throws {
    guard loadError == nil else {
      throw ProjectEditorError.readFailed(
        path: url.path,
        message: "The file could not be saved because it failed to open."
      )
    }
    lastErrorMessage = nil
    let currentDiskData = try readDiskData()
    if currentDiskData != diskData {
      _ = try refreshFromDisk()
      throw ProjectEditorError.externalChangeDetected(path: url.path)
    }

    let encodedContent = Data(content.utf8)
    if currentDiskData != encodedContent, let currentDiskData {
      guard let currentDiskContent = String(data: currentDiskData, encoding: .utf8) else {
        throw ProjectEditorError.invalidUTF8(path: url.path)
      }
      try recordHistory(content: currentDiskContent, reason: .save)
    }

    do {
      try encodedContent.write(to: url, options: [.atomic])
    } catch {
      throw ProjectEditorError.writeFailed(
        path: url.path,
        message: error.localizedDescription
      )
    }

    diskData = encodedContent
    baselineContent = content
    isDirty = false
    isMissing = false
    undoManager.removeAllActions()
    refreshUndoState()
  }

  @discardableResult
  func refreshFromDisk() throws -> Bool {
    guard loadError == nil else {
      return false
    }
    lastErrorMessage = nil
    let currentDiskData = try readDiskData()
    guard currentDiskData != diskData else {
      return false
    }

    guard let currentDiskData else {
      try recordHistory(content: content, reason: .externalDeletion)
      diskData = nil
      isMissing = true
      isDirty = true
      refreshUndoState()
      return true
    }

    guard let diskContent = String(data: currentDiskData, encoding: .utf8) else {
      throw ProjectEditorError.invalidUTF8(path: url.path)
    }

    if diskContent != content {
      try recordHistory(content: content, reason: .externalChange)
      content = diskContent
    }
    diskData = currentDiskData
    baselineContent = diskContent
    isDirty = false
    isMissing = false
    undoManager.removeAllActions()
    refreshUndoState()
    return true
  }

  func restoreHistoryEntry(id: UUID) throws {
    guard let entry = historyEntries.first(where: { $0.id == id }) else {
      throw ProjectEditorError.historyEntryNotFound(id)
    }
    replaceContent(entry.content, actionName: "Restore History")
  }

  private func applyContent(
    _ newContent: String,
    registerUndo: Bool,
    actionName: String
  ) {
    guard newContent != content else {
      return
    }

    let previousContent = content
    if registerUndo {
      undoManager.registerUndo(withTarget: self) { target in
        target.applyContent(
          previousContent,
          registerUndo: true,
          actionName: actionName
        )
      }
      undoManager.setActionName(actionName)
    }
    content = newContent
    isDirty = newContent != baselineContent || isMissing
    refreshUndoState()
  }

  private func readDiskData() throws -> Data? {
    do {
      return try Data(contentsOf: url)
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      throw ProjectEditorError.readFailed(
        path: url.path,
        message: error.localizedDescription
      )
    }
  }

  private func recordHistory(
    content: String,
    reason: ProjectLocalHistoryReason
  ) throws {
    _ = try historyStore.record(
      projectID: projectID,
      fileURL: url,
      rootURL: rootURL,
      content: content,
      reason: reason
    )
    historyEntries = try historyStore.entries(
      for: projectID,
      fileURL: url,
      rootURL: rootURL
    )
  }

  private func refreshUndoState() {
    canUndo = undoManager.canUndo
    canRedo = undoManager.canRedo
  }
}

enum ProjectSourceSyntaxTokenKind: Equatable {
  case comment
  case string
  case number
  case keyword
  case type
  case function
  case attribute
  case constant
}

struct ProjectSourceSyntaxToken: Equatable {
  let range: NSRange
  let kind: ProjectSourceSyntaxTokenKind
}

@MainActor
enum ProjectSourceSyntaxHighlighter {
  static func tokens(
    in source: String,
    fileExtension: String
  ) -> [ProjectSourceSyntaxToken] {
    let language = Language(fileExtension: fileExtension)
    guard language != .plain else {
      return []
    }

    let text = source as NSString
    let length = text.length
    var result: [ProjectSourceSyntaxToken] = []
    var index = 0

    func code(at position: Int) -> unichar {
      text.character(at: position)
    }

    func isWhitespace(_ value: unichar) -> Bool {
      value == 9 || value == 10 || value == 11 || value == 12 || value == 13 || value == 32
    }

    func isDigit(_ value: unichar) -> Bool {
      value >= 48 && value <= 57
    }

    func isIdentifierStart(_ value: unichar) -> Bool {
      (value >= 65 && value <= 90)
        || (value >= 97 && value <= 122)
        || value == 95
        || value == 36
        || value >= 128
    }

    func isIdentifierContinuation(_ value: unichar) -> Bool {
      isIdentifierStart(value) || isDigit(value)
    }

    func nextNonWhitespaceCode(after position: Int) -> unichar? {
      var cursor = position
      while cursor < length && isWhitespace(code(at: cursor)) {
        cursor += 1
      }
      return cursor < length ? code(at: cursor) : nil
    }

    func append(_ kind: ProjectSourceSyntaxTokenKind, start: Int, end: Int) {
      guard end > start else {
        return
      }
      result.append(
        ProjectSourceSyntaxToken(
          range: NSRange(location: start, length: end - start),
          kind: kind
        )
      )
    }

    while index < length {
      let current = code(at: index)
      let next = index + 1 < length ? code(at: index + 1) : 0

      if current == 47, next == 47 {
        let start = index
        index += 2
        while index < length, code(at: index) != 10 {
          index += 1
        }
        append(.comment, start: start, end: index)
        continue
      }

      if current == 47, next == 42 {
        let start = index
        index += 2
        var depth = 1
        while index < length, depth > 0 {
          let character = code(at: index)
          let following = index + 1 < length ? code(at: index + 1) : 0
          if character == 47, following == 42 {
            depth += 1
            index += 2
          } else if character == 42, following == 47 {
            depth -= 1
            index += 2
          } else {
            index += 1
          }
        }
        append(.comment, start: start, end: index)
        continue
      }

      if language.treatsHashAsComment, current == 35 {
        let start = index
        index += 1
        while index < length, code(at: index) != 10 {
          index += 1
        }
        append(.comment, start: start, end: index)
        continue
      }

      if language == .swift, current == 35, next == 34 {
        let start = index
        index += 2
        while index < length {
          let character = code(at: index)
          let following = index + 1 < length ? code(at: index + 1) : 0
          if character == 34, following == 35 {
            index += 2
            break
          }
          index += 1
        }
        append(.string, start: start, end: index)
        continue
      }

      if language.supportsDirectives, current == 35, isIdentifierStart(next) {
        let start = index
        index += 1
        while index < length, isIdentifierContinuation(code(at: index)) {
          index += 1
        }
        append(.keyword, start: start, end: index)
        continue
      }

      if language == .swift, current == 64, isIdentifierStart(next) {
        let start = index
        index += 1
        while index < length, isIdentifierContinuation(code(at: index)) {
          index += 1
        }
        append(.attribute, start: start, end: index)
        continue
      }

      if current == 34
        || (current == 39 && language.allowsSingleQuotedStrings)
        || (current == 96 && language.allowsBacktickStrings)
      {
        let start = index
        let quote = current
        let isTripleQuote =
          quote == 34
          && index + 2 < length
          && code(at: index + 1) == 34
          && code(at: index + 2) == 34
        index += isTripleQuote ? 3 : 1
        var escaped = false
        while index < length {
          let character = code(at: index)
          if isTripleQuote {
            if character == 34,
              index + 2 < length,
              code(at: index + 1) == 34,
              code(at: index + 2) == 34
            {
              index += 3
              break
            }
            index += 1
            continue
          }
          if escaped {
            escaped = false
            index += 1
          } else if character == 92 {
            escaped = true
            index += 1
          } else if character == quote {
            index += 1
            break
          } else {
            index += 1
          }
        }
        append(.string, start: start, end: index)
        continue
      }

      if isDigit(current) || (current == 46 && isDigit(next)) {
        let start = index
        index += 1
        while index < length {
          let character = code(at: index)
          let isNumberCharacter =
            isDigit(character)
            || (character >= 65 && character <= 70)
            || (character >= 97 && character <= 102)
            || character == 46
            || character == 95
          if isNumberCharacter {
            index += 1
          } else if (character == 43 || character == 45)
            && index > start
            && (code(at: index - 1) == 69 || code(at: index - 1) == 101)
          {
            index += 1
          } else {
            break
          }
        }
        append(.number, start: start, end: index)
        continue
      }

      if isIdentifierStart(current) {
        let start = index
        index += 1
        while index < length, isIdentifierContinuation(code(at: index)) {
          index += 1
        }
        let word = text.substring(with: NSRange(location: start, length: index - start))
        let kind: ProjectSourceSyntaxTokenKind?
        if language.constants.contains(word) {
          kind = .constant
        } else if language.keywords.contains(word) {
          kind = .keyword
        } else if language.types.contains(word)
          || word.first.map({ $0.isUppercase }) == true
        {
          kind = .type
        } else if nextNonWhitespaceCode(after: index) == 40 {
          kind = .function
        } else {
          kind = nil
        }
        if let kind {
          append(kind, start: start, end: index)
        }
        continue
      }

      index += 1
    }

    return result
  }

  static func apply(
    to textStorage: NSTextStorage,
    fileExtension: String,
    baseFont: NSFont
  ) {
    let fullRange = NSRange(location: 0, length: textStorage.length)
    textStorage.beginEditing()
    if fullRange.length > 0 {
      textStorage.setAttributes(
        [
          .font: baseFont,
          .foregroundColor: WorkspaceChrome.nsTextPrimary,
        ],
        range: fullRange
      )
    }

    for token in tokens(in: textStorage.string, fileExtension: fileExtension) {
      guard NSMaxRange(token.range) <= textStorage.length else {
        continue
      }
      textStorage.addAttribute(
        .foregroundColor,
        value: color(for: token.kind),
        range: token.range
      )
    }
    textStorage.endEditing()
  }

  private static func color(for kind: ProjectSourceSyntaxTokenKind) -> NSColor {
    switch kind {
    case .comment:
      WorkspaceChrome.nsRGB(104, 117, 110)
    case .string:
      WorkspaceChrome.nsRGB(152, 195, 121)
    case .number:
      WorkspaceChrome.nsRGB(209, 154, 102)
    case .keyword:
      WorkspaceChrome.nsRGB(199, 131, 218)
    case .type:
      WorkspaceChrome.nsRGB(97, 175, 239)
    case .function:
      WorkspaceChrome.nsRGB(229, 192, 123)
    case .attribute:
      WorkspaceChrome.nsRGB(229, 192, 123)
    case .constant:
      WorkspaceChrome.nsRGB(224, 108, 117)
    }
  }

  private enum Language: Equatable {
    case swift
    case rust
    case cLike
    case script
    case json
    case plain

    init(fileExtension: String) {
      switch fileExtension.lowercased() {
      case "swift":
        self = .swift
      case "rs":
        self = .rust
      case "c", "cc", "cpp", "h", "hh", "hpp", "java", "go", "kt", "kts", "js", "jsx", "ts", "tsx",
        "css", "scss":
        self = .cLike
      case "json":
        self = .json
      case "py", "rb", "sh", "bash", "zsh", "fish", "yaml", "yml", "toml":
        self = .script
      default:
        self = .plain
      }
    }

    var keywords: Set<String> {
      switch self {
      case .swift:
        [
          "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch",
          "class", "continue", "convenience", "default", "defer", "deinit", "didSet", "do", "else",
          "enum", "extension", "fallthrough", "fileprivate", "final", "for", "func", "get", "guard",
          "if", "import", "indirect", "init", "inout", "internal", "is", "lazy", "let", "macro",
          "mutating",
          "nil", "nonisolated", "open", "operator", "override", "package", "private", "protocol",
          "public",
          "repeat", "required", "rethrows", "return", "self", "set", "some", "static", "struct",
          "subscript",
          "super", "switch", "throw", "throws", "try", "typealias", "unowned", "var", "weak",
          "where",
          "while", "willSet",
        ]
      case .rust:
        [
          "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
          "extern",
          "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub",
          "ref",
          "return", "self", "Self", "static", "struct", "super", "trait", "type", "unsafe", "use",
          "where",
          "while",
        ]
      case .cLike:
        [
          "async", "await", "auto", "bool", "break", "case", "catch", "char", "class", "const",
          "continue",
          "default", "delete", "do", "double", "else", "enum", "export", "extends", "false",
          "final", "float",
          "for", "from", "function", "if", "implements", "import", "in", "interface", "int", "let",
          "namespace",
          "new", "null", "private", "protected", "public", "return", "static", "struct", "switch",
          "template",
          "this", "throw", "try", "true", "type", "typeof", "typename", "using", "var", "virtual",
          "void", "while",
        ]
      case .script:
        [
          "and", "as", "async", "await", "class", "def", "elif", "else", "except", "finally", "for",
          "from",
          "function", "if", "import", "in", "is", "lambda", "let", "not", "or", "pass", "raise",
          "return",
          "try", "var", "while", "with", "yield",
        ]
      case .json, .plain:
        []
      }
    }

    var types: Set<String> {
      switch self {
      case .swift:
        [
          "AppKit", "Array", "Bool", "CGFloat", "ClairApp", "Color", "Combine", "Data", "Date",
          "Dictionary",
          "Double", "Error", "Font", "Foundation", "Int", "NSColor", "NSFont", "NSView", "Optional",
          "Result",
          "Set", "String", "SwiftUI", "Task", "URL", "UUID", "View", "XCTest",
        ]
      case .rust:
        [
          "Option", "Result", "String", "Vec", "bool", "char", "f32", "f64", "i8", "i16", "i32",
          "i64", "isize", "str", "u8", "u16", "u32", "u64", "usize",
        ]
      case .cLike, .script, .json, .plain:
        []
      }
    }

    var constants: Set<String> {
      switch self {
      case .swift, .rust:
        ["false", "nil", "None", "Some", "true"]
      case .cLike, .script:
        ["false", "None", "null", "true", "undefined"]
      case .json:
        ["false", "null", "true"]
      case .plain:
        []
      }
    }

    var treatsHashAsComment: Bool {
      self == .script
    }

    var supportsDirectives: Bool {
      self == .swift || self == .rust || self == .cLike
    }

    var allowsSingleQuotedStrings: Bool {
      self != .swift && self != .json
    }

    var allowsBacktickStrings: Bool {
      self == .cLike
    }
  }
}

@MainActor
struct ProjectSourceEditorView: NSViewRepresentable {
  @ObservedObject var document: ProjectEditorTab
  let selection: ProjectEditorSelection?
  let fontSize: CGFloat
  let wordWrap: Bool
  let onSave: () -> Void

  init(
    document: ProjectEditorTab,
    selection: ProjectEditorSelection? = nil,
    fontSize: CGFloat = 13,
    wordWrap: Bool = false,
    onSave: @escaping () -> Void
  ) {
    self.document = document
    self.selection = selection
    self.fontSize = fontSize
    self.wordWrap = wordWrap
    self.onSave = onSave
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(document: document)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView(frame: .zero)
    let textView = ProjectSourceTextView(frame: .zero)
    textView.delegate = context.coordinator
    textView.onSave = onSave
    textView.string = document.content
    textView.allowsUndo = true
    textView.isEditable = !document.isMissing && !document.isReadOnly
    textView.isSelectable = true
    textView.isRichText = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.drawsBackground = true
    configure(textView)
    textView.applySyntaxHighlighting(for: document.url.pathExtension)
    textView.textContainerInset = NSSize(width: 12, height: 12)
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = !wordWrap
    textView.textContainer?.widthTracksTextView = wordWrap
    textView.textContainer?.heightTracksTextView = false

    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = true
    scrollView.backgroundColor = WorkspaceChrome.nsCanvas
    scrollView.documentView = textView
    context.coordinator.textView = textView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? ProjectSourceTextView else {
      return
    }

    textView.onSave = onSave
    configure(textView)
    textView.isEditable = !document.isMissing && !document.isReadOnly
    if textView.string != document.content {
      let selectedRange = textView.selectedRange()
      context.coordinator.isUpdatingFromModel = true
      textView.string = document.content
      context.coordinator.isUpdatingFromModel = false

      if selectedRange.location != NSNotFound {
        let location = min(selectedRange.location, document.content.utf16.count)
        let length = min(
          selectedRange.length,
          document.content.utf16.count - location
        )
        textView.setSelectedRange(NSRange(location: location, length: length))
      }
    }
    textView.applySyntaxHighlighting(for: document.url.pathExtension)
    applySelectionIfNeeded(to: textView, context: context)
  }

  private func configure(_ textView: ProjectSourceTextView) {
    textView.drawsBackground = true
    textView.backgroundColor = WorkspaceChrome.nsCanvas
    textView.textColor = WorkspaceChrome.nsTextPrimary
    textView.insertionPointColor = WorkspaceChrome.nsTextPrimary
    let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    textView.font = font
    textView.typingAttributes = [
      .font: font,
      .foregroundColor: WorkspaceChrome.nsTextPrimary,
    ]
    textView.isHorizontallyResizable = !wordWrap
    textView.textContainer?.widthTracksTextView = wordWrap
    textView.textContainer?.lineBreakMode = wordWrap ? .byCharWrapping : .byClipping
  }

  static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
    guard let textView = nsView.documentView as? ProjectSourceTextView else {
      return
    }
    textView.delegate = nil
    textView.onSave = nil
    coordinator.textView = nil
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    let document: ProjectEditorTab
    weak var textView: NSTextView?
    var isUpdatingFromModel = false
    var lastAppliedSelection: ProjectEditorSelection?

    init(document: ProjectEditorTab) {
      self.document = document
    }

    func textViewDidChange(_ notification: Notification) {
      guard !isUpdatingFromModel, let textView else {
        return
      }
      document.updateFromEditor(textView.string)
      guard !textView.hasMarkedText() else {
        return
      }
      (textView as? ProjectSourceTextView)?.applySyntaxHighlighting(
        for: document.url.pathExtension
      )
    }

    func undoManager(for textView: NSTextView) -> UndoManager? {
      document.editorUndoManager()
    }
  }

  private func applySelectionIfNeeded(
    to textView: NSTextView,
    context: Context
  ) {
    guard let selection else {
      context.coordinator.lastAppliedSelection = nil
      return
    }
    guard
      context.coordinator.lastAppliedSelection != selection,
      let range = document.selectionRange(for: selection)
    else {
      return
    }

    context.coordinator.lastAppliedSelection = selection
    textView.setSelectedRange(range)
    textView.scrollRangeToVisible(range)
    DispatchQueue.main.async { @MainActor [weak document] in
      guard let document, document.selectionRequest == selection else {
        return
      }
      document.clearSelectionRequest()
    }
  }
}

@MainActor
private final class ProjectSourceTextView: NSTextView {
  var onSave: (() -> Void)?
  private var highlightedContent: String?
  private var highlightedFileExtension: String?
  private var highlightedFontSize: CGFloat?

  override var acceptsFirstResponder: Bool {
    true
  }

  func applySyntaxHighlighting(for fileExtension: String) {
    guard let baseFont = font else {
      return
    }
    let normalizedExtension = fileExtension.lowercased()
    let needsUpdate =
      highlightedContent != string
      || highlightedFileExtension != normalizedExtension
      || highlightedFontSize != baseFont.pointSize
    guard needsUpdate else {
      typingAttributes = [
        .font: baseFont,
        .foregroundColor: WorkspaceChrome.nsTextPrimary,
      ]
      return
    }
    guard let textStorage else {
      return
    }

    ProjectSourceSyntaxHighlighter.apply(
      to: textStorage,
      fileExtension: normalizedExtension,
      baseFont: baseFont
    )
    typingAttributes = [
      .font: baseFont,
      .foregroundColor: WorkspaceChrome.nsTextPrimary,
    ]
    highlightedContent = string
    highlightedFileExtension = normalizedExtension
    highlightedFontSize = baseFont.pointSize
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if modifiers.contains(.command), event.charactersIgnoringModifiers == "s" {
      onSave?()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}
