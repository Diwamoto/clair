#if os(macOS)
  import ClairShared
  import AppKit
  import ClairDesignSystem
  import ClairEditorCore
  import ClairEditorLanguage
  import ClairWorkspace
  import SwiftUI

  private typealias C = DesignTokens.Color
  private typealias L = DesignTokens.Line

  /// One edit Claude Code proposed through `openDiff`, waiting for the user in a proposal diff tab.
  struct ClaudeProposal {
    let root: String
    let path: String
    let tabName: String
    let tab: WorkbenchDiffTab
    /// Answers the waiting `openDiff` call; nil once answered.
    var reply: (@MainActor (ClaudeIDEToolResult) -> Void)?
  }

  // ADR-0022: the store's side of the Claude Code IDE connection — starting the socket and lock file, answering the
  // tools from live editor state, and the accept/reject of proposed edits.
  extension ClairWorkbenchStore {
    private static let portKey = "clair.claudeIDEPort"

    func startClaudeIDE() {
      claudeIDE.onMessage = { [weak self] text, reply in
        ClaudeIDE.handle(
          text, call: { tool, arguments, done in
            guard let self else { return done(.error(code: -32000, message: "Clair is closing")) }
            self.claudeTool(tool, arguments, done)
          }, reply: reply)
      }
      claudeIDE.onReady = { [weak self] port in
        UserDefaults.standard.set(Int(port), forKey: Self.portKey)
        // Shells started from here on inherit these through `clair attach` (the daemon forwards them).
        setenv("CLAUDE_CODE_SSE_PORT", String(port), 1)
        setenv("ENABLE_IDE_INTEGRATION", "true", 1)
        setenv("FORCE_CODE_TERMINAL", "true", 1)
        self?.refreshClaudeLock()
      }
      let saved = UserDefaults.standard.integer(forKey: Self.portKey)
      claudeIDE.start(preferred: (1024...65535).contains(saved) ? UInt16(saved) : nil)
    }

    func stopClaudeIDE() {
      if let port = claudeIDE.port { ClaudeIDE.removeLock(port: port, directory: ClaudeIDE.lockDirectory()) }
      for (_, p) in proposals { p.reply?(.text(["DIFF_REJECTED", p.tabName])) }
      proposals = [:]
      claudeIDE.stop()
    }

    /// The lock file lists the open Projects, so `/ide` in any of them finds Clair.
    func refreshClaudeLock() {
      guard let port = claudeIDE.port else { return }
      try? ClaudeIDE.writeLock(port: port, token: claudeIDE.token, folders: state.projects.map(\.path), directory: ClaudeIDE.lockDirectory())
    }

    /// `selection_changed` for connected sessions, at most every 100 ms.
    func broadcastSelection() {
      guard claudeIDE.hasClients else { return }
      selectionBroadcast?.cancel()
      selectionBroadcast = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled, let self, let c = self.state.editorContext else { return }
        self.claudeIDE.broadcast(
          ClaudeIDE.selectionChanged(
            path: c.path, text: c.selectedText ?? "", startLine: c.startLine - 1, startCharacter: c.startColumn,
            endLine: c.endLine - 1, endCharacter: c.endColumn))
      }
    }

    /// `agent.mention`: hands the selection (or the caret's file) to every connected Claude Code as `@file#Lx-y`.
    func mentionSelectionToClaude() {
      guard claudeIDE.hasClients else { languageNotice = tr("Claude Code が接続されていません"); return }
      guard let c = state.editorContext else { languageNotice = tr("ファイルが開かれていません"); return }
      let lines: (Int?, Int?) = c.selectedText == nil ? (nil, nil) : (c.startLine - 1, c.endLine - 1)
      claudeIDE.broadcast(ClaudeIDE.atMentioned(path: c.path, lineStart: lines.0, lineEnd: lines.1))
      languageNotice = nil
    }

    // MARK: tools

    private func claudeTool(_ tool: String, _ args: [String: Any], _ done: @escaping @MainActor (ClaudeIDEToolResult) -> Void) {
      let string = { (key: String) in args[key] as? String }
      switch tool {
      case "openFile":
        guard let path = string("filePath").map(absolute) else { return done(.error(code: -32602, message: "filePath is required")) }
        var input: CommandInput = ["path": .string(path)]
        if let start = string("startText"), let text = try? String(contentsOfFile: path, encoding: .utf8), let r = text.range(of: start) {
          input["line"] = .int(text[..<r.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).count)
        }
        switch run("file.open", input) {
        case .success: done(.text(["Opened file: \(path)"]))
        case .failure(let e): done(.error(code: -32000, message: e.message))
        }
      case "openDiff":
        guard let path = string("new_file_path").map(absolute), let contents = string("new_file_contents"), let tab = string("tab_name") else {
          return done(.error(code: -32602, message: "new_file_path, new_file_contents and tab_name are required"))
        }
        openProposal(path: path, contents: contents, tabName: tab, done: done)
      case "getCurrentSelection", "getLatestSelection":
        guard let c = state.editorContext else { return done(.text([ClaudeIDE.json(["success": false, "message": "No active editor found"])])) }
        done(.text([ClaudeIDE.json([
          "success": true, "text": c.selectedText ?? "", "filePath": c.path, "fileUrl": URL(fileURLWithPath: c.path).absoluteString,
          "selection": [
            "start": ["line": c.startLine - 1, "character": c.startColumn], "end": ["line": c.endLine - 1, "character": c.endColumn],
            "isEmpty": c.selectedText == nil,
          ],
        ])]))
      case "getOpenEditors":
        let root = activeRoot ?? ""
        let tabs: [[String: Any]] = state.tabs.map { rel in
          let path = root + "/" + rel
          return [
            "uri": URL(fileURLWithPath: path).absoluteString, "isActive": rel == state.active, "label": (rel as NSString).lastPathComponent,
            "languageId": EditorLanguageID.detect(path: rel)?.lspLanguageID ?? "plaintext", "isDirty": state.dirty.contains(rel),
          ]
        }
        done(.text([ClaudeIDE.json(["tabs": tabs])]))
      case "getWorkspaceFolders":
        let folders: [[String: Any]] = state.projects.map { ["name": $0.displayName, "uri": URL(fileURLWithPath: $0.path).absoluteString, "path": $0.path] }
        done(.text([ClaudeIDE.json(["success": true, "folders": folders, "rootPath": activeRoot ?? ""])]))
      case "getDiagnostics":
        done(.text([ClaudeIDE.json(claudeDiagnostics(uri: string("uri")))]))
      case "checkDocumentDirty":
        guard let rel = string("filePath").flatMap(openRelative) else {
          return done(.text([ClaudeIDE.json(["success": false, "message": "Document not open"])]))
        }
        done(.text([ClaudeIDE.json(["success": true, "filePath": absolute(rel), "isDirty": state.dirty.contains(rel), "isUntitled": false])]))
      case "saveDocument":
        guard let rel = string("filePath").flatMap(openRelative) else {
          return done(.text([ClaudeIDE.json(["success": false, "message": "Document not open"])]))
        }
        Task {
          let saved = await saveFile(rel)
          done(.text([ClaudeIDE.json(["success": saved, "filePath": absolute(rel), "saved": saved])]))
        }
      case "close_tab":
        let name = string("tab_name") ?? ""
        for (key, p) in proposals where p.tabName == name { closeProposal(key) }
        done(.text(["TAB_CLOSED"]))
      case "closeAllDiffTabs":
        let count = proposals.count
        for key in proposals.keys { closeProposal(key) }
        done(.text(["CLOSED_\(count)_DIFF_TABS"]))
      default:
        done(.error(code: -32601, message: "Unknown tool \(tool)"))
      }
    }

    private func absolute(_ path: String) -> String {
      if path.hasPrefix("file://"), let url = URL(string: path) { return url.path }
      return path.hasPrefix("/") ? path : (activeRoot ?? "") + "/" + path
    }

    /// The active Project's relative path of `path` when it is open in an editor.
    private func openRelative(_ path: String) -> String? {
      guard let root = activeRoot else { return nil }
      let abs = absolute(path)
      guard abs.hasPrefix(root + "/") else { return nil }
      let rel = String(abs.dropFirst(root.count + 1))
      return state.tabs.contains(rel) ? rel : nil
    }

    private func claudeDiagnostics(uri: String?) -> [[String: Any]] {
      guard let root = activeRoot else { return [] }
      let rel = uri.map(absolute).flatMap { $0.hasPrefix(root + "/") ? String($0.dropFirst(root.count + 1)) : nil }
      let severity = ["error": "Error", "warning": "Warning", "information": "Information", "hint": "Hint"]
      let byFile = Dictionary(grouping: agentDiagnostics(in: root, path: rel), by: \.path)
      return byFile.keys.sorted().map { path -> [String: Any] in
        [
          "uri": URL(fileURLWithPath: path).absoluteString,
          "diagnostics": byFile[path]!.map { d -> [String: Any] in
            [
              "message": d.message, "severity": severity[d.severity] ?? "Information",
              "range": ["start": ["line": d.line - 1, "character": d.column], "end": ["line": d.endLine - 1, "character": d.endColumn]],
            ]
          },
        ]
      }
    }

    // MARK: proposals

    /// Shows Claude's proposed text for `path` as a diff tab in the file's Project; the call is answered when the user
    /// accepts (Claude Code then writes the file) or rejects it.
    private func openProposal(path: String, contents: String, tabName: String, done: @escaping @MainActor (ClaudeIDEToolResult) -> Void) {
      guard let project = state.projects.filter({ path.hasPrefix($0.path + "/") }).max(by: { $0.path.count < $1.path.count }) else {
        return done(.error(code: -32000, message: "\(path) is not in a Project open in Clair"))
      }
      let rel = String(path.dropFirst(project.path.count + 1))
      let dir = ClaudeIDE.proposalDirectory.appending(path: UUID().uuidString)
      let file = dir.appending(path: (rel as NSString).lastPathComponent)
      do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try contents.write(to: file, atomically: true, encoding: .utf8)
      } catch {
        return done(.error(code: -32000, message: "Clair could not stage the proposal: \(error.localizedDescription)"))
      }
      // A newer proposal for the same tab replaces the older one, which counts as rejected.
      for (key, p) in proposals where p.tabName == tabName { resolveProposal(key, accept: false) }
      if project.name != state.project { run("project.switch", ["name": .string(project.name)]) }
      let tab = WorkbenchDiffTab(path: rel, staged: false, untracked: false, proposal: file.path)
      proposals[file.path] = ClaudeProposal(root: project.path, path: rel, tabName: tabName, tab: tab, reply: done)
      switch run("diff.open", ["path": .string(rel), "staged": .bool(false), "untracked": .bool(false), "proposal": .string(file.path)]) {
      case .success:
        NSApp?.activate(ignoringOtherApps: true)
      case .failure(let e):
        proposals[file.path] = nil
        try? FileManager.default.removeItem(at: dir)
        done(.error(code: -32000, message: e.message))
      }
    }

    /// The user's answer from the proposal bar (or closing its tab, which rejects).
    func resolveProposal(_ key: String, accept: Bool) {
      guard var p = proposals[key] else { return }
      if let reply = p.reply {
        p.reply = nil
        proposals[key] = p
        if accept, let text = try? String(contentsOfFile: key, encoding: .utf8) {
          reply(.text(["FILE_SAVED", text]))
        } else {
          reply(.text(["DIFF_REJECTED", p.tabName]))
        }
      }
      closeProposal(key)
    }

    /// Removes the proposal's tab and staged text; an unanswered call is answered as rejected.
    func closeProposal(_ key: String) {
      guard let p = proposals.removeValue(forKey: key) else { return }
      p.reply?(.text(["DIFF_REJECTED", p.tabName]))
      if state.diffTabs.contains(p.tab) || state.layouts.values.contains(where: { $0.diffTabs.contains(p.tab) }) {
        if let owner = state.projects.first(where: { $0.path == p.root }), owner.name != state.project {
          state.layouts[owner.name]?.diffTabs.removeAll { $0 == p.tab }
          if state.layouts[owner.name]?.activeDiff == p.tab { state.layouts[owner.name]?.activeDiff = nil }
        } else {
          run("diff.close", ["path": .string(p.path), "staged": .bool(false), "untracked": .bool(false), "proposal": .string(key)])
        }
      }
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: key).deletingLastPathComponent())
    }
  }

  /// Above a proposal's diff: whose change it is and the two answers. Accepting lets Claude Code write the file.
  struct ProposalBar: View {
    let path: String
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
      HStack(spacing: 8) {
        Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(C.textTertiary)
        Text(tr("Claude Code が %@ の変更を提案しています", path)).font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary)
          .lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 8)
        Button(tr("却下"), action: onReject).buttonStyle(.hoverWash).foregroundStyle(C.textTertiary)
          .keyboardShortcut(.escape, modifiers: [.command])
        Button(tr("承認"), action: onAccept).buttonStyle(.hoverWash).foregroundStyle(C.textPrimary)
          .keyboardShortcut(.return, modifiers: [.command])
      }
      .font(Typography.font(Typography.chrome))
      .padding(.horizontal, 12).frame(height: 34)
      .background(C.chromeRaised)
      .overlay(alignment: .bottom) { Rectangle().fill(L.hairline).frame(height: 1) }
      .accessibilityElement(children: .contain).accessibilityLabel(tr("Claude Code の提案"))
    }
  }
#endif
