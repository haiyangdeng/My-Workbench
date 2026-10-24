import Darwin
import Foundation

/// Processes started under a CLI. Killing the CLI's process group is not enough: Codex, for one, runs each shell command
/// in a new process group, and children of a CLI that has exited are re-parented to launchd. ProcessRunner records the
/// tree while the CLI runs and signals every recorded process that is still the same process (same PID and start time).
public enum ProcessTree {
    public struct Entry: Hashable, Sendable {
        public let pid: pid_t
        /// Start time in microseconds, so a reused PID is never mistaken for the recorded process.
        public let started: Int64
    }

    private static func all() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = processes.count * stride
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return [] }
        return Array(processes.prefix(size / stride))
    }

    private static func started(_ process: kinfo_proc) -> Int64 {
        Int64(process.kp_proc.p_starttime.tv_sec) * 1_000_000 + Int64(process.kp_proc.p_starttime.tv_usec)
    }

    /// Every process whose parent chain leads to `root`, not including `root`.
    public static func descendants(of root: pid_t) -> Set<Entry> {
        let processes = all()
        var children: [pid_t: [kinfo_proc]] = [:]
        for process in processes { children[process.kp_eproc.e_ppid, default: []].append(process) }
        var result: Set<Entry> = [], queue = [root], seen: Set<pid_t> = [root]
        while let parent = queue.popLast() {
            for child in children[parent] ?? [] where seen.insert(child.kp_proc.p_pid).inserted {
                result.insert(Entry(pid: child.kp_proc.p_pid, started: started(child)))
                queue.append(child.kp_proc.p_pid)
            }
        }
        return result
    }

    /// The recorded entries that are still running as the same process.
    public static func alive(_ entries: Set<Entry>) -> [Entry] {
        guard !entries.isEmpty else { return [] }
        let current = Dictionary(all().map { ($0.kp_proc.p_pid, started($0)) }, uniquingKeysWith: { first, _ in first })
        return entries.filter { current[$0.pid] == $0.started }
    }

    /// Signals each recorded process that is still the same process, and its process group when it leads one.
    public static func signal(_ entries: Set<Entry>, _ signal: Int32) {
        for entry in alive(entries) {
            if getpgid(entry.pid) == entry.pid { kill(-entry.pid, signal) }
            kill(entry.pid, signal)
        }
    }
}
