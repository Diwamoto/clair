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
      "Before save"
    case .externalChange:
      "Before disk reload"
    case .externalDeletion:
      "Before file deletion"
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
  @Published private(set) var canUndo = false
  @Published private(set) var canRedo = false
  @Published private(set) var historyEntries: [ProjectLocalHistoryEntry] = []
  @Published private(set) var lastErrorMessage: String?
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
  ) throws {
    let canonicalURL = url.standardizedFileURL
    let data: Data
    do {
      data = try Data(contentsOf: canonicalURL)
    } catch CocoaError.fileReadNoSuchFile {
      throw ProjectEditorError.fileMissing(path: canonicalURL.path)
    } catch {
      throw ProjectEditorError.readFailed(
        path: canonicalURL.path,
        message: error.localizedDescription
      )
    }
    guard let content = String(data: data, encoding: .utf8) else {
      throw ProjectEditorError.invalidUTF8(path: canonicalURL.path)
    }

    self.id = canonicalURL.path
    self.url = canonicalURL
    self.title = canonicalURL.lastPathComponent
    self.projectID = projectID
    self.rootURL = rootURL.standardizedFileURL
    self.fileManager = fileManager
    self.historyStore = historyStore
    self.content = content
    self.baselineContent = content
    self.diskData = data
    self.historyEntries =
      (try? historyStore.entries(
        for: projectID,
        fileURL: canonicalURL,
        rootURL: rootURL
      )) ?? []

    let fileWatcher = ProjectEditorFileWatcher(fileURL: canonicalURL) {
      [weak self] in
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

  func updateFromEditor(_ newContent: String) {
    guard newContent != content else {
      refreshUndoState()
      return
    }
    content = newContent
    isDirty = newContent != baselineContent || isMissing
    refreshUndoState()
  }

  func replaceContent(_ newContent: String, actionName: String = "Edit") {
    guard newContent != content else {
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

@MainActor
struct ProjectSourceEditorView: NSViewRepresentable {
  @ObservedObject var document: ProjectEditorTab
  let selection: ProjectEditorSelection?
  let onSave: () -> Void

  init(
    document: ProjectEditorTab,
    selection: ProjectEditorSelection? = nil,
    onSave: @escaping () -> Void
  ) {
    self.document = document
    self.selection = selection
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
    textView.isEditable = !document.isMissing
    textView.isSelectable = true
    textView.isRichText = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.drawsBackground = true
    textView.backgroundColor = .textBackgroundColor
    textView.textColor = .textColor
    textView.insertionPointColor = .textColor
    textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    textView.textContainerInset = NSSize(width: 12, height: 12)
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = true
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.heightTracksTextView = false

    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .textBackgroundColor
    scrollView.documentView = textView
    context.coordinator.textView = textView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? ProjectSourceTextView else {
      return
    }

    textView.onSave = onSave
    textView.isEditable = !document.isMissing
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
    applySelectionIfNeeded(to: textView, context: context)
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

  override var acceptsFirstResponder: Bool {
    true
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
