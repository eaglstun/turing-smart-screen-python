import Darwin
import Foundation
import IOKit

// Readings mirror the Python sensor interface (library/sensors/sensors.py) and compute values the same way as
// library/sensors/sensors_python.py + apple_silicon.py, so themes render identically. Missing values are .nan.

public enum CPU {
    private static var lastTicks: (busy: UInt64, total: UInt64)?
    private static let frequencySampler = IOReport.Sampler(group: "CPU Stats", subgroup: "CPU Complex Performance States")
    private static let smc = SMC()
    private static let temperatureKeys: [String] = {
        guard let smc else { return [] }
        return smc.temperatureSensors(prefix: "Tp") + smc.temperatureSensors(prefix: "Te")
    }()

    /// CPU usage (%) across all cores since the previous call (like psutil.cpu_percent(interval=None)).
    public static func percentage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return .nan }
        let t = info.cpu_ticks
        let user = UInt64(t.0), system = UInt64(t.1), idle = UInt64(t.2), nice = UInt64(t.3)
        let busy = user + system + nice, total = busy + idle
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total else { return 0 }
        return Double(busy - last.busy) / Double(total - last.total) * 100
    }

    /// Frequency (MHz) of the busiest CPU cluster since the previous call.
    public static func frequency() -> Double {
        guard let sampler = frequencySampler, let e = PMGR.tables["E"], let p = PMGR.tables["P"] else { return .nan }
        let clusters = sampler.sample().compactMap { ch -> Double? in
            guard ["CPU", "CPU1", "CPU2", "CPU3"].contains(where: { ch.name.hasSuffix($0) }) else { return nil }
            return PMGR.averageMHz(ch, table: ch.name.hasPrefix("E") ? e : p)
        }
        return clusters.max() ?? .nan
    }

    /// 1 / 5 / 15 minute load averages.
    public static func load() -> (Double, Double, Double) {
        var l = [Double](repeating: .nan, count: 3)
        return getloadavg(&l, 3) == 3 ? (l[0], l[1], l[2]) : (.nan, .nan, .nan)
    }

    /// Average of the SMC CPU core sensors (°C).
    public static func temperature() -> Double {
        smc?.average(temperatureKeys) ?? .nan
    }
}

public enum GPU {
    public struct Stats {
        public let load: Double, memoryPercent: Double, memoryUsedMB: Double, memoryTotalMB: Double, temperature: Double
    }

    private static let service = IORegistry.service("IOAccelerator")
    private static let frequencySampler = IOReport.Sampler(group: "GPU Stats", subgroup: "GPU Performance States")
    private static let smc = SMC()
    private static let temperatureKeys = smc?.temperatureSensors(prefix: "Tg") ?? []

    public static var isAvailable: Bool { service != nil }

    /// Load and in-use memory from the GPU driver's PerformanceStatistics; memory is unified with system RAM.
    public static func stats() -> Stats {
        let nan = Stats(load: .nan, memoryPercent: .nan, memoryUsedMB: .nan, memoryTotalMB: .nan, temperature: .nan)
        guard let service, let perf = IORegistry.property(service, "PerformanceStatistics") as? [String: Any] else { return nan }
        let load = (perf["Device Utilization %"] as? NSNumber)?.doubleValue ?? .nan
        let usedMB = ((perf["In use system memory"] as? NSNumber)?.doubleValue ?? .nan) / 1_048_576
        let totalMB = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
        return Stats(load: load, memoryPercent: usedMB / totalMB * 100, memoryUsedMB: usedMB, memoryTotalMB: totalMB,
                     temperature: smc?.average(temperatureKeys) ?? .nan)
    }

    /// Average active GPU frequency (MHz) since the previous call; 0 if the GPU was off throughout.
    public static func frequency() -> Double {
        guard let sampler = frequencySampler, let table = PMGR.tables["GPU"] else { return .nan }
        guard let ph = sampler.sample().first(where: { $0.name == "GPUPH" }) else { return .nan }
        return PMGR.averageMHz(ph, table: table) ?? 0
    }
}

public enum Memory {
    /// (percent, used bytes, available bytes), computed like psutil: available = inactive + free; used = total - available.
    public static func virtual() -> (percent: Double, used: UInt64, free: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return (.nan, 0, 0) }
        let page = UInt64(vm_kernel_page_size)
        let total = ProcessInfo.processInfo.physicalMemory
        let available = (UInt64(stats.inactive_count) + UInt64(stats.free_count)) * page
        let used = total > available ? total - available : 0
        return ((Double(used) / Double(total) * 1000).rounded() / 10, used, available)
    }

    /// Swap usage (%), from vm.swapusage.
    public static func swapPercent() -> Double {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return .nan }
        return usage.xsu_total == 0 ? 0 : Double(usage.xsu_used) / Double(usage.xsu_total) * 100
    }
}

public enum Disk {
    /// On macOS "/" is the sealed system volume; user data lives on the Data volume of the same APFS container.
    static let path = FileManager.default.fileExists(atPath: "/System/Volumes/Data") ? "/System/Volumes/Data" : "/"

    /// (percent, used bytes, free bytes); used = total - free across the APFS container, as Finder reports.
    public static func usage() -> (percent: Double, used: UInt64, free: UInt64) {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return (.nan, 0, 0) }
        let total = UInt64(fs.f_blocks) * UInt64(fs.f_bsize)
        let free = UInt64(fs.f_bavail) * UInt64(fs.f_bsize)
        let used = total - free
        return (Double(used) / Double(total) * 100, used, free)
    }
}

public enum Net {
    private static var last: [String: (time: Double, sent: UInt64, received: UInt64)] = [:]

    /// 64-bit byte counters per interface (sysctl NET_RT_IFLIST2, as psutil uses).
    static func counters() -> [String: (sent: UInt64, received: UInt64)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [:] }
        var result: [String: (UInt64, UInt64)] = [:]
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(hdr.ifm_type) == RTM_IFINFO2 {
                    let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                    if if_indextoname(UInt32(msg.ifm_index), &name) != nil {
                        result[String(cString: name)] = (msg.ifm_data.ifi_obytes, msg.ifm_data.ifi_ibytes)
                    }
                }
                offset += Int(hdr.ifm_msglen)
            }
        }
        return result.mapValues { (sent: $0.0, received: $0.1) }
    }

    /// (upload rate B/s, uploaded B, download rate B/s, downloaded B) for one interface since the previous call.
    public static func stats(interface: String) -> (uploadRate: Double, uploaded: UInt64, downloadRate: Double, downloaded: UInt64)? {
        guard !interface.isEmpty, let c = counters()[interface] else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        defer { last[interface] = (now, c.sent, c.received) }
        guard let prev = last[interface], now > prev.time else { return (0, c.sent, 0, c.received) }
        let dt = now - prev.time
        return (Double(c.sent &- prev.sent) / dt, c.sent, Double(c.received &- prev.received) / dt, c.received)
    }
}

public enum System {
    /// Seconds since boot (kern.boottime).
    public static func uptime() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return .nan }
        return Date().timeIntervalSince1970 - (Double(boot.tv_sec) + Double(boot.tv_usec) / 1e6)
    }
}
