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
    case .file(let path): "Project 内のファイル `\(path)` をレビューしてください。"
    case .folder(let path): "Project 内のフォルダ `\(path)/` 配下をレビューしてください。"
    case .project: "この Project 全体をレビューしてください。変更中のファイルだけでなく、関連する実装も確認してください。"
    }
    return "\(scope)\nコードを変更せず、正しさ・データ損失・セキュリティ・回帰の問題を探してください。"
      + "指摘は重要度順に、ファイルと行、再現条件、理由を具体的に報告してください。"
      + "問題が見つからなければ、その旨と確認した範囲を報告してください。"
  }
}
