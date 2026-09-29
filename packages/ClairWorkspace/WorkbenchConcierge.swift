import Foundation

// ADR-0020: one concierge agent per Project. It is an ordinary raw-PTY agent terminal; the GUI draws
// its official Claude Code transcript (found by the session id fixed at launch) as chat, and types the
// composer's text into its PTY. Children are agents launched with `parent` = the concierge's terminal key.
// ponytail: Claude Code only — it is the one provider whose session id can be fixed at launch
// (`--session-id`); Codex/OpenCode need a session-discovery step before they can be a concierge.

public enum Concierge {
  public static let instructionsPath = ".clair/concierge.md"

  static let basePrompt = """
    あなたはこの Project 専属のコンシェルジュです。ユーザーの依頼を受け、Clair の操作と作業の割り振りを担当します。自分で大きな実装はしません。

    ## できること
    - `clair` CLI で Clair を操作する(ファイルを開く、ペイン、git、プレビューなど)。使い方は clair-agents / clair-preview skill を参照。
    - 作業は子 agent に任せる: `clair agent.launch --profile <claude|codex|opencode> --prompt "<依頼>" [--branch <名前>]`。互いに独立した作業は別々の branch で並列に起動する。

    ## トークン節約のルール(重要)
    - 子 agent の出力を逐一読まない。進み具合は Clair のサイドバーが表示している。
    - 起動したら、どの子に何を任せたかを1〜2行で報告して手を止める。
    - 結果が必要なときだけ、`clair agent.status` で終了を確認してから `clair agent.output --lines 40` で末尾だけ読み、要点を3行以内でまとめる。
    - 詳細はユーザーがリンクから実際のターミナルで見る。長いログを貼らない。

    ## 振る舞い
    - 返答は短く、日本語で。
    - 依頼が曖昧なら、起動する前に1問だけ確認する。
    - 危険な操作(削除、push、force など)は子にもさせず、ユーザーに確認する。
    - 子が「入力待ち」になったら、何を聞かれているかを1行で伝える。代わりに答えてよいのは、明らかに安全な場合だけ。
    - 終わった子のペインは、ユーザーが見終えたら `clair agent.close` で閉じてよい。
    """

  /// The system prompt: the fixed role plus the Project's own `.clair/concierge.md`, read at launch.
  public static func prompt(root: String) -> String {
    let extra = (try? String(contentsOfFile: root + "/" + instructionsPath, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return extra.isEmpty ? basePrompt : basePrompt + "\n\n## Project の指示\n" + extra
  }

  /// Claude Code keeps each session at `~/.claude/projects/<cwd slug>/<id>.jsonl`; the slug is not
  /// something to re-derive, so look the id up one level down.
  public static func transcriptFile(session: String, home: URL = .homeDirectory) -> URL? {
    let root = home.appending(path: ".claude/projects")
    let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    return dirs.lazy.map { $0.appending(path: "\(session).jsonl") }.first { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// `opening` rides as Claude's initial prompt, so a request sent before the TUI was up is never lost.
  static func command(session: String, root: String, opening: String? = nil) -> String {
    // A restored pane reopens the same chat; a new one starts it under the fixed id.
    let start = transcriptFile(session: session) == nil ? "--session-id" : "--resume"
    let first = start == "--session-id" ? opening.map { " " + AgentRun.quote($0) } ?? "" : ""
    return "claude \(start) \(session) --append-system-prompt \(AgentRun.quote(prompt(root: root)))\(first)"
  }
}

extension WorkbenchState {
  /// The Project's concierge terminal, if one is open.
  public func concierge(in project: String) -> (pane: Int, session: String)? {
    let l = withLayoutCopy(project)
    return l.launches.sorted { $0.key < $1.key }.lazy.compactMap { pane, launch in
      launch.concierge.map { (pane, $0) }
    }.first { pane, _ in l.tree.leaves.contains { $0.id == pane } }
  }

  /// Agents the Project's concierge launched (its `parent` is the concierge terminal).
  public func conciergeChildren(in project: String) -> [(session: AgentSession, launch: AgentLaunch)] {
    guard let c = concierge(in: project), let root = projects.first(where: { $0.name == project })?.path else { return [] }
    let key = Self.terminalKey(root, c.pane)
    // Children can live in the worktree Projects agent.launch creates, so search every Project.
    return agentSessions.compactMap { s in
      guard let l = withLayoutCopy(s.project).launches[s.pane], l.parent == key else { return nil }
      return (s, l)
    }
  }
}
