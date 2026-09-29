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
  var names: [pid_t: String] = [:]
  var parents: [pid_t: pid_t] = [:]

  var totalFootprint: UInt64 { footprintBytes.values.reduce(0, +) }

  static func current(root: pid_t = getpid()) -> ProcessSample {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let ticksToSeconds = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    var sample = ProcessSample()
    let (pids, parents) = descendants(of: root)
    sample.parents = parents
    for pid in pids {
      var info = rusage_info_v2()
      let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
      }
      guard ok == 0 else { continue }  // exited, or not ours to read
      sample.cpuSeconds[pid] = Double(info.ri_user_time + info.ri_system_time) * ticksToSeconds
      sample.footprintBytes[pid] = info.ri_phys_footprint
      var name = [CChar](repeating: 0, count: 64)
      proc_name(pid, &name, UInt32(name.count))
      sample.names[pid] = String(cString: name)
    }
    return sample
  }

  /// `root` and every process below it, from one scan of the process table.
  static func descendants(of root: pid_t) -> (pids: [pid_t], parents: [pid_t: pid_t]) {
    let capacity = Int(proc_listallpids(nil, 0)) + 64
    var pids = [pid_t](repeating: 0, count: capacity)
    let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
    var children: [pid_t: [pid_t]] = [:], parents: [pid_t: pid_t] = [:]
    for pid in pids.prefix(max(count, 0)) where pid > 0 {
      var info = proc_bsdshortinfo()
      if proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size)) > 0 {
        children[pid_t(info.pbsi_ppid), default: []].append(pid)
        parents[pid] = pid_t(info.pbsi_ppid)
      }
    }
    var result = [root], i = 0
    while i < result.count { result += children[result[i]] ?? []; i += 1 }
    return (result, parents)
  }

  /// `root#pane` of the Clair terminal `pid` runs in, read from its inherited `CLAIR_TERMINAL_KEY`.
  /// Only our own user's processes are readable; anything else (or the daemon itself) is nil.
  static func terminalKey(of pid: pid_t) -> (root: String, pane: Int)? {
    guard let value = rawTerminalKey(of: pid), let hash = value.lastIndex(of: "#"),
      let pane = Int(value[value.index(after: hash)...]) else { return nil }
    return (String(value[..<hash]), pane)
  }

  private static func rawTerminalKey(of pid: pid_t) -> String? {
    arguments(of: pid)?.env.first { $0.hasPrefix("CLAIR_TERMINAL_KEY=") }.map { String($0.dropFirst("CLAIR_TERMINAL_KEY=".count)) }
  }

  /// The command the terminal is running on `pid`'s behalf: the daemon spawns one shell per terminal,
  /// so climb to the process whose parent is `ClairDaemon` (the shell) and print the job just below it.
  static func terminalCommand(of pid: pid_t, in sample: ProcessSample) -> String? {
    var chain = [pid]
    while let parent = sample.parents[chain.last!], parent > 1, chain.count < 64 {
      if sample.names[parent] == "ClairDaemon" { break }
      chain.append(parent)
    }
    guard chain.count >= 2, sample.names[sample.parents[chain.last!] ?? 0] == "ClairDaemon",
      let argv = arguments(of: chain[chain.count - 2])?.argv, let first = argv.first else { return nil }
    let line = ([(first as NSString).lastPathComponent] + argv.dropFirst()).joined(separator: " ")
    return line.count > 60 ? String(line.prefix(59)) + "…" : line
  }

  /// argv and environment of one of our own processes (`KERN_PROCARGS2`).
  static func arguments(of pid: pid_t) -> (argv: [String], env: [String])? {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
    // Layout: argc (Int32), exec path, NUL padding, argv[argc], then environment, all NUL-separated.
    let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
    let strings = buf[4..<size].split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
    let count = min(Int(argc), max(strings.count - 1, 0))
    return (Array(strings.dropFirst().prefix(count)), Array(strings.dropFirst(1 + count)))
  }

  /// CPU percent of one core between two samples (over 100 on several cores, like Activity Monitor).
  /// A process born since `old` counts from zero; one that exited drops out.
  static func cpuPercent(from old: ProcessSample, to new: ProcessSample, interval: Double) -> Double {
    perProcessCPU(from: old, to: new, interval: interval).values.reduce(0, +)
  }

  static func perProcessCPU(from old: ProcessSample, to new: ProcessSample, interval: Double) -> [pid_t: Double] {
    guard interval > 0 else { return [:] }
    return new.cpuSeconds.reduce(into: [:]) { $0[$1.key] = max($1.value - (old.cpuSeconds[$1.key] ?? 0), 0) / interval * 100 }
  }

  /// The `limit` heaviest processes: CPU first, memory breaks ties (idle processes sort by memory).
  static func top(_ sample: ProcessSample, cpu: [pid_t: Double], limit: Int = 5) -> [(pid: pid_t, name: String, cpu: Double, bytes: UInt64)] {
    sample.footprintBytes.map { (pid: $0.key, name: sample.names[$0.key] ?? "?", cpu: cpu[$0.key] ?? 0, bytes: $0.value) }
      .sorted { ($0.cpu.rounded(), $0.bytes) > ($1.cpu.rounded(), $1.bytes) }
      .prefix(limit).map { $0 }
  }
}

/// Footer meter next to the quota meter: compact CPU/memory for all of Clair, detail in a hover popover.
struct ClairResourceMeter: View {
  private typealias C = DesignTokens.Color
  /// Session title for a terminal pane (`root`, `pane`), if the workbench knows one.
  var sessionTitle: (String, Int) -> String = { _, pane in "ターミナル \(pane)" }
  @State private var sample = ProcessSample()
  @State private var cpu: Double = 0
  @State private var perProcess: [pid_t: Double] = [:]
  @State private var hovered = false
  /// Last two minutes of (cpu %, footprint bytes), oldest first.
  @State private var history: [(cpu: Double, bytes: UInt64)] = []
  private let interval = 2.0

  var body: some View {
    let memory = Self.bytes(sample.totalFootprint)
    HStack(spacing: 6) {
      Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 11))
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
        Divider().gridCellColumns(2)
        GridRow { Text("上位プロセス").font(.system(size: 13, weight: .semibold)); Text("") }
        ForEach(ProcessSample.top(sample, cpu: perProcess), id: \.pid) { p in
          GridRow {
            VStack(alignment: .leading, spacing: 1) {
              Text(p.pid == getpid() ? "Clair" : p.name).lineLimit(1).truncationMode(.middle)
              if let where_ = owner(p.pid) { Text(where_).foregroundStyle(C.textQuaternary).lineLimit(1).truncationMode(.middle) }
            }.help("pid \(p.pid)")
            Text(String(format: "%.0f%%", p.cpu) + " · " + Self.bytes(p.bytes)).gridColumnAlignment(.trailing)
          }
        }
      }
      .font(Typography.font(Typography.chrome)).monospacedDigit()
      .frame(width: 340, alignment: .leading).padding(12)
    }
    .accessibilityElement(children: .combine)
    .task {
      // Off the main actor: the process-table scan is a few hundred syscalls.
      sample = await Task.detached(priority: .utility) { ProcessSample.current() }.value
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        let next = await Task.detached(priority: .utility) { ProcessSample.current() }.value
        perProcess = ProcessSample.perProcessCPU(from: sample, to: next, interval: interval)
        cpu = perProcess.values.reduce(0, +)
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

  /// "project · session" for a process running in a Clair terminal.
  private func owner(_ pid: pid_t) -> String? {
    guard let key = ProcessSample.terminalKey(of: pid) else { return nil }
    let project = (key.root as NSString).lastPathComponent
    let command = ProcessSample.terminalCommand(of: pid, in: sample).map { " · " + $0 } ?? ""
    return "\(project) · " + sessionTitle(key.root, key.pane) + command
  }

  private static func bytes(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .memory) }

  private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
    GridRow {
      Text(title).foregroundStyle(C.textTertiary)
      Text(value).fontWeight(.semibold).gridColumnAlignment(.trailing)
    }
  }
}
