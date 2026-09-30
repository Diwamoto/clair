import Testing

@testable import ClairAppKit

#if os(macOS)
  @Suite
  struct ClairResourceMeterTests {
    @Test func cpuIsAShareOfAllCoresSoTheTotalStaysAtMost100() {
      // Two processes saturating 3 of 4 cores for the whole 2 s interval; one born mid-way.
      let old = ProcessSample(cpuSeconds: [1: 10, 2: 5])
      let new = ProcessSample(cpuSeconds: [1: 14, 2: 7, 3: 1])
      let cpu = ProcessSample.perProcessCPU(from: old, to: new, interval: 2, cores: 4)
      #expect(cpu == [1: 50, 2: 25, 3: 12.5])
      #expect(cpu.values.reduce(0, +) <= 100)
    }
  }
#endif
