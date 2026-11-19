import AppKit
import ServiceManagement
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
        case searching, connected, paused, sleeping, error(String)
        var label: String {
            switch self {
            case .searching: return "Display not connected"
            case .connected: return "Running"
            case .paused: return "Paused"
            case .sleeping: return "Sleeping"
            case .error(let e): return e
            }
        }
        var color: Color {
            switch self {
            case .connected: return .green
            case .paused, .sleeping: return .yellow
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
    /// Turn the panel off while the Mac or its displays sleep.
    @AppStorage("sleepWithMac") var sleepWithMac = true

    /// Open at login (SMAppService); reads the system's state so it stays true to System Settings > Login Items.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                loginItemError = nil
            } catch {
                loginItemError = error.localizedDescription
            }
            objectWillChange.send()
        }
    }
    @Published private(set) var loginItemError: String?

    @Published private(set) var status: Status = .searching
    @Published private(set) var preview: NSImage?
    @Published private(set) var themes: [ThemeInfo] = ThemeCatalog.themes()
    @Published var previewActive = false { didSet { if previewActive { refreshPreview() } } }

    private var monitor: Monitor?
    private var sink = DeviceSink()
    private var paused = false
    private var sleeping = false
    private var watchdog: Timer?, previewTimer: Timer?

    init() {
        if !themes.contains(where: { $0.name == themeName }), let first = themes.first { themeName = first.name }
        restart()
        // However the app quits (menu, logout, script), finish the frame being sent: a half-sent bitmap leaves the
        // panel out of step until it's replugged
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.monitor?.stop() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.macWillSleep() }
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.macDidWake() }
            }
        }
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
        guard !sleeping else { status = .sleeping; return }
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

    /// Mac (or its displays) going to sleep: finish the current frame, turn the backlight off, stop updating.
    private func macWillSleep() {
        guard sleepWithMac, !sleeping else { return }
        sleeping = true
        if let m = monitor {
            m.stop()
            m.onSinkQueue { [sink] in sink.setScreen(on: false); sink.disconnect() }
        }
        monitor = nil
        status = .sleeping
    }

    /// Waking up: the panel can come back in its default orientation, so reconnect from scratch and redraw.
    private func macDidWake() {
        guard sleeping else { return }
        sleeping = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.sleeping else { return }
            self.restart()
        }
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
