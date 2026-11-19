# SPDX-License-Identifier: GPL-3.0-or-later
#
# Live CPU frequency on Apple Silicon, without sudo.
#
# psutil.cpu_freq() returns placeholder values on Apple Silicon. Like macmon, this reads the private
# IOReport framework: "CPU Stats" / "CPU Complex Performance States" gives, per CPU cluster, how long it
# spent in each DVFS state since the last sample. The frequency of each state comes from the pmgr device
# in the IORegistry (voltage-states*-sram). Average frequency = residency-weighted mean over active states.

import ctypes
import ctypes.util
import struct
from typing import Dict, List, Optional

_cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))
_iokit = ctypes.CDLL(ctypes.util.find_library("IOKit"))
_ior = ctypes.CDLL("/usr/lib/libIOReport.dylib")

_vp = ctypes.c_void_p
kCFStringEncodingUTF8 = 0x08000100

_cf.CFStringCreateWithCString.restype = _vp
_cf.CFStringCreateWithCString.argtypes = [_vp, ctypes.c_char_p, ctypes.c_uint32]
_cf.CFStringGetCString.restype = ctypes.c_bool
_cf.CFStringGetCString.argtypes = [_vp, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
_cf.CFDictionaryGetValue.restype = _vp
_cf.CFDictionaryGetValue.argtypes = [_vp, _vp]
_cf.CFArrayGetCount.restype = ctypes.c_long
_cf.CFArrayGetCount.argtypes = [_vp]
_cf.CFArrayGetValueAtIndex.restype = _vp
_cf.CFArrayGetValueAtIndex.argtypes = [_vp, ctypes.c_long]
_cf.CFDataGetLength.restype = ctypes.c_long
_cf.CFDataGetLength.argtypes = [_vp]
_cf.CFDataGetBytePtr.restype = ctypes.POINTER(ctypes.c_ubyte)
_cf.CFDataGetBytePtr.argtypes = [_vp]
_cf.CFRelease.restype = None
_cf.CFRelease.argtypes = [_vp]

_iokit.IOServiceMatching.restype = _vp
_iokit.IOServiceMatching.argtypes = [ctypes.c_char_p]
_iokit.IOServiceGetMatchingServices.restype = ctypes.c_int
_iokit.IOServiceGetMatchingServices.argtypes = [ctypes.c_uint32, _vp, ctypes.POINTER(ctypes.c_uint32)]
_iokit.IOIteratorNext.restype = ctypes.c_uint32
_iokit.IOIteratorNext.argtypes = [ctypes.c_uint32]
_iokit.IORegistryEntryGetName.restype = ctypes.c_int
_iokit.IORegistryEntryGetName.argtypes = [ctypes.c_uint32, ctypes.c_char_p]
_iokit.IORegistryEntryCreateCFProperty.restype = _vp
_iokit.IORegistryEntryCreateCFProperty.argtypes = [ctypes.c_uint32, _vp, _vp, ctypes.c_uint32]
_iokit.IOObjectRelease.restype = ctypes.c_int
_iokit.IOObjectRelease.argtypes = [ctypes.c_uint32]

_ior.IOReportCopyChannelsInGroup.restype = _vp
_ior.IOReportCopyChannelsInGroup.argtypes = [_vp, _vp, ctypes.c_uint64, ctypes.c_uint64, ctypes.c_uint64]
_ior.IOReportCreateSubscription.restype = _vp
_ior.IOReportCreateSubscription.argtypes = [_vp, _vp, ctypes.POINTER(_vp), ctypes.c_uint64, _vp]
_ior.IOReportCreateSamples.restype = _vp
_ior.IOReportCreateSamples.argtypes = [_vp, _vp, _vp]
_ior.IOReportCreateSamplesDelta.restype = _vp
_ior.IOReportCreateSamplesDelta.argtypes = [_vp, _vp, _vp]
for _name in ("IOReportChannelGetGroup", "IOReportChannelGetSubGroup", "IOReportChannelGetChannelName"):
    getattr(_ior, _name).restype = _vp
    getattr(_ior, _name).argtypes = [_vp]
_ior.IOReportStateGetCount.restype = ctypes.c_int32
_ior.IOReportStateGetCount.argtypes = [_vp]
_ior.IOReportStateGetNameForIndex.restype = _vp
_ior.IOReportStateGetNameForIndex.argtypes = [_vp, ctypes.c_int32]
_ior.IOReportStateGetResidency.restype = ctypes.c_int64
_ior.IOReportStateGetResidency.argtypes = [_vp, ctypes.c_int32]

_IDLE_STATES = {"IDLE", "DOWN", "OFF"}


def _cfstr(s: str):
    return _cf.CFStringCreateWithCString(None, s.encode(), kCFStringEncodingUTF8)


def _pystr(ref) -> str:
    if not ref:
        return ""
    buf = ctypes.create_string_buffer(256)
    return buf.value.decode() if _cf.CFStringGetCString(ref, buf, 256, kCFStringEncodingUTF8) else ""


def _pmgr_freqs_mhz() -> Dict[str, List[float]]:
    """DVFS frequency tables (MHz) per cluster type, from the pmgr IORegistry entry."""
    tables = {}
    it = ctypes.c_uint32()
    if _iokit.IOServiceGetMatchingServices(0, _iokit.IOServiceMatching(b"AppleARMIODevice"), ctypes.byref(it)) != 0:
        return tables
    while True:
        entry = _iokit.IOIteratorNext(it.value)
        if not entry:
            break
        name = ctypes.create_string_buffer(128)
        _iokit.IORegistryEntryGetName(entry, name)
        if name.value == b"pmgr":
            # voltage-states1-sram = E cluster, voltage-states5-sram = P cluster(s)
            for kind, key in (("E", "voltage-states1-sram"), ("P", "voltage-states5-sram")):
                k = _cfstr(key)
                data = _iokit.IORegistryEntryCreateCFProperty(entry, k, None, 0)
                _cf.CFRelease(k)
                if data:
                    raw = ctypes.string_at(_cf.CFDataGetBytePtr(data), _cf.CFDataGetLength(data))
                    _cf.CFRelease(data)
                    # pairs of (frequency, voltage) as little-endian uint32
                    freqs = [struct.unpack_from("<I", raw, i)[0] for i in range(0, len(raw) - 7, 8)]
                    freqs = [f for f in freqs if f]
                    # M1-M3 store Hz, M4 stores kHz
                    scale = 1e6 if freqs and max(freqs) > 1e8 else 1e3
                    tables[kind] = [f / scale for f in freqs]
        _iokit.IOObjectRelease(entry)
    _iokit.IOObjectRelease(it.value)
    return tables


class AppleCpuFrequency:
    def __init__(self):
        self.freqs = _pmgr_freqs_mhz()
        if not self.freqs:
            raise RuntimeError("pmgr DVFS tables not found")
        group, subgroup = _cfstr("CPU Stats"), _cfstr("CPU Complex Performance States")
        self._channels = _ior.IOReportCopyChannelsInGroup(group, subgroup, 0, 0, 0)
        _cf.CFRelease(group)
        _cf.CFRelease(subgroup)
        self._subbed = _vp()
        self._sub = _ior.IOReportCreateSubscription(None, self._channels, ctypes.byref(self._subbed), 0, None)
        if not self._sub:
            raise RuntimeError("IOReport subscription failed")
        self._prev = _ior.IOReportCreateSamples(self._sub, self._subbed, None)
        self._key_channels = _cfstr("IOReportChannels")

    def clusters_mhz(self) -> Dict[str, float]:
        """Average active frequency (MHz) per cluster since the previous call."""
        cur = _ior.IOReportCreateSamples(self._sub, self._subbed, None)
        delta = _ior.IOReportCreateSamplesDelta(self._prev, cur, None)
        _cf.CFRelease(self._prev)
        self._prev = cur
        result = {}
        if not delta:
            return result
        chans = _cf.CFDictionaryGetValue(delta, self._key_channels)
        for i in range(_cf.CFArrayGetCount(chans) if chans else 0):
            ch = _cf.CFArrayGetValueAtIndex(chans, i)
            name = _pystr(_ior.IOReportChannelGetChannelName(ch))  # e.g. ECPU, PCPU, PCPU1
            kind = "E" if name.startswith("E") else "P"
            table = self.freqs.get(kind)
            if not table or not name.endswith(("CPU", "CPU1", "CPU2", "CPU3")):
                continue
            weighted, active, idx = 0.0, 0, 0
            for s in range(_ior.IOReportStateGetCount(ch)):
                state = _pystr(_ior.IOReportStateGetNameForIndex(ch, s))
                res = _ior.IOReportStateGetResidency(ch, s)
                if state in _IDLE_STATES:
                    continue
                if idx < len(table):
                    weighted += res * table[idx]
                    active += res
                idx += 1
            if active:
                result[name] = weighted / active
        _cf.CFRelease(delta)
        return result

    def current_mhz(self) -> Optional[float]:
        """Frequency of the fastest-running cluster, in MHz (None until a cluster has been active)."""
        clusters = self.clusters_mhz()
        return max(clusters.values()) if clusters else None
