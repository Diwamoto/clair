import SwiftUI
import ClairWorkspace

/// Activity is the number of prompts the user sent, across all three provider histories.
struct AgentUsageView: View {
  @State private var summary: AgentUsageSummary?
  private let calendar = Calendar.current

  private var weeks: [[Date]] {
    let today = calendar.startOfDay(for: .now)
    return (0..<53).map { week in
      (0..<7).map { day in calendar.date(byAdding: .day, value: -(52 - week) * 7 - (6 - day), to: today)! }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Button("再集計") {
        Task { summary = AgentUsageSummary(histories: await AgentHistoryStore.shared.refresh()) }
      }.font(.caption)
      HStack(alignment: .firstTextBaseline, spacing: 28) {
        VStack(alignment: .leading, spacing: 4) {
          Text("今日の依頼").font(.caption).foregroundStyle(.secondary)
          Text(summary.map { "\($0.prompts(on: .now)) 件" } ?? "—")
            .font(.system(size: 30, weight: .semibold, design: .rounded))
        }
        VStack(alignment: .leading, spacing: 4) {
          Text("費用の推定").font(.caption).foregroundStyle(.secondary)
          Text(summary.map { String(format: "$%.2f", $0.estimatedUSD) } ?? "—")
            .font(.system(size: 30, weight: .semibold, design: .rounded))
        }
      }
      Text("1マスは1日。送信した依頼・追記を1件として数えます。")
        .font(.caption).foregroundStyle(.secondary)
      ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: 3) {
          ForEach(weeks.indices, id: \.self) { index in
            VStack(spacing: 3) {
              ForEach(weeks[index], id: \.self) { date in
                let count = summary?.prompts(on: date, calendar: calendar) ?? 0
                RoundedRectangle(cornerRadius: 2)
                  .fill(Color.accentColor.opacity(count == 0 ? 0.1 : min(0.25 + Double(count) * 0.12, 0.95)))
                  .frame(width: 11, height: 11)
                  .help("\(date.formatted(date: .abbreviated, time: .omitted)): \(count) 件")
              }
            }
          }
        }.padding(.vertical, 4)
      }
      if let summary {
        VStack(alignment: .leading, spacing: 8) {
          Text("エージェント別").font(.headline)
          ForEach(summary.providers) { item in
            HStack {
              Image(systemName: item.provider == .claude ? "sparkles" : item.provider == .codex ? "chevron.left.forwardslash.chevron.right" : "square.stack.3d.up")
                .frame(width: 18)
              Text(item.provider.rawValue)
              Spacer()
              Text("\(item.prompts) 件")
              Text(String(format: "$%.2f", item.estimatedUSD))
                .frame(width: 72, alignment: .trailing)
            }.font(.caption)
          }
        }
      }
      Text("費用は provider の記録値または 2026-09-24 時点のモデル別 API 単価による推定額です。実際の請求額ではありません。")
        .font(.caption).foregroundStyle(.secondary)
      if let missing = summary?.sessionsWithoutCost, missing > 0 {
        Text("\(missing) 件のチャットは費用情報がなく、推定額に含まれていません。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task {
      let histories = await AgentHistoryStore.shared.all()
      summary = AgentUsageSummary(histories: histories)
    }
  }
}
