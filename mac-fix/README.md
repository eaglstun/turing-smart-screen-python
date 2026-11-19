# mac-fix: TURZX 3.5" rev A on macOS

This unit (VID `1a86`, PID `5722`, serial `USB35INCHIPSV2`) garbles every image
sent by the stock rev A driver on macOS.

## Cause

The firmware draws **every USB packet as 64 bytes (32 RGB565 pixels), whatever
its real length**:

- A short packet is padded with stale bytes from the firmware's buffer.
- When a write is an exact multiple of 64 bytes, macOS ends it with a
  zero-length packet. The firmware draws that as a duplicate 64 bytes.

Either way the pixel stream goes out of step. The screen then stays confused
until it is unplugged and plugged back in.

## Workaround

`pattern_31px.py` draws a test pattern that comes out correctly:

1. Open the port at 115200 baud with `rtscts=False` and DTR/RTS on.
2. Send the `DISPLAY_BITMAP` (197) header, then wait 10 ms (the vendor app's
   timing).
3. Send each 32-pixel block of a row as its own **62-byte write (31 real
   pixels)**, about 1 ms apart. The firmware's junk 32nd pixel lands on columns
   `x % 32 == 31`, so the only visible damage is faint hairlines.

A full frame takes about 4.8 s at 1 ms per packet.

## Also avoid

- `Reset()`: afterwards the screen ignores drawing commands.
- Any write whose length is a multiple of 64 bytes.

## To do

- [ ] Find the smallest safe pause between packets.
- [ ] Patch `library/lcd/lcd_comm_rev_a.py` `DisplayPILImage` to use the
      31-pixel layout, including partial updates (keep blocks 32-px aligned).
- [ ] Skip `Reset()` on startup (`RESET_ON_STARTUP: false`).
- [ ] Try to get rid of the hairlines.
