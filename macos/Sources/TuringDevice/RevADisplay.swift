import Foundation
import IOKit
import IOUSBHost
import TuringTheme

/// Turing / UsbMonitor 3.5" rev. A display (USB 1a86:5722), driven over raw USB bulk transfers like the vendor
/// Windows app. On macOS the CDC serial path corrupts images: the firmware treats pixel data per 64-byte USB
/// packet, so every command is its own transfer and bitmaps are always whole 64-byte packets (see mac-fix/README.md).
public final class RevADisplay {
    public static let vendorID = 0x1A86, productID = 0x5722
    static let dataInterface = 1, outEndpoint: UInt8 = 0x03
    static let chunk = 4096  // multiple of 64; the firmware only sees 64-byte packets anyway

    public enum Orientation: UInt8 { case portrait = 0, reversePortrait = 1, landscape = 2, reverseLandscape = 3 }

    public enum DriverError: Error, CustomStringConvertible {
        case notFound, open(Error), pipe(Error), write(Error)
        public var description: String {
            switch self {
            case .notFound: return "display not found on USB (1a86:5722)"
            case .open(let e): return "cannot open the display's USB interface: \(e.localizedDescription)"
            case .pipe(let e): return "cannot open the display's USB endpoint: \(e.localizedDescription)"
            case .write(let e): return "USB write failed: \(e.localizedDescription)"
            }
        }
    }

    private let interface: IOUSBHostInterface
    private let pipe: IOUSBHostPipe
    public private(set) var width = 320, height = 480

    /// Opens the display's CDC data interface. Works alongside Apple's CDC driver as long as nothing has the
    /// /dev/cu.usbmodem* serial port open.
    public init() throws {
        guard let service = Self.findDataInterface() else { throw DriverError.notFound }
        defer { IOObjectRelease(service) }
        do {
            interface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
        } catch { throw DriverError.open(error) }
        do {
            pipe = try interface.copyPipe(withAddress: Int(Self.outEndpoint))
        } catch { interface.destroy(); throw DriverError.pipe(error) }
    }

    deinit { interface.destroy() }

    /// The display's CDC data interface: an IOUSBHostInterface with our vendor/product IDs and interface number.
    static func findDataInterface() -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator)
                == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        func int(_ entry: io_service_t, _ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                as? NSNumber)?.intValue
        }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            if int(entry, "idVendor") == vendorID, int(entry, "idProduct") == productID,
               int(entry, "bInterfaceNumber") == dataInterface {
                return entry
            }
            IOObjectRelease(entry)
        }
        return nil
    }

    /// Whether the display is plugged in (without opening it).
    public static var isConnected: Bool {
        guard let s = findDataInterface() else { return false }
        IOObjectRelease(s)
        return true
    }

    /// One USB transfer.
    func write(_ bytes: [UInt8]) throws {
        let data = NSMutableData(bytes: bytes, length: bytes.count)
        var sent = 0
        do { try pipe.__sendIORequest(with: data, bytesTransferred: &sent, completionTimeout: 10) }
        catch { throw DriverError.write(error) }
    }

    static func header(_ cmd: UInt8, x: Int, y: Int, ex: Int, ey: Int) -> [UInt8] {
        [UInt8(x >> 2), UInt8(((x & 3) << 6) + (y >> 4)), UInt8(((y & 15) << 4) + (ex >> 6)),
         UInt8(((ex & 63) << 2) + (ey >> 8)), UInt8(ey & 255), cmd]
    }

    /// Brightness 0-100% (the panel uses 0 = brightest, 255 = darkest).
    public func setBrightness(_ percent: Int) throws {
        let level = 255 - Int(Double(max(0, min(100, percent))) / 100 * 255)
        try write(Self.header(110, x: level, y: 0, ex: 0, ey: 0))
    }

    public func setOrientation(_ o: Orientation, width w: Int, height h: Int) throws {
        (width, height) = (w, h)
        var buf = Self.header(121, x: 0, y: 0, ex: 0, ey: 0)  // 11 bytes: command + orientation + size
        buf += [o.rawValue + 100, UInt8(w >> 8), UInt8(w & 255), UInt8(h >> 8), UInt8(h & 255)]
        try write(buf)
    }

    public func screenOn() throws { try write(Self.header(109, x: 0, y: 0, ex: 0, ey: 0)) }
    public func screenOff() throws { try write(Self.header(108, x: 0, y: 0, ex: 0, ey: 0)) }

    /// Draws an image at (x, y). Its width must be a multiple of 32 px so the pixel data is whole 64-byte packets
    /// (a short final packet would be padded with stale pixels by the firmware).
    public func draw(_ image: Bitmap, x: Int, y: Int) throws {
        precondition(image.width % 32 == 0 || (image.width * image.height) % 32 == 0, "bitmap must be whole packets")
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 2)
        image.pixels.withUnsafeBufferPointer { src in
            for i in 0..<(image.width * image.height) {
                let r = UInt16(src[i * 3]), g = UInt16(src[i * 3 + 1]), b = UInt16(src[i * 3 + 2])
                let v = (r << 8) & 0xF800 | (g << 3) & 0x07E0 | b >> 3  // RGB565, little-endian on the wire
                pixels[i * 2] = UInt8(v & 0xFF); pixels[i * 2 + 1] = UInt8(v >> 8)
            }
        }
        try write(Self.header(197, x: x, y: y, ex: x + image.width - 1, ey: y + image.height - 1))
        Thread.sleep(forTimeInterval: 0.01)  // the vendor app pauses 10 ms between header and pixel data
        var offset = 0
        while offset < pixels.count {
            let end = min(offset + Self.chunk, pixels.count)
            try write(Array(pixels[offset..<end]))
            offset = end
        }
    }
}
