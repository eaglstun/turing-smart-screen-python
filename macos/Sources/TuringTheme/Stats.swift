import Foundation

/// Sensor values the theme draws. Live readings come from TuringSensors; tests use fixed values.
/// Missing readings are .nan (or nil), and their widgets are hidden, like the Python app.
public protocol SensorSource {
    func cpuPercent() -> Double
    func cpuFrequencyMHz() -> Double
    func cpuLoad() -> (Double, Double, Double)
    func cpuTemperature() -> Double
    func cpuFanPercent() -> Double
    /// load %, memory %, memory used MB, memory total MB, temperature °C
    func gpuStats() -> (Double, Double, Double, Double, Double)
    func gpuFPS() -> Int
    func gpuFanPercent() -> Double
    func gpuFrequencyMHz() -> Double
    func swapPercent() -> Double
    func memoryPercent() -> Double
    func memoryUsed() -> Double   // bytes
    func memoryFree() -> Double   // bytes
    func diskPercent() -> Double
    func diskUsed() -> Double     // bytes
    func diskFree() -> Double     // bytes
    /// upload rate B/s, uploaded B, download rate B/s, downloaded B
    func net(_ interface: String) -> (Double, Double, Double, Double)
    func now() -> Date
    func uptimeSeconds() -> Int
    func pingMS() -> Double?
    /// temperature, felt, update time, description, humidity (nil = not configured)
    func weather() -> (String?, String?, String?, String?, String?)?
    /// Per-core CPU activity by cluster, for the `MACOS: CORE_GRID` widget; empty if unavailable.
    func cpuCores() -> [CoreCluster]
}

public extension SensorSource {
    func cpuCores() -> [CoreCluster] { [] }
}

/// One CPU cluster: the share of the last interval each core was running (0...1), and whether the whole cluster was
/// powered down.
public struct CoreCluster {
    public var efficiency: Bool
    public var active: [Double]
    public var poweredDown: Bool
    public init(efficiency: Bool, active: [Double], poweredDown: Bool) {
        (self.efficiency, self.active, self.poweredDown) = (efficiency, active, poweredDown)
    }
}

public struct StatsConfig {
    public var ethernet = "", wifi = "", locale = Locale(identifier: "en_US")
    public init(ethernet: String = "", wifi: String = "", locale: Locale = Locale(identifier: "en_US")) {
        (self.ethernet, self.wifi, self.locale) = (ethernet, wifi, locale)
    }
}

/// Port of library/stats.py: turns sensor values into themed widgets on a ThemeRenderer.
public final class ThemeStats {
    public let renderer: ThemeRenderer
    let source: SensorSource
    let config: StatsConfig
    private var history: [String: [Double]] = [:]
    private var hidden: Set<String> = []  // widgets switched off because their sensor is unsupported

    static let defaultHistory = 10

    public init(renderer: ThemeRenderer, source: SensorSource, config: StatsConfig = StatsConfig()) {
        (self.renderer, self.source, self.config) = (renderer, source, config)
        // The per-core grid takes the CPU usage bar's place in the macOS app
        if renderer.coreGrid != nil { hidden.insert("CPU.PERCENTAGE.GRAPH") }
    }

    var stats: ThemeNode { renderer.theme["STATS"] }

    // MARK: - Helpers (stats.py display_themed_*)

    private func node(_ path: [String]) -> ThemeNode { path.reduce(stats) { $0[$1] } }
    private func shown(_ path: [String]) -> Bool { !hidden.contains(path.joined(separator: ".")) && node(path).bool("SHOW", false) }

    private func save(_ value: Double, _ key: String, lineGraph: [String]) -> [Double] {
        let size = node(lineGraph).int("HISTORY_SIZE", Self.defaultHistory)
        var h = history[key] ?? []
        if h.count != size { h = [Double](repeating: .nan, count: size) }
        h.append(value); h.removeFirst()
        history[key] = h
        return h
    }

    /// Hide every widget of a stat whose sensor returns no value (stats.py does this once and logs a warning).
    private func hide(_ base: [String], _ kinds: [String] = ["TEXT", "GRAPH", "RADIAL", "LINE_GRAPH"]) {
        for k in kinds { hidden.insert((base + [k]).joined(separator: ".")) }
    }

    private static func pad(_ value: String, _ minSize: Int) -> String {
        value.count >= minSize ? value : String(repeating: " ", count: minSize - value.count) + value
    }

    func value(_ path: [String], _ value: String?, minSize: Int = 0, unit: String = "") {
        guard shown(path), let value else { return }
        let t = node(path)
        var text = Self.pad(value, t.int("MIN_SIZE", minSize))
        if t.bool("SHOW_UNIT", true) && !unit.isEmpty { text += unit }
        renderer.displayText(text, x: t.int("X", 0), y: t.int("Y", 0), width: t.int("WIDTH", 0), height: t.int("HEIGHT", 0),
                             font: renderer.fontPath(t.string("FONT", "roboto-mono/RobotoMono-Regular.ttf")),
                             fontSize: t.int("FONT_SIZE", 10), fontColor: t.color("FONT_COLOR", RGB(0, 0, 0)),
                             backgroundColor: t.color("BACKGROUND_COLOR", RGB(255, 255, 255)),
                             backgroundImage: renderer.themeFile(t["BACKGROUND_IMAGE"].string),
                             anchor: t.string("ANCHOR", "lt"))
    }

    func percent(_ path: [String], _ v: Double) { value(path, String(Int(v)), minSize: 3, unit: "%") }
    func temperature(_ path: [String], _ v: Double) { value(path, String(Int(v)), minSize: 3, unit: "°C") }

    func progress(_ path: [String], _ v: Double) {
        guard shown(path) else { return }
        let t = node(path)
        renderer.displayProgressBar(x: t.int("X", 0), y: t.int("Y", 0), width: t.int("WIDTH", 0), height: t.int("HEIGHT", 0),
                                    minValue: t.double("MIN_VALUE", 0), maxValue: t.double("MAX_VALUE", 100),
                                    value: Double(Int(v)), barColor: t.color("BAR_COLOR", RGB(0, 0, 0)),
                                    barOutline: t.bool("BAR_OUTLINE", false),
                                    backgroundColor: t.color("BACKGROUND_COLOR", RGB(255, 255, 255)),
                                    backgroundImage: renderer.themeFile(t["BACKGROUND_IMAGE"].string),
                                    reverse: t.bool("REVERSE_DIRECTION", false))
    }

    func radial(_ path: [String], value v: Double, text valueText: String, minSize: Int = 0, unit: String = "",
                customText: String? = nil) {
        guard shown(path) else { return }
        let t = node(path)
        var text = ""
        if t.bool("SHOW_TEXT", false) {
            if let customText, !customText.isEmpty { text = customText }
            else {
                text = Self.pad(valueText, minSize)
                if t.bool("SHOW_UNIT", true) && !unit.isEmpty { text += unit }
            }
        }
        renderer.displayRadialProgressBar(
            xc: t.int("X", 0), yc: t.int("Y", 0), radius: t.int("RADIUS", 1), barWidth: t.int("WIDTH", 1),
            minValue: t.double("MIN_VALUE", 0), maxValue: t.double("MAX_VALUE", 100),
            angleStart: t.double("ANGLE_START", 0), angleEnd: t.double("ANGLE_END", 360),
            angleSep: t.double("ANGLE_SEP", 0), angleSteps: t.int("ANGLE_STEPS", 1),
            clockwise: t.bool("CLOCKWISE", false), value: v, text: text,
            font: renderer.fontPath(t.string("FONT", "roboto-mono/RobotoMono-Regular.ttf")),
            fontSize: t.int("FONT_SIZE", 10), fontColor: t.color("FONT_COLOR", RGB(0, 0, 0)),
            barColor: t.color("BAR_COLOR", RGB(0, 0, 0)), backgroundColor: t.color("BACKGROUND_COLOR", RGB(0, 0, 0)),
            backgroundImage: renderer.themeFile(t["BACKGROUND_IMAGE"].string),
            customBBox: t["CUSTOM_BBOX"].list.compactMap(\.int), textOffset: t["TEXT_OFFSET"].list.compactMap(\.int),
            barBackgroundColor: t.color("BAR_BACKGROUND_COLOR", RGB(0, 0, 0)),
            drawBarBackground: t.bool("DRAW_BAR_BACKGROUND", false), barDecoration: t.string("BAR_DECORATION", ""))
    }

    func percentRadial(_ path: [String], _ v: Double) { radial(path, value: Double(Int(v)), text: String(Int(v)), minSize: 3, unit: "%") }
    func temperatureRadial(_ path: [String], _ v: Double) { radial(path, value: Double(Int(v)), text: String(Int(v)), minSize: 3, unit: "°C") }

    func lineGraph(_ path: [String], _ values: [Double]) {
        guard shown(path) else { return }
        let t = node(path)
        let lineColor = t.color("LINE_COLOR", RGB(0, 0, 0))
        renderer.displayLineGraph(x: t.int("X", 0), y: t.int("Y", 0), width: t.int("WIDTH", 1), height: t.int("HEIGHT", 1),
                                  values: values, minValue: t.double("MIN_VALUE", 0), maxValue: t.double("MAX_VALUE", 100),
                                  autoscale: t.bool("AUTOSCALE", false), lineColor: lineColor,
                                  lineWidth: t.int("LINE_WIDTH", 2), axis: t.bool("AXIS", false),
                                  axisColor: t.color("AXIS_COLOR", lineColor),
                                  axisFont: renderer.fontPath(t.string("AXIS_FONT", "roboto/Roboto-Black.ttf")),
                                  axisFontSize: t.int("AXIS_FONT_SIZE", 10),
                                  backgroundColor: t.color("BACKGROUND_COLOR", RGB(0, 0, 0)),
                                  backgroundImage: renderer.themeFile(t["BACKGROUND_IMAGE"].string))
    }

    /// The usual four widgets of a numeric stat (GRAPH, RADIAL, TEXT, LINE_GRAPH), hiding them if the value is missing.
    private func gauge(_ base: [String], _ v: Double, key: String, kind: Kind) {
        let h = save(v, key, lineGraph: base + ["LINE_GRAPH"])
        var v = v
        if v.isNaN { v = 0; hide(base) }
        progress(base + ["GRAPH"], v)
        switch kind {
        case .percent: percentRadial(base + ["RADIAL"], v); percent(base + ["TEXT"], v)
        case .temperature: temperatureRadial(base + ["RADIAL"], v); temperature(base + ["TEXT"], v)
        }
        lineGraph(base + ["LINE_GRAPH"], h)
    }

    private enum Kind { case percent, temperature }

    // MARK: - Python bytes2human / timedelta / babel

    static func bytes2human(_ n: Double, rate: Bool = false) -> String {
        let symbols = ["K", "M", "G", "T", "P", "E", "Z", "Y"]
        for (i, s) in symbols.enumerated().reversed() {
            let prefix = pow(2.0, Double((i + 1) * 10))
            if abs(n) >= prefix { return String(format: rate ? "%.1f %@/s" : "%.1f%@", n / prefix, s) }
        }
        return String(format: rate ? "%.1f B/s" : "%.1fB", n)
    }

    static func timedelta(_ seconds: Int) -> String {
        let d = seconds / 86400, rest = seconds % 86400
        let hms = String(format: "%d:%02d:%02d", rest / 3600, rest % 3600 / 60, rest % 60)
        return d == 0 ? hms : "\(d) day\(d == 1 ? "" : "s"), \(hms)"
    }

    func formatDate(_ date: Date, format: String, time: Bool) -> String {
        let f = DateFormatter()
        f.locale = config.locale
        let styles: [String: DateFormatter.Style] = ["short": .short, "medium": .medium, "long": .long, "full": .full]
        if let style = styles[format] {
            if time { f.timeStyle = style; f.dateStyle = .none } else { f.dateStyle = style; f.timeStyle = .none }
        } else {
            f.dateFormat = format
        }
        return f.string(from: date)
    }

    // MARK: - Stats (stats.py classes)

    public func cpuPercentage() {
        gauge(["CPU", "PERCENTAGE"], source.cpuPercent(), key: "cpu%", kind: .percent)
        coreGrid()
    }

    /// `display: MACOS: CORE_GRID`: one bar per CPU core, grouped by cluster, on the CPU usage interval.
    func coreGrid() {
        guard let g = renderer.coreGrid else { return }
        let accent = renderer.accentKey ?? RGB(10, 132, 255)
        renderer.displayCoreGrid(source.cpuCores(), x: g.int("X", 0), y: g.int("Y", 0), width: g.int("WIDTH", 0),
                                 height: g.int("HEIGHT", 0), performanceColor: g.color("P_COLOR", accent),
                                 efficiencyColor: g.color("E_COLOR", accent),
                                 trackColor: renderer.macos.color("TRACK_COLOR", RGB(255, 255, 255)),
                                 trackOpacity: renderer.macos.double("TRACK_OPACITY", 0.16),
                                 gap: g.int("GAP", 2), clusterGap: g.int("CLUSTER_GAP", 4),
                                 backgroundImage: renderer.themeFile(g["BACKGROUND_IMAGE"].string))
    }

    public func cpuFrequency() {
        let ghz = source.cpuFrequencyMHz() / 1000, base = ["CPU", "FREQUENCY"]
        let h = save(ghz, "cpufreq", lineGraph: base + ["LINE_GRAPH"])
        let s = String(format: "%.2f", ghz)
        value(base + ["TEXT"], s, minSize: 4, unit: " GHz")
        progress(base + ["GRAPH"], ghz)
        radial(base + ["RADIAL"], value: Double(s) ?? 0, text: s, minSize: 4, unit: " GHz")
        lineGraph(base + ["LINE_GRAPH"], h)
    }

    public func cpuLoad() {
        let l = source.cpuLoad()
        percent(["CPU", "LOAD", "ONE", "TEXT"], l.0)
        percent(["CPU", "LOAD", "FIVE", "TEXT"], l.1)
        percent(["CPU", "LOAD", "FIFTEEN", "TEXT"], l.2)
    }

    public func cpuTemperature() { gauge(["CPU", "TEMPERATURE"], source.cpuTemperature(), key: "cputemp", kind: .temperature) }
    public func cpuFanSpeed() { gauge(["CPU", "FAN_SPEED"], source.cpuFanPercent(), key: "cpufan", kind: .percent) }

    public func gpu() {
        var (load, memPct, memUsed, memTotal, temp) = source.gpuStats()
        var fps = source.gpuFPS()
        var fan = source.gpuFanPercent()
        let ghz = source.gpuFrequencyMHz() / 1000
        let hLoad = save(load, "gpu%", lineGraph: ["GPU", "PERCENTAGE", "LINE_GRAPH"])
        let hMem = save(memPct, "gpumem%", lineGraph: ["GPU", "MEMORY_PERCENT", "LINE_GRAPH"])
        let hTemp = save(temp, "gputemp", lineGraph: ["GPU", "TEMPERATURE", "LINE_GRAPH"])
        let hFps = save(Double(fps), "gpufps", lineGraph: ["GPU", "FPS", "LINE_GRAPH"])
        let hFan = save(fan, "gpufan", lineGraph: ["GPU", "FAN_SPEED", "LINE_GRAPH"])
        let hFreq = save(ghz, "gpufreq", lineGraph: ["GPU", "FREQUENCY", "LINE_GRAPH"])

        // Backward-compatible MEMORY section
        if memPct.isNaN { memPct = 0; hide(["GPU", "MEMORY"], ["GRAPH", "RADIAL"]) }
        if memUsed.isNaN { memUsed = 0; hide(["GPU", "MEMORY"], ["TEXT"]) }
        progress(["GPU", "MEMORY", "GRAPH"], memPct)
        percentRadial(["GPU", "MEMORY", "RADIAL"], memPct)
        value(["GPU", "MEMORY", "TEXT"], String(Int(memUsed)), minSize: 5, unit: " M")

        if load.isNaN { load = 0; hide(["GPU", "PERCENTAGE"]) }
        progress(["GPU", "PERCENTAGE", "GRAPH"], load)
        percentRadial(["GPU", "PERCENTAGE", "RADIAL"], load)
        percent(["GPU", "PERCENTAGE", "TEXT"], load)
        lineGraph(["GPU", "PERCENTAGE", "LINE_GRAPH"], hLoad)

        progress(["GPU", "MEMORY_PERCENT", "GRAPH"], memPct)
        percentRadial(["GPU", "MEMORY_PERCENT", "RADIAL"], memPct)
        percent(["GPU", "MEMORY_PERCENT", "TEXT"], memPct)
        lineGraph(["GPU", "MEMORY_PERCENT", "LINE_GRAPH"], hMem)

        value(["GPU", "MEMORY_USED", "TEXT"], String(Int(memUsed)), minSize: 5, unit: " M")
        if memTotal.isNaN { memTotal = 0; hide(["GPU", "MEMORY_TOTAL"], ["TEXT"]) }
        value(["GPU", "MEMORY_TOTAL", "TEXT"], String(Int(memTotal)), minSize: 5, unit: " M")

        if temp.isNaN { temp = 0; hide(["GPU", "TEMPERATURE"]) }
        temperature(["GPU", "TEMPERATURE", "TEXT"], temp)
        progress(["GPU", "TEMPERATURE", "GRAPH"], temp)
        temperatureRadial(["GPU", "TEMPERATURE", "RADIAL"], temp)
        lineGraph(["GPU", "TEMPERATURE", "LINE_GRAPH"], hTemp)

        if fps < 0 { fps = 0; hide(["GPU", "FPS"]) }
        progress(["GPU", "FPS", "GRAPH"], Double(fps))
        value(["GPU", "FPS", "TEXT"], String(fps), minSize: 4, unit: " FPS")
        radial(["GPU", "FPS", "RADIAL"], value: Double(fps), text: String(fps), minSize: 4, unit: " FPS")
        lineGraph(["GPU", "FPS", "LINE_GRAPH"], hFps)

        if fan.isNaN { fan = 0; hide(["GPU", "FAN_SPEED"]) }
        percent(["GPU", "FAN_SPEED", "TEXT"], fan)
        progress(["GPU", "FAN_SPEED", "GRAPH"], fan)
        percentRadial(["GPU", "FAN_SPEED", "RADIAL"], fan)
        lineGraph(["GPU", "FAN_SPEED", "LINE_GRAPH"], hFan)

        let s = String(format: "%.2f", ghz)
        value(["GPU", "FREQUENCY", "TEXT"], s, minSize: 4, unit: " GHz")
        progress(["GPU", "FREQUENCY", "GRAPH"], ghz)
        radial(["GPU", "FREQUENCY", "RADIAL"], value: Double(s) ?? 0, text: s, minSize: 4, unit: " GHz")
        lineGraph(["GPU", "FREQUENCY", "LINE_GRAPH"], hFreq)
    }

    public func memory() {
        let swap = source.swapPercent()
        let hSwap = save(swap, "swap", lineGraph: ["MEMORY", "SWAP", "LINE_GRAPH"])
        progress(["MEMORY", "SWAP", "GRAPH"], swap)
        percentRadial(["MEMORY", "SWAP", "RADIAL"], swap)
        lineGraph(["MEMORY", "SWAP", "LINE_GRAPH"], hSwap)

        let virt = source.memoryPercent()
        let hVirt = save(virt, "virt", lineGraph: ["MEMORY", "VIRTUAL", "LINE_GRAPH"])
        progress(["MEMORY", "VIRTUAL", "GRAPH"], virt)
        percentRadial(["MEMORY", "VIRTUAL", "RADIAL"], virt)
        percent(["MEMORY", "VIRTUAL", "PERCENT_TEXT"], virt)
        lineGraph(["MEMORY", "VIRTUAL", "LINE_GRAPH"], hVirt)
        let used = source.memoryUsed(), free = source.memoryFree(), mb = 1024.0 * 1024
        value(["MEMORY", "VIRTUAL", "USED"], String(Int(used / mb)), minSize: 5, unit: " M")
        value(["MEMORY", "VIRTUAL", "FREE"], String(Int(free / mb)), minSize: 5, unit: " M")
        value(["MEMORY", "VIRTUAL", "TOTAL"], String(Int((free + used) / mb)), minSize: 5, unit: " M")
    }

    public func disk() {
        let used = source.diskUsed(), free = source.diskFree(), pct = source.diskPercent()
        let h = save(pct, "disk", lineGraph: ["DISK", "USED", "LINE_GRAPH"])
        progress(["DISK", "USED", "GRAPH"], pct)
        percentRadial(["DISK", "USED", "RADIAL"], pct)
        percent(["DISK", "USED", "PERCENT_TEXT"], pct)
        lineGraph(["DISK", "USED", "LINE_GRAPH"], h)
        value(["DISK", "USED", "TEXT"], String(Int(used / 1e9)), minSize: 5, unit: " G")
        value(["DISK", "TOTAL", "TEXT"], String(Int((free + used) / 1e9)), minSize: 5, unit: " G")
        value(["DISK", "FREE", "TEXT"], String(Int(free / 1e9)), minSize: 5, unit: " G")
    }

    public func network() {
        for (card, iface) in [("WLO", config.wifi), ("ETH", config.ethernet)] {
            let (up, uploaded, down, downloaded) = source.net(iface)
            let hUp = save(up, "\(card)up", lineGraph: ["NET", card, "UPLOAD", "LINE_GRAPH"])
            value(["NET", card, "UPLOAD", "TEXT"], Self.bytes2human(up, rate: true), minSize: 10)
            value(["NET", card, "UPLOADED", "TEXT"], Self.bytes2human(uploaded), minSize: 6)
            lineGraph(["NET", card, "UPLOAD", "LINE_GRAPH"], hUp)
            let hDown = save(down, "\(card)down", lineGraph: ["NET", card, "DOWNLOAD", "LINE_GRAPH"])
            value(["NET", card, "DOWNLOAD", "TEXT"], Self.bytes2human(down, rate: true), minSize: 10)
            value(["NET", card, "DOWNLOADED", "TEXT"], Self.bytes2human(downloaded), minSize: 6)
            lineGraph(["NET", card, "DOWNLOAD", "LINE_GRAPH"], hDown)
        }
    }

    public func date() {
        let now = source.now()
        let day = ["DATE", "DAY", "TEXT"], hour = ["DATE", "HOUR", "TEXT"]
        value(day, formatDate(now, format: node(day).string("FORMAT", "medium"), time: false))
        value(hour, formatDate(now, format: node(hour).string("FORMAT", "medium"), time: true))
    }

    public func uptime() {
        let s = source.uptimeSeconds()
        value(["UPTIME", "SECONDS", "TEXT"], String(s))
        value(["UPTIME", "FORMATTED", "TEXT"], Self.timedelta(s))
    }

    public func ping() {
        let delay = source.pingMS() ?? .nan
        let h = save(delay, "ping", lineGraph: ["PING", "LINE_GRAPH"])
        guard !delay.isNaN else { return }
        progress(["PING", "GRAPH"], delay)
        radial(["PING", "RADIAL"], value: Double(Int(delay)), text: String(Int(delay)), minSize: 6, unit: "ms")
        value(["PING", "TEXT"], String(Int(delay)), minSize: 6, unit: "ms")
        lineGraph(["PING", "LINE_GRAPH"], h)
    }

    public func weather() {
        let w = stats["WEATHER"]
        let keys = ["TEMPERATURE", "TEMPERATURE_FELT", "UPDATE_TIME", "WEATHER_DESCRIPTION", "HUMIDITY"]
        guard keys.contains(where: { w[$0]["TEXT"].bool("SHOW", false) }), let (t, f, u, d, h) = source.weather() else { return }
        value(["WEATHER", "TEMPERATURE", "TEXT"], t)
        value(["WEATHER", "TEMPERATURE_FELT", "TEXT"], f)
        value(["WEATHER", "UPDATE_TIME", "TEXT"], u)
        value(["WEATHER", "HUMIDITY", "TEXT"], h)
        value(["WEATHER", "WEATHER_DESCRIPTION", "TEXT"], d)
    }

    /// Every stat once, in main.py's order.
    public func updateAll() {
        cpuPercentage(); cpuFrequency(); cpuLoad(); cpuTemperature(); cpuFanSpeed()
        gpu(); memory(); disk(); network(); date(); uptime(); ping(); weather()
    }
}
