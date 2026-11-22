import SwiftUI
import TuringSensors

/// Per-core CPU grid (one bar per core, grouped by cluster) and a GPU section, for the menu bar popover.
/// A bar's height is the share of the last second the core was running; a powered-down cluster shows outlined cores.
/// The GPU only reports activity for the whole GPU, so its section shows load split by pipeline stage and its
/// temperature sensors instead of per-core bars.
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
                gpuSection(s.gpu)
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

    private func gpuSection(_ gpu: ChipActivity.GPUActivity) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("GPU").font(.caption.bold())
                Spacer()
                Text([gpu.cores.map { "\($0) cores" }, Self.gigahertz(gpu.mhz.isFinite && gpu.mhz > 0 ? gpu.mhz : nil),
                      Self.celsius(gpu.temperature)].compactMap { $0 }.joined(separator: "  "))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            gpuBar("Load", gpu.load, help: "Share of time the GPU was busy")
            gpuBar("Render", gpu.rendererLoad, help: "Renderer: pixel (fragment) and compute work")
            gpuBar("Tiler", gpu.tilerLoad, help: "Tiler: geometry (vertex) work")
            sensorStrip(gpu.sensors)
        }
    }

    private static let gpuLabelWidth: CGFloat = 46, gpuValueWidth: CGFloat = 52

    private func gpuBar(_ label: String, _ value: Double, help: String) -> some View {
        let fraction = min(max((value.isFinite ? value : 0) / 100, 0), 1)
        return HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: Self.gpuLabelWidth, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5).fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 2.5).fill(Color.purple).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 7)
            Text(Self.percent(value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: Self.gpuValueWidth, alignment: .trailing)
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("GPU \(label.lowercased()), \(Self.percent(value))")
    }

    /// One cell per GPU temperature sensor, colored on a fixed 40-100 °C scale (blue to red); gray while parked.
    private func sensorStrip(_ sensors: [(key: String, celsius: Double?)]) -> some View {
        let readings = sensors.compactMap(\.celsius)
        let range = readings.isEmpty ? "–°"
            : "\(Self.celsius(readings.min()!))–\(Self.celsius(readings.max()!))".replacingOccurrences(of: "°–", with: "–")
        return HStack(spacing: 8) {
            Text("Sensors").font(.caption).foregroundStyle(.secondary).frame(width: Self.gpuLabelWidth, alignment: .leading)
            HStack(spacing: 1.5) {
                ForEach(sensors, id: \.key) { sensor in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(sensor.celsius.map(Self.heat) ?? Color.primary.opacity(0.08))
                        .frame(maxWidth: .infinity)
                        .help(sensor.celsius.map { String(format: "%@: %.1f °C", sensor.key, $0) } ?? "\(sensor.key): parked")
                }
            }
            .frame(height: 12)
            Text(range).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: Self.gpuValueWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("GPU temperature sensors, \(sensors.count) sensors, \(range)")
    }

    private static func heat(_ celsius: Double) -> Color {
        let t = min(max((celsius - 40) / 60, 0), 1)
        return Color(hue: 0.62 * (1 - t), saturation: 0.75, brightness: 0.95)
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
