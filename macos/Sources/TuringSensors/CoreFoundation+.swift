import CoreFoundation
import Foundation
import IOKit

/// IORegistry helpers shared by the Apple Silicon sensors.
enum IORegistry {
    /// First service matching an IOKit class name, or nil.
    static func service(_ className: String) -> io_service_t? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
        return service == 0 ? nil : service
    }

    /// All services matching an IOKit class name. Caller releases each with IOObjectRelease.
    static func services(_ className: String) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [io_service_t] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 { result.append(entry) }
        return result
    }

    static func name(_ entry: io_registry_entry_t) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(entry, &buf)
        return String(cString: buf)
    }

    static func property(_ entry: io_registry_entry_t, _ key: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(entry, key as NSString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
