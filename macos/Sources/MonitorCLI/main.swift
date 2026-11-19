import Foundation
import TuringMonitor
import TuringTheme

// Runs a theme against live sensors for a while without a display, then reports update statistics.
// Usage: MonitorCLI <res dir> <theme> <seconds> [out.png] [wifi interface]

/// Applies updates to an in-memory copy of the screen (what the display would show) and counts them.
final class RecordingSink: DisplaySink {
    var screen: Bitmap?
    var updates = 0, pixels = 0
    let alignment = 32
    func update(_ region: Bitmap, x: Int, y: Int) {
        updates += 1
        pixels += region.width * region.height
        screen?.paste(region, x: x, y: y)
    }
}

let args = CommandLine.arguments
guard args.count >= 4, let seconds = Double(args[3]) else {
    FileHandle.standardError.write("usage: MonitorCLI <res dir> <theme> <seconds> [out.png] [wifi]\n".data(using: .utf8)!)
    exit(2)
}
let sink = RecordingSink()
let monitor = try Monitor(themeName: args[2], resDir: URL(fileURLWithPath: args[1]), sensors: LiveSensors(),
                          config: StatsConfig(wifi: args.count > 5 ? args[5] : "en0", locale: .current), sink: sink)
sink.screen = Bitmap(width: monitor.renderer.width, height: monitor.renderer.height)

let cpuStart = ProcessInfo.processInfo.systemUptime
var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
let cpu0 = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6

monitor.start()
Thread.sleep(forTimeInterval: seconds)
monitor.stop()

getrusage(RUSAGE_SELF, &usage)
let cpu1 = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
let wall = ProcessInfo.processInfo.systemUptime - cpuStart
print(String(format: "%d updates, %d pixels (%.1f full frames) in %.1f s; CPU %.2f s (%.1f%% of one core)",
             sink.updates, sink.pixels, Double(sink.pixels) / Double(monitor.renderer.width * monitor.renderer.height),
             wall, cpu1 - cpu0, (cpu1 - cpu0) / wall * 100))
if args.count > 4, let screen = sink.screen { try screen.writePNG(URL(fileURLWithPath: args[4])) }
