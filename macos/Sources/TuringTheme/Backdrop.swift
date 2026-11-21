import CoreGraphics
import CoreImage
import ImageIO
import Foundation

/// Builds a theme background from any image, macOS widget style: the image scaled to fill the screen and dimmed,
/// with frosted-glass panels (blurred, saturated, tinted, rounded, hairline border) and capsule progress tracks.
///
/// Driven by the theme's `display: MACOS:` section, which the Python app ignores:
///
///     MACOS:
///       WALLPAPER: background.png   # theme image the desktop wallpaper replaces
///       SYSTEM_FONTS: true          # draw every FONT in San Francisco at the same weight
///       ACCENT_COLOR: 10, 132, 255  # theme color replaced by the system accent color
///       WALLPAPER_DIM: 0.2          # 0-1, darkens the whole wallpaper
///       PANEL_BLUR: 10              # px
///       PANEL_TINT: 30, 30, 34
///       PANEL_OPACITY: 0.4          # 0-1, tint over the blurred wallpaper
///       PANEL_RADIUS: 18
///       PANEL_BORDER_OPACITY: 0.12  # white hairline around each panel
///       PANELS: { NAME: { X, Y, WIDTH, HEIGHT } ... }
///       TRACK_COLOR: 255, 255, 255
///       TRACK_OPACITY: 0.16
///       TRACKS: { NAME: { X, Y, WIDTH, HEIGHT } ... }   # capsules under progress bars
///       CORE_GRID:                  # one bar per CPU core in place of the CPU usage bar (see displayCoreGrid)
///         X, Y, WIDTH, HEIGHT, BACKGROUND_IMAGE
///         P_COLOR / E_COLOR: performance / efficiency cores (default ACCENT_COLOR, so they follow the system accent)
///         GAP: 2                    # px between cores
///         CLUSTER_GAP: 4            # px between clusters
///         REPLACES_TRACK: CPU       # TRACKS entry left out of the live backdrop (still baked for the Python app)
public enum Backdrop {
    public static func compose(_ image: CGImage, width w: Int, height h: Int, style s: ThemeNode,
                               skippingTracks: Set<String> = []) -> Bitmap? {
        let ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        let extent = CGRect(x: 0, y: 0, width: w, height: h)

        // Aspect fill, centered
        let src = CIImage(cgImage: image)
        let scale = max(CGFloat(w) / src.extent.width, CGFloat(h) / src.extent.height)
        let scaled = src.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let filled = scaled.transformed(by: CGAffineTransform(translationX: (CGFloat(w) - scaled.extent.width) / 2,
                                                              y: (CGFloat(h) - scaled.extent.height) / 2))
        let dim = 1 - min(max(s.double("WALLPAPER_DIM", 0), 0), 1)
        let base = filled.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: dim, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: dim, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: dim, w: 0),
        ]).cropped(to: extent)

        // Frosted glass: blur + saturation boost (macOS vibrancy) of the original wallpaper, then the tint
        let tint = s.color("PANEL_TINT", RGB(30, 30, 34)), opacity = s.double("PANEL_OPACITY", 0.4)
        let glass = filled.clampedToExtent()
            .applyingGaussianBlur(sigma: s.double("PANEL_BLUR", 10))
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.6])
            .cropped(to: extent)
        let tinted = CIImage(color: CIColor(red: CGFloat(tint.r) / 255, green: CGFloat(tint.g) / 255,
                                            blue: CGFloat(tint.b) / 255, alpha: opacity))
            .cropped(to: extent).composited(over: glass)

        guard let baseCG = ci.createCGImage(base, from: extent), let glassCG = ci.createCGImage(tinted, from: extent)
        else { return nil }

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(baseCG, in: extent)

        // Theme coordinates are y-down; CoreGraphics is y-up
        func rect(_ n: ThemeNode) -> CGRect {
            CGRect(x: n.double("X", 0), y: Double(h) - n.double("Y", 0) - n.double("HEIGHT", 0),
                   width: n.double("WIDTH", 0), height: n.double("HEIGHT", 0))
        }
        let radius = s.double("PANEL_RADIUS", 18), border = s.double("PANEL_BORDER_OPACITY", 0.12)
        for (_, p) in s["PANELS"].entries {
            let path = CGPath(roundedRect: rect(p), cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            ctx.draw(glassCG, in: extent)
            ctx.restoreGState()
            if border > 0 {
                let inset = CGPath(roundedRect: rect(p).insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius - 0.5,
                                   cornerHeight: radius - 0.5, transform: nil)
                ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: border)
                ctx.setLineWidth(1)
                ctx.addPath(inset); ctx.strokePath()
            }
        }
        let track = s.color("TRACK_COLOR", RGB(255, 255, 255))
        ctx.setFillColor(red: CGFloat(track.r) / 255, green: CGFloat(track.g) / 255, blue: CGFloat(track.b) / 255,
                         alpha: s.double("TRACK_OPACITY", 0.16))
        for (name, t) in s["TRACKS"].entries where !skippingTracks.contains(name) {
            let r = rect(t), cr = min(r.width, r.height) / 2
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: cr, cornerHeight: cr, transform: nil))
            ctx.fillPath()
        }

        var out = Bitmap(width: w, height: h)
        for i in 0..<(w * h) {
            out.pixels[i * 3] = rgba[i * 4]; out.pixels[i * 3 + 1] = rgba[i * 4 + 1]; out.pixels[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return out
    }

    /// Loads an image file (any ImageIO format, HEIC included), downsampled to at most `maxPixels` on its long side.
    public static func loadImage(_ url: URL, maxPixels: Int = 1600) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
