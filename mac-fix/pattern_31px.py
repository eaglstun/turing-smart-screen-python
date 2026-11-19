"""Workaround test: the firmware draws 64 bytes (32 px) per USB packet regardless of real length.

So send each packet as 62 bytes = 31 real pixels; the firmware's 32nd (junk) pixel lands on
column x % 32 == 31, which we simply skip. Total drawn = exactly 320x480, no overflow.
Usage: pattern_31px.py [pause_ms_per_packet] [flush] [flip]
  pause_ms_per_packet  busy-wait after each packet (default 1.0)
  flush                wait for each packet to leave the Mac before sending the next
  flip                 draw the bands upside down (blue on top), to tell runs apart
"""
import os, sys, time
REPO = os.path.expanduser("~/Downloads/rar/turing-smart-screen-python")
sys.path.insert(0, REPO)
os.chdir(REPO)
import serial
from PIL import Image, ImageDraw
from library.lcd.lcd_comm_rev_a import LcdCommRevA
from library.lcd.serialize import image_to_RGB565

PAUSE = float(sys.argv[1]) / 1000 if len(sys.argv) > 1 else 0.001
FLUSH = "flush" in sys.argv[2:]
FLIP = "flip" in sys.argv[2:]
W, H = 320, 480
img = Image.new("RGB", (W, H))
d = ImageDraw.Draw(img)
top, bottom = ((0, 0, 255), (255, 0, 0)) if FLIP else ((255, 0, 0), (0, 0, 255))
d.rectangle([0, 0, W, H // 3], fill=top)
d.rectangle([0, H // 3, W, 2 * H // 3], fill=(0, 255, 0))
d.rectangle([0, 2 * H // 3, W, H], fill=bottom)
d.rectangle([0, 0, 40, H], fill=(255, 255, 255))
data = image_to_RGB565(img, "little")

# One packet per 32-px block: its first 31 pixels (62 bytes); pixel 31 is left to the firmware's junk.
packets = []
for y in range(H):
    row = data[y * W * 2:(y + 1) * W * 2]
    for bx in range(0, W, 32):
        packets.append(row[bx * 2:(bx + 31) * 2])


def header(cmd, x, y, ex, ey):
    return bytes([x >> 2, ((x & 3) << 6) + (y >> 4), ((y & 15) << 4) + (ex >> 6),
                  ((ex & 63) << 2) + (ey >> 8), ey & 255, cmd])


port = LcdCommRevA.auto_detect_com_port()
ser = serial.Serial(port, 115200, timeout=1, rtscts=False)
ser.dtr = True
ser.rts = True
time.sleep(0.2)

start = time.perf_counter()
ser.write(header(197, 0, 0, W - 1, H - 1)); ser.flush()
time.sleep(0.010)
nxt = time.perf_counter()
for p in packets:
    ser.write(p)
    if FLUSH:
        ser.flush()
    nxt = max(nxt + PAUSE, time.perf_counter()) if FLUSH else nxt + PAUSE
    while time.perf_counter() < nxt:
        pass
ser.flush()
elapsed = time.perf_counter() - start
print(f"{len(packets)} packets x 62 bytes, pause {PAUSE * 1000:.2f} ms, flush={FLUSH}: {elapsed:.2f}s")
time.sleep(0.5)
ser.close()
