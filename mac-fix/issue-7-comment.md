<!-- Posted 2026-11-19, edited to link PR #1138: https://github.com/mathoudebine/turing-smart-screen-python/issues/7#issuecomment-7003732361 -->
**Update:** PR #1138 adds the USB bulk fix below as an opt-in `USB_BULK` option.

Another rev A unit (`1a86:5722`, serial `USB35INCHIPSV2`, TURZX-branded) working on macOS. I'm on an M4 Max, macOS 27, with the screen behind a USB-C dock. A few findings that might help this get merged.

**1. Raw USB works without root.** I used the bulk endpoint approach from marcelors27 and amarok30. On my machine `detach_kernel_driver()` fails with `Access denied`, but `claim_interface(1)` succeeds anyway with the CDC driver still attached, and writes to endpoint `0x03` draw perfectly. So a macOS backend doesn't need sudo or a special entitlement.

**2. Why the serial path corrupts, as seen on this unit.** Before finding this thread I worked it out from photos of test patterns. The firmware draws **every USB packet as 64 bytes (32 px), whatever its real length**:

- a short packet is drawn padded with stale bytes, which makes slanted or staircase images;
- when a write's length is an exact multiple of 64, macOS ends the transfer with a zero-length packet, and that is drawn as a duplicate 64 bytes. With large writes this shows up as about 20% extra data: bands too tall, and leftover pixels that become the "second pass" / desync people describe here.

This fits amarok30's "transfer-oriented" description. It also explains why flushing and delays never fully fixed it: they change where the packet boundaries fall, not what the firmware does with them.

**3. Partial updates.** I keep a framebuffer copy of the screen and widen every `DisplayPILImage` call horizontally to the 32-px grid. Each bitmap is then exactly `w*h*2` bytes in whole 64-byte packets, so text, clock and progress-bar updates are packet-aligned too, not only full frames. A full 320×480 frame takes about 1.9 s. The stock `3.5inchTheme2` theme runs at about 1% of one core.

**4. Fallback for people who can't use libusb.** Through `/dev/cu.usbmodem*` it also works if each write is several full 64-byte packets plus one **62-byte** packet (no write is ever a multiple of 64), with `flush()` after each write and 160 px per write. The firmware's junk pixel then always lands on the same column, which leaves 2 faint hairlines (x = 159 and 319). Writes over ~512 bytes got split by macOS and broke it.

Two smaller things:

- `Reset()` on startup left my unit ignoring draw commands until it was replugged. `RESET_ON_STARTUP: false` avoids that.
- The same unit draws correctly on **Raspberry Pi OS through the stock serial path**, with no workarounds. That confirms this is specific to macOS's serial driver.
- Unrelated to the display, but needed for a usable Mac theme: on Apple Silicon `psutil.cpu_freq()` returns placeholders (the theme shows 0.00 GHz), and `disk_usage("/")` reads the sealed system volume. I read live per-cluster frequency from IOReport (no root, residency-weighted over the `pmgr` DVFS tables) and use `/System/Volumes/Data` for disk. I've since added GPU load, memory, frequency and temperature, plus CPU temperature, from IOAccelerator, IOReport and the SMC. SMC sensor keys are found from the SMC's own key table, because the M1–M3 names don't all exist on M4, and parked cores read a 40.0 °C placeholder. That overlaps #977, so I've kept it out of #1138. Happy to send it separately if it's useful.

**PR #1138** adds the USB bulk transport as `USB_BULK` under `REVISION: A` (default `false`; `configure.py`'s revision map untouched), falling back to the serial port if the device can't be opened over USB. The serial 62-byte workaround from point 4 is left out to keep it small.
