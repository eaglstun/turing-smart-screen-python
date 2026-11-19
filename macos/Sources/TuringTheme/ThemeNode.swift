import Foundation
import Yams

/// A parsed YAML value with the same semantics the Python app relies on: mappings keep their file order
/// (static images are drawn in order), and missing keys read as `.null` so lookups chain like `dict.get()`.
public indirect enum ThemeNode {
    case map([(key: String, value: ThemeNode)])
    case list([ThemeNode])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    public init(yaml node: Yams.Node?) {
        guard let node else { self = .null; return }
        switch node {
        case .mapping(let m):
            self = .map(m.map { (key: $0.key.string ?? "", value: ThemeNode(yaml: $0.value)) })
        case .sequence(let s):
            self = .list(s.map { ThemeNode(yaml: $0) })
        case .scalar:
            let tag = node.tag.description  // resolved YAML 1.1 tag, e.g. "tag:yaml.org,2002:bool"
            if tag.hasSuffix(":null") { self = .null }
            else if tag.hasSuffix(":bool"), let b = node.bool { self = .bool(b) }
            else if tag.hasSuffix(":int"), let i = node.int { self = .int(i) }
            else if tag.hasSuffix(":float"), let d = node.float { self = .double(d) }
            else { self = .string(node.string ?? "") }
        default:
            self = .null
        }
    }

    public static func load(_ url: URL) throws -> ThemeNode {
        let text = try String(contentsOf: url, encoding: .utf8)
        return ThemeNode(yaml: try Yams.compose(yaml: text))
    }

    public subscript(key: String) -> ThemeNode {
        if case .map(let pairs) = self, let v = pairs.first(where: { $0.key == key }) { return v.value }
        return .null
    }

    public var entries: [(key: String, value: ThemeNode)] {
        if case .map(let pairs) = self { return pairs }
        return []
    }

    public var isNull: Bool { if case .null = self { return true }; return false }
    public var isMap: Bool { if case .map = self { return true }; return false }

    public var string: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "True" : "False"
        default: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public var int: Int? { double.map { Int($0) } }

    public var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i != 0
        default: return nil
        }
    }

    public var list: [ThemeNode] { if case .list(let l) = self { return l }; return [] }

    // dict.get(key, default) helpers
    public func int(_ key: String, _ fallback: Int) -> Int { self[key].int ?? fallback }
    public func double(_ key: String, _ fallback: Double) -> Double { self[key].double ?? fallback }
    public func bool(_ key: String, _ fallback: Bool) -> Bool { self[key].bool ?? fallback }
    public func string(_ key: String, _ fallback: String) -> String { self[key].string ?? fallback }
    public func color(_ key: String, _ fallback: RGB) -> RGB { RGB(self[key]) ?? fallback }

    /// Recursively supply default values (library/config.py copy_default).
    public func withDefaults(_ defaults: ThemeNode) -> ThemeNode {
        guard case .map(var pairs) = self, case .map(let defaultPairs) = defaults else { return self }
        for (key, dv) in defaultPairs {
            if let i = pairs.firstIndex(where: { $0.key == key }) {
                if dv.isMap { pairs[i].value = pairs[i].value.withDefaults(dv) }
            } else {
                pairs.append((key: key, value: dv))
            }
        }
        return .map(pairs)
    }

    /// Returns a copy with `value` set at `key` (used to switch off unsupported widgets, like the Python app does).
    public func setting(_ key: String, _ value: ThemeNode) -> ThemeNode {
        guard case .map(var pairs) = self else { return self }
        if let i = pairs.firstIndex(where: { $0.key == key }) { pairs[i].value = value } else { pairs.append((key, value)) }
        return .map(pairs)
    }
}

/// 8-bit RGB color, parsed like library/lcd/color.py parse_color: "r, g, b" strings, lists, or #hex.
public struct RGB: Equatable {
    public var r: UInt8, g: UInt8, b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { (self.r, self.g, self.b) = (r, g, b) }

    public init?(_ node: ThemeNode) {
        switch node {
        case .list(let l) where l.count == 3:
            guard let r = l[0].int, let g = l[1].int, let b = l[2].int else { return nil }
            self.init(UInt8(clamping: r), UInt8(clamping: g), UInt8(clamping: b))
        case .string(let s):
            let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 3, let r = Int(parts[0]), let g = Int(parts[1]), let b = Int(parts[2]) {
                self.init(UInt8(clamping: r), UInt8(clamping: g), UInt8(clamping: b))
            } else if s.hasPrefix("#"), s.count == 7, let v = UInt32(s.dropFirst(), radix: 16) {
                self.init(UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF))
            } else if let named = RGB.named[s.lowercased()] {
                self = named
            } else {
                return nil
            }
        default:
            return nil
        }
    }

    static let named: [String: RGB] = [
        "black": RGB(0, 0, 0), "white": RGB(255, 255, 255), "red": RGB(255, 0, 0), "green": RGB(0, 128, 0),
        "blue": RGB(0, 0, 255), "yellow": RGB(255, 255, 0), "gray": RGB(128, 128, 128), "grey": RGB(128, 128, 128),
    ]
}
