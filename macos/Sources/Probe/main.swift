import Foundation
import TuringSensors

// Prints every sensor reading, sampled over one second, as JSON (for comparing with the Python sensors).
let interfaces = CommandLine.arguments.dropFirst().isEmpty ? ["en0"] : Array(CommandLine.arguments.dropFirst())

_ = CPU.percentage(); _ = CPU.frequency(); _ = GPU.frequency()
for i in interfaces { _ = Net.stats(interface: i) }
Thread.sleep(forTimeInterval: 1)

let gpu = GPU.stats()
let mem = Memory.virtual()
let disk = Disk.usage()
let load = CPU.load()
var out: [String: Any] = [
    "cpu_percent": CPU.percentage(),
    "cpu_mhz": CPU.frequency(),
    "cpu_temp": CPU.temperature(),
    "load": [load.0, load.1, load.2],
    "gpu_available": GPU.isAvailable,
    "gpu_load": gpu.load, "gpu_mem_percent": gpu.memoryPercent, "gpu_mem_used_mb": gpu.memoryUsedMB,
    "gpu_mem_total_mb": gpu.memoryTotalMB, "gpu_temp": gpu.temperature, "gpu_mhz": GPU.frequency(),
    "mem_percent": mem.percent, "mem_used": mem.used, "mem_free": mem.free, "swap_percent": Memory.swapPercent(),
    "disk_percent": disk.percent, "disk_used": disk.used, "disk_free": disk.free,
    "uptime_s": System.uptime(),
]
for i in interfaces {
    if let n = Net.stats(interface: i) {
        out["net_\(i)"] = ["up_Bps": n.uploadRate, "uploaded": n.uploaded, "down_Bps": n.downloadRate, "downloaded": n.downloaded]
    }
}
let clean = out.mapValues { v -> Any in (v as? Double).map { $0.isNaN ? NSNull() : $0 as Any } ?? v }
let data = try JSONSerialization.data(withJSONObject: clean, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
