import AppKit
import Foundation
import SwiftUI
import TuringDevice
import TuringMonitor
import TuringSensors
import TuringTheme

/// App state: settings, the running monitor, the display connection and the live preview.
@MainActor
final class AppModel: ObservableObject {
    enum Status: Equatable {
        case searching, connected, paused, error(String)
        var label: String {
            switch self {
            case .searching: return "Display not connected"
            case .connected: return "Running"
            case .paused: return "Paused"
            case .error(let e): return e
            }
        }
        var color: Color {
            switch self {
            case .connected: return .green
            case .paused: return .yellow
            case .searching: return .secondary
            case .error: return .red
            }
        }
    }

    @AppStorage("theme") var themeName = "3.5inchTheme2" { didSet { restart() } }
    @AppStorage("brightness") var brightness = 20.0
    @AppStorage("wifi") var wifi = "en0" { didSet { restart() } }
    @AppStorage("ethernet") var ethernet = "" { didSet { restart() } }
    @AppStorage("pingHost") var pingHost = "8.8.8.8" { didSet { restart() } }
    @AppStorage("reverse") var reverse = false { didSet { restart() } }

    @Published private(set) var status: Status = .searching
    @Published private(set) var preview: NSImage?
    @Published private(set) var themes: [ThemeInfo] = ThemeCatalog.themes()
    @Published var previewActive = false { didSet { if previewActive { refreshPreview() } } }

    private var monitor: Monitor?
    private var sink = DeviceSink()
    private var paused = false
    private var watchdog: Timer?, previewTimer: Timer?

    init() {
        if !themes.contains(where: { $0.name == themeName }), let first = themes.first { themeName = first.name }
        restart()
        // Hotplug: retry the display every 2 s while it's missing
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkConnection() }
        }
        previewTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.previewActive == true { self?.refreshPreview() } }
        }
    }

    var currentTheme: ThemeInfo? { themes.first { $0.name == themeName } }

    /// (Re)creates the monitor for the current settings and connects to the display if it's there.
    func restart() {
        monitor?.stop()
        monitor = nil
        sink.disconnect()
        guard !paused else { status = .paused; return }
        guard let res = ThemeCatalog.resDir else { status = .error("Themes folder not found"); return }
        let sensors = LiveSensors(pingHost: pingHost)
        do {
            let m = try Monitor(themeName: themeName, resDir: res, sensors: sensors,
                                config: StatsConfig(ethernet: ethernet, wifi: wifi, locale: .current), sink: sink)
            monitor = m
            sink.onDisconnect = { [weak self] in Task { @MainActor in self?.status = .searching } }
            connectAndStart(m)
        } catch {
            status = .error("Cannot load theme \(themeName)")
        }
    }

    private func connectAndStart(_ m: Monitor) {
        let (w, h, landscape) = (m.renderer.width, m.renderer.height, m.renderer.isLandscape)
        let (sink, reverse, level) = (sink, reverse, Int(brightness))
        guard RevADisplay.isConnected else { status = .searching; m.start(); return }
        m.onSinkQueue {
            let ok = sink.connect(width: w, height: h, landscape: landscape, reverse: reverse, brightness: level)
            let error = sink.lastError
            Task { @MainActor [weak self] in
                self?.status = ok ? .connected : .error(error ?? "Cannot open the display")
            }
        }
        m.start()
    }

    private func checkConnection() {
        guard !paused, let m = monitor else { return }
        if status == .connected, !RevADisplay.isConnected { status = .searching; m.onSinkQueue { [sink] in sink.disconnect() } }
        guard status != .connected, RevADisplay.isConnected else { return }
        // Plugged back in: reconnect and send a full frame
        let (w, h, landscape) = (m.renderer.width, m.renderer.height, m.renderer.isLandscape)
        let (sink, reverse, level) = (sink, reverse, Int(brightness))
        m.onSinkQueue {
            let ok = sink.connect(width: w, height: h, landscape: landscape, reverse: reverse, brightness: level)
            Task { @MainActor [weak self] in
                self?.status = ok ? .connected : .searching
                if ok { m.redrawAll() }
            }
        }
    }

    func setBrightness(_ value: Double) {
        brightness = value
        monitor?.onSinkQueue { [sink] in sink.setBrightness(Int(value)) }
    }

    func togglePause() {
        paused.toggle()
        restart()
    }

    var isPaused: Bool { paused }

    func reloadThemes() { themes = ThemeCatalog.themes() }

    private func refreshPreview() {
        monitor?.snapshot { [weak self] bmp in self?.preview = bmp.nsImage }
    }

    func quit() {
        monitor?.stop()
        NSApp.terminate(nil)
    }

    static var networkInterfaces: [String] { Net.activeInterfaces() }
}
