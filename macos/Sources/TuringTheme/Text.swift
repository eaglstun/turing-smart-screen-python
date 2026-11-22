import AppKit
import CoreGraphics
import CoreText
import Foundation

/// A TrueType font at a pixel size, loaded from a file like ImageFont.truetype(path, size).
final class Font {
    let ctFont: CTFont
    /// FreeType size metrics in whole pixels (hinted fonts round the ascender up and the descender down).
    let ascender: Int, descender: Int
    /// The font's Unicode character map, read from its 'cmap' table.
    let cmap: CMap?
    /// Snap glyph tops and bottoms to the nearest pixel like FreeType hinting (font files, to match Pillow).
    /// The system font is drawn unhinted, so its ink boxes round outward instead or strokes get clipped.
    let hinted: Bool

    private static var cache: [String: Font] = [:]

    /// `path` is a font file, or a system font spec from `systemSpec(forFile:)` ("system:<weight>[:mono]").
    static func load(_ path: String, size: Int) -> Font? {
        let key = "\(path)#\(size)"
        if let f = cache[key] { return f }
        let font: CTFont
        if path.hasPrefix("system:") {
            font = systemFont(path, size: CGFloat(size))
        } else {
            guard let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL),
                  let cg = CGFont(provider) else { return nil }
            font = CTFontCreateWithGraphicsFont(cg, CGFloat(size), nil, nil)
        }
        let f = Font(font, hinted: !path.hasPrefix("system:"))
        cache[key] = f
        return f
    }

    // MARK: - System font (San Francisco)

    /// The system font that stands in for a font file: same weight (OS/2 usWeightClass), SF Mono if the file is
    /// monospaced (post isFixedPitch). Returns nil if the file can't be read.
    static func systemSpec(forFile path: String) -> String? {
        guard let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL), let cg = CGFont(provider)
        else { return nil }
        var weight = 400, mono = false
        if let os2 = cg.table(for: CTFontTableTag(kCTFontTableOS2)) as Data?, os2.count >= 6 {
            weight = Int(os2[4]) << 8 | Int(os2[5])
        }
        if let post = cg.table(for: CTFontTableTag(kCTFontTablePost)) as Data?, post.count >= 16 {
            mono = post[12...15].contains { $0 != 0 }
        }
        return "system:\(weight)" + (mono ? ":mono" : "")
    }

    private static func systemFont(_ spec: String, size: CGFloat) -> CTFont {
        let parts = spec.split(separator: ":")
        let w = parts.count > 1 ? Int(parts[1]) ?? 400 : 400
        let weight: NSFont.Weight
        switch w {
        case ..<150: weight = .ultraLight
        case ..<250: weight = .thin
        case ..<350: weight = .light
        case ..<450: weight = .regular
        case ..<550: weight = .medium
        case ..<650: weight = .semibold
        case ..<750: weight = .bold
        case ..<850: weight = .heavy
        default: weight = .black
        }
        // Proportional text gets tabular figures so changing numbers don't shift sideways
        let ns = parts.contains("mono") ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        return ns as CTFont
    }

    private init(_ font: CTFont, hinted: Bool) {
        ctFont = font
        self.hinted = hinted
        cmap = (CTFontCopyTable(font, CTFontTableTag(kCTFontTableCmap), []) as Data?).flatMap(CMap.init)
        // FreeType's face ascender/descender: OS/2 typo metrics when the font sets USE_TYPO_METRICS (fsSelection
        // bit 7), otherwise 'hhea' (CoreText may pick differently). Scaled size metrics round outward to pixels.
        let size = Double(CTFontGetSize(font)), upem = Double(CTFontGetUnitsPerEm(font))
        func int16(_ d: Data, _ o: Int) -> Int16 { Int16(bitPattern: UInt16(d[o]) << 8 | UInt16(d[o + 1])) }
        let os2 = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?
        let hhea = CTFontCopyTable(font, CTFontTableTag(kCTFontTableHhea), []) as Data?
        var units: (Int16, Int16)?
        if let os2, os2.count >= 72, UInt16(os2[62]) << 8 | UInt16(os2[63]) & 0x80 != 0 {
            units = (int16(os2, 68), int16(os2, 70))
        } else if let hhea, hhea.count >= 8, int16(hhea, 4) != 0 || int16(hhea, 6) != 0 {
            units = (int16(hhea, 4), int16(hhea, 6))
        } else if let os2, os2.count >= 72 {
            units = (int16(os2, 68), int16(os2, 70))
        }
        if let (asc, desc) = units {
            ascender = Int((Double(asc) * size / upem).rounded(.up))
            descender = Int((Double(desc) * size / upem).rounded(.down))
        } else {
            ascender = Int(CTFontGetAscent(font).rounded(.up))
            descender = -Int(CTFontGetDescent(font).rounded(.up))
        }
    }
}

/// Single-line text laid out the way Pillow's FreeType + Raqm path does (_imagingft.c bounding_box_and_anchors):
/// glyph origins are whole pixels (PIXEL of the 26.6 pen position), advances are HarfBuzz's unhinted 26.6 values,
/// and the bounding box is the union of the advance and each glyph's pixel-snapped ink box.
struct TextLayout {
    let font: Font
    let glyphs: [CGGlyph]
    let originX: [Int]          // glyph origin, pixels from the pen start
    let xMin: Int, xMax: Int    // pixel extents, relative to the pen start
    let yMin: Int, yMax: Int    // pixel extents, y up from the baseline
    let position: Int           // final pen position, 26.6

    @inline(__always) private static func PIXEL(_ v: Int) -> Int { (v + 32) >> 6 }

    /// HarfBuzz's space fallback: a Unicode space the font lacks is drawn as the regular space glyph at this width
    /// (fraction of the em, or of the space advance for U+202F), instead of a fallback font.
    private static func fallbackSpaceWidth(_ c: Unicode.Scalar, font: Font) -> Double? {
        let em = Double(CTFontGetSize(font.ctFont))
        func advance(_ s: String) -> Double {
            var u = Array(s.utf16), g = [CGGlyph](repeating: 0, count: u.count)
            guard CTFontGetGlyphsForCharacters(font.ctFont, &u, &g, u.count) else { return 0 }
            return CTFontGetAdvancesForGlyphs(font.ctFont, .horizontal, g, nil, 1)
        }
        switch c.value {
        case 0x00A0: return advance(" ")
        case 0x2000, 0x2002: return em / 2
        case 0x2001, 0x2003: return em
        case 0x2004: return em / 3
        case 0x2005: return em / 4
        case 0x2006: return em / 6
        case 0x2007: return advance("0")
        case 0x2008: return advance(".")
        case 0x2009: return em / 5
        case 0x200A: return em / 16
        case 0x202F: return advance(" ") / 2
        case 0x205F: return em * 4 / 18
        default: return nil
        }
    }

    init(_ text: String, font: Font, startX: Double = 0) {
        self.font = font
        // Characters the font lacks: Unicode spaces become a sized space (HarfBuzz), anything else .notdef (glyph 0)
        var shaped = "", overrides: [Int: Double] = [:]  // UTF-16 offset -> advance in pixels
        for c in text.unicodeScalars {
            // The font's own cmap decides, as for HarfBuzz (CoreText synthesizes mappings for some characters)
            let present = font.cmap.map { $0.glyph(c.value) != 0 } ?? true
            if !present, let w = Self.fallbackSpaceWidth(c, font: font) {
                overrides[shaped.utf16.count] = w
                shaped.unicodeScalars.append(" ")
            } else {
                shaped.unicodeScalars.append(c)
            }
        }
        let attr = NSAttributedString(string: shaped, attributes: [kCTFontAttributeName as NSAttributedString.Key: font.ctFont])
        let line = CTLineCreateWithAttributedString(attr)
        let ourName = CTFontCopyPostScriptName(font.ctFont) as String
        let notdefAdvance = CTFontGetAdvancesForGlyphs(font.ctFont, .horizontal, [CGGlyph(0)], nil, 1)
        var glyphs: [CGGlyph] = [], advances: [CGSize] = []
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let n = CTRunGetGlyphCount(run)
            var g = [CGGlyph](repeating: 0, count: n), a = [CGSize](repeating: .zero, count: n)
            var idx = [CFIndex](repeating: 0, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &g)
            CTRunGetAdvances(run, CFRange(location: 0, length: n), &a)
            CTRunGetStringIndices(run, CFRange(location: 0, length: n), &idx)
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = attrs[kCTFontAttributeName as String] as! CTFont
            let fallback = CTFontCopyPostScriptName(runFont) as String != ourName
            for i in 0..<n {
                if let w = overrides[idx[i]] { a[i].width = w }
                else if fallback { g[i] = 0; a[i].width = notdefAdvance }  // CoreText borrowed another font
            }
            glyphs += g; advances += a
        }
        var rects = [CGRect](repeating: .zero, count: glyphs.count)
        CTFontGetBoundingRectsForGlyphs(font.ctFont, .horizontal, glyphs, &rects, glyphs.count)

        var position = Int((startX * 64).rounded()), xMin = 0, xMax = 0, yMin = 0, yMax = 0
        var origins: [Int] = []
        for i in 0..<glyphs.count {
            let px = Self.PIXEL(position)
            origins.append(px)
            position += Int((advances[i].width * 64).rounded())  // HarfBuzz advances: unhinted, 26.6
            xMax = max(xMax, Self.PIXEL(position))
            let r = rects[i]
            guard !r.isEmpty else { continue }
            xMin = min(xMin, px + Int(r.minX.rounded(.down))); xMax = max(xMax, px + Int(r.maxX.rounded(.up)))
            // FreeType hinting snaps vertical extents (cap height, overshoots, baseline) to the pixel grid
            if font.hinted {
                yMin = min(yMin, Int(r.minY.rounded())); yMax = max(yMax, Int(r.maxY.rounded()))
            } else {
                yMin = min(yMin, Int(r.minY.rounded(.down))); yMax = max(yMax, Int(r.maxY.rounded(.up)))
            }
        }
        (self.glyphs, originX, self.position) = (glyphs, origins, position)
        (self.xMin, self.xMax, self.yMin, self.yMax) = (xMin, xMax, yMin, yMax)
    }

    var width: Int { xMax - xMin }
    var height: Int { yMax - yMin }

    /// Offset of the anchor point from the pen start (x right, y up), per Pillow's anchor letters.
    func anchorPoint(_ anchor: String) -> (x: Int, y: Int) {
        let a = Array(anchor.count == 2 ? anchor : "la")
        let x: Int
        switch a[0] {
        case "m": x = Self.PIXEL(position / 2)
        case "r": x = Self.PIXEL(position)
        default: x = 0
        }
        let y: Int
        switch a[1] {
        case "a": y = font.ascender
        case "t": y = yMax
        case "m": y = Self.PIXEL((font.ascender + font.descender) * 64 / 2)
        case "b": y = yMin
        case "d": y = font.descender
        default: y = 0  // "s" baseline
        }
        return (x, y)
    }

    /// ImageDraw.textbbox((x, y), text, anchor): (left, top, right, bottom) in screen pixels.
    func bbox(x: Int, y: Int, anchor: String) -> (Int, Int, Int, Int) {
        let p = anchorPoint(anchor)
        let left = x - p.x + xMin, top = y + p.y - yMax
        return (left, top, left + width, top + height)
    }

    /// ImageDraw.text((x, y), text, fill, anchor): rasterize with CoreText, blend with Pillow's BLEND.
    func draw(into bmp: inout Bitmap, x: Int, y: Int, anchor: String, color: RGB, clip: (Int, Int, Int, Int)? = nil) {
        guard width > 0, height > 0 else { return }
        let p = anchorPoint(anchor)
        let (w, h) = (width, height)
        var mask = [UInt8](repeating: 0, count: w * h)
        // Grayscale coverage mask: white glyphs on black, so each byte is the glyph coverage (0-255)
        guard let ctx = CGContext(data: &mask, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(false)
        ctx.setAllowsFontSubpixelPositioning(false)
        ctx.setShouldSubpixelPositionFonts(false)
        ctx.setAllowsFontSubpixelQuantization(false)
        // Mask row 0 is the top (yMax); CoreGraphics is y-up, so the baseline sits at -yMin from the bottom.
        let positions = originX.map { CGPoint(x: CGFloat($0 - xMin), y: CGFloat(-yMin)) }
        CTFontDrawGlyphs(font.ctFont, glyphs, positions, glyphs.count, ctx)

        let left = x - p.x + xMin, top = y + p.y - yMax
        for my in 0..<h {
            let sy = top + my
            if let c = clip, sy < c.1 || sy >= c.3 { continue }
            for mx in 0..<w {
                let a = mask[my * w + mx]  // bitmap memory row 0 is the top of the image
                guard a > 0 else { continue }
                let sx = left + mx
                if let c = clip, sx < c.0 || sx >= c.2 { continue }
                bmp.blend(sx, sy, color, a)
            }
        }
    }
}

/// Debug helper: layout metrics in Pillow's terms, for checking against ImageFont.getbbox / getmetrics.
public enum TextMetrics {
    public static func describe(font path: String, size: Int, text: String) -> String {
        guard let f = Font.load(path, size: size) else { return "cannot load \(path)" }
        let l = TextLayout(text, font: f)
        var rects = [CGRect](repeating: .zero, count: l.glyphs.count)
        CTFontGetBoundingRectsForGlyphs(f.ctFont, .horizontal, l.glyphs, &rects, l.glyphs.count)
        let la = l.bbox(x: 0, y: 0, anchor: "la"), lt = l.bbox(x: 0, y: 0, anchor: "lt")
        return "metrics (\(f.ascender), \(-f.descender)) la \(la) lt \(lt) length \(Double(l.position) / 64)\n" +
            "origins \(l.originX) glyphs \(l.glyphs)\n" + "glyph tops " + rects.map { String(format: "%.2f", $0.maxY) }.joined(separator: " ") + "\n" +
            "glyph bottoms " + rects.map { String(format: "%.2f", $0.minY) }.joined(separator: " ")
    }
}

/// Unicode -> glyph lookup from a font's 'cmap' table (formats 4 and 12), with no synthesized mappings.
struct CMap {
    private let data: Data
    private let format: UInt16, offset: Int

    init?(_ table: Data) {
        data = table
        func u16(_ o: Int) -> UInt16 { UInt16(table[o]) << 8 | UInt16(table[o + 1]) }
        func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) << 16 | UInt32(u16(o + 2)) }
        guard table.count >= 4 else { return nil }
        var best: (rank: Int, format: UInt16, offset: Int)?
        for i in 0..<Int(u16(2)) {
            let rec = 4 + 8 * i
            guard rec + 8 <= table.count else { break }
            let (pid, eid, off) = (u16(rec), u16(rec + 2), Int(u32(rec + 4)))
            guard off + 2 <= table.count else { continue }
            let fmt = u16(off)
            // Prefer full Unicode (format 12), then the BMP Windows/Unicode subtables (format 4)
            let rank: Int
            switch (fmt, pid, eid) {
            case (12, 3, 10), (12, 0, _): rank = 3
            case (4, 3, 1), (4, 0, _): rank = 2
            case (4, _, _): rank = 1
            default: continue
            }
            if best == nil || rank > best!.rank { best = (rank, fmt, off) }
        }
        guard let best else { return nil }
        (format, offset) = (best.format, best.offset)
    }

    private func u16(_ o: Int) -> UInt16 { UInt16(data[o]) << 8 | UInt16(data[o + 1]) }
    private func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) << 16 | UInt32(u16(o + 2)) }

    func glyph(_ c: UInt32) -> UInt32 {
        if format == 12 {
            let n = Int(u32(offset + 12))
            for g in 0..<n {
                let rec = offset + 16 + 12 * g
                let (start, end, startGlyph) = (u32(rec), u32(rec + 4), u32(rec + 8))
                if c >= start && c <= end { return startGlyph + (c - start) }
            }
            return 0
        }
        guard c <= 0xFFFF else { return 0 }
        let segX2 = Int(u16(offset + 6)), ends = offset + 14, starts = ends + segX2 + 2
        let deltas = starts + segX2, ranges = deltas + segX2
        for s in 0..<(segX2 / 2) {
            let end = UInt32(u16(ends + 2 * s))
            guard c <= end else { continue }
            let start = UInt32(u16(starts + 2 * s))
            guard c >= start else { return 0 }
            let delta = u16(deltas + 2 * s), rangeOffset = Int(u16(ranges + 2 * s))
            if rangeOffset == 0 { return UInt32((UInt16(truncatingIfNeeded: c) &+ delta)) }
            let addr = ranges + 2 * s + rangeOffset + 2 * Int(c - start)
            guard addr + 2 <= data.count else { return 0 }
            let g = u16(addr)
            return g == 0 ? 0 : UInt32(g &+ delta)
        }
        return 0
    }
}
