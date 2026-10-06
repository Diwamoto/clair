import Charts
import ClairDesignSystem
import ClairShared
import ClairWorkspace
import SwiftUI

private typealias C = DesignTokens.Color
private typealias L = DesignTokens.Line

/// 設定 › 使用状況 (canvas: SettingsUsage). Activity is the prompts the user sent, across all three provider histories.
/// Every chart is grayscale — the canvas gives colour only to diff, debug and tab groups — so magnitude is lightness and
/// an agent is told apart by its icon.
struct AgentUsageView: View {
  let projects: [WorkbenchProject]
  /// Active Project name; the commit chart starts on it.
  let activeProject: String
  let onResume: (AgentHistory) -> Void

  /// Kept across window openings so Settings shows the last totals at once; 再集計 rescans.
  @MainActor private static var cached: (summary: AgentUsageSummary, figures: UsageFigures, at: Date)?
  @State private var loaded = Self.cached
  @State private var calendarFilter = "すべて"
  @State private var monthMode = "依頼・追記"
  @State private var commitProject: String?
  @State private var commits: [Date: Int]??
  @State private var concurrencyMode = "今日"
  @State private var modelRange = "30日"
  private let calendar = Calendar.current

  private var summary: AgentUsageSummary? { loaded?.summary }
  private var figures: UsageFigures? { loaded?.figures }
  private var today: Date { calendar.startOfDay(for: .now) }

  private func daysAgo(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: today) ?? today }

  private func reload(refresh: Bool) async {
    let histories = await (refresh ? AgentHistoryStore.shared.refresh() : AgentHistoryStore.shared.all())
    let now = Date.now
    let result = await Task.detached(priority: .userInitiated) {
      let summary = AgentUsageSummary(histories: histories)
      return (summary, UsageFigures(summary, now: now))
    }.value
    loaded = (result.0, result.1, now)
    Self.cached = loaded
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Spacer()
        if let at = loaded?.at {
          Text(tr("%@ に集計", at.formatted(date: .omitted, time: .shortened))).font(.system(size: 13)).foregroundStyle(C.textTertiary)
        }
        Button(tr("再集計")) { Task { await reload(refresh: true) } }.font(.system(size: 13))
      }
      if let summary, summary.histories.isEmpty {
        Text(tr("まだ依頼がありません。ターミナルで Claude Code・Codex・OpenCode を使うと、ここに集計されます。"))
          .font(.system(size: 14)).foregroundStyle(C.textTertiary).multilineTextAlignment(.center)
          .frame(maxWidth: .infinity).padding(24)
          .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(L.strong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
      } else {
        // Three groups, each its own builder block: a ViewBuilder takes at most ten children.
        VStack(alignment: .leading, spacing: 12) {
          group(tr("アクティビティ"))
          UsageCard(title: tr("概要")) { overview }
          UsageCard(title: tr("日別アクティビティ"), accessory: {
            SettingsSegmented(options: ["すべて"] + AgentHistory.Provider.allCases.map(\.rawValue), value: calendarFilter) { calendarFilter = $0 }
          }) {
            ActivityCalendar(days: figures?.days ?? [:], provider: AgentHistory.Provider(rawValue: calendarFilter))
          }
          UsageCard(title: tr("曜日 × 時間帯"), note: tr("直近 90 日 · 円の大きさ = 依頼数")) { punchcard }
          UsageCard(title: tr("今月と先月"), accessory: {
            SettingsSegmented(options: ["依頼・追記", "推定費用"], value: monthMode) { monthMode = $0 }
          }) { monthComparison }
          UsageCard(title: tr("依頼とコミット"), accessory: { projectPicker }) { promptsAndCommits }
        }
        VStack(alignment: .leading, spacing: 12) {
          group(tr("待ち時間と並列"))
          UsageCard(title: tr("AI を待っている時間"), note: tr("直近 7 日")) { waitTime }
          UsageCard(title: tr("同時に動いたエージェント数"), accessory: {
            SettingsSegmented(options: ["今日", "直近7日の平均"], value: concurrencyMode) { concurrencyMode = $0 }
          }) { concurrency }
        }
        VStack(alignment: .leading, spacing: 12) {
          group(tr("ランキング"))
          UsageCard(title: tr("エージェント別"), note: tr("全期間 · 推定費用は API 換算で、請求額ではありません")) { agents }
          UsageCard(title: tr("モデル別"), accessory: {
            SettingsSegmented(options: ["7日", "30日", "全期間"], value: modelRange) { modelRange = $0 }
          }) { models }
          UsageCard(title: tr("費用の大きいセッション"), note: tr("直近 30 日 · 上位 5 件")) { sessions }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task {
      guard loaded == nil else { return }
      await reload(refresh: false)
    }
  }

  private func group(_ title: String) -> some View {
    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(C.textTertiary).padding(.top, 8)
  }

  private func placeholder(_ text: String) -> some View {
    Text(text).font(.system(size: 14)).foregroundStyle(C.textTertiary).multilineTextAlignment(.center)
      .frame(maxWidth: .infinity).padding(18)
      .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(L.strong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
  }

  private func note(_ text: String) -> some View {
    Text(text).font(.system(size: 13)).foregroundStyle(C.textTertiary).fixedSize(horizontal: false, vertical: true)
  }

  // MARK: ① 概要

  private var overview: some View {
    let f = figures
    var change: Int?
    if let f, f.previousWeek > 0 { change = Int((Double(f.week - f.previousWeek) / Double(f.previousWeek) * 100).rounded()) }
    let hours = f?.busiestHours ?? []
    return HStack(alignment: .top, spacing: 10) {
      UsageTile(title: tr("今日"), value: f.map { "\($0.today)" } ?? "—", unit: tr("件"), sub: f.map { tr("昨日 %@ 件", $0.yesterday) })
      UsageTile(title: tr("直近7日"), value: f.map { "\($0.week)" } ?? "—", unit: tr("件"),
                sub: change.map { tr("前週比 %@%", ($0 >= 0 ? "+" : "") + "\($0)") }) {
        if let spark = f?.spark, spark.contains(where: { $0 > 0 }) {
          Chart(Array(spark.enumerated()), id: \.offset) { point in
            LineMark(x: .value("日", point.offset), y: .value("件", point.element))
              .foregroundStyle(C.textSecondary).lineStyle(StrokeStyle(lineWidth: 1.5)).interpolationMethod(.monotone)
          }
          .chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 24)
          .accessibilityLabel(tr("直近 14 日の依頼数"))
        }
      }
      UsageTile(title: tr("連続日数"), value: f.map { "\($0.streak)" } ?? "—", unit: tr("日"), sub: f.map { tr("最長 %@ 日", $0.longest) })
      UsageTile(title: tr("よく使う時間帯"), value: hours.first.map { "\($0)" } ?? "—", unit: hours.isEmpty ? nil : tr("時台"),
                sub: hours.count > 1 ? tr("次いで %@ 時台", hours[1]) : nil)
    }
  }

  // MARK: ③ 曜日 × 時間帯

  /// Short names in the app's language (not the system locale), Sunday first.
  private static var weekdays: [String] {
    ClairLanguage.current == .english ? englishCalendar.shortWeekdaySymbols : ["日", "月", "火", "水", "木", "金", "土"]
  }

  fileprivate static func monthName(_ month: Int) -> String {
    ClairLanguage.current == .english ? englishCalendar.shortMonthSymbols[month - 1] : "\(month)月"
  }

  fileprivate static let englishCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
  }()

  private struct PunchPoint: Identifiable {
    let day: Int
    let hour: Int
    let count: Int
    var id: Int { day * 24 + hour }
  }

  private var punchcard: some View {
    let grid = figures?.weekdayHours ?? Array(repeating: Array(repeating: 0, count: 24), count: 7)
    let peak = max(grid.flatMap { $0 }.max() ?? 0, 1)
    let names = Self.weekdays
    let points = (0..<7).flatMap { day in (0..<24).map { PunchPoint(day: day, hour: $0, count: grid[day][$0]) } }
    return Chart(points) { point in
      PointMark(x: .value(tr("時"), Double(point.hour)), y: .value(tr("曜日"), names[point.day]))
        .symbolSize(point.count == 0 ? 4 : 16 + 300 * Double(point.count) / Double(peak))
        .foregroundStyle(point.count == 0 ? C.divider : C.textSecondary)
        .accessibilityValue(tr("%@ 件", point.count))
    }
    .chartXScale(domain: -0.5...23.5)
    .chartYScale(domain: names)
    .chartXAxis {
      AxisMarks(values: [0.0, 6, 12, 18, 23]) { value in
        AxisValueLabel { Text(tr("%@時", Int(value.as(Double.self) ?? 0))).font(.system(size: 11)).foregroundStyle(C.textTertiary) }
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading) { _ in AxisValueLabel().font(.system(size: 11)).foregroundStyle(C.textTertiary) }
    }
    .frame(height: 190)
  }

  // MARK: ④ 今月と先月

  private struct MonthPoint: Identifiable {
    let month: String
    let day: Int
    let value: Double
    var id: String { "\(month)-\(day)" }
  }

  private var monthComparison: some View {
    let cost = monthMode == "推定費用"
    let thisMonth = summary?.cumulative(month: .now, cost: cost, calendar: calendar) ?? []
    let lastMonthDate = calendar.date(byAdding: .month, value: -1, to: .now) ?? .now
    let lastMonth = summary?.cumulative(month: lastMonthDate, cost: cost, calendar: calendar) ?? []
    let thisName = Self.monthName(calendar.component(.month, from: .now))
    let lastName = Self.monthName(calendar.component(.month, from: lastMonthDate))
    let points = lastMonth.enumerated().map { MonthPoint(month: lastName, day: $0.offset + 1, value: $0.element) }
      + thisMonth.enumerated().map { MonthPoint(month: thisName, day: $0.offset + 1, value: $0.element) }
    let format: (Double) -> String = { cost ? String(format: "$%.2f", $0) : String(Int($0.rounded())) }
    let now = thisMonth.last
    // Same day of last month, or its last day when this month is longer.
    let then = lastMonth.isEmpty ? nil : lastMonth[min(max(thisMonth.count - 1, 0), lastMonth.count - 1)]
    let unpriced = summary?.sessionsWithoutCost(month: .now, calendar: calendar) ?? 0
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 14) {
        legendLine(thisName, dashed: false)
        legendLine(lastName, dashed: true)
        Spacer()
        if let now, let then {
          let diff = now - then
          Text(tr("今日まで %@(先月同日 %@)", format(now), (diff >= 0 ? "+" : "−") + format(abs(diff))))
            .font(.system(size: 13)).foregroundStyle(C.textSecondary).monospacedDigit()
        }
      }
      Chart(points) { point in
        LineMark(x: .value(tr("日"), point.day), y: .value(cost ? "USD" : tr("件"), point.value), series: .value(tr("月"), point.month))
          .foregroundStyle(point.month == thisName ? C.textPrimary : C.textTertiary)
          .lineStyle(point.month == thisName ? StrokeStyle(lineWidth: 2) : StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
      }
      .chartXScale(domain: 1...31)
      .chartXAxis {
        AxisMarks(values: [1, 10, 20, 31]) { value in
          AxisValueLabel { Text(tr("%@日", value.as(Int.self) ?? 0)).font(.system(size: 11)).foregroundStyle(C.textTertiary) }
        }
      }
      .chartYAxis {
        AxisMarks(position: .leading) { _ in
          AxisGridLine().foregroundStyle(L.hairlineSoft)
          AxisValueLabel().font(.system(size: 11)).foregroundStyle(C.textTertiary)
        }
      }
      .frame(height: 170)
      if cost {
        note(unpriced > 0
          ? tr("API 標準料金で換算した推定です。費用を算出できないセッション %@ 件は含めていません。", unpriced)
          : tr("API 標準料金で換算した推定です。"))
      }
    }
  }

  private func legendLine(_ title: String, dashed: Bool) -> some View {
    HStack(spacing: 6) {
      Path { $0.move(to: .init(x: 0, y: 1)); $0.addLine(to: .init(x: 16, y: 1)) }
        .stroke(dashed ? C.textTertiary : C.textPrimary, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 3] : []))
        .frame(width: 16, height: 2)
      Text(title).font(.system(size: 13)).foregroundStyle(C.textSecondary)
    }
  }

  // MARK: ⑤ 依頼とコミット

  private var selectedProject: WorkbenchProject? {
    let name = commitProject ?? activeProject
    return projects.first { $0.name == name } ?? projects.first
  }

  private var projectPicker: some View {
    Menu(selectedProject.map { $0.label ?? $0.name } ?? tr("Project なし")) {
      ForEach(projects, id: \.path) { project in
        Button(project.label ?? project.name) { commitProject = project.name }
      }
    }
    .menuStyle(.borderlessButton).fixedSize().font(.system(size: 13)).disabled(projects.isEmpty)
  }

  private struct DayCount: Identifiable {
    let date: Date
    let count: Int
    var id: Date { date }
  }

  private var promptsAndCommits: some View {
    let start = daysAgo(29)
    let dates = (0...29).reversed().map { daysAgo($0) }
    let root = selectedProject?.path
    var prompts: [Date: Int] = [:]
    if let root {
      for history in summary?.histories ?? [] where history.project == root || history.project?.hasPrefix(root + "/") == true {
        for message in history.messages where message.role == "user" && message.date >= start {
          prompts[calendar.startOfDay(for: message.date), default: 0] += 1
        }
      }
    }
    return VStack(alignment: .leading, spacing: 10) {
      if root == nil {
        placeholder(tr("Project を開くと、依頼とコミットを並べて表示します。"))
      } else {
        dayBars(tr("依頼・追記"), dates.map { DayCount(date: $0, count: prompts[$0] ?? 0) }, ink: C.textSecondary, start: start)
        switch commits {
        case .none:
          ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
        case .some(.none):
          placeholder(tr("この Project は Git リポジトリではないため、コミット数を表示できません。"))
        case .some(.some(let counts)):
          dayBars(tr("コミット"), dates.map { DayCount(date: $0, count: counts[$0] ?? 0) }, ink: C.textTertiary, start: start)
        }
        note(tr("直近 30 日 · あなたのコミット(merge を除く)"))
      }
    }
    .task(id: root) {
      commits = nil
      guard let root else { return }
      let counts = await Task.detached(priority: .utility) { WorkbenchGit.dailyCommits(root, since: start) }.value
      commits = .some(counts)
    }
  }

  private func dayBars(_ title: String, _ values: [DayCount], ink: Color, start: Date) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(C.textSecondary)
      Chart(values) { value in
        BarMark(x: .value(tr("日"), value.date, unit: .day), y: .value(tr("件"), value.count))
          .foregroundStyle(ink).cornerRadius(2)
      }
      .chartXScale(domain: start...(calendar.date(byAdding: .day, value: 1, to: today) ?? today))
      .chartXAxis {
        AxisMarks(values: .stride(by: .day, count: 7)) { _ in
          AxisValueLabel(format: .dateTime.month(.defaultDigits).day()).font(.system(size: 11)).foregroundStyle(C.textTertiary)
        }
      }
      .chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { _ in
          AxisGridLine().foregroundStyle(L.hairlineSoft)
          AxisValueLabel().font(.system(size: 11)).foregroundStyle(C.textTertiary)
        }
      }
      .frame(height: 80)
    }
  }

  // MARK: ⑥ AI を待っている時間

  private static let binTitles = ["〜10秒", "10〜30秒", "30秒〜1分", "1〜2分", "2〜5分", "5〜10分", "10〜30分", "30分+"]

  private static func duration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return tr("%@秒", s) }
    if s < 3600 { return tr("%@分%@秒", s / 60, s % 60) }
    return tr("%@時間%@分", s / 3600, s % 3600 / 60)
  }

  private var waitTime: some View {
    let waits = figures?.waits ?? []
    let bins = AgentUsageSummary.histogram(waits)
    let byProvider = AgentHistory.Provider.allCases.compactMap { provider -> String? in
      AgentUsageSummary.median(waits.filter { $0.provider == provider }.map(\.seconds))
        .map { "\(provider.rawValue) \(Self.duration($0))" }
    }
    return VStack(alignment: .leading, spacing: 12) {
      if waits.isEmpty {
        placeholder(tr("直近 7 日に返答のあった依頼がありません。"))
      } else {
        HStack(alignment: .top, spacing: 10) {
          UsageTile(title: tr("待った時間の合計"), value: Self.duration(waits.map(\.seconds).reduce(0, +)), sub: tr("依頼 %@ 件", waits.count))
          UsageTile(title: tr("中央値"), value: AgentUsageSummary.median(waits.map(\.seconds)).map(Self.duration) ?? "—",
                    sub: byProvider.joined(separator: " · "))
        }
        Chart(Array(bins.enumerated()), id: \.offset) { bin in
          BarMark(x: .value(tr("待ち時間"), tr(Self.binTitles[bin.offset])), y: .value(tr("件"), bin.element))
            .foregroundStyle(C.textSecondary).cornerRadius(2)
        }
        .chartXScale(domain: Self.binTitles.map { tr($0) })
        .chartXAxis {
          AxisMarks { _ in AxisValueLabel().font(.system(size: 11)).foregroundStyle(C.textTertiary) }
        }
        .chartYAxis {
          AxisMarks(position: .leading) { _ in
            AxisGridLine().foregroundStyle(L.hairlineSoft)
            AxisValueLabel().font(.system(size: 11)).foregroundStyle(C.textTertiary)
          }
        }
        .frame(height: 150)
        note(tr("依頼から最後の返答まで。30 分を超えたものは 30 分として数えます。"))
      }
    }
  }

  // MARK: ⑦ 同時に動いたエージェント数

  private struct HourValue: Identifiable {
    let id: Int
    let hour: Double
    let value: Double
  }

  private var concurrency: some View {
    let average = concurrencyMode == "直近7日の平均"
    let pairs: [(hour: Double, value: Double)]
    if average {
      let hours = figures?.averageByHour ?? []
      pairs = hours.enumerated().map { (hour: Double($0.offset), value: $0.element) } + [(hour: 24, value: hours.last ?? 0)]
    } else {
      let steps = figures?.todaySteps ?? []
      pairs = steps.map { (hour: $0.date.timeIntervalSince(today) / 3600, value: Double($0.running)) }
        + [(hour: Date.now.timeIntervalSince(today) / 3600, value: Double(steps.last?.running ?? 0))]
    }
    let values = pairs.enumerated().map { HourValue(id: $0.offset, hour: $0.element.hour, value: $0.element.value) }
    let peak = values.max { $0.value < $1.value }
    return VStack(alignment: .leading, spacing: 8) {
      if !average, (figures?.todaySteps ?? []).allSatisfy({ $0.running == 0 }) {
        placeholder(tr("今日はまだエージェントが動いていません。"))
      } else {
        Chart(values) { value in
          AreaMark(x: .value(tr("時"), value.hour), y: .value(tr("本"), value.value))
            .interpolationMethod(.stepEnd).foregroundStyle(C.textSecondary.opacity(0.16))
          LineMark(x: .value(tr("時"), value.hour), y: .value(tr("本"), value.value))
            .interpolationMethod(.stepEnd).foregroundStyle(C.textSecondary).lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXScale(domain: 0.0...24.0)
        .chartYScale(domain: 0...max(ceil(peak?.value ?? 1), 1))
        .chartXAxis {
          AxisMarks(values: [0.0, 6, 12, 18, 24]) { value in
            AxisValueLabel { Text(tr("%@時", Int(value.as(Double.self) ?? 0))).font(.system(size: 11)).foregroundStyle(C.textTertiary) }
          }
        }
        .chartYAxis {
          AxisMarks(position: .leading) { _ in
            AxisGridLine().foregroundStyle(L.hairlineSoft)
            AxisValueLabel().font(.system(size: 11)).foregroundStyle(C.textTertiary)
          }
        }
        .frame(height: 140)
        if average {
          note(tr("時間帯ごとの平均 · 最大 %@ 本(%@ 時台)", String(format: "%.1f", peak?.value ?? 0), Int(peak?.hour ?? 0)))
        } else if let peak {
          let parallel = AgentUsageSummary.seconds(figures?.todaySteps ?? [], atLeast: 2, until: .now)
          let at = today.addingTimeInterval(peak.hour * 3600).formatted(date: .omitted, time: .shortened)
          note(tr("最大 %@ 本(%@) · 2 本以上で並列していた時間 %@", Int(peak.value), at, Self.duration(parallel)))
        }
      }
    }
  }

  // MARK: ⑧–⑩ ランキング

  private var agents: some View {
    HStack(spacing: 10) {
      ForEach(summary?.providers ?? []) { item in
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            ProviderBrandIcon(provider: item.provider.rawValue, size: 16)
            Text(item.provider.rawValue).font(.system(size: 14)).foregroundStyle(C.textSecondary)
          }
          Text(tr("%@ 件", item.prompts)).font(.system(size: 18, weight: .semibold)).foregroundStyle(C.textPrimary).monospacedDigit()
          Text(item.sessionsWithoutCost > 0
            ? tr("推定 %@ · 費用不明 %@ セッション", String(format: "$%.2f", item.estimatedUSD), item.sessionsWithoutCost)
            : tr("推定 %@", String(format: "$%.2f", item.estimatedUSD)))
            .font(.system(size: 13)).foregroundStyle(C.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(C.canvas, in: RoundedRectangle(cornerRadius: Radius.card))
      }
    }
  }

  private var models: some View {
    let since: Date? = switch modelRange {
    case "7日": daysAgo(6)
    case "30日": daysAgo(29)
    default: nil
    }
    let rows = summary?.models(since: since) ?? []
    let total = rows.compactMap(\.usd).reduce(0, +)
    return Group {
      if rows.isEmpty {
        placeholder(tr("この期間に使われたモデルはありません。"))
      } else {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
          GridRow {
            Text("#"); Text(tr("モデル")); Text(tr("セッション")).gridColumnAlignment(.trailing)
            Text(tr("推定費用")).gridColumnAlignment(.trailing); Text(tr("割合"))
          }
          .font(.system(size: 13)).foregroundStyle(C.textTertiary)
          ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            Divider().overlay(L.hairlineSoft)
            GridRow {
              Text(row.usd == nil ? "—" : "\(index + 1)").foregroundStyle(C.textTertiary)
              HStack(spacing: 6) {
                ProviderBrandIcon(provider: row.provider.rawValue, size: 14)
                Text(row.name).font(.system(size: 14, design: .monospaced)).lineLimit(1).truncationMode(.middle)
              }
              Text("\(row.sessions)").monospacedDigit()
              Text(row.usd.map { String(format: "$%.2f", $0) } ?? tr("算出不可"))
                .foregroundStyle(row.usd == nil ? C.textTertiary : C.textPrimary).monospacedDigit()
              shareBar(row.usd.map { total > 0 ? $0 / total : 0 })
            }
            .font(.system(size: 14))
          }
        }
      }
    }
  }

  private func shareBar(_ share: Double?) -> some View {
    Group {
      if let share {
        Capsule().fill(C.surfaceActive)
          .overlay(alignment: .leading) {
            GeometryReader { proxy in Capsule().fill(C.textSecondary).frame(width: max(2, proxy.size.width * share)) }
          }
          .frame(width: 120, height: 6)
          .help(String(format: "%.1f%%", share * 100))
      } else {
        Color.clear.frame(width: 120, height: 6)
      }
    }
  }

  private var sessions: some View {
    let rows = summary?.costliestSessions(since: daysAgo(29), limit: 5) ?? []
    return Group {
      if rows.isEmpty {
        placeholder(tr("直近 30 日に費用を推定できたセッションはありません。"))
      } else {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
          GridRow {
            Text("#"); Text(tr("セッション")); Text("Project")
            Text(tr("依頼")).gridColumnAlignment(.trailing); Text(tr("推定")).gridColumnAlignment(.trailing); Text("")
          }
          .font(.system(size: 13)).foregroundStyle(C.textTertiary)
          ForEach(Array(rows.enumerated()), id: \.element.id) { index, history in
            let resumable = projects.contains { $0.path == history.project }
            Divider().overlay(L.hairlineSoft)
            GridRow {
              Text("\(index + 1)").foregroundStyle(C.textTertiary)
              HStack(spacing: 6) {
                ProviderBrandIcon(provider: history.provider.rawValue, size: 14)
                Text(history.title).lineLimit(1).truncationMode(.tail)
              }
              Text(history.project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—").foregroundStyle(C.textTertiary).lineLimit(1)
              Text("\(history.promptCount)").monospacedDigit()
              Text(String(format: "$%.2f", history.estimatedUSD ?? 0)).monospacedDigit()
              Button(tr("再開")) { onResume(history) }
                .font(.system(size: 13)).disabled(!resumable)
                .help(resumable ? tr("%@ をターミナルで開き、このチャットを再開", history.provider.rawValue)
                  : tr("このチャットのディレクトリを Project に追加すると再開できます"))
            }
            .font(.system(size: 14))
          }
        }
      }
    }
  }
}

/// ② One Sunday-first column per week for the last year, lightness by prompt count. Its own view so hovering a cell
/// re-renders the calendar, not the whole usage screen.
private struct ActivityCalendar: View {
  let days: [Date: AgentUsageDay]
  let provider: AgentHistory.Provider?
  @State private var hoveredDate: Date?
  private let calendar = Calendar.current

  private var today: Date { calendar.startOfDay(for: .now) }
  private func daysAgo(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: today) ?? today }

  private func count(on date: Date) -> Int {
    guard let usage = days[date] else { return 0 }
    return provider.map { usage.providerPrompts[$0] ?? 0 } ?? usage.prompts
  }

  /// 53 Sunday-first columns ending today.
  private var weeks: [[Date?]] {
    let first = daysAgo(364)
    let pad = calendar.component(.weekday, from: first) - 1
    let cells: [Date?] = Array(repeating: nil, count: pad) + (0...364).reversed().map { Optional(daysAgo($0)) }
    return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
  }

  private static func level(_ count: Int) -> Int {
    switch count {
    case 0: 0
    case 1...3: 1
    case 4...7: 2
    case 8...12: 3
    default: 4
    }
  }

  private static func fill(_ level: Int) -> Color {
    level == 0 ? C.surfaceActive : C.textSecondary.opacity([0, 0.25, 0.45, 0.7, 0.95][level])
  }

  private func detail(for date: Date) -> String {
    let usage = days[date]
    let lines = AgentHistory.Provider.allCases.compactMap { provider -> String? in
      guard let count = usage?.providerPrompts[provider], count > 0 else { return nil }
      return tr("%@: %@ 件", provider.rawValue, count)
    }
    return ([date.formatted(date: .complete, time: .omitted), tr("依頼・追記: %@ 件", usage?.prompts ?? 0)] + lines)
      .joined(separator: "\n")
  }

  var body: some View {
    let columns = weeks
    return VStack(alignment: .leading, spacing: 8) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: 2) {
          ForEach(columns.indices, id: \.self) { index in
            VStack(spacing: 2) {
              let firstOfMonth = columns[index].compactMap { $0 }.first { calendar.component(.day, from: $0) == 1 }
              Text(firstOfMonth.map { AgentUsageView.monthName(calendar.component(.month, from: $0)) } ?? " ")
                .font(.system(size: 10)).foregroundStyle(C.textTertiary).fixedSize().frame(width: 10, height: 14, alignment: .leading)
              ForEach(0..<7, id: \.self) { row in
                if row < columns[index].count, let date = columns[index][row] {
                  RoundedRectangle(cornerRadius: 2)
                    .fill(Self.fill(Self.level(count(on: date))))
                    .frame(width: 10, height: 10)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                      if hovering { hoveredDate = date } else if hoveredDate == date { hoveredDate = nil }
                    }
                    .overlay {
                      if hoveredDate == date {
                        RoundedRectangle(cornerRadius: 2).strokeBorder(C.textPrimary, lineWidth: 1).allowsHitTesting(false)
                      }
                    }
                    .anchorPreference(key: HoveredCellAnchor.self, value: .bounds) { hoveredDate == date ? $0 : nil }
                    .accessibilityLabel(detail(for: date))
                } else {
                  Color.clear.frame(width: 10, height: 10)
                }
              }
            }
          }
        }
        .padding(.top, 2)
      }
      .defaultScrollAnchor(.trailing)
      // An overlay, not a popover: a popover window covers the neighbouring cells and eats their hover.
      .overlayPreferenceValue(HoveredCellAnchor.self) { anchor in
        GeometryReader { proxy in
          if let anchor, let hoveredDate {
            let cell = proxy[anchor]
            Text(detail(for: hoveredDate))
              .font(.system(size: 13))
              .padding(12)
              .frame(minWidth: 190, alignment: .leading)
              .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
              .shadow(radius: 4)
              .fixedSize()
              .frame(width: 1, height: 1, alignment: .bottom)  // grows upward from the point below
              .position(x: cell.midX, y: cell.minY - 6)
              .allowsHitTesting(false)
          }
        }
      }
      HStack(spacing: 4) {
        Text(tr("直近 1 年 · 右端が今日"))
        Spacer()
        Text(tr("少"))
        ForEach(0..<5, id: \.self) { RoundedRectangle(cornerRadius: 2).fill(Self.fill($0)).frame(width: 10, height: 10) }
        Text(tr("多"))
      }
      .font(.system(size: 13)).foregroundStyle(C.textTertiary)
    }
  }
}

/// Everything the usage screen derives from a summary that is too costly to recompute on every body pass.
struct UsageFigures: Sendable {
  var today = 0, yesterday = 0, week = 0, previousWeek = 0
  var spark: [Int] = []
  var streak = 0, longest = 0
  var busiestHours: [Int] = []
  var weekdayHours: [[Int]] = []
  var waits: [AgentUsageSummary.Wait] = []
  var todaySteps: [AgentUsageSummary.Step] = []
  var averageByHour: [Double] = []
  var days: [Date: AgentUsageDay] = [:]

  init(_ summary: AgentUsageSummary, now: Date, calendar: Calendar = .current) {
    let today = calendar.startOfDay(for: now)
    func day(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: today) ?? today }
    func prompts(_ range: Range<Int>) -> Int { range.reduce(0) { $0 + summary.prompts(on: day($1), calendar: calendar) } }
    self.today = prompts(0..<1)
    yesterday = prompts(1..<2)
    week = prompts(0..<7)
    previousWeek = prompts(7..<14)
    spark = (0..<14).reversed().map { summary.prompts(on: day($0), calendar: calendar) }
    streak = summary.streak(now: now, calendar: calendar)
    longest = summary.longestStreak(calendar: calendar)
    busiestHours = summary.busiestHours(since: day(89), calendar: calendar)
    weekdayHours = summary.weekdayHours(since: day(89), calendar: calendar)
    waits = summary.waits(in: DateInterval(start: day(6), end: max(now, day(6))))
    todaySteps = summary.concurrency(in: DateInterval(start: today, end: max(now, today)))
    averageByHour = summary.averageConcurrencyByHour(dayCount: 7, now: now, calendar: calendar)
    days = Dictionary(summary.days.map { ($0.date, $0) }) { first, _ in first }
  }
}

private struct UsageCard<Accessory: View, Content: View>: View {
  let title: String
  var note: String? = nil
  @ViewBuilder var accessory: Accessory
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .center, spacing: 12) {
        Text(title).font(.system(size: 18, weight: .semibold)).foregroundStyle(C.textPrimary)
        Spacer(minLength: 0)
        if let note { Text(note).font(.system(size: 13)).foregroundStyle(C.textTertiary).lineLimit(1) }
        accessory
      }
      content
    }
    .padding(.horizontal, 22).padding(.vertical, 20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(C.chrome, in: RoundedRectangle(cornerRadius: Radius.card))
  }
}

extension UsageCard where Accessory == EmptyView {
  init(title: String, note: String? = nil, @ViewBuilder content: () -> Content) {
    self.init(title: title, note: note, accessory: { EmptyView() }, content: content)
  }
}

private struct UsageTile<Extra: View>: View {
  let title: String
  let value: String
  var unit: String? = nil
  var sub: String? = nil
  @ViewBuilder var extra: Extra

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(C.textTertiary)
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(C.textPrimary)
          .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        if let unit { Text(unit).font(.system(size: 13)).foregroundStyle(C.textTertiary) }
      }
      if let sub { Text(sub).font(.system(size: 13)).foregroundStyle(C.textTertiary).monospacedDigit() }
      extra
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(C.canvas, in: RoundedRectangle(cornerRadius: Radius.card))
  }
}

extension UsageTile where Extra == EmptyView {
  init(title: String, value: String, unit: String? = nil, sub: String? = nil) {
    self.init(title: title, value: value, unit: unit, sub: sub, extra: { EmptyView() })
  }
}

private struct HoveredCellAnchor: PreferenceKey {
  static let defaultValue: Anchor<CGRect>? = nil
  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = value ?? nextValue()
  }
}
