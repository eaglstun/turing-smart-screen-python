import Foundation
import IOKit

/// Per-core CPU activity and GPU activity for the menu bar popover (not used by themes).
///
/// An instance owns its IOReport subscriptions and SMC connection, so sampling it never disturbs the
/// since-last-call deltas behind `CPU.frequency()` / `GPU.frequency()` that the display's update loop reads.
public final class ChipActivity {
    public struct Core: Identifiable {
        public enum Kind { case efficiency, performance }
        /// IOReport channel name, e.g. "PCPU130" (P cluster 1, core 3).
        public let id: String
        public let kind: Kind
        public let cluster: Int
        public let index: Int
        /// Share of the interval the core was running (not idle, not powered down), 0...1.
        public let active: Double
        /// Share of the interval its cluster was powered down, 0...1.
        public let poweredDown: Double
        /// Residency-weighted frequency while running (MHz); nil if it never ran.
        public let mhz: Double?
    }

    public struct Cluster: Identifiable {
        /// "E", "P0", "P1"...
        public let id: String
        public let cores: [Core]
        public var active: Double { cores.map(\.active).reduce(0, +) / Double(max(cores.count, 1)) }
        public var poweredDown: Bool { cores.allSatisfy { $0.poweredDown > 0.5 } }
        /// Average frequency of its running cores, weighted by how long each ran (MHz).
        public var mhz: Double? {
            let running = cores.compactMap { c in c.mhz.map { (mhz: $0, weight: c.active) } }
            let weight = running.map(\.weight).reduce(0, +)
            return weight > 0 ? running.map { $0.mhz * $0.weight }.reduce(0, +) / weight : nil
        }
    }

    public struct GPUActivity {
        public let cores: Int?
        /// Device utilization (%).
        public let load: Double
        /// Average active frequency (MHz); 0 if the GPU was off throughout.
        public let mhz: Double
        public let temperature: Double
    }

    public struct Snapshot {
        public let clusters: [Cluster]
        public let performanceTemperature: Double
        public let efficiencyTemperature: Double
        public let gpu: GPUActivity
    }

    private let cpuSampler = IOReport.Sampler(group: "CPU Stats", subgroup: "CPU Core Performance States")
    private let gpuSampler = IOReport.Sampler(group: "GPU Stats", subgroup: "GPU Performance States")
    private let smc = SMC()
    private lazy var pKeys = smc?.temperatureSensors(prefix: "Tp") ?? []
    private lazy var eKeys = smc?.temperatureSensors(prefix: "Te") ?? []
    private lazy var gKeys = smc?.temperatureSensors(prefix: "Tg") ?? []

    private static let idleStates: Set<String> = ["IDLE", "DOWN", "OFF"]

    public init() {}

    /// Number of GPU cores, from the GPU driver's registry entry.
    public static let gpuCoreCount: Int? = {
        guard let service = IORegistry.service("IOAccelerator") else { return nil }
        defer { IOObjectRelease(service) }
        return (IORegistry.property(service, "gpu-core-count") as? NSNumber)?.intValue
    }()

    /// Activity since the previous call (since `init` for the first one).
    public func sample() -> Snapshot {
        let cores = (cpuSampler?.sample() ?? []).compactMap(Self.core)
        let clusters = Dictionary(grouping: cores) { $0.kind == .efficiency ? "E" : "P\($0.cluster)" }
            .map { Cluster(id: $0.key, cores: $0.value.sorted { $0.index < $1.index }) }
            .sorted { ($0.id == "E" ? "" : $0.id) < ($1.id == "E" ? "" : $1.id) }  // E first, then P0, P1...

        var gpuLoad = Double.nan
        if let service = IORegistry.service("IOAccelerator") {
            defer { IOObjectRelease(service) }
            let perf = IORegistry.property(service, "PerformanceStatistics") as? [String: Any]
            gpuLoad = (perf?["Device Utilization %"] as? NSNumber)?.doubleValue ?? .nan
        }
        var gpuMHz = Double.nan
        if let table = PMGR.tables["GPU"], let ph = gpuSampler?.sample().first(where: { $0.name == "GPUPH" }) {
            gpuMHz = PMGR.averageMHz(ph, table: table) ?? 0
        }
        return Snapshot(clusters: clusters,
                        performanceTemperature: smc?.average(pKeys) ?? .nan,
                        efficiencyTemperature: smc?.average(eKeys) ?? .nan,
                        gpu: GPUActivity(cores: Self.gpuCoreCount, load: gpuLoad, mhz: gpuMHz,
                                         temperature: smc?.average(gKeys) ?? .nan))
    }

    /// Parses "ECPU030" / "PCPU150": kind, cluster digit, core digit; residency shares; frequency.
    private static func core(_ channel: IOReport.Channel) -> Core? {
        let name = Array(channel.name)
        guard name.count == 7, name[1...3] == ["C", "P", "U"], let cluster = name[4].wholeNumberValue,
              let index = name[5].wholeNumberValue else { return nil }
        let kind: Core.Kind
        switch name[0] {
        case "E": kind = .efficiency
        case "P": kind = .performance
        default: return nil
        }
        let total = channel.states.map(\.residency).reduce(0, +)
        guard total > 0 else { return nil }
        let running = channel.states.filter { !idleStates.contains($0.name) }.map(\.residency).reduce(0, +)
        let down = channel.states.first { $0.name == "DOWN" }?.residency ?? 0
        let table = PMGR.tables[kind == .efficiency ? "E" : "P"]
        return Core(id: channel.name, kind: kind, cluster: cluster, index: index,
                    active: Double(running) / Double(total), poweredDown: Double(down) / Double(total),
                    mhz: table.flatMap { PMGR.averageMHz(channel, table: $0) })
    }
}
