import AppKit
import Foundation
import TuringTheme

/// The Mac's look, for themes with a `display: MACOS:` section: desktop wallpaper and accent color.
enum MacAppearance {
    /// The wallpaper of the main display (the one with the menu bar). Aerials report a still image of the current
    /// video; a folder or a dynamic (time-of-day) wallpaper reports its file, of which the first image is used.
    static var wallpaperURL: URL? {
        NSScreen.screens.first.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
    }

    static var accent: RGB {
        let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)
        func byte(_ v: CGFloat) -> UInt8 { UInt8(clamping: Int((v * 255).rounded())) }
        return RGB(byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }

    /// Changes whenever the wallpaper file, its contents or the accent color change.
    static func signature(wallpaper: URL?, accent: RGB) -> String {
        let modified = wallpaper.flatMap {
            try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date
        }
        return "\(wallpaper?.path ?? "-")|\(modified?.timeIntervalSince1970 ?? 0)|\(accent.r),\(accent.g),\(accent.b)"
    }
}
