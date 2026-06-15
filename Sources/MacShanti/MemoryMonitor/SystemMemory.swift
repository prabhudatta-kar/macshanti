import Foundation
import Darwin
import AppKit

/// Low-level system memory + per-process sampling via Mach / libproc / sysctl.
///
/// - `host_statistics64(HOST_VM_INFO64)` → page-level memory accounting.
/// - `sysctlbyname("vm.swapusage")`      → swap totals.
/// - `proc_listpids` + `proc_pidinfo`    → per-process RSS and CPU time.
enum SystemMemory {

    // MARK: - Aggregate memory

    struct Aggregate {
        let totalBytes: UInt64
        let usedBytes: UInt64
        let freeBytes: UInt64
        let swapUsedBytes: UInt64
        let swapTotalBytes: UInt64
        /// `kern.memorystatus_vm_pressure_level`: 1 = normal, 2 = warning, 4 = critical.
        let kernelPressureRaw: Int32
    }

    static func aggregate() -> Aggregate {
        let pageSize = machPageSize()
        let total = ProcessInfo.processInfo.physicalMemory

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        var used: UInt64 = 0
        var free: UInt64 = 0
        if kr == KERN_SUCCESS {
            // "App memory" + wired + compressed approximates the macOS notion of
            // memory in use; inactive/free/speculative pages are reclaimable.
            let active = UInt64(stats.active_count) * pageSize
            let wired = UInt64(stats.wire_count) * pageSize
            let compressed = UInt64(stats.compressor_page_count) * pageSize
            free = UInt64(stats.free_count + stats.inactive_count) * pageSize
            used = active + wired + compressed
        } else {
            // Conservative fallback.
            free = 0
            used = total
        }

        let swap = swapUsage()
        return Aggregate(totalBytes: total,
                         usedBytes: min(used, total),
                         freeBytes: free,
                         swapUsedBytes: swap.used,
                         swapTotalBytes: swap.total,
                         kernelPressureRaw: kernelPressureLevel())
    }

    /// The kernel's live memory-pressure verdict — the same signal behind
    /// Activity Monitor's memory-pressure graph. Defaults to "normal" (1) if the
    /// sysctl is unavailable.
    private static func kernelPressureLevel() -> Int32 {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.stride
        let result = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        guard result == 0, level != 0 else { return 1 }
        return level
    }

    private static func machPageSize() -> UInt64 {
        var size: vm_size_t = 0
        host_page_size(mach_host_self(), &size)
        return UInt64(size)
    }

    private static func swapUsage() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        guard result == 0 else { return (0, 0) }
        return (UInt64(usage.xsu_used), UInt64(usage.xsu_total))
    }

    // MARK: - Per-process sampling

    /// PROC_PIDTASKINFO flavor for `proc_pidinfo`.
    private static let pidTaskInfoFlavor: Int32 = 4
    /// PROC_ALL_PIDS type for `proc_listpids`.
    private static let allPidsType: UInt32 = 1

    /// Returns one sample per accessible process with RSS and cumulative CPU time.
    static func processSamples() -> [ProcessSample] {
        let pids = listAllPIDs()

        // Map pid → running GUI application for friendly names + bundle ids.
        var appByPID: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            appByPID[app.processIdentifier] = app
        }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1

        var samples: [ProcessSample] = []
        samples.reserveCapacity(pids.count)

        for pid in pids where pid > 0 {
            guard let info = taskInfo(for: pid) else { continue }

            let rss = UInt64(info.pti_resident_size)
            // pti_total_user / pti_total_system are in nanoseconds.
            let cpuSeconds = Double(info.pti_total_user &+ info.pti_total_system) / 1_000_000_000.0

            let runningApp = appByPID[pid]
            let name = runningApp?.localizedName ?? processName(for: pid) ?? "pid \(pid)"
            let bundleId = runningApp?.bundleIdentifier

            samples.append(ProcessSample(
                pid: pid,
                name: name,
                bundleIdentifier: bundleId,
                rssBytes: rss,
                cpuTimeSeconds: cpuSeconds,
                isFrontmost: pid == frontPID
            ))
        }
        return samples
    }

    private static func listAllPIDs() -> [pid_t] {
        let needed = proc_listpids(allPidsType, 0, nil, 0)
        guard needed > 0 else { return [] }
        let count = Int(needed) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: count)
        let written = proc_listpids(allPidsType, 0, &pids, needed)
        guard written > 0 else { return [] }
        let actual = Int(written) / MemoryLayout<pid_t>.stride
        return Array(pids.prefix(actual))
    }

    private static func taskInfo(for pid: pid_t) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        let result = proc_pidinfo(pid, pidTaskInfoFlavor, 0, &info, size)
        return result == size ? info : nil
    }

    private static func processName(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
