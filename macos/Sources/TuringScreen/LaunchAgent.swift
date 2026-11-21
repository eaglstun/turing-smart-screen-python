import Foundation
import ServiceManagement

/// Start at login through a per-user LaunchAgent (~/Library/LaunchAgents/local.turingscreen.plist) instead of an
/// SMAppService login item: launchd also relaunches the app after a crash (KeepAlive on unsuccessful exit), while Quit
/// (a clean exit) leaves it quit until the next login.
///
/// Toggling only writes or removes the plist, never calls launchctl: bootstrapping now would start a second copy next to
/// this one, and booting out a job we're running under would make launchd kill us. Either way it applies from the next
/// login; bundle.sh --install reloads the agent when it installs a new build.
enum LaunchAgent {
    static let label = "local.turingscreen"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    enum Failure: LocalizedError {
        case notBundled
        var errorDescription: String? {
            "Open at login needs the installed app (run bundle.sh --install), not a build-folder binary."
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled { try install() } else if isEnabled { try FileManager.default.removeItem(at: plistURL) }
    }

    private static func install() throws {
        guard Bundle.main.bundleURL.pathExtension == "app", let exe = Bundle.main.executableURL else {
            throw Failure.notBundled
        }
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TuringScreen.log")
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe.path],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
    }

    /// Earlier builds registered an SMAppService login item; alongside the agent it would start a second copy at login,
    /// and two copies fight over the USB display.
    static func removeLegacyLoginItem() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
    }
}
