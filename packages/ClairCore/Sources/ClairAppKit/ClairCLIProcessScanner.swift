#if os(macOS)
  import ClairDaemonKit
  import Darwin
  import Foundation

  /// Identifies known CLI agents under shells owned by Clair's daemon. Process names are
  /// advisory UI facts; they never authorize commands or infer approval state.
  enum ClairCLIProcessScanner {
    struct ProcessInfo {
      let pid: Int32
      let parent: Int32
      let name: String
      var path = ""
    }

    static func profiles(shells: [String: Int32]) -> [String: String] {
      let processes = snapshot()
      return shells.compactMapValues { profile(shell: $0, processes: processes) }
    }

    static func profiles(keys: [String]) -> [String: String] {
      let client = ClairDaemonControlClient(paths: ClairDaemonLauncher.paths)
      var shells: [String: Int32] = [:]
      for key in keys {
        if case .processID(let pid)? = try? client.terminal(.processID(key: key)), let pid {
          shells[key] = pid
        }
      }
      return profiles(shells: shells)
    }

    static func profile(shell: Int32, processes: [ProcessInfo]) -> String? {
      let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
      for process in processes {
        // Claude's native installer runs `~/.local/share/claude/versions/<version>`, so its
        // process name is the version; name it by the directory that holds `versions/`.
        let parts = process.path.split(separator: "/")
        let name = parts.count > 2 && parts[parts.count - 2] == "versions"
          ? String(parts[parts.count - 3]) : process.name.lowercased()
        let profile: String? = switch name {
        case "claude": "claude"
        case "codex": "codex"
        case "opencode": "opencode"
        default: nil
        }
        guard let profile else { continue }
        var parent = process.parent
        var seen: Set<Int32> = [process.pid]
        while parent > 1, seen.insert(parent).inserted {
          if parent == shell { return profile }
          guard let next = byPID[parent] else { break }
          parent = next.parent
        }
        if process.pid == shell { return profile } // shell replaced itself with the CLI
      }
      return nil
    }

    private static func executablePath(_ pid: Int32) -> String {
      var buffer = [CChar](repeating: 0, count: 4096)  // PROC_PIDPATHINFO_MAXSIZE
      guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
      return String(cString: buffer)
    }

    private static func snapshot() -> [ProcessInfo] {
      var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
      var length = 0
      guard sysctl(&mib, 4, nil, &length, nil, 0) == 0 else { return [] }
      var entries = [kinfo_proc](repeating: kinfo_proc(), count: length / MemoryLayout<kinfo_proc>.stride + 128)
      let result = entries.withUnsafeMutableBufferPointer { buffer in
        sysctl(&mib, 4, buffer.baseAddress, &length, nil, 0)
      }
      guard result == 0 else { return [] }
      return entries.prefix(length / MemoryLayout<kinfo_proc>.stride).map { entry in
        let name = withUnsafeBytes(of: entry.kp_proc.p_comm) { bytes in
          String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        var info = ProcessInfo(pid: entry.kp_proc.p_pid, parent: entry.kp_eproc.e_ppid, name: name)
        if name.first?.isNumber == true { info.path = executablePath(info.pid) }  // version-named binaries only
        return info
      }
    }
  }
#endif
