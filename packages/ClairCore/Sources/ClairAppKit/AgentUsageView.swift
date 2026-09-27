import SwiftUI
import ClairWorkspace

/// Activity is the number of prompts the user sent, across all three provider histories.
struct AgentUsageView: View {
  @State private var summary: AgentUsageSummary?
  @State private var hoveredDate: Date?
  private let calendar = Calendar.current

  private var weeks: [[Date?]] {
    let today = calendar.startOfDay(for: .now)
    let dates = (0..<100).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    let cells: [Date?] = Array(repeating: nil, count: (7 - dates.count % 7) % 7) + dates.map(Optional.some)
    return stride(from: 0, to: cells.count, by: 7).map { index in
      Array(cells[index..<index + 7])
    }
  }

  private func detail(for date: Date) -> String {
    let usage = summary?.usage(on: date, calendar: calendar)
    let lines = AgentHistory.Provider.allCases.compactMap { provider -> String? in
      guard let count = usage?.providerPrompts[provider], count > 0 else { return nil }
      return "\(provider.rawValue): \(count) 件"
    }
    return (["\(date.formatted(date: .complete, time: .omitted))", "依頼・追記: \(usage?.prompts ?? 0) 件"] + lines)
      .joined(separator: "\n")
  }

  private func intensity(_ count: Int) -> Double {
    switch count {
    case 0: 0.10
    case 1: 0.24
    case 2: 0.38
    case 3...4: 0.52
    case 5...7: 0.68
    case 8...11: 0.82
    default: 0.96
    }
  }

  private func recentPrompts(_ dayCount: Int) -> Int? {
    guard let summary else { return nil }
    let start = calendar.startOfDay(for: .now)
    return (0..<dayCount).compactMap { calendar.date(byAdding: .day, value: -$0, to: start) }
      .reduce(0) { $0 + summary.prompts(on: $1, calendar: calendar) }
  }

  private func metric(_ title: String, value: String, unit: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(value).font(.system(size: 34, weight: .semibold, design: .rounded))
          .monospacedDigit()
        Text(unit).font(.system(size: 13)).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Text("依頼・追記").font(.system(size: 19, weight: .semibold))
        Spacer()
        Button("再集計") {
          Task { summary = AgentUsageSummary(histories: await AgentHistoryStore.shared.refresh()) }
        }.font(.system(size: 13))
      }
      HStack(spacing: 10) {
        metric("今日", value: recentPrompts(1).map(String.init) ?? "—", unit: "件")
        metric("直近7日", value: recentPrompts(7).map(String.init) ?? "—", unit: "件")
        metric("直近100日", value: recentPrompts(100).map(String.init) ?? "—", unit: "件")
      }
      metric("費用の推定・全期間", value: summary.map { String(format: "$%.2f", $0.estimatedUSD) } ?? "—", unit: "USD")

      VStack(alignment: .leading, spacing: 10) {
        Text("日別アクティビティ").font(.system(size: 17, weight: .semibold))
        Text("直近100日 · 1マス = 1日 · 右端が最新")
          .font(.system(size: 13)).foregroundStyle(.secondary)
        HStack(alignment: .top, spacing: 3) {
          ForEach(weeks.indices, id: \.self) { index in
            VStack(spacing: 3) {
              ForEach(weeks[index].indices, id: \.self) { day in
                if let date = weeks[index][day] {
                  let count = summary?.prompts(on: date, calendar: calendar) ?? 0
                  RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(intensity(count)))
                    .frame(width: 15, height: 15)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                      if hovering { hoveredDate = date }
                      else if hoveredDate == date { hoveredDate = nil }
                    }
                    .overlay {
                      if hoveredDate == date {
                        RoundedRectangle(cornerRadius: 2).strokeBorder(.primary, lineWidth: 1)
                          .allowsHitTesting(false)
                      }
                    }
                    .popover(isPresented: Binding(
                      get: { hoveredDate == date },
                      set: { if !$0 && hoveredDate == date { hoveredDate = nil } }
                    ), arrowEdge: .bottom) {
                      Text(detail(for: date))
                        .font(.system(size: 13))
                        .padding(12)
                        .frame(minWidth: 190, alignment: .leading)
                    }
                    .accessibilityLabel(detail(for: date))
                } else {
                  Color.clear.frame(width: 15, height: 15)
                }
              }
            }
          }
        }
      }
      if let summary {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("エージェント別").font(.system(size: 17, weight: .semibold))
            Spacer()
            Text("依頼・追記 / 推定費用").font(.system(size: 12)).foregroundStyle(.secondary)
          }
          ForEach(summary.providers) { item in
            HStack {
              ProviderBrandIcon(provider: item.provider.rawValue, size: 18)
                .frame(width: 18)
              Text(item.provider.rawValue)
              Spacer()
              Text("\(item.prompts)").monospacedDigit().frame(width: 64, alignment: .trailing)
              Text(String(format: "$%.2f", item.estimatedUSD))
                .monospacedDigit().frame(width: 72, alignment: .trailing)
            }.font(.system(size: 15))
          }
        }
      }
      Text("推定費用 · provider の記録値または 2026-09-24 時点のモデル別 API 単価。実際の請求額とは異なります。")
        .font(.system(size: 12)).foregroundStyle(.secondary)
      if let missing = summary?.sessionsWithoutCost, missing > 0 {
        Text("費用情報なし: \(missing) チャット（推定額に含まれません）")
          .font(.system(size: 12)).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task {
      let histories = await AgentHistoryStore.shared.all()
      summary = AgentUsageSummary(histories: histories)
    }
  }
}
