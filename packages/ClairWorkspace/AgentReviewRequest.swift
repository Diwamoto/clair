import ClairShared

/// A review request is a read-only task for an existing agent launch profile.
/// The GUI chooses the target from the active Project; the agent runs in that Project root.
public enum AgentReviewRequest {
  public enum Target: Equatable, Sendable {
    case file(String)
    case folder(String)
    case project
  }

  public static func prompt(for target: Target) -> String {
    let scope: String = switch target {
    case .file(let path): tr("Project 内のファイル `%@` をレビューしてください。", path)
    case .folder(let path): tr("Project 内のフォルダ `%@/` 配下をレビューしてください。", path)
    case .project: tr("この Project 全体をレビューしてください。変更中のファイルだけでなく、関連する実装も確認してください。")
    }
    return tr("%@\nコードを変更せず、正しさ・データ損失・セキュリティ・回帰の問題を探してください。", scope)
      + tr("指摘は重要度順に、ファイルと行、再現条件、理由を具体的に報告してください。")
      + tr("問題が見つからなければ、その旨と確認した範囲を報告してください。")
  }
}
