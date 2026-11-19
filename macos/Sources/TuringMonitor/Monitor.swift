import Foundation
import TuringTheme

/// Receives screen updates. The USB display driver implements this; tests can record or save them.
public protocol DisplaySink: AnyObject {
    /// Called on the sink queue with a region of the screen, already aligned to `alignment` pixels horizontally.
    func update(_ region: Bitmap, x: Int, y: Int)
    /// Horizontal alignment the sink needs for x and width (the rev. A USB transport wants 32-px blocks).
    var alignment: Int { get }
}

/// Runs a theme like main.py + library/scheduler.py: static content once, then each stat on its own interval
/// (INTERVAL 0 = never). After every stat update the changed regions are merged, aligned and sent to the sink.
public final class Monitor {
    public let renderer: ThemeRenderer
    let stats: ThemeStats
    private let queue = DispatchQueue(label: "monitor.render")
    private let sinkQueue = DispatchQueue(label: "monitor.sink")
    private var timers: [DispatchSourceTimer] = []
    public weak var sink: DisplaySink?

    /// Update counters, for status display and tests.
    public private(set) var updatesSent = 0, pixelsSent = 0

    public init(themeName: String, resDir: URL, sensors: SensorSource, config: StatsConfig, sink: DisplaySink?) throws {
        renderer = try ThemeRenderer(themeName: themeName, resDir: resDir)
        stats = ThemeStats(renderer: renderer, source: sensors, config: config)
        self.sink = sink
    }

    /// Jobs and their intervals, mirroring scheduler.py.
    private func jobs(gpuAvailable: Bool) -> [(name: String, interval: Double, run: () -> Void)] {
        let s = renderer.theme["STATS"]
        var list: [(String, Double, () -> Void)] = [
            ("cpu%", s["CPU"]["PERCENTAGE"].double("INTERVAL", 0), stats.cpuPercentage),
            ("cpufreq", s["CPU"]["FREQUENCY"].double("INTERVAL", 0), stats.cpuFrequency),
            ("cpuload", s["CPU"]["LOAD"].double("INTERVAL", 0), stats.cpuLoad),
            ("cputemp", s["CPU"]["TEMPERATURE"].double("INTERVAL", 0), stats.cpuTemperature),
            ("cpufan", s["CPU"]["FAN_SPEED"].double("INTERVAL", 0), stats.cpuFanSpeed),
            ("memory", s["MEMORY"].double("INTERVAL", 0), stats.memory),
            ("disk", s["DISK"].double("INTERVAL", 0), stats.disk),
            ("net", s["NET"].double("INTERVAL", 0), stats.network),
            ("date", s["DATE"].double("INTERVAL", 0), stats.date),
            ("uptime", s["UPTIME"].double("INTERVAL", 0), stats.uptime),
            ("ping", s["PING"].double("INTERVAL", 0), stats.ping),
        ]
        if gpuAvailable { list.append(("gpu", s["GPU"].double("INTERVAL", 0), stats.gpu)) }
        let weather = s["WEATHER"].double("INTERVAL", 0)
        if weather > 0 { list.append(("weather", max(300, weather), stats.weather)) }
        return list.filter { $0.1 > 0 }.map { (name: $0.0, interval: $0.1, run: $0.2) }
    }

    /// Draws the static content, sends a full frame, then starts every stat's timer.
    public func start(gpuAvailable: Bool = true) {
        queue.async { [self] in
            renderer.displayStaticImages()
            renderer.displayStaticText()
            renderer.dirty = [Rect(x0: 0, y0: 0, x1: renderer.width, y1: renderer.height)]
            flush()
            for job in jobs(gpuAvailable: gpuAvailable) {
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now(), repeating: job.interval, leeway: .milliseconds(50))
                t.setEventHandler { [weak self] in
                    job.run()
                    self?.flush()
                }
                t.resume()
                timers.append(t)
            }
        }
    }

    public func stop() {
        queue.sync {
            timers.forEach { $0.cancel() }
            timers.removeAll()
        }
        sinkQueue.sync {}  // let pending writes finish
    }

    /// A copy of the current screen, delivered on the main queue (for a live preview).
    public func snapshot(_ completion: @escaping (Bitmap) -> Void) {
        queue.async { [self] in
            let copy = renderer.screen
            DispatchQueue.main.async { completion(copy) }
        }
    }

    /// Runs a block on the sink queue, after any pending writes (e.g. to reconfigure the display).
    public func onSinkQueue(_ block: @escaping () -> Void) { sinkQueue.async(execute: block) }

    /// Redraws everything (e.g. after the display reconnects).
    public func redrawAll() {
        queue.async { [self] in
            renderer.dirty = [Rect(x0: 0, y0: 0, x1: renderer.width, y1: renderer.height)]
            flush()
        }
    }

    /// Merges dirty rects, aligns them for the sink, and queues copies of those regions to it. Runs on `queue`.
    private func flush() {
        let rects = Self.merge(renderer.dirty, alignment: sink?.alignment ?? 1, width: renderer.width)
        renderer.dirty.removeAll()
        guard let sink, !rects.isEmpty else { return }
        for r in rects {
            let region = renderer.screen.crop(x0: r.x0, y0: r.y0, x1: r.x1, y1: r.y1)
            updatesSent += 1
            pixelsSent += region.width * region.height
            sinkQueue.async { sink.update(region, x: r.x0, y: r.y0) }
        }
    }

    /// Aligns rects horizontally to `alignment` px and merges overlapping or touching ones.
    static func merge(_ rects: [Rect], alignment: Int, width: Int) -> [Rect] {
        var aligned = rects.compactMap { r -> Rect? in
            guard !r.isEmpty else { return nil }
            let a = max(1, alignment)
            return Rect(x0: r.x0 / a * a, y0: r.y0, x1: min(width, (r.x1 + a - 1) / a * a), y1: r.y1)
        }
        var merged = true
        while merged {
            merged = false
            outer: for i in 0..<aligned.count {
                for j in (i + 1)..<aligned.count {
                    if aligned[i].touches(aligned[j]) {
                        aligned[i] = aligned[i].union(aligned[j])
                        aligned.remove(at: j)
                        merged = true
                        break outer
                    }
                }
            }
        }
        return aligned
    }
}
