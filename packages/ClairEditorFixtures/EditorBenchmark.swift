import Foundation

/// Minimal harness for editor latency and memory measurements.
///
/// `E01` defines the harness shape and units. `E02`-`E10` will plug concrete editor
/// operations into it. Keeping the harness in the fixtures package lets every later
/// task depend on the same measurement contract.
public struct EditorBenchmark: Sendable {
  /// A single measured operation.
  public struct Operation: Sendable {
    public let name: String
    public let fixture: String
    public let iterations: Int
    public let closure: @Sendable () async throws -> Void

    public init(
      name: String,
      fixture: String,
      iterations: Int,
      closure: @escaping @Sendable () async throws -> Void
    ) {
      self.name = name
      self.fixture = fixture
      self.iterations = iterations
      self.closure = closure
    }
  }

  /// Result of one benchmark run.
  public struct Result: Sendable {
    public let operation: String
    public let fixture: String
    public let iterations: Int
    public let medianNanos: UInt64
    public let p95Nanos: UInt64
    public let maxRSSBytes: Int64
    public let unit: String

    public init(
      operation: String,
      fixture: String,
      iterations: Int,
      medianNanos: UInt64,
      p95Nanos: UInt64,
      maxRSSBytes: Int64,
      unit: String
    ) {
      self.operation = operation
      self.fixture = fixture
      self.iterations = iterations
      self.medianNanos = medianNanos
      self.p95Nanos = p95Nanos
      self.maxRSSBytes = maxRSSBytes
      self.unit = unit
    }
  }

  /// Run `operation` and report median, nearest-rank p95, and max RSS.
  public static func run(_ operation: Operation) async throws -> Result {
    var durations = [UInt64](repeating: 0, count: operation.iterations)
    var peakRSS: Int64 = 0

    for index in durations.indices {
      let start = DispatchTime.now().uptimeNanoseconds
      try await operation.closure()
      let end = DispatchTime.now().uptimeNanoseconds
      durations[index] = end - start
      peakRSS = max(peakRSS, currentMaxRSS())
    }

    durations.sort()
    let median = durations[durations.count / 2]
    let p95Index = Int((Double(durations.count) * 0.95).rounded(.up)) - 1
    let p95 = durations[max(0, min(p95Index, durations.count - 1))]

    return Result(
      operation: operation.name,
      fixture: operation.fixture,
      iterations: operation.iterations,
      medianNanos: median,
      p95Nanos: p95,
      maxRSSBytes: peakRSS,
      unit: "ns"
    )
  }

  /// Current process maximum resident set size, or -1 if unavailable.
  public static func currentMaxRSS() -> Int64 {
    var info = rusage()
    guard getrusage(RUSAGE_SELF, &info) == 0 else { return -1 }
    return Int64(info.ru_maxrss)
  }

  /// Print a result in a stable format suitable for regression tracking.
  public static func print(_ result: Result) {
    Swift.print("benchmark result:")
    Swift.print("  operation: \(result.operation)")
    Swift.print("  fixture: \(result.fixture)")
    Swift.print("  iterations: \(result.iterations)")
    Swift.print("  median: \(result.medianNanos) ns")
    Swift.print("  p95: \(result.p95Nanos) ns")
    Swift.print("  max_rss: \(result.maxRSSBytes) bytes")
  }
}
