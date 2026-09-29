import ClairDesignSystem
import ClairShared
import Charts
import Darwin
import SwiftUI

/// All of Clair: this app plus every descendant (daemon, shells, agents, language servers).
/// CPU is cumulative seconds per pid; memory is the physical footprint Activity Monitor shows.
struct ProcessSample: Equatable {
  var cpuSeconds: [pid_t: Double] = [:]
  var footprintBytes: [pid_t: UInt64] = [:]

  var totalFootprint: UInt64 { footprintBytes.values.reduce(0, +) }

  static func current(root: pid_t = getpid()) -> ProcessSample {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let ticksToSeconds = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    var sample = ProcessSample()
    for pid in descendants(of: root) {
      var info = rusage_info_v2()
      let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
      }
      guard ok == 0 else { continue }  // exited, or not ours to read
      sample.cpuSeconds[pid] = Double(info.ri_user_time + info.ri_system_time) * ticksToSeconds
      sample.footprintBytes[pid] = info.ri_phys_footprint
    }
    return sample
  }

  /// `root` and every process below it, from one scan of the process table.
  static func descendants(of root: pid_t) -> [pid_t] {
    let capacity = Int(proc_listallpids(nil, 0)) + 64
    var pids = [pid_t](repeating: 0, count: capacity)
    let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
    var children: [pid_t: [pid_t]] = [:]
    for pid in pids.prefix(max(count, 0)) where pid > 0 {
      var info = proc_bsdshortinfo()
      if proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size)) > 0 {
        children[pid_t(info.pbsi_ppid), default: []].append(pid)
      }
    }
    var result = [root], i = 0
    while i < result.count { result += children[result[i]] ?? []; i += 1 }
    return result
  }

  /// CPU percent of one core between two samples (over 100 on several cores, like Activity Monitor).
  /// A process born since `old` counts from zero; one that exited drops out.
  static func cpuPercent(from old: ProcessSample, to new: ProcessSample, interval: Double) -> Double {
    guard interval > 0 else { return 0 }
    let used = new.cpuSeconds.reduce(0.0) { $0 + max($1.value - (old.cpuSeconds[$1.key] ?? 0), 0) }
    return used / interval * 100
  }
}

/// Footer meter next to the quota meter: compact CPU/memory for all of Clair, detail in a hover popover.
struct ClairResourceMeter: View {
  private typealias C = DesignTokens.Color
  @State private var sample = ProcessSample()
  @State private var cpu: Double = 0
  @State private var hovered = false
  /// Last two minutes of (cpu %, footprint bytes), oldest first.
  @State private var history: [(cpu: Double, bytes: UInt64)] = []
  private let interval = 2.0

  var body: some View {
    let memory = Self.bytes(sample.totalFootprint)
    HStack(spacing: 6) {
      spark(history.map(\.cpu), tint: C.debugBlue).frame(width: 34, height: 12)
      Text("CPU \(Int(cpu.rounded()))% · \(memory)")
    }
    .foregroundStyle(C.textQuaternary)
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .popover(isPresented: $hovered, arrowEdge: .top) {
      let app = sample.footprintBytes[getpid()] ?? 0
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
        GridRow { Text("Clair 全体").font(.system(size: 14, weight: .semibold)); Text("") }
        row("CPU", String(format: "%.1f%%", cpu))
        GridRow { spark(history.map(\.cpu), tint: C.debugBlue).frame(height: 36).gridCellColumns(2) }
        row("メモリ", memory)
        GridRow { spark(history.map { Double($0.bytes) }, tint: C.success).frame(height: 36).gridCellColumns(2) }
        row("　アプリ本体", Self.bytes(app))
        row("　子プロセス", Self.bytes(sample.totalFootprint - app))
        row("プロセス数", "\(sample.footprintBytes.count)")
      }
      .font(Typography.font(Typography.chrome)).monospacedDigit()
      .frame(width: 240, alignment: .leading).padding(12)
    }
    .accessibilityElement(children: .combine)
    .task {
      // Off the main actor: the process-table scan is a few hundred syscalls.
      sample = await Task.detached(priority: .utility) { ProcessSample.current() }.value
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        let next = await Task.detached(priority: .utility) { ProcessSample.current() }.value
        cpu = ProcessSample.cpuPercent(from: sample, to: next, interval: interval)
        sample = next
        history = (history + [(cpu, next.totalFootprint)]).suffix(60)
      }
    }
  }

  /// Area sparkline from zero; no axes — the numbers sit in the row above it.
  private func spark(_ values: [Double], tint: Color) -> some View {
    Chart(Array(values.enumerated()), id: \.offset) { point in
      AreaMark(x: .value("t", point.offset), y: .value("v", point.element)).foregroundStyle(tint.opacity(0.25))
      LineMark(x: .value("t", point.offset), y: .value("v", point.element)).foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth: 1))
    }
    .chartXScale(domain: 0...59).chartXAxis(.hidden).chartYAxis(.hidden)
    .accessibilityHidden(true)
  }

  private static func bytes(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .memory) }

  private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
    GridRow {
      Text(title).foregroundStyle(C.textTertiary)
      Text(value).fontWeight(.semibold).gridColumnAlignment(.trailing)
    }
  }
}
