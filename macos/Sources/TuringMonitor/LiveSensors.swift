import Foundation
import TuringSensors
import TuringTheme

/// Live readings from TuringSensors in the shape the theme engine expects (library/sensors/sensors_python.py).
public final class LiveSensors: SensorSource {
    public var pingHost: String

    public init(pingHost: String = "8.8.8.8") { self.pingHost = pingHost }

    public func cpuPercent() -> Double { CPU.percentage() }
    public func cpuFrequencyMHz() -> Double { CPU.frequency() }
    public func cpuLoad() -> (Double, Double, Double) { CPU.load() }
    public func cpuTemperature() -> Double { CPU.temperature() }
    public func cpuFanPercent() -> Double { .nan }

    public func gpuStats() -> (Double, Double, Double, Double, Double) {
        let s = GPU.stats()
        return (s.load, s.memoryPercent, s.memoryUsedMB, s.memoryTotalMB, s.temperature)
    }
    public func gpuFPS() -> Int { -1 }
    public func gpuFanPercent() -> Double { .nan }
    public func gpuFrequencyMHz() -> Double { GPU.frequency() }

    public func swapPercent() -> Double { Memory.swapPercent() }
    public func memoryPercent() -> Double { Memory.virtual().percent }
    public func memoryUsed() -> Double { Double(Memory.virtual().used) }
    public func memoryFree() -> Double { Double(Memory.virtual().free) }

    public func diskPercent() -> Double { Disk.usage().percent }
    public func diskUsed() -> Double { Double(Disk.usage().used) }
    public func diskFree() -> Double { Double(Disk.usage().free) }

    public func net(_ interface: String) -> (Double, Double, Double, Double) {
        guard let s = Net.stats(interface: interface) else { return (0, 0, 0, 0) }
        return (s.uploadRate, Double(s.uploaded), s.downloadRate, Double(s.downloaded))
    }

    public func now() -> Date { Date() }
    public func uptimeSeconds() -> Int { Int(System.uptime()) }

    /// Round-trip time in ms via /sbin/ping (one packet, 1 s timeout); nil if unreachable.
    public func pingMS() -> Double? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/ping")
        p.arguments = ["-c", "1", "-t", "1", "-q", pingHost]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // "round-trip min/avg/max/stddev = 12.3/12.3/12.3/0.000 ms"
        guard let stats = text.split(separator: "=").last?.split(separator: "/"), stats.count >= 2 else { return nil }
        return Double(stats[1].trimmingCharacters(in: .whitespaces))
    }

    public func weather() -> (String?, String?, String?, String?, String?)? { nil }
}
