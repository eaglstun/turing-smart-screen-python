import AppKit
import Foundation
import TuringTheme

/// A theme folder under res/themes that fits the 3.5" display.
struct ThemeInfo: Identifiable, Hashable {
    let name: String
    let landscape: Bool
    let preview: URL?
    var id: String { name }
}

enum ThemeCatalog {
    /// The res/ folder: inside the app bundle, or (when run from a build folder) the repo's res/ found by walking up.
    static let resDir: URL? = {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("res"),
           FileManager.default.fileExists(atPath: r.appendingPathComponent("themes/default.yaml").path) { return r }
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        while let d = dir, d.path != "/" {
            let r = d.appendingPathComponent("res")
            if FileManager.default.fileExists(atPath: r.appendingPathComponent("themes/default.yaml").path) { return r }
            dir = d.deletingLastPathComponent()
        }
        return nil
    }()

    /// Themes made for the 3.5" display (DISPLAY_SIZE 3.5" or unset), sorted by name.
    static func themes() -> [ThemeInfo] {
        guard let res = resDir else { return [] }
        let dir = res.appendingPathComponent("themes")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name -> ThemeInfo? in
            let folder = dir.appendingPathComponent(name)
            guard let theme = try? ThemeNode.load(folder.appendingPathComponent("theme.yaml")) else { return nil }
            guard theme["display"].string("DISPLAY_SIZE", "3.5\"") == "3.5\"" else { return nil }
            let preview = folder.appendingPathComponent("preview.png")
            return ThemeInfo(name: name, landscape: theme["display"].string("DISPLAY_ORIENTATION", "portrait") == "landscape",
                             preview: FileManager.default.fileExists(atPath: preview.path) ? preview : nil)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

extension Bitmap {
    var nsImage: NSImage? { cgImage().map { NSImage(cgImage: $0, size: NSSize(width: width, height: height)) } }
}
