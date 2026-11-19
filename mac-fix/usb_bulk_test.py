"""Test: draw the test pattern through raw USB (PyUSB/libusb), bypassing the macOS serial driver.

Approach from issue #7 (@marcelors27, @amarok30): write to bulk OUT endpoint 0x03 of the CDC data
interface, one USB transfer per command, pixel data in 64-byte-aligned chunks totalling exactly w*h*2.
Usage: usb_bulk_test.py [flip]
"""
import os
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)

import usb.core
import usb.util
from PIL import Image, ImageDraw

from library.lcd.serialize import image_to_RGB565

VID, PID = 0x1A86, 0x5722
INTERFACE, OUT_EP = 1, 0x03
W, H = 320, 480
FLIP = "flip" in sys.argv[1:]


def header(cmd, x, y, ex, ey):
    return bytes([x >> 2, ((x & 3) << 6) + (y >> 4), ((y & 15) << 4) + (ex >> 6),
                  ((ex & 63) << 2) + (ey >> 8), ey & 255, cmd])


img = Image.new("RGB", (W, H))
d = ImageDraw.Draw(img)
top, bottom = ((0, 0, 255), (255, 0, 0)) if FLIP else ((255, 0, 0), (0, 0, 255))
d.rectangle([0, 0, W, H // 3], fill=top)
d.rectangle([0, H // 3, W, 2 * H // 3], fill=(0, 255, 0))
d.rectangle([0, 2 * H // 3, W, H], fill=bottom)
d.rectangle([0, 0, 40, H], fill=(255, 255, 255))
data = image_to_RGB565(img, "little")

dev = usb.core.find(idVendor=VID, idProduct=PID)
print("1. found device:", dev is not None)
if dev is None:
    sys.exit(1)

try:
    active = dev.is_kernel_driver_active(INTERFACE)
    print("2. macOS serial driver attached to interface 1:", active)
    if active:
        dev.detach_kernel_driver(INTERFACE)
        print("   detached")
except Exception as e:
    print("   detach step:", type(e).__name__, e)

try:
    usb.util.claim_interface(dev, INTERFACE)
    print("3. claimed interface 1")
except Exception as e:
    print("3. claim FAILED:", type(e).__name__, e)
    sys.exit(2)

try:
    orient = bytearray(11)
    orient[5] = 121
    orient[6] = 100  # portrait
    orient[7:11] = bytes([W >> 8, W & 255, H >> 8, H & 255])
    dev.write(OUT_EP, bytes(orient), timeout=5000)
    time.sleep(0.05)

    start = time.perf_counter()
    dev.write(OUT_EP, header(197, 0, 0, W - 1, H - 1), timeout=5000)
    time.sleep(0.02)
    for i in range(0, len(data), 4096):
        dev.write(OUT_EP, data[i:i + 4096], timeout=5000)
    print(f"4. sent {len(data)} bytes in {time.perf_counter() - start:.2f}s")
finally:
    usb.util.release_interface(dev, INTERFACE)
    try:
        dev.attach_kernel_driver(INTERFACE)
        print("5. gave interface back to the macOS serial driver")
    except Exception as e:
        print("5. reattach:", type(e).__name__, e)
    usb.util.dispose_resources(dev)
