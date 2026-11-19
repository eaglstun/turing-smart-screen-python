import CoreFoundation
import Foundation

/// Private IOReport framework (libIOReport.dylib), loaded at runtime.
/// Gives per-state residency for CPU clusters and the GPU, the way macmon reads frequencies without sudo.
final class IOReport {
    private typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64)
        -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription = @convention(c) (
        UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
        UInt64, CFTypeRef?
    ) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?)
        -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?)
        -> Unmanaged<CFDictionary>?
    private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias StateGetCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateGetName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateGetResidency = @convention(c) (CFDictionary, Int32) -> Int64

    private let copyChannelsInGroup: CopyChannelsInGroup
    private let createSubscription: CreateSubscription
    private let createSamples: CreateSamples
    private let createSamplesDelta: CreateSamplesDelta
    private let channelGetName: ChannelString
    private let stateGetCount: StateGetCount
    private let stateGetName: StateGetName
    private let stateGetResidency: StateGetResidency

    static let shared: IOReport? = IOReport()

    private init?() {
        guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _: T.Type) -> T? {
            guard let p = dlsym(lib, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let a = sym("IOReportCopyChannelsInGroup", CopyChannelsInGroup.self),
              let b = sym("IOReportCreateSubscription", CreateSubscription.self),
              let c = sym("IOReportCreateSamples", CreateSamples.self),
              let d = sym("IOReportCreateSamplesDelta", CreateSamplesDelta.self),
              let e = sym("IOReportChannelGetChannelName", ChannelString.self),
              let f = sym("IOReportStateGetCount", StateGetCount.self),
              let g = sym("IOReportStateGetNameForIndex", StateGetName.self),
              let h = sym("IOReportStateGetResidency", StateGetResidency.self)
        else { return nil }
        (copyChannelsInGroup, createSubscription, createSamples, createSamplesDelta) = (a, b, c, d)
        (channelGetName, stateGetCount, stateGetName, stateGetResidency) = (e, f, g, h)
    }

    /// One channel of a sample delta: its name and (state name, residency) pairs.
    struct Channel {
        let name: String
        let states: [(name: String, residency: Int64)]
    }

    /// Subscription to one group/subgroup; each `sample()` returns the per-channel deltas since the previous call.
    final class Sampler {
        private let ior: IOReport
        private let subscription: OpaquePointer
        private let subscribed: CFMutableDictionary
        private var previous: CFDictionary

        init?(group: String, subgroup: String) {
            guard let ior = IOReport.shared,
                  let channels = ior.copyChannelsInGroup(group as CFString, subgroup as CFString, 0, 0, 0)?
                      .takeRetainedValue()
            else { return nil }
            var subbed: Unmanaged<CFMutableDictionary>?
            guard let sub = ior.createSubscription(nil, channels, &subbed, 0, nil),
                  let subscribed = subbed?.takeRetainedValue(),
                  let first = ior.createSamples(sub, subscribed, nil)?.takeRetainedValue()
            else { return nil }
            self.ior = ior
            subscription = sub
            self.subscribed = subscribed
            previous = first
        }

        func sample() -> [Channel] {
            guard let current = ior.createSamples(subscription, subscribed, nil)?.takeRetainedValue() else { return [] }
            defer { previous = current }
            guard let delta = ior.createSamplesDelta(previous, current, nil)?.takeRetainedValue(),
                  let channels = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary]
            else { return [] }
            return channels.map { ch in
                let dict = ch as CFDictionary
                let name = ior.channelGetName(dict)?.takeUnretainedValue() as String? ?? ""
                let states = (0..<ior.stateGetCount(dict)).map { i in
                    (name: ior.stateGetName(dict, i)?.takeUnretainedValue() as String? ?? "",
                     residency: ior.stateGetResidency(dict, i))
                }
                return Channel(name: name, states: states)
            }
        }
    }
}

/// DVFS frequency tables (MHz) from the pmgr IORegistry entry.
enum PMGR {
    /// E-cluster, P-cluster(s) and GPU tables. CPU tables are Hz on M1-M3 and kHz on M4; GPU tables are Hz.
    static let tables: [String: [Double]] = {
        let keys = ["E": "voltage-states1-sram", "P": "voltage-states5-sram", "GPU": "voltage-states9"]
        var result: [String: [Double]] = [:]
        for entry in IORegistry.services("AppleARMIODevice") {
            defer { IOObjectRelease(entry) }
            guard IORegistry.name(entry) == "pmgr" else { continue }
            for (kind, key) in keys {
                guard let data = IORegistry.property(entry, key) as? Data else { continue }
                // Pairs of (frequency, voltage) as little-endian UInt32; GPU tables start with 0 for the OFF state
                let freqs = stride(from: 0, to: data.count - 7, by: 8).map { off in
                    data.subdata(in: off..<off + 4).withUnsafeBytes { Double(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
                }.filter { $0 > 0 }
                guard let maxFreq = freqs.max() else { continue }
                let scale = maxFreq > 1e8 ? 1e6 : 1e3
                result[kind] = freqs.map { $0 / scale }
            }
        }
        return result
    }()

    private static let idleStates: Set<String> = ["IDLE", "DOWN", "OFF"]

    /// Residency-weighted average frequency (MHz) over a channel's active states; nil if it was idle throughout.
    static func averageMHz(_ channel: IOReport.Channel, table: [Double]) -> Double? {
        var weighted = 0.0, active: Int64 = 0, index = 0
        for state in channel.states where !idleStates.contains(state.name) {
            if index < table.count {
                weighted += Double(state.residency) * table[index]
                active += state.residency
            }
            index += 1
        }
        return active > 0 ? weighted / Double(active) : nil
    }
}
