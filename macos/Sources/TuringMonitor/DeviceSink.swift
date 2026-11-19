import Foundation
import TuringDevice
import TuringTheme

/// Sends screen updates to a rev. A display over USB. Regions arrive aligned to 32 px, so every bitmap is whole
/// 64-byte packets. If a write fails (display unplugged), the sink drops updates until `connect()` succeeds again.
public final class DeviceSink: DisplaySink {
    public let alignment = 32
    private var display: RevADisplay?
    public private(set) var lastError: String?
    public var isConnected: Bool { display != nil }
    /// Called (on the sink queue) when the connection is lost.
    public var onDisconnect: (() -> Void)?

    public init() {}

    /// Opens the display and sets it up for a theme of the given size. Returns false if it isn't available.
    @discardableResult
    public func connect(width: Int, height: Int, landscape: Bool, reverse: Bool = false, brightness: Int) -> Bool {
        do {
            let d = try RevADisplay()
            try d.screenOn()
            try d.setBrightness(brightness)
            let o: RevADisplay.Orientation = landscape ? (reverse ? .reverseLandscape : .landscape)
                                                       : (reverse ? .reversePortrait : .portrait)
            try d.setOrientation(o, width: width, height: height)
            display = d
            lastError = nil
            return true
        } catch {
            display = nil
            lastError = "\(error)"
            return false
        }
    }

    public func disconnect() { display = nil }

    public func setBrightness(_ percent: Int) {
        guard let display else { return }
        do { try display.setBrightness(percent) } catch { fail(error) }
    }

    public func update(_ region: Bitmap, x: Int, y: Int) {
        guard let display else { return }
        do { try display.draw(region, x: x, y: y) } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        lastError = "\(error)"
        display = nil
        onDisconnect?()
    }
}
