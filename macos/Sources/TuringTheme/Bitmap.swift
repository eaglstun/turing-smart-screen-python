import CoreGraphics
import Foundation
import ImageIO

/// An 8-bit RGB image with Pillow-compatible (aliased, integer-coordinate) drawing primitives.
/// Pillow's ImageDraw shapes are not antialiased, so these aren't either; only text is.
public struct Bitmap {
    public let width: Int, height: Int
    public var pixels: [UInt8]  // RGB, row-major, top-left origin

    public init(width: Int, height: Int, fill: RGB = RGB(0, 0, 0)) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 3)
        if fill != RGB(0, 0, 0) { fillRect(x0: 0, y0: 0, x1: width - 1, y1: height - 1, fill) }
    }

    @inline(__always) func index(_ x: Int, _ y: Int) -> Int { (y * width + x) * 3 }

    public func pixel(_ x: Int, _ y: Int) -> RGB {
        let i = index(x, y)
        return RGB(pixels[i], pixels[i + 1], pixels[i + 2])
    }

    @inline(__always) public mutating func set(_ x: Int, _ y: Int, _ c: RGB) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let i = index(x, y)
        pixels[i] = c.r; pixels[i + 1] = c.g; pixels[i + 2] = c.b
    }

    /// Pillow BLEND with DIV255 rounding: out = (in * (255 - a) + ink * a) / 255.
    @inline(__always) public mutating func blend(_ x: Int, _ y: Int, _ c: RGB, _ a: UInt8) {
        guard a > 0, x >= 0, y >= 0, x < width, y < height else { return }
        let i = index(x, y), m = Int(a), im = 255 - m
        func div255(_ v: Int) -> UInt8 { let t = v + 128; return UInt8((t + (t >> 8)) >> 8) }
        pixels[i] = div255(Int(pixels[i]) * im + Int(c.r) * m)
        pixels[i + 1] = div255(Int(pixels[i + 1]) * im + Int(c.g) * m)
        pixels[i + 2] = div255(Int(pixels[i + 2]) * im + Int(c.b) * m)
    }

    // MARK: - Regions

    /// Image.crop: area outside the source reads as black, like Pillow.
    public func crop(x0: Int, y0: Int, x1: Int, y1: Int) -> Bitmap {
        var out = Bitmap(width: max(0, x1 - x0), height: max(0, y1 - y0))
        for y in 0..<out.height {
            let sy = y0 + y
            guard sy >= 0, sy < height else { continue }
            for x in 0..<out.width {
                let sx = x0 + x
                guard sx >= 0, sx < width else { continue }
                let s = index(sx, sy), d = out.index(x, y)
                out.pixels[d] = pixels[s]; out.pixels[d + 1] = pixels[s + 1]; out.pixels[d + 2] = pixels[s + 2]
            }
        }
        return out
    }

    /// Image.paste at (x, y), clipped to this bitmap.
    public mutating func paste(_ src: Bitmap, x: Int, y: Int) {
        for sy in 0..<src.height {
            let dy = y + sy
            guard dy >= 0, dy < height else { continue }
            let xStart = max(0, -x), xEnd = min(src.width, width - x)
            guard xStart < xEnd else { continue }
            let s = src.index(xStart, sy), d = index(x + xStart, dy), n = (xEnd - xStart) * 3
            pixels.withUnsafeMutableBufferPointer { dst in
                src.pixels.withUnsafeBufferPointer { sp in
                    dst.baseAddress!.advanced(by: d).update(from: sp.baseAddress!.advanced(by: s), count: n)
                }
            }
        }
    }

    // MARK: - Shapes (Pillow ImageDraw semantics)

    /// Filled rectangle with inclusive integer corners (ImagingDrawRectangle).
    public mutating func fillRect(x0: Int, y0: Int, x1: Int, y1: Int, _ c: RGB) {
        let (ax, bx) = (max(min(x0, x1), 0), min(max(x0, x1), width - 1))
        let (ay, by) = (max(min(y0, y1), 0), min(max(y0, y1), height - 1))
        guard ax <= bx, ay <= by else { return }
        for y in ay...by { for x in ax...bx { set(x, y, c) } }
    }

    /// draw.rectangle(xy, fill, outline): coordinates are truncated to int as Pillow's C layer does.
    public mutating func rectangle(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, fill: RGB?, outline: RGB?) {
        let (a, b, c, d) = (Int(x0), Int(y0), Int(x1), Int(y1))
        if let fill { fillRect(x0: a, y0: b, x1: c, y1: d, fill) }
        if let outline, fill != outline {
            fillRect(x0: a, y0: b, x1: c, y1: b, outline); fillRect(x0: a, y0: d, x1: c, y1: d, outline)
            fillRect(x0: a, y0: b, x1: a, y1: d, outline); fillRect(x0: c, y0: b, x1: c, y1: d, outline)
        }
    }

    /// 1-pixel line between integer points (ImagingDrawLine: Bresenham with horizontal/vertical fast paths).
    public mutating func line1(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: RGB) {
        var (x, y) = (x0, y0)
        let dx = abs(x1 - x0), dy = abs(y1 - y0), sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
        var err = dx - dy
        while true {
            set(x, y, c)
            if x == x1 && y == y1 { break }
            let e2 = 2 * err
            if e2 > -dy { err -= dy; x += sx }
            if e2 < dx { err += dx; y += sy }
        }
    }

    /// draw.line(points, fill, width): width 1 uses Bresenham; wider segments are filled quads
    /// built like ImagingDrawWideLine.
    public mutating func polyline(_ points: [(Double, Double)], width: Int, _ c: RGB) {
        guard points.count >= 2 else { return }
        for i in 0..<points.count - 1 {
            let (x0, y0, x1, y1) = (Int(points[i].0), Int(points[i].1), Int(points[i + 1].0), Int(points[i + 1].1))
            if width <= 1 { line1(x0, y0, x1, y1, c); continue }
            let dx = Double(x1 - x0), dy = Double(y1 - y0)
            if dx == 0 && dy == 0 { set(x0, y0, c); continue }
            let big = (dx * dx + dy * dy).squareRoot(), small = Double(width - 1) / 2
            let ratioMax = small.rounded(.up) / big, ratioMin = small.rounded(.down) / big
            let dxmin = Int((ratioMin * dy).rounded(.down)), dxmax = Int((ratioMax * dy).rounded(.down))
            let dymin = Int((ratioMin * dx).rounded(.down)), dymax = Int((ratioMax * dx).rounded(.down))
            fillPolygon([(Double(x0 - dxmin), Double(y0 + dymax)), (Double(x1 - dxmin), Double(y1 + dymax)),
                         (Double(x1 + dxmax), Double(y1 - dymin)), (Double(x0 + dxmax), Double(y0 - dymin))], c)
        }
    }

    /// Scanline polygon fill (pixel centers on integer coordinates, like Pillow's polygon_generic).
    public mutating func fillPolygon(_ v: [(Double, Double)], _ c: RGB) {
        guard let minY = v.map(\.1).min(), let maxY = v.map(\.1).max() else { return }
        for y in Int(minY.rounded(.up))...Int(maxY.rounded(.down)) {
            var xs: [Double] = []
            for i in 0..<v.count {
                let (a, b) = (v[i], v[(i + 1) % v.count])
                if a.1 == b.1 {
                    if Double(y) == a.1 { xs.append(contentsOf: [a.0, b.0]) }
                    continue
                }
                let (lo, hi) = a.1 < b.1 ? (a, b) : (b, a)
                if Double(y) >= lo.1 && Double(y) <= hi.1 {
                    xs.append(lo.0 + (Double(y) - lo.1) * (hi.0 - lo.0) / (hi.1 - lo.1))
                }
            }
            guard let l = xs.min(), let r = xs.max() else { continue }
            fillRect(x0: Int(l.rounded(.up)), y0: y, x1: Int(r.rounded(.down)), y1: y, c)
        }
    }

    /// draw.arc(bbox, start, end, fill, width): pixels whose centers lie in the ring between the bbox ellipse and
    /// the ellipse `width` pixels inside it, within [start, end] degrees (0 = 3 o'clock, clockwise).
    public mutating func arc(x0: Double, y0: Double, x1: Double, y1: Double, start: Double, end: Double,
                             width: Int, _ c: RGB) {
        ellipseRing(x0: x0, y0: y0, x1: x1, y1: y1, start: start, end: end, width: Double(width), c)
    }

    /// draw.ellipse(bbox, fill): filled ellipse.
    public mutating func fillEllipse(x0: Double, y0: Double, x1: Double, y1: Double, _ c: RGB) {
        ellipseRing(x0: x0, y0: y0, x1: x1, y1: y1, start: 0, end: 360, width: .infinity, c)
    }

    private mutating func ellipseRing(x0: Double, y0: Double, x1: Double, y1: Double, start: Double, end: Double,
                                      width: Double, _ c: RGB) {
        let a = (x1 - x0 + 1) / 2, b = (y1 - y0 + 1) / 2
        guard a > 0, b > 0 else { return }
        let cx = x0 + a, cy = y0 + b
        let full = end - start >= 360
        var s = start.truncatingRemainder(dividingBy: 360); if s < 0 { s += 360 }
        var span = end - start; if !full { span = span.truncatingRemainder(dividingBy: 360); if span < 0 { span += 360 } }
        let ia = a - width, ib = b - width
        for py in Int(y0.rounded(.down))...Int(y1.rounded(.up)) {
            for px in Int(x0.rounded(.down))...Int(x1.rounded(.up)) {
                let dx = Double(px) + 0.5 - cx, dy = Double(py) + 0.5 - cy
                guard (dx * dx) / (a * a) + (dy * dy) / (b * b) <= 1 else { continue }
                if ia > 0 && ib > 0 && (dx * dx) / (ia * ia) + (dy * dy) / (ib * ib) < 1 { continue }
                if !full {
                    var ang = atan2(dy, dx) * 180 / .pi; if ang < 0 { ang += 360 }
                    var rel = ang - s; if rel < 0 { rel += 360 }
                    guard rel <= span else { continue }
                }
                set(px, py, c)
            }
        }
    }

    // MARK: - Image files

    /// Loads an image file as RGB, dropping alpha the way Pillow does when pasting an RGBA image onto an RGB one.
    public static func load(_ url: URL) -> Bitmap? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        var out = Bitmap(width: w, height: h)
        // Fast path: 8-bit RGB(A) data straight from the decoder, unpremultiplied (keeps transparent pixels' RGB)
        if img.bitsPerComponent == 8, let data = img.dataProvider?.data, let base = CFDataGetBytePtr(data),
           img.colorSpace?.model == .rgb {
            let bpp = img.bitsPerPixel / 8, row = img.bytesPerRow, alpha = img.alphaInfo
            let first = alpha == .first || alpha == .premultipliedFirst || alpha == .noneSkipFirst
            let bgr = img.bitmapInfo.contains(.byteOrder32Little)
            if bpp == 3 || bpp == 4 {
                for y in 0..<h {
                    for x in 0..<w {
                        let p = base + y * row + x * bpp
                        var (r, g, b): (UInt8, UInt8, UInt8)
                        if bpp == 3 { (r, g, b) = (p[0], p[1], p[2]) }
                        else if bgr { (r, g, b) = first ? (p[2], p[1], p[0]) : (p[3], p[2], p[1]) }
                        else { (r, g, b) = first ? (p[1], p[2], p[3]) : (p[0], p[1], p[2]) }
                        if alpha == .premultipliedLast || alpha == .premultipliedFirst {
                            let a = Int(bgr ? (first ? p[3] : p[0]) : (first ? p[0] : p[3]))
                            if a > 0 && a < 255 {
                                r = UInt8(min(255, Int(r) * 255 / a)); g = UInt8(min(255, Int(g) * 255 / a))
                                b = UInt8(min(255, Int(b) * 255 / a))
                            }
                        }
                        let i = out.index(x, y)
                        out.pixels[i] = r; out.pixels[i + 1] = g; out.pixels[i + 2] = b
                    }
                }
                return out
            }
        }
        // Fallback (grayscale, 16-bit, palettes): draw into an opaque RGB context
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in 0..<(w * h) {
            out.pixels[i * 3] = rgba[i * 4]; out.pixels[i * 3 + 1] = rgba[i * 4 + 1]; out.pixels[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return out
    }

    /// Image.resize with a smooth (bicubic-like) filter.
    public func resized(width w: Int, height h: Int) -> Bitmap {
        guard w > 0, h > 0, w != width || h != height, let src = cgImage() else { return self }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return self }
        ctx.interpolationQuality = .high
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out = Bitmap(width: w, height: h)
        for i in 0..<(w * h) {
            out.pixels[i * 3] = rgba[i * 4]; out.pixels[i * 3 + 1] = rgba[i * 4 + 1]; out.pixels[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return out
    }

    public func cgImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public func writePNG(_ url: URL) throws {
        guard let img = cgImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
