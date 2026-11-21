import Foundation
import IOKit

/// Minimal read-only AppleSMC client (temperature sensors). No root needed.
/// Sensor key names change between chip generations, so keys are discovered from the SMC's own key table.
final class SMC {
    private var connection: io_connect_t = 0
    private var keyInfoCache: [String: [UInt8]] = [:]

    private static let readKey: UInt8 = 5, keyFromIndex: UInt8 = 8, keyInfo: UInt8 = 9
    /// Sensors of parked CPU cores report exactly 40.0 until the core wakes; real readings have decimals.
    private static let placeholder: Float = 40.0

    init?() {
        guard let service = IORegistry.service("AppleSMC") else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit { IOServiceClose(connection) }

    /// Calls the SMC with an 80-byte SMCKeyData buffer; returns the output, or nil on error.
    private func call(_ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: 80)
        var outSize = 80
        let r = input.withUnsafeBytes { inp in
            output.withUnsafeMutableBytes { out in
                IOConnectCallStructMethod(connection, 2, inp.baseAddress, 80, out.baseAddress, &outSize)
            }
        }
        return r == KERN_SUCCESS && output[40] == 0 ? output : nil  // output[40] = SMC result code
    }

    private static func request(_ key: String, _ selector: UInt8) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 80)
        let code = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        withUnsafeBytes(of: code.littleEndian) { buf.replaceSubrange(0..<4, with: $0) }
        buf[42] = selector
        return buf
    }

    private func info(_ key: String) -> [UInt8]? {
        if let cached = keyInfoCache[key] { return cached.isEmpty ? nil : cached }
        let out = call(Self.request(key, Self.keyInfo)).map { Array($0[28..<37]) }
        keyInfoCache[key] = out ?? []
        return out
    }

    private func readRaw(_ key: String) -> (type: String, bytes: [UInt8])? {
        guard let info = info(key) else { return nil }
        var buf = Self.request(key, Self.readKey)
        buf.replaceSubrange(28..<37, with: info)
        guard let out = call(buf) else { return nil }
        let size = Int(UInt32(info[0]) | UInt32(info[1]) << 8 | UInt32(info[2]) << 16 | UInt32(info[3]) << 24)
        let type = String(bytes: info[4..<8].reversed(), encoding: .ascii) ?? ""
        return (type, Array(out[48..<48 + min(size, 32)]))
    }

    func float(_ key: String) -> Float? {
        guard let (type, b) = readRaw(key) else { return nil }
        if type == "flt ", b.count == 4 {
            return Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
        }
        if type == "sp78", b.count == 2 { return Float(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256 }
        return nil
    }

    /// All SMC keys starting with prefix (enumerates the SMC key table; call once and cache).
    func keys(prefix: String) -> [String] {
        guard let raw = readRaw("#KEY"), raw.bytes.count >= 4 else { return [] }
        let count = UInt32(raw.bytes[0]) << 24 | UInt32(raw.bytes[1]) << 16 | UInt32(raw.bytes[2]) << 8 | UInt32(raw.bytes[3])
        var found: [String] = []
        for i in 0..<count {
            var req = [UInt8](repeating: 0, count: 80)
            req[42] = Self.keyFromIndex
            withUnsafeBytes(of: i.littleEndian) { req.replaceSubrange(44..<48, with: $0) }
            guard let out = call(req) else { continue }
            let code = UInt32(out[0]) | UInt32(out[1]) << 8 | UInt32(out[2]) << 16 | UInt32(out[3]) << 24
            let key = String(bytes: withUnsafeBytes(of: code.bigEndian, Array.init), encoding: .ascii) ?? ""
            if key.hasPrefix(prefix) { found.append(key) }
        }
        return found
    }

    /// Float keys under prefix, not filtered on their current value (parked cores read 0 or a placeholder).
    func temperatureSensors(prefix: String) -> [String] {
        keys(prefix: prefix).filter { float($0) != nil }
    }

    /// A plausible temperature (°C), or nil for a parked sensor: those read the 40.0 placeholder, 0, or under 2°C.
    func temperature(_ key: String) -> Double? {
        guard let v = float(key), v >= 10, v < 130, v != Self.placeholder else { return nil }
        return Double(v)
    }

    /// Average of plausible readings (see `temperature(_:)`).
    func average(_ keys: [String]) -> Double? {
        let values = keys.compactMap { float($0) }.filter { $0 >= 10 && $0 < 130 && $0 != Self.placeholder }
        return values.isEmpty ? nil : Double(values.reduce(0, +)) / Double(values.count)
    }
}
