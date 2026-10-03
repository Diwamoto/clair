#if os(macOS)
  import ClairEditorCore
  import ClairEditorView
  import ClairWorkspace
  import Foundation

  // The GUI half of `WorkbenchAgentContext.swift`: after the registry validated an `editor.diagnostics` /
  // `review.*` call, the store answers it from the live language servers and review store.
  extension ClairWorkbenchStore {
    /// The real result of an agent-context command the registry accepted; nil for every other command.
    func answerAgentContext(_ id: String, _ input: CommandInput) -> Result<CommandResult, CommandError>? {
      switch id {
      case "editor.diagnostics": return scope(input).map { CommandResult.diagnostics(agentDiagnostics(in: $0.root, path: $0.path)) }
      case "review.threads":
        return scope(input).map { s in CommandResult.reviewThreads(reviews.list(root: s.root, path: s.path) { self.lines(root: s.root, $0) }) }
      case "review.comment", "review.suggest": return postReview(id, input)
      default: return nil
      }
    }

    private func scope(_ input: CommandInput) -> Result<(root: String, path: String?), CommandError> {
      guard case .string(let raw)? = input["path"] else {
        guard let root = activeRoot else { return .failure(CommandError(.preconditionFailed, "no active Project")) }
        return .success((root, nil))
      }
      do { let t = try state.agentFile(raw); return .success((t.root, t.path)) } catch { return .failure(error) }
    }

    /// Diagnostics of the documents open on a language server under `root`, on the revision the user sees.
    /// Only the active Project has editor buffers, so another Project has none to report.
    func agentDiagnostics(in root: String, path: String?) -> [WorkbenchDiagnostic] {
      guard root == activeRoot else { return [] }
      let paths = path.map { [$0] } ?? buffers.language.diagnostics.keys.compactMap { abs in
        abs.hasPrefix(root + "/") ? String(abs.dropFirst(root.count + 1)) : nil
      }.sorted()
      return paths.flatMap { p -> [WorkbenchDiagnostic] in
        // The live view carries spans rebased through every edit since the server answered (INV-REV-004).
        if let view = buffers.view(p) { return Self.diagnostics(view.diagnostics, in: view.snapshot, path: root + "/" + p) }
        guard let published = buffers.language.diagnostics[root + "/" + p],
          case .ready(let m)? = buffers.peek(p), m.buffer.snapshot.revision == published.revision
        else { return [] }
        return Self.diagnostics(published.spans, in: m.buffer.snapshot, path: root + "/" + p)
      }
    }

    static func diagnostics(_ spans: [EditorDiagnosticSpan], in snapshot: TextSnapshot, path: String) -> [WorkbenchDiagnostic] {
      spans.compactMap { d in
        guard let start = try? snapshot.position(at: d.range.lowerBound, columnUnit: UTF16Unit.self, rounding: .down),
          let end = try? snapshot.position(at: d.range.upperBound, columnUnit: UTF16Unit.self, rounding: .down)
        else { return nil }
        return WorkbenchDiagnostic(
          path: path, line: start.line.value + 1, column: start.column.value, endLine: end.line.value + 1,
          endColumn: end.column.value, severity: String(describing: d.severity), message: d.message)
      }.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }

    /// The file as the user sees it: the open buffer of the active Project, else the disk.
    private func lines(root: String, _ path: String) -> [String]? {
      var text: String?
      if root == activeRoot, case .ready(let m)? = buffers.peek(path) { text = m.buffer.snapshot.string() }
      else { text = try? String(contentsOfFile: root + "/" + path, encoding: .utf8) }
      return text?.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private func postReview(_ id: String, _ input: CommandInput) -> Result<CommandResult, CommandError> {
      guard case .string(let raw)? = input["path"], case .int(let line)? = input["line"] else {
        return .failure(CommandError(.invalidInput, "path and line are required"))
      }
      let target: AgentFileTarget
      do { target = try state.agentFile(raw) } catch { return .failure(error) }
      let endLine: Int? = if case .int(let e)? = input["endLine"] { e } else { nil }
      let body: String? = if case .string(let b)? = input["body"] { b } else { nil }
      if id == "review.suggest" {
        // Bound to the open buffer's revision, so 適用 lands as one undo unit on exactly what was proposed against.
        guard target.root == activeRoot, case .ready(let m) = buffers.load(target.path, root: target.root) else {
          return .failure(CommandError(.preconditionFailed, "\(target.path) cannot be opened as text in the active Project"))
        }
        guard case .string(let replacement)? = input["replacement"],
          reviews.suggest(root: target.root, path: target.path, line: line, endLine: endLine, replacement: replacement,
            description: body, snapshot: m.buffer.snapshot)
        else { return .failure(CommandError(.invalidInput, "line \(line) is past the end of \(target.path)")) }
        return .success(.ok)
      }
      // A thread needs only the line's position and text, so a file that is not open is read from disk
      // rather than cached as a buffer (buffers belong to the active Project's editors).
      let snapshot: TextSnapshot
      if target.root == activeRoot, case .ready(let m)? = buffers.peek(target.path) {
        snapshot = m.buffer.snapshot
      } else {
        guard let text = try? String(contentsOfFile: target.root + "/" + target.path, encoding: .utf8),
          let buffer = try? TextBuffer(text)
        else { return .failure(CommandError(.preconditionFailed, "\(target.path) is not a UTF-8 text file")) }
        snapshot = buffer.snapshot
      }
      let lineText = (try? snapshot.line(at: TextLineIndex(line - 1))).flatMap { try? snapshot.text(in: $0.contentRange) }
      guard
        reviews.add(root: target.root, path: target.path, line: line, endLine: endLine, text: lineText, body: body ?? "",
          author: ReviewStore.agent, snapshot: snapshot)
      else { return .failure(CommandError(.invalidInput, "line \(line) is past the end of \(target.path)")) }
      return .success(.ok)
    }
  }
#endif
