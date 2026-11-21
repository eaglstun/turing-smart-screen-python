import CoreGraphics
import Foundation

/// A screen rectangle (x0, y0 inclusive; x1, y1 exclusive).
public struct Rect: Equatable {
    public var x0: Int, y0: Int, x1: Int, y1: Int
    public init(x0: Int, y0: Int, x1: Int, y1: Int) { (self.x0, self.y0, self.x1, self.y1) = (x0, y0, x1, y1) }
    public var isEmpty: Bool { x1 <= x0 || y1 <= y0 }
    /// Overlapping or touching.
    public func touches(_ o: Rect) -> Bool {
        let h = x0 <= o.x1 && o.x0 <= x1
        let v = y0 <= o.y1 && o.y0 <= y1
        return h && v
    }
    public func union(_ o: Rect) -> Rect {
        Rect(x0: min(x0, o.x0), y0: min(y0, o.y0), x1: max(x1, o.x1), y1: max(y1, o.y1))
    }
}

/// Draws a theme onto an in-memory screen, porting library/lcd/lcd_comm.py's Display* functions.
/// Every draw records the rectangle it changed in `dirty`, for sending partial updates to the display.
public final class ThemeRenderer {
    public let theme: ThemeNode
    public let themeDir: URL
    public let fontsDir: URL
    public private(set) var screen: Bitmap
    public var dirty: [Rect] = []

    private var imageCache: [String: Bitmap] = [:]

    /// The theme's `display: MACOS:` section (macOS app only; see Backdrop).
    public var macos: ThemeNode { theme["display"]["MACOS"] }
    /// Theme image the desktop wallpaper replaces, if the theme asks for it.
    public var wallpaperFile: String? { themeFile(macos["WALLPAPER"].string) }
    /// The theme color drawn in the system accent color instead, if the theme asks for it.
    public var accentKey: RGB? { RGB(macos["ACCENT_COLOR"]) }
    /// The system accent color (set by the app); nil keeps the theme's own color.
    public var accent: RGB?
    /// The per-core CPU grid (`MACOS: CORE_GRID`), if the theme has one.
    public var coreGrid: ThemeNode? { macos["CORE_GRID"].isMap ? macos["CORE_GRID"] : nil }
    private var textBBoxCache: [String: (Int, Int, Int, Int)] = [:]

    public var width: Int { screen.width }
    public var height: Int { screen.height }

    /// Loads res/themes/<name>/theme.yaml with res/themes/default.yaml filled in (library/config.py load_theme).
    public init(themeName: String, resDir: URL) throws {
        themeDir = resDir.appendingPathComponent("themes/\(themeName)")
        fontsDir = resDir.appendingPathComponent("fonts")
        let defaults = try ThemeNode.load(resDir.appendingPathComponent("themes/default.yaml"))
        theme = try ThemeNode.load(themeDir.appendingPathComponent("theme.yaml")).withDefaults(defaults)
        let (w, h) = ThemeRenderer.size(theme)
        screen = Bitmap(width: w, height: h, fill: RGB(255, 255, 255))
    }

    /// Screen size for the theme's DISPLAY_SIZE and orientation (library/display.py _get_theme_size).
    static func size(_ theme: ThemeNode) -> (Int, Int) {
        let sizes: [String: (Int, Int)] = [
            "0.96\"": (80, 160), "2.1\"": (480, 480), "2.8\"": (480, 480), "3.5\"": (320, 480), "4.6\"": (320, 960),
            "5\"": (480, 800), "5.2\"": (720, 1280), "8\"": (800, 1280), "8.8\"": (480, 1920), "9.2\"": (480, 1920),
            "12.3\"": (720, 1920),
        ]
        let (w, h) = sizes[theme["display"].string("DISPLAY_SIZE", "3.5\"")] ?? (320, 480)
        return theme["display"].string("DISPLAY_ORIENTATION", "portrait") == "landscape" ? (h, w) : (w, h)
    }

    public var isLandscape: Bool { theme["display"].string("DISPLAY_ORIENTATION", "portrait") == "landscape" }

    // MARK: - Resources

    func themeFile(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        return themeDir.appendingPathComponent(name).path
    }

    /// A theme font file, or the system font standing in for it when the theme sets MACOS: SYSTEM_FONTS.
    func fontPath(_ name: String) -> String {
        let path = fontsDir.appendingPathComponent(name).path
        guard macos.bool("SYSTEM_FONTS", false) else { return path }
        if let spec = systemFontSpecs[path] { return spec }
        let spec = Font.systemSpec(forFile: path) ?? "system:400"
        systemFontSpecs[path] = spec
        return spec
    }
    private var systemFontSpecs: [String: String] = [:]

    /// Swaps the theme's accent color for the system one.
    @inline(__always) func ink(_ c: RGB) -> RGB {
        if let accent, let accentKey, c == accentKey { return accent }
        return c
    }

    /// Replaces the theme's wallpaper image with `image` composed as a backdrop (nil restores the theme's file).
    /// Redraw everything afterwards.
    public func setWallpaper(_ image: CGImage?) {
        guard let file = wallpaperFile else { return }
        // The grid replaces a capsule track (kept in the YAML so a baked background still has it for Python)
        let skip = Set([coreGrid?["REPLACES_TRACK"].string].compactMap { $0 })
        imageCache[file] = image.flatMap {
            Backdrop.compose($0, width: width, height: height, style: macos, skippingTracks: skip)
        }
    }

    func image(_ path: String) -> Bitmap? {
        if let b = imageCache[path] { return b }
        let b = Bitmap.load(URL(fileURLWithPath: path))
        imageCache[path] = b
        return b
    }

    private func paste(_ region: Bitmap, x: Int, y: Int) {
        screen.paste(region, x: x, y: y)
        let r = Rect(x0: max(0, x), y0: max(0, y), x1: min(width, x + region.width), y1: min(height, y + region.height))
        if !r.isEmpty { dirty.append(r) }
    }

    /// Background region: a crop of the background image, or a solid color.
    private func background(_ path: String?, color: RGB, x0: Int, y0: Int, x1: Int, y1: Int) -> Bitmap {
        if let path, let bg = image(path) { return bg.crop(x0: x0, y0: y0, x1: x1, y1: y1) }
        return Bitmap(width: x1 - x0, height: y1 - y0, fill: color)
    }

    // MARK: - lcd_comm.py

    public func displayBitmap(_ path: String, x: Int = 0, y: Int = 0, width w: Int = 0, height h: Int = 0) {
        guard var img = image(path) else { return }
        if w != 0 && h != 0 && (w != img.width || h != img.height) { img = img.resized(width: w, height: h) }
        paste(img.crop(x0: 0, y0: 0, x1: min(img.width, width - x), y1: min(img.height, height - y)), x: x, y: y)
    }

    public func displayText(_ text: String, x: Int, y: Int, width w: Int = 0, height h: Int = 0, font: String,
                            fontSize: Int, fontColor: RGB, backgroundColor: RGB, backgroundImage: String?,
                            anchor: String = "la") {
        guard !text.isEmpty, fontSize > 0, let f = Font.load(font, size: fontSize) else { return }
        let layout = TextLayout(text, font: f)
        var (x, y, w, h) = (x, y, w, h)
        if w > 0 && h == 0 { h = fontSize }
        var box: (Int, Int, Int, Int)
        if w == 0 || h == 0 {
            box = layout.bbox(x: x, y: y, anchor: anchor)
            // Union with the area drawn last time at this origin, so a shorter value erases the old one
            let key = "\(x),\(y)"
            if let prev = textBBoxCache[key] {
                textBBoxCache[key] = box
                box = (min(box.0, prev.0), min(box.1, prev.1), max(box.2, prev.2), max(box.3, prev.3))
            } else {
                textBBoxCache[key] = box
            }
        } else {
            box = (x, y, x + w, y + h)
            let a = Array(anchor)
            x = a.first == "m" ? Int(Double(box.2 + box.0) / 2) : a.first == "r" ? box.2 : box.0
            y = a.last == "m" ? Int(Double(box.3 + box.1) / 2) : a.last == "b" ? box.3 : box.1
        }
        let l = max(box.0, 0), t = max(box.1, 0), r = min(box.2, width), b = min(box.3, height)
        guard r > l, b > t else { return }
        var region = background(backgroundImage, color: ink(backgroundColor), x0: l, y0: t, x1: r, y1: b)
        layout.draw(into: &region, x: x - l, y: y - t, anchor: anchor, color: ink(fontColor))
        paste(region, x: l, y: t)
    }

    public func displayProgressBar(x: Int, y: Int, width w: Int, height h: Int, minValue: Double, maxValue: Double,
                                   value: Double, barColor themeBarColor: RGB, barOutline: Bool, backgroundColor: RGB,
                                   backgroundImage: String?, reverse: Bool) {
        guard w > 0, h > 0, x + w <= width, y + h <= height, maxValue != minValue else { return }
        let barColor = ink(themeBarColor)
        let v = min(max(value, minValue), maxValue)
        var bar = background(backgroundImage, color: backgroundColor, x0: x, y0: y, x1: x + w, y1: y + h)
        let frac = (v - minValue) / (maxValue - minValue)
        var (x1, y1, x2, y2) = (0.0, 0.0, Double(w - 1), Double(h - 1))
        if w > h {
            let filled = max(0, frac * Double(w) - 1)
            if reverse { x1 = Double(w - 1) - filled } else { x2 = filled }
        } else {
            let filled = max(0, frac * Double(h) - 1)
            if reverse { y2 = filled } else { y1 = Double(h - 1) - filled }
        }
        bar.rectangle(x1, y1, x2, y2, fill: barColor, outline: barColor)
        if barOutline { bar.rectangle(0, 0, Double(w - 1), Double(h - 1), fill: nil, outline: barColor) }
        paste(bar, x: x, y: y)
    }

    /// Per-core CPU bars (macOS app only): cores side by side, `gap` px apart, `clusterGap` px between clusters, centered
    /// in the box. A core's track is filled from the bottom by its activity; a powered-down cluster shows only a 1 px
    /// baseline per core.
    public func displayCoreGrid(_ clusters: [CoreCluster], x: Int, y: Int, width w: Int, height h: Int,
                                performanceColor: RGB, efficiencyColor: RGB, trackColor: RGB, trackOpacity: Double,
                                gap: Int, clusterGap: Int, backgroundImage: String?) {
        guard w > 0, h > 0, x >= 0, y >= 0, x + w <= width, y + h <= height else { return }
        var region = background(backgroundImage, color: RGB(0, 0, 0), x0: x, y0: y, x1: x + w, y1: y + h)
        let n = clusters.map(\.active.count).reduce(0, +)
        if n > 0 {
            let gaps = (n - clusters.count) * gap + (clusters.count - 1) * clusterGap
            let cell = max(1, (w - gaps) / n)
            var cx = max(0, (w - cell * n - gaps) / 2)
            let trackAlpha = UInt8(min(max(trackOpacity, 0), 1) * 255)
            for (i, cluster) in clusters.enumerated() {
                if i > 0 { cx += clusterGap - gap }
                let color = ink(cluster.efficiency ? efficiencyColor : performanceColor)
                for active in cluster.active {
                    if cluster.poweredDown {
                        for px in cx..<(cx + cell) { region.blend(px, h - 1, trackColor, trackAlpha) }
                    } else {
                        for py in 0..<h { for px in cx..<(cx + cell) { region.blend(px, py, trackColor, trackAlpha) } }
                        // Fill from the bottom; the partial top row is blended by its coverage
                        let filled = Double(h) * min(max(active.isFinite ? active : 0, 0), 1)
                        let full = Int(filled)
                        if full > 0 { region.fillRect(x0: cx, y0: h - full, x1: cx + cell - 1, y1: h - 1, color) }
                        let partial = UInt8((filled - Double(full)) * 255)
                        if full < h && partial > 0 {
                            for px in cx..<(cx + cell) { region.blend(px, h - full - 1, color, partial) }
                        }
                    }
                    cx += cell + gap
                }
            }
        }
        paste(region, x: x, y: y)
    }

    public func displayLineGraph(x: Int, y: Int, width w: Int, height h: Int, values: [Double], minValue: Double,
                                 maxValue: Double, autoscale: Bool, lineColor: RGB, lineWidth: Int, axis: Bool,
                                 axisColor: RGB, axisFont: String, axisFontSize: Int, backgroundColor: RGB,
                                 backgroundImage: String?) {
        guard w > 0, h > 0, x + w <= width, y + h <= height, !values.isEmpty else { return }
        var graph = background(backgroundImage, color: backgroundColor, x0: x, y0: y, x1: x + w, y1: y + h)
        var (lo, hi) = (minValue, maxValue)
        if autoscale {
            var trueMin = hi, trueMax = lo
            for v in values where !v.isNaN { trueMin = min(trueMin, v); trueMax = max(trueMax, v) }
            if trueMin != hi && trueMax != lo { lo = max(trueMin - 5, lo); hi = min(trueMax + 5, hi) }
        }
        let step = Double(w) / Double(values.count)
        let yScale = hi - lo != 0 ? Double(h) / (hi - lo) : 0
        var points: [(Double, Double)] = []
        for v in values where !v.isNaN {
            let c = min(max(v, lo), hi)
            points.append((Double(points.count) * step, Double(h) - (c - lo) * yScale))
        }
        graph.polyline(points, width: lineWidth, ink(lineColor))
        if axis {
            let axisColor = ink(axisColor)
            graph.line1(0, h - 1, w - 1, h - 1, axisColor)
            graph.line1(0, 0, 0, h - 1, axisColor)
            graph.line1(0, 0, 1, 0, axisColor)
            if let f = Font.load(axisFont, size: axisFontSize) {
                let top = TextLayout(String(format: "%.0f", hi), font: f)
                top.draw(into: &graph, x: 2, y: f.ascender - top.yMax, anchor: "la", color: axisColor)
                let bottom = TextLayout(String(format: "%.0f", lo), font: f)
                let bTop = f.ascender - bottom.yMax, bBottom = bTop + bottom.height
                bottom.draw(into: &graph, x: w - 1 - bottom.xMax, y: h - 2 - bBottom, anchor: "la", color: axisColor)
            }
        }
        paste(graph, x: x, y: y)
    }

    private func radialDecoration(_ bmp: inout Bitmap, angle: Double, radius: Double, width: Double, color: RGB) {
        func snap(_ v: Double, _ positive: Bool) -> Double {
            if v - v.rounded(.down) == 0.5 { return positive ? v.rounded(.down) : v.rounded(.up) }
            return (v + 0.5).rounded(.down)
        }
        let c = cos(angle * .pi / 180), s = sin(angle * .pi / 180)
        let xf = snap(c * (radius - width / 2) + radius, c > 0), yf = snap(s * (radius - width / 2) + radius, s > 0)
        bmp.fillEllipse(x0: xf - width / 2, y0: yf - width / 2, x1: xf + width / 2, y1: yf - 1 + width / 2 - 1, color)
    }

    public func displayRadialProgressBar(xc: Int, yc: Int, radius: Int, barWidth: Int, minValue: Double,
                                         maxValue: Double, angleStart: Double, angleEnd: Double, angleSep: Double,
                                         angleSteps: Int, clockwise: Bool, value: Double, text: String?,
                                         font: String, fontSize: Int, fontColor: RGB, barColor: RGB,
                                         backgroundColor: RGB, backgroundImage: String?, customBBox: [Int],
                                         textOffset: [Int], barBackgroundColor: RGB, drawBarBackground: Bool,
                                         barDecoration: String) {
        let (fontColor, barColor, barBackgroundColor) = (ink(fontColor), ink(barColor), ink(barBackgroundColor))
        var (start, end) = (angleStart, angleEnd)
        if start.truncatingRemainder(dividingBy: 361) == end.truncatingRemainder(dividingBy: 361) {
            if clockwise { start += 0.1 } else { end += 0.1 }
        }
        guard xc - radius >= 0, xc + radius <= width, yc - radius >= 0, yc + radius <= height,
              barWidth > 0, barWidth <= radius, angleSteps > 0, maxValue != minValue else { return }
        let v = min(max(value, minValue), maxValue)
        let d = 2 * radius, dm1 = Double(d - 1)
        var bar = background(backgroundImage, color: backgroundColor, x0: xc - radius, y0: yc - radius,
                             x1: xc + radius, y1: yc + radius)
        let pct = (v - minValue) / (maxValue - minValue)
        start = start.truncatingRemainder(dividingBy: 361)
        end = end.truncatingRemainder(dividingBy: 361)
        func arc(_ s: Double, _ e: Double, _ c: RGB) {
            bar.arc(x0: 0, y0: 0, x1: dm1, y1: dm1, start: s, end: e, width: barWidth, c)
        }
        let r = Double(radius), bw = Double(barWidth)
        if clockwise {
            let ecart = end < start ? 360 - start + end : end - start
            if drawBarBackground { arc(start, start + ecart, barBackgroundColor) }
            if barDecoration == "Ellipse" {
                radialDecoration(&bar, angle: end, radius: r, width: bw, color: barBackgroundColor)
                radialDecoration(&bar, angle: start, radius: r, width: bw, color: barColor)
                radialDecoration(&bar, angle: start + pct * ecart, radius: r, width: bw, color: barColor)
            }
            if angleSep == 0 {
                arc(start, start + pct * ecart, barColor)
            } else {
                let angleE = start + pct * ecart, complet = ecart / Double(angleSteps)
                let etapes = Int((angleE - start) / complet)
                for i in 0..<etapes { arc(start + Double(i) * complet, start + Double(i + 1) * complet - angleSep, barColor) }
                arc(start + Double(etapes) * complet, angleE, barColor)
            }
        } else {
            let ecart = end < start ? start - end : 360 - end + start
            if drawBarBackground { arc(start - ecart, start, barBackgroundColor) }
            if barDecoration == "Ellipse" {
                radialDecoration(&bar, angle: end, radius: r, width: bw, color: barBackgroundColor)
                radialDecoration(&bar, angle: start, radius: r, width: bw, color: barColor)
                radialDecoration(&bar, angle: start - pct * ecart, radius: r, width: bw, color: barColor)
            }
            if angleSep == 0 {
                arc(start - pct * ecart, start, barColor)
            } else {
                let angleS = start - pct * ecart, complet = ecart / Double(angleSteps)
                let etapes = Int((start - angleS) / complet)
                for i in 0..<etapes { arc(start - Double(i + 1) * complet + angleSep, start - Double(i) * complet, barColor) }
                arc(angleS, start - Double(etapes) * complet, barColor)
            }
        }
        let label = text ?? "\(Int(pct * 100 + 0.5))%"
        if !label.isEmpty, let f = Font.load(font, size: fontSize) {
            let probe = TextLayout(label, font: f)
            let top = f.ascender - probe.yMax
            let tx = r - Double(probe.width) / 2 + Double(textOffset.first ?? 0)
            let ty = r - Double(top) - Double(probe.height) / 2 + Double(textOffset.count > 1 ? textOffset[1] : 0)
            // Pillow keeps the fractional part of x as the pen start and truncates the integer part
            let layout = TextLayout(label, font: f, startX: tx - tx.rounded(.towardZero))
            layout.draw(into: &bar, x: Int(tx), y: Int(ty) + f.ascender, anchor: "ls", color: fontColor)
        }
        var (ox, oy) = (xc - radius, yc - radius)
        if customBBox.count == 4, customBBox.contains(where: { $0 != 0 }) {
            bar = bar.crop(x0: customBBox[0], y0: customBBox[1], x1: customBBox[2], y1: customBBox[3])
            ox += customBBox[0]; oy += customBBox[1]
        }
        paste(bar, x: ox, y: oy)
    }

    // MARK: - display.py

    public func displayStaticImages() {
        for (_, img) in theme["static_images"].entries {
            guard let path = themeFile(img["PATH"].string) else { continue }
            displayBitmap(path, x: img.int("X", 0), y: img.int("Y", 0), width: img.int("WIDTH", 0),
                          height: img.int("HEIGHT", 0))
        }
    }

    public func displayStaticText() {
        for (_, t) in theme["static_text"].entries {
            guard let text = t["TEXT"].string else { continue }
            displayText(text, x: t.int("X", 0), y: t.int("Y", 0), width: t.int("WIDTH", 0), height: t.int("HEIGHT", 0),
                        font: fontPath(t.string("FONT", "roboto-mono/RobotoMono-Regular.ttf")),
                        fontSize: t.int("FONT_SIZE", 10), fontColor: t.color("FONT_COLOR", RGB(0, 0, 0)),
                        backgroundColor: t.color("BACKGROUND_COLOR", RGB(255, 255, 255)),
                        backgroundImage: themeFile(t["BACKGROUND_IMAGE"].string), anchor: t.string("ANCHOR", "lt"))
        }
    }
}
