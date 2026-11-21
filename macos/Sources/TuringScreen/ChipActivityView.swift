import SwiftUI
import TuringSensors

/// Per-core CPU grid (one bar per core, grouped by cluster) and a GPU row, for the menu bar popover.
/// A bar's height is the share of the last second the core was running; a powered-down cluster shows outlined cores.
struct ChipActivityView: View {
    let snapshot: ChipActivity.Snapshot?

    private static let cellWidth: CGFloat = 13, cellHeight: CGFloat = 20, spacing: CGFloat = 3
    private static let barsWidth = 6 * cellWidth + 5 * spacing  // widest cluster, so rows line up

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("CPU").font(.caption.bold())
                Spacer()
                if let s = snapshot {
                    Text("P \(Self.celsius(s.performanceTemperature))  E \(Self.celsius(s.efficiencyTemperature))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let s = snapshot, !s.clusters.isEmpty {
                ForEach(s.clusters) { cluster in clusterRow(cluster) }
                Divider().padding(.vertical, 2)
                gpuRow(s.gpu)
            } else {
                Text(snapshot == nil ? "Sampling…" : "Per-core activity isn't available on this Mac")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 3 * Self.cellHeight, alignment: .center)
            }
        }
    }

    private func clusterRow(_ cluster: ChipActivity.Cluster) -> some View {
        HStack(spacing: 8) {
            Text(cluster.id).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 26, alignment: .leading)
            HStack(spacing: Self.spacing) {
                ForEach(cluster.cores) { core in coreCell(core, clusterID: cluster.id) }
            }
            .frame(width: Self.barsWidth, alignment: .leading)
            Spacer(minLength: 0)
            Group {
                if cluster.poweredDown {
                    Text("powered down").foregroundStyle(.tertiary)
                } else if cluster.mhz == nil {
                    Text("idle").foregroundStyle(.tertiary)
                } else {
                    Text("\(Self.gigahertz(cluster.mhz))  \(Self.percent(cluster.active * 100))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption.monospacedDigit())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cluster.poweredDown
            ? "\(cluster.id) cluster, powered down"
            : "\(cluster.id) cluster, \(cluster.cores.count) cores, \(Self.percent(cluster.active * 100)) active at \(Self.gigahertz(cluster.mhz))")
    }

    private func coreCell(_ core: ChipActivity.Core, clusterID: String) -> some View {
        let off = core.poweredDown > 0.5
        let tint: Color = core.kind == .efficiency ? .teal : .accentColor
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(off ? Color.clear : Color.primary.opacity(0.08))
            if off {
                RoundedRectangle(cornerRadius: 2.5)
                    .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            } else {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(tint)
                    .frame(height: max(1.5, Self.cellHeight * core.active))
            }
        }
        .frame(width: Self.cellWidth, height: Self.cellHeight)
        .help(off ? "\(clusterID) core \(core.index): powered down"
                  : "\(clusterID) core \(core.index): \(Self.percent(core.active * 100)) active at \(Self.gigahertz(core.mhz))")
    }

    private func gpuRow(_ gpu: ChipActivity.GPUActivity) -> some View {
        HStack(spacing: 8) {
            Text("GPU").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 26, alignment: .leading)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.5).fill(Color.primary.opacity(0.08))
                RoundedRectangle(cornerRadius: 2.5).fill(Color.purple)
                    .frame(width: Self.barsWidth * min(max((gpu.load.isFinite ? gpu.load : 0) / 100, 0), 1))
            }
            .frame(width: Self.barsWidth, height: 8)
            .help(gpu.cores.map { "\($0)-core GPU" } ?? "GPU")
            Spacer(minLength: 0)
            Text("\(Self.gigahertz(gpu.mhz.isFinite && gpu.mhz > 0 ? gpu.mhz : nil))  \(Self.percent(gpu.load))  \(Self.celsius(gpu.temperature))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("GPU, \(gpu.cores.map { "\($0) cores, " } ?? "")\(Self.percent(gpu.load)) busy at \(Self.gigahertz(gpu.mhz))")
    }

    private static func gigahertz(_ mhz: Double?) -> String {
        guard let mhz, mhz.isFinite, mhz > 0 else { return "– GHz" }
        return String(format: "%.1f GHz", mhz / 1000)
    }

    private static func percent(_ value: Double) -> String {
        value.isFinite ? String(format: "%.0f%%", value) : "–%"
    }

    private static func celsius(_ value: Double) -> String {
        value.isFinite ? String(format: "%.0f°", value) : "–°"
    }
}
