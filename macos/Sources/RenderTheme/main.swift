import CoreGraphics
import Foundation
import TuringTheme

// Renders a theme once with the same fixed values as the Python STATIC sensors
// (library/sensors/sensors_stub_static.py and the STATIC branches of library/stats.py) and writes a PNG.
// Usage: RenderTheme <res dir> <theme name> <out.png>

struct StaticSensors: SensorSource {
    let pct = 50.0, temp = 67.3
    func cpuPercent() -> Double { pct }
    func cpuFrequencyMHz() -> Double { 2400 }
    func cpuLoad() -> (Double, Double, Double) { (pct, pct, pct) }
    func cpuTemperature() -> Double { temp }
    func cpuFanPercent() -> Double { pct }
    func gpuStats() -> (Double, Double, Double, Double, Double) { (pct, pct, 32.0 / 100 * pct * 1024, 32 * 1024, temp) }
    func gpuFPS() -> Int { 120 }
    func gpuFanPercent() -> Double { pct }
    func gpuFrequencyMHz() -> Double { 1500 }
    func swapPercent() -> Double { pct }
    func memoryPercent() -> Double { pct }
    func memoryUsed() -> Double { Double(Int(64.0 / 100 * pct)) * 1e9 }
    func memoryFree() -> Double { Double(Int(64.0 / 100 * (100 - pct))) * 1e9 }
    func diskPercent() -> Double { pct }
    func diskUsed() -> Double { Double(Int(1000.0 / 100 * pct)) * 1e9 }
    func diskFree() -> Double { Double(Int(1000.0 / 100 * (100 - pct))) * 1e9 }
    func net(_ interface: String) -> (Double, Double, Double, Double) { (1061000000, 1061000000, 1061000000, 1061000000) }
    func now() -> Date { Date(timeIntervalSince1970: 1694014609) }
    func uptimeSeconds() -> Int { 4294036 }
    func pingMS() -> Double? { 50 }
    func weather() -> (String?, String?, String?, String?, String?)? { ("17.5°C", "(17.2°C)", "@15:33", "Cloudy", "45%") }
}

let args = CommandLine.arguments
// Debug: RenderTheme --text <font file> <size> <text>  prints the layout metrics (compare with Pillow getbbox)
if args.count == 5, args[1] == "--text" {
    print(TextMetrics.describe(font: args[2], size: Int(args[3]) ?? 10, text: args[4]))
    exit(0)
}
// Options after the three paths:
//   --wallpaper <image>        render with this image as the desktop wallpaper (themes with MACOS: WALLPAPER)
//   --bake-background <image>  instead of rendering, compose the image into the theme's WALLPAPER file (the static
//                              backdrop the Python app and a wallpaper-less Mac use)
var options: [String: String] = [:]
var i = 4
while i + 1 < args.count, args[i].hasPrefix("--") { options[args[i]] = args[i + 1]; i += 2 }
guard args.count >= 4, i == args.count else {
    FileHandle.standardError.write(("usage: RenderTheme <res dir> <theme name> <out.png> [--wallpaper <image>] "
        + "[--bake-background <image>]\n").data(using: .utf8)!)
    exit(2)
}
let renderer = try ThemeRenderer(themeName: args[2], resDir: URL(fileURLWithPath: args[1]))
func image(_ path: String) -> CGImage {
    guard let img = Backdrop.loadImage(URL(fileURLWithPath: path)) else { fatalError("cannot load \(path)") }
    return img
}
if let src = options["--bake-background"] {
    guard let file = renderer.wallpaperFile,
          let bmp = Backdrop.compose(image(src), width: renderer.width, height: renderer.height, style: renderer.macos)
    else { fatalError("theme has no MACOS: WALLPAPER") }
    try bmp.writePNG(URL(fileURLWithPath: file))
    print(file)
    exit(0)
}
if let wp = options["--wallpaper"] { renderer.setWallpaper(image(wp)) }
renderer.displayStaticImages()
renderer.displayStaticText()
ThemeStats(renderer: renderer, source: StaticSensors()).updateAll()
try renderer.screen.writePNG(URL(fileURLWithPath: args[3]))
