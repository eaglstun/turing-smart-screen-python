import Foundation
import TuringMonitor
import TuringTheme

// Runs a theme against live sensors for a while, then reports update statistics.
// Usage: MonitorCLI <res dir> <theme> <seconds> [out.png | --device] [wifi interface]
//   out.png   record updates in memory (no display) and save the final screen
//   --device  draw on the USB display

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
    FileHandle.standardError.write("usage: MonitorCLI <res dir> <theme> <seconds> [out.png | --device] [wifi]\n".data(using: .utf8)!)
    exit(2)
}
let useDevice = args.count > 4 && args[4] == "--device"
let recorder = RecordingSink(), device = DeviceSink()
let sink: DisplaySink = useDevice ? device : recorder
let monitor = try Monitor(themeName: args[2], resDir: URL(fileURLWithPath: args[1]), sensors: LiveSensors(),
                          config: StatsConfig(wifi: args.count > 5 ? args[5] : "en0", locale: .current), sink: sink)
recorder.screen = Bitmap(width: monitor.renderer.width, height: monitor.renderer.height)
if useDevice {
    guard device.connect(width: monitor.renderer.width, height: monitor.renderer.height,
                         landscape: monitor.renderer.isLandscape, brightness: 20) else {
        print("error: \(device.lastError ?? "cannot open the display")")
        exit(1)
    }
}

let cpuStart = ProcessInfo.processInfo.systemUptime
var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
let cpu0 = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6

monitor.start()
Thread.sleep(forTimeInterval: seconds)
monitor.stop()

getrusage(RUSAGE_SELF, &usage)
let cpu1 = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
let wall = ProcessInfo.processInfo.systemUptime - cpuStart
print(String(format: "%d updates, %d pixels (%.1f full frames) in %.1f s; CPU %.2f s (%.1f%% of one core)%@",
             monitor.updatesSent, monitor.pixelsSent,
             Double(monitor.pixelsSent) / Double(monitor.renderer.width * monitor.renderer.height),
             wall, cpu1 - cpu0, (cpu1 - cpu0) / wall * 100,
             useDevice ? (device.isConnected ? "; display OK" : "; display error: \(device.lastError ?? "?")") : ""))
if !useDevice, args.count > 4, let screen = recorder.screen { try screen.writePNG(URL(fileURLWithPath: args[4])) }
