import CryptoKit
import Foundation

// ADR-0020: one concierge agent for all of Clair, hosted in some Project's layout. It is an ordinary raw-PTY agent terminal; the GUI draws
// its official Claude Code transcript (found by the session id fixed at launch) as chat, and types the
// composer's text into its PTY. Children are agents launched with `parent` = the concierge's terminal key.
// ponytail: Claude Code only — it is the one provider whose session id can be fixed at launch
// (`--session-id`); Codex/OpenCode need a session-discovery step before they can be a concierge.

public enum Concierge {
  static let basePrompt = """
    あなたは Clair 全体のコンシェルジュです。ユーザーの依頼を受け、Clair の操作と作業の割り振りを担当します。自分で大きな実装はしません。

    ## できること
    - `clair` CLI で Clair を操作する(ファイルを開く、ペイン、git、プレビューなど)。使い方は clair-agents / clair-preview skill を参照。
    - 作業は子 agent に任せる: `clair agent launch profile=<claude|codex|opencode> prompt="<依頼>" [branch=<名前>]`。互いに独立した作業は別々の branch で並列に起動する。

    ## トークン節約のルール(重要)
    - `clair` は必ず `--compact` を付けて実行する(色なしの1行の JSON になる)。
    - 子 agent の出力を逐一読まない。進み具合は Clair のサイドバーが表示している。
    - 起動したら、どの子に何を任せたかを1〜2行で報告して手を止める。
    - 結果が必要なときだけ、`clair agent status` で終了を確認してから `clair agent output lines=40` で末尾だけ読み、要点を3行以内でまとめる。
    - 詳細はユーザーがリンクから実際のターミナルで見る。長いログを貼らない。

    ## 振る舞い
    - 返答は短く、日本語で。
    - 依頼が曖昧なら、起動する前に1問だけ確認する。
    - 危険な操作(削除、push、force など)は子にもさせず、ユーザーに確認する。
    - 子が「入力待ち」になったら、何を聞かれているかを1行で伝える。代わりに答えてよいのは、明らかに安全な場合だけ。
    - 終わった子のペインは、ユーザーが見終えたら `clair agent close` で閉じてよい。
    """

  /// The system prompt: the fixed role plus the user's `settings.concierge` prompt.
  public static func prompt(extra: String) -> String {
    let extra = extra.trimmingCharacters(in: .whitespacesAndNewlines)
    return extra.isEmpty ? basePrompt : basePrompt + "\n\n## ユーザーの指示\n" + extra
  }

  /// What the concierge reads at launch besides its prompt: Claude Code's project files in `cwd`.
  // ponytail: cwd only; ~/.claude (user-level skills, settings) is not covered — add it if the user wants that gated too.
  static let readPaths = ["CLAUDE.md", "CLAUDE.local.md", ".mcp.json", ".claude"]
  static let readDirs = ["skills", "agents", "commands", "hooks", "rules"]

  /// #76: a hash of everything that steers the concierge. The user approves this; any change asks again.
  public static func fingerprint(prompt: String, cwd: String) -> String {
    var hasher = SHA256()
    func add(_ s: String) { hasher.update(data: Data((s + "\u{1f}").utf8)) }
    add(prompt); add(cwd)
    let fm = FileManager.default
    var files: [String] = []
    for p in readPaths.dropLast() { files.append(cwd + "/" + p) }
    for f in ["CLAUDE.md", "settings.json", "settings.local.json"] { files.append(cwd + "/.claude/" + f) }
    for d in readDirs {
      let root = cwd + "/.claude/" + d
      files += (fm.subpaths(atPath: root) ?? []).map { root + "/" + $0 }
    }
    for f in files.sorted() {
      var dir: ObjCBool = false
      guard fm.fileExists(atPath: f, isDirectory: &dir), !dir.boolValue else { continue }
      add(f); add((try? Data(contentsOf: URL(fileURLWithPath: f))).map { SHA256.hash(data: $0).description } ?? "")
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Approvals live in the GUI's defaults, like `ClairSchedule.approvals`.
  // ponytail: advisory, same ceiling as schedules (an agent with a shell can `defaults write`).
  nonisolated(unsafe) public static var approvals: UserDefaults = .standard
  static let approvalKey = "approvedConcierge"
  public static func isApproved(_ fingerprint: String) -> Bool { approvals.string(forKey: approvalKey) == fingerprint }
  public static func approve(_ fingerprint: String) { approvals.set(fingerprint, forKey: approvalKey) }

  /// Claude Code keeps each session at `~/.claude/projects/<cwd slug>/<id>.jsonl`; the slug is not
  /// something to re-derive, so look the id up one level down.
  public static func transcriptFile(session: String, home: URL = .homeDirectory) -> URL? {
    let root = home.appending(path: ".claude/projects")
    let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    return dirs.lazy.map { $0.appending(path: "\(session).jsonl") }.first { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// `opening` rides as Claude's initial prompt, so a request sent before the TUI was up is never lost.
  static func command(session: String, extra: String, opening: String? = nil) -> String {
    // A restored pane reopens the same chat; a new one starts it under the fixed id.
    let start = transcriptFile(session: session) == nil ? "--session-id" : "--resume"
    let first = start == "--session-id" ? opening.map { " " + AgentRun.quote($0) } ?? "" : ""
    return "claude \(start) \(session) --append-system-prompt \(AgentRun.quote(prompt(extra: extra)))\(first)"
  }
}

extension WorkbenchState {
  /// Clair's concierge terminal, in whichever Project's layout hosts it.
  public func concierge() -> (project: String, pane: Int, session: String)? {
    projects.lazy.compactMap { p -> (String, Int, String)? in
      let l = withLayoutCopy(p.name)
      return l.launches.sorted { $0.key < $1.key }.lazy.compactMap { pane, launch in
        launch.concierge.map { (p.name, pane, $0) }
      }.first { _, pane, _ in l.tree.leaves.contains { $0.id == pane } }
    }.first
  }

  /// Agents the concierge launched (their `parent` is the concierge terminal).
  public func conciergeChildren() -> [(session: AgentSession, launch: AgentLaunch)] {
    guard let c = concierge(), let root = projects.first(where: { $0.name == c.project })?.path else { return [] }
    let key = Self.terminalKey(root, c.pane)
    // Children can live in the worktree Projects agent.launch creates, so search every Project.
    return agentSessions.compactMap { s in
      guard let l = withLayoutCopy(s.project).launches[s.pane], l.parent == key else { return nil }
      return (s, l)
    }
  }
}
