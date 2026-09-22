#if os(macOS)
  import AppKit
  import Darwin
  import QuartzCore

  /// `BUDGET-START-HALFBOUNCE` instrumentation
  /// (docs/benchmarks/clair-v2-performance-budget.md §1).
  ///
  /// Measures `exec` → first presented frame from inside the process, so the
  /// number does not depend on an external harness guessing when the app was
  /// spawned or when it drew. Off unless `CLAIR_STARTUP_TRACE` is set, so a
  /// normal launch pays nothing but one environment lookup.
  public enum ClairStartupTrace {
    @MainActor private static var reported = false

    /// Milliseconds since this process was `exec`d, or nil if the kernel will not say.
    ///
    /// `p_starttime` is the real exec time, which is earlier than anything the
    /// process itself can observe: a `main()`-relative measurement silently
    /// drops dyld, framework load and static initialisers, which are exactly
    /// the parts of startup most likely to regress.
    public static func millisecondsSinceExec() -> Double? {
      var info = kinfo_proc()
      var size = MemoryLayout<kinfo_proc>.stride
      var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
      guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
      let started = info.kp_proc.p_starttime
      let startedAt = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
      return (Date().timeIntervalSince1970 - startedAt) * 1_000
    }

    /// Arms a one-shot first-frame report if `CLAIR_STARTUP_TRACE` is set.
    ///
    /// - `CLAIR_STARTUP_TRACE=1` prints the measurement and keeps running.
    /// - `CLAIR_STARTUP_TRACE=exit` prints it and quits, so a runner can loop.
    ///
    /// The trigger is the first `didUpdate` of a visible window, and the
    /// measurement is taken in that runloop turn's CoreAnimation completion
    /// block, which runs after the render server committed — the first frame
    /// actually on screen.
    ///
    /// Deliberately not `didBecomeKey`: a launch that cannot take focus (a
    /// non-interactive shell, another app already frontmost) never becomes
    /// key, and the run would hang instead of reporting. Drawing does not
    /// depend on focus, so `didUpdate` measures the same thing and always fires.
    @MainActor public static func armIfRequested() {
      guard let mode = ProcessInfo.processInfo.environment["CLAIR_STARTUP_TRACE"],
        !mode.isEmpty
      else { return }
      NotificationCenter.default.addObserver(
        forName: NSWindow.didUpdateNotification, object: nil, queue: .main
      ) { _ in
        MainActor.assumeIsolated {
          guard !reported else { return }  // later updates are not the first frame
          reported = true
          CATransaction.begin()
          CATransaction.setCompletionBlock { MainActor.assumeIsolated { report(mode) } }
          CATransaction.commit()
        }
      }
      // Watchdog: a launch that never draws must fail loudly, not hang a
      // measurement run forever behind a window that never appeared.
      let deadline =
        Double(ProcessInfo.processInfo.environment["CLAIR_STARTUP_TIMEOUT"] ?? "") ?? 30
      DispatchQueue.main.asyncAfter(deadline: .now() + deadline) {
        MainActor.assumeIsolated {
          guard !reported else { return }
          reported = true
          print("clair.startup.no_frame_within_ms=\(Int(deadline * 1000))")
          fflush(stdout)
          if mode == "exit" { exit(2) }
        }
      }
    }

    @MainActor private static func report(_ mode: String) {
      let millis = millisecondsSinceExec() ?? -1
      // One line, fixed shape: `run-startup.sh` greps for this prefix.
      print(String(format: "clair.startup.first_frame_ms=%.2f", millis))
      fflush(stdout)
      // The measurement is already taken, so the quit path costs nothing here —
      // and it is the path that stops a daemon this launch may have started.
      if mode == "exit" { NSApp.terminate(nil) }
    }
  }
#endif
