import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

/// Developer-only switch for exercising the AppKit editor adapter without
/// changing the Stable default or importing the unverified CodeEdit package.
enum ProjectEditorEngine {
  static let nativeOptInDefaultsKey = "clair.editor.native-v1"

  static func usesAppKitNativeEditor(
    defaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    #if CLAIR_DEV
      if defaults.object(forKey: nativeOptInDefaultsKey) != nil {
        return defaults.bool(forKey: nativeOptInDefaultsKey)
      }
      guard let value = environment["CLAIR_NATIVE_EDITOR"]?.lowercased() else {
        return false
      }
      return ["1", "true", "yes", "on"].contains(value)
    #else
      return false
    #endif
  }
}

enum ProjectEditorError: Error, Equatable, LocalizedError, Sendable {
  case fileMissing(path: String)
  case invalidUTF8(path: String)
  case readFailed(path: String, message: String)
  case writeFailed(path: String, message: String)
  case externalChangeDetected(path: String)

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
    }
  }
}

struct ProjectEditorSelection: Equatable, Sendable {
  let line: Int
  let column: Int
  let length: Int
}

final class ProjectEditorFileWatcher: @unchecked Sendable {
  private let fileURL: URL
  private let parentURL: URL
  private let queue: DispatchQueue
  private let onChange: @Sendable () -> Void
  private var source: DispatchSourceFileSystemObject?
  private var isStarted = false

  init(fileURL: URL, onChange: @escaping @Sendable () -> Void) {
    self.fileURL = fileURL
    self.parentURL = fileURL.deletingLastPathComponent()
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
    // Keep watching the file while it exists, but fall back to its parent
    // directory after an unlink/rename. Atomic saves replace the inode, and a
    // file-only watcher cannot observe the file being recreated afterwards.
    let watchURL = FileManager.default.fileExists(atPath: fileURL.path)
      ? fileURL
      : parentURL
    let descriptor = Darwin.open(watchURL.path, O_EVTONLY)
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

  /// The buffer text is deliberately *not* `@Published`: publishing it made
  /// every keystroke invalidate every view observing the document, which in
  /// turn re-entered `updateNSView`, compared the whole buffer, and re-ran
  /// syntax highlighting on the full document. The live editor already holds
  /// the text it just produced, so only model-sourced replacements need to
  /// reach the view layer; those bump `contentSyncToken` instead.
  private(set) var content: String
  /// Advances when the document text is replaced by something other than the
  /// live editor: an external-change reload from disk, undo/redo that the
  /// document itself performs, or a workspace-wide replacement. Typing never
  /// advances it.
  @Published private(set) var contentSyncToken: UInt64 = 0
  @Published private(set) var isDirty = false
  @Published private(set) var isMissing = false
  @Published private(set) var isReadOnly = false
  @Published private(set) var canUndo = false
  @Published private(set) var canRedo = false
  @Published private(set) var lastErrorMessage: String?
  @Published private(set) var loadError: ProjectEditorError?
  @Published private(set) var selectionRequest: ProjectEditorSelection?
  /// The editor viewport state belongs to the document, rather than to a
  /// particular WKWebView instance. This keeps the caret and scroll position
  /// when SwiftUI tears down and recreates a tab's view.
  /// Viewport is persisted separately and must not be `@Published`; publishing
  /// it would re-render the editor on every scroll frame.
  private(set) var editorSelection: ProjectEditorUTF16Range?
  private(set) var editorScrollTop: Double = 0
  var onEditorViewportChange: (() -> Void)?

  let projectID: UUID
  let rootURL: URL

  private let fileManager: FileManager
  private let undoManager = UndoManager()
  private let documentModel: ProjectEditorDocumentModel
  private var baselineContent: String
  private var diskData: Data?
  private var fileWatcher: ProjectEditorFileWatcher?
  private var editorCommandHandler: ((ProjectEditorCommand) -> Void)?

  init(
    projectID: UUID,
    rootURL: URL,
    url: URL,
    fileManager: FileManager = .default
  ) {
    let canonicalURL = url.standardizedFileURL
    self.id = canonicalURL.path
    self.url = canonicalURL
    self.title = canonicalURL.lastPathComponent
    self.projectID = projectID
    self.rootURL = rootURL.standardizedFileURL
    self.fileManager = fileManager

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

    let shouldWatch: Bool
    switch loadResult {
    case .success((let content, let data)):
      self.content = content
      self.documentModel = ProjectEditorDocumentModel(content: content)
      self.baselineContent = content
      self.diskData = data
      self.loadError = nil
      self.isReadOnly = false
      self.isMissing = false
      self.editorSelection = nil

      shouldWatch = true
    case .failure(.fileMissing):
      self.content = ""
      self.documentModel = ProjectEditorDocumentModel(content: "")
      self.baselineContent = ""
      self.diskData = nil
      self.loadError = nil
      self.isReadOnly = false
      self.isMissing = true
      self.editorSelection = nil
      shouldWatch = true
    case .failure(let error):
      let errorContent = Self.errorContent(for: error)
      self.content = errorContent
      self.documentModel = ProjectEditorDocumentModel(content: errorContent)
      self.baselineContent = errorContent
      self.diskData = nil
      self.loadError = error
      self.isReadOnly = true
      self.isMissing = false
      self.editorSelection = nil
      shouldWatch = false
    }

    if shouldWatch {
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
    } else {
      self.fileWatcher = nil
    }
  }

  deinit {
    fileWatcher?.stop()
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

  func setEditorCommandHandler(_ handler: ((ProjectEditorCommand) -> Void)?) {
    editorCommandHandler = handler
  }

  func detachEditorCommandHandler() {
    editorCommandHandler = nil
    refreshUndoState()
  }

  /// Revision advertised to the WebKit bridge. Selection changes deliberately
  /// leave this value unchanged; document edits advance it exactly once.
  var editorRevision: UInt64 {
    documentModel.revision
  }

  @discardableResult
  func applyEditorChange(
    _ change: ProjectEditorWebChange
  ) throws -> ProjectEditorDocumentChange? {
    guard !isReadOnly else {
      return nil
    }

    let documentChange = try documentModel.apply(change.transaction())
    content = documentModel.content
    updateDirtyState(content != baselineContent || isMissing)
    updateUndoState(canUndo: change.canUndo, canRedo: change.canRedo)
    try? documentModel.setSelection(change.selection.range)
    editorSelection = documentModel.selection
    if let scrollTop = change.scrollTop, scrollTop.isFinite {
      editorScrollTop = max(0, scrollTop)
    }
    onEditorViewportChange?()
    return documentChange
  }

  func applyEditorSelection(_ change: ProjectEditorWebSelectionChange) {
    try? documentModel.setSelection(change.selection.range)
    editorSelection = documentModel.selection
    if let scrollTop = change.scrollTop, scrollTop.isFinite {
      editorScrollTop = max(0, scrollTop)
    }
    updateUndoState(canUndo: change.canUndo, canRedo: change.canRedo)
    onEditorViewportChange?()
  }

  func updateEditorViewport(
    selection: ProjectEditorUTF16Range?,
    scrollTop: Double
  ) {
    try? documentModel.setSelection(selection)
    editorSelection = documentModel.selection
    if scrollTop.isFinite {
      editorScrollTop = max(0, scrollTop)
    }
    onEditorViewportChange?()
  }

  func restoreEditorViewport(
    selection: ProjectEditorUTF16Range?,
    scrollTop: Double?
  ) {
    try? documentModel.setSelection(selection)
    editorSelection = documentModel.selection
    if let scrollTop, scrollTop.isFinite {
      editorScrollTop = max(0, scrollTop)
    }
  }

  private static func errorContent(for error: ProjectEditorError) -> String {
    let message = error.localizedDescription
    return """
      The editor could not open this file.

      \(message)
      """
  }

  func updateFromEditor(
    _ newContent: String,
    canUndo embeddedCanUndo: Bool? = nil,
    canRedo embeddedCanRedo: Bool? = nil
  ) {
    guard !isReadOnly else {
      return
    }
    if newContent == content {
      if let embeddedCanUndo, let embeddedCanRedo {
        updateUndoState(canUndo: embeddedCanUndo, canRedo: embeddedCanRedo)
      } else {
        refreshUndoState()
      }
      return
    }
    applyModelContent(
      newContent,
      source: .user,
      undoUnit: .typing
    )
    if let embeddedCanUndo, let embeddedCanRedo {
      updateUndoState(canUndo: embeddedCanUndo, canRedo: embeddedCanRedo)
    } else {
      refreshUndoState()
    }
  }

  func replaceContent(_ newContent: String, actionName: String = "Edit") {
    guard !isReadOnly, newContent != content else {
      return
    }
    applyContent(newContent, registerUndo: true, actionName: actionName)
  }

  func undo() {
    if let editorCommandHandler {
      editorCommandHandler(.undo)
      return
    }
    guard undoManager.canUndo else {
      return
    }
    undoManager.undo()
    refreshUndoState()
  }

  func redo() {
    if let editorCommandHandler {
      editorCommandHandler(.redo)
      return
    }
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
    _ = documentModel.snapshot(reason: .save)
    if editorCommandHandler == nil {
      undoManager.removeAllActions()
      refreshUndoState()
    }
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
      diskData = nil
      isMissing = true
      isDirty = true
      refreshUndoState()
      return true
    }

    guard let diskContent = String(data: currentDiskData, encoding: .utf8) else {
      throw ProjectEditorError.invalidUTF8(path: url.path)
    }

    guard !isDirty else {
      // Don't silently clobber unsaved edits with the external content; the
      // user's buffer is the only copy of those edits now that we don't keep
      // a separate history store, so leave it alone until they save or the
      // conflict resolves itself (e.g. a future disk write matches it again).
      lastErrorMessage = "ファイルが外部で変更されましたが、未保存の変更があるため自動では反映しませんでした。"
      return false
    }

    if diskContent != content {
      documentModel.replaceSnapshot(content: diskContent)
      content = documentModel.content
      advanceContentSyncToken()
      editorSelection = documentModel.selection
      editorScrollTop = 0
      onEditorViewportChange?()
    }
    diskData = currentDiskData
    baselineContent = diskContent
    isDirty = false
    isMissing = false
    undoManager.removeAllActions()
    refreshUndoState()
    _ = documentModel.snapshot(reason: .initialLoad)
    return true
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
    applyModelContent(
      newContent,
      source: .user,
      undoUnit: .typing
    )
    // The replacement did not come from the live editor, so the view layer has
    // to be told to pull the new text.
    advanceContentSyncToken()
    refreshUndoState()
  }

  private func applyModelContent(
    _ newContent: String,
    source: ProjectEditorChangeSource,
    undoUnit: ProjectEditorUndoUnit
  ) {
    guard newContent != documentModel.content else {
      return
    }

    let transaction = ProjectEditorTransaction(
      baseRevision: documentModel.revision,
      edits: [
        ProjectEditorReplacement(
          range: ProjectEditorUTF16Range(
            location: 0,
            length: documentModel.utf16Length
          ),
          text: newContent
        )
      ],
      source: source,
      undoUnit: undoUnit
    )
    do {
      _ = try documentModel.apply(transaction)
    } catch {
      // A full replacement is the compatibility path for the NSTextView
      // fallback. Its range is built from the same model it replaces, so a
      // failure indicates an internal invariant breach; retain the old text
      // rather than letting the two representations diverge.
      return
    }
    content = documentModel.content
    updateDirtyState(content != baselineContent || isMissing)
  }

  /// Signals the view layer that the buffer was replaced from outside the live
  /// editor. Typing must never call this.
  private func advanceContentSyncToken() {
    contentSyncToken &+= 1
  }

  private func updateDirtyState(_ newValue: Bool) {
    guard isDirty != newValue else {
      return
    }
    isDirty = newValue
  }

  /// `@Published` republishes on every assignment, equal values included, so
  /// undo availability is only published when it actually changes.
  private func updateUndoState(canUndo newCanUndo: Bool, canRedo newCanRedo: Bool) {
    if canUndo != newCanUndo {
      canUndo = newCanUndo
    }
    if canRedo != newCanRedo {
      canRedo = newCanRedo
    }
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

  private func refreshUndoState() {
    updateUndoState(canUndo: undoManager.canUndo, canRedo: undoManager.canRedo)
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
          .foregroundColor: WorkspaceChrome.nsCode,
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

  /// One Dark, from the Tokens artboard's editor colours. Types are amber and
  /// functions blue, the way One Dark itself assigns them.
  private static func color(for kind: ProjectSourceSyntaxTokenKind) -> NSColor {
    switch kind {
    case .comment:
      WorkspaceChrome.nsRGB(92, 99, 112)
    case .string:
      WorkspaceChrome.nsRGB(152, 195, 121)
    case .number:
      WorkspaceChrome.nsRGB(209, 154, 102)
    case .keyword:
      WorkspaceChrome.nsRGB(198, 120, 221)
    case .type:
      WorkspaceChrome.nsRGB(229, 192, 123)
    case .function:
      WorkspaceChrome.nsRGB(97, 175, 239)
    case .attribute:
      WorkspaceChrome.nsRGB(229, 192, 123)
    case .constant:
      WorkspaceChrome.nsRGB(209, 154, 102)
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
    WorkspaceChrome.configureThinScrollbars(in: scrollView)
    context.coordinator.textView = textView
    context.coordinator.scrollView = scrollView
    context.coordinator.startObservingScroll()
    context.coordinator.restoreEditorViewport()
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
    textView.insertionPointColor = WorkspaceChrome.nsTextPrimary
    let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    textView.font = font
    textView.typingAttributes = [
      .font: font,
      .foregroundColor: WorkspaceChrome.nsCode,
    ]
    textView.isHorizontallyResizable = !wordWrap
    textView.textContainer?.widthTracksTextView = wordWrap
    textView.textContainer?.lineBreakMode = wordWrap ? .byCharWrapping : .byClipping
  }

  static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
    guard let textView = nsView.documentView as? ProjectSourceTextView else {
      return
    }
    coordinator.stopObservingScroll()
    textView.delegate = nil
    textView.onSave = nil
    coordinator.textView = nil
    coordinator.scrollView = nil
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    let document: ProjectEditorTab
    weak var textView: NSTextView?
    weak var scrollView: NSScrollView?
    var isUpdatingFromModel = false
    var lastAppliedSelection: ProjectEditorSelection?
    private var scrollObserver: NSObjectProtocol?

    init(document: ProjectEditorTab) {
      self.document = document
    }

    func startObservingScroll() {
      guard let scrollView, scrollObserver == nil else {
        return
      }
      scrollView.contentView.postsBoundsChangedNotifications = true
      scrollObserver = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification,
        object: scrollView.contentView,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.captureViewport()
        }
      }
    }

    func stopObservingScroll() {
      if let scrollObserver {
        NotificationCenter.default.removeObserver(scrollObserver)
        self.scrollObserver = nil
      }
    }

    func restoreEditorViewport() {
      guard let textView else {
        return
      }

      let documentLength = textView.string.utf16.count
      let selection = document.editorSelection
      let range =
        selection.map {
          let location = min(max(0, $0.location), documentLength)
          let length = min(max(0, $0.length), documentLength - location)
          return NSRange(location: location, length: length)
        } ?? NSRange(location: 0, length: 0)

      isUpdatingFromModel = true
      textView.setSelectedRange(range)
      isUpdatingFromModel = false

      guard document.editorScrollTop.isFinite else {
        return
      }
      let scrollTop = max(0, document.editorScrollTop)
      DispatchQueue.main.async { @MainActor [weak self] in
        guard let self, let scrollView = self.scrollView else {
          return
        }
        var origin = scrollView.contentView.bounds.origin
        origin.y = scrollTop
        self.isUpdatingFromModel = true
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        self.isUpdatingFromModel = false
      }
    }

    func captureViewport() {
      guard !isUpdatingFromModel, let textView, let scrollView else {
        return
      }
      let selectedRange = textView.selectedRange()
      let selection: ProjectEditorUTF16Range? =
        selectedRange.location == NSNotFound
        ? nil
        : ProjectEditorUTF16Range(
          location: selectedRange.location,
          length: selectedRange.length
        )
      let scrollTop = max(0, Double(scrollView.contentView.bounds.origin.y))
      guard
        document.editorSelection != selection
          || document.editorScrollTop != scrollTop
      else {
        return
      }
      document.updateEditorViewport(selection: selection, scrollTop: scrollTop)
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

    func textViewDidChangeSelection(_ notification: Notification) {
      captureViewport()
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
        .foregroundColor: WorkspaceChrome.nsCode,
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
      .foregroundColor: WorkspaceChrome.nsCode,
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
