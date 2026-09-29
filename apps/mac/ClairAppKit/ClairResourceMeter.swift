import ClairDesignSystem
import ClairShared
import Darwin
import SwiftUI

/// Clair's own process footprint: CPU since the previous sample, and memory as Activity Monitor counts it.
struct ProcessSample: Equatable {
  var cpuSeconds: Double
  var footprintBytes: UInt64
  var peakBytes: UInt64
  var threads: Int

  static func current() -> ProcessSample {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    var threads: thread_act_array_t?
    var threadCount: mach_msg_type_number_t = 0
    if task_threads(mach_task_self_, &threads, &threadCount) == KERN_SUCCESS, let threads {
      for i in 0..<Int(threadCount) { mach_port_deallocate(mach_task_self_, threads[i]) }
      vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
    }
    // ru_maxrss is bytes on macOS.
    return ProcessSample(cpuSeconds: cpu, footprintBytes: kr == KERN_SUCCESS ? info.phys_footprint : 0,
                         peakBytes: UInt64(max(usage.ru_maxrss, 0)), threads: Int(threadCount))
  }

  /// CPU percent of one core between two samples (can exceed 100 on several cores, like Activity Monitor).
  static func cpuPercent(from old: ProcessSample, to new: ProcessSample, interval: Double) -> Double {
    guard interval > 0 else { return 0 }
    return max(new.cpuSeconds - old.cpuSeconds, 0) / interval * 100
  }
}

/// Footer meter next to the quota meter: compact CPU/memory, full detail in a hover popover.
struct ClairResourceMeter: View {
  private typealias C = DesignTokens.Color
  @State private var sample = ProcessSample.current()
  @State private var cpu: Double = 0
  @State private var hovered = false
  private let interval = 2.0

  var body: some View {
    let memory = ByteCountFormatter.string(fromByteCount: Int64(sample.footprintBytes), countStyle: .memory)
    HStack(spacing: 6) {
      Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 11))
      Text("CPU \(Int(cpu.rounded()))% · \(memory)")
    }
    .foregroundStyle(C.textQuaternary)
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .popover(isPresented: $hovered, arrowEdge: .top) {
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
        GridRow { Text("Clair").font(.system(size: 14, weight: .semibold)); Text("") }
        row("CPU", String(format: "%.1f%%", cpu))
        row("メモリ", memory)
        row("ピークメモリ", ByteCountFormatter.string(fromByteCount: Int64(sample.peakBytes), countStyle: .memory))
        row("スレッド", "\(sample.threads)")
      }
      .font(Typography.font(Typography.chrome)).monospacedDigit()
      .frame(width: 240, alignment: .leading).padding(12)
    }
    .accessibilityElement(children: .combine)
    .task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        let next = ProcessSample.current()
        cpu = ProcessSample.cpuPercent(from: sample, to: next, interval: interval)
        sample = next
      }
    }
  }

  private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
    GridRow {
      Text(title).foregroundStyle(C.textTertiary)
      Text(value).fontWeight(.semibold).gridColumnAlignment(.trailing)
    }
  }
}
