"""Demo of the patched rev A driver (packet_fix): background, text, then a ticking clock.

Usage: demo.py [seconds]   (default 20)
Runs from any directory; does not Reset() the screen.
"""
import os
import sys
import time
from datetime import datetime

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)
os.chdir(REPO)

from library.lcd.lcd_comm import Orientation
from library.lcd.lcd_comm_rev_a import LcdCommRevA

SECONDS = float(sys.argv[1]) if len(sys.argv) > 1 else 20

lcd = LcdCommRevA(com_port="AUTO", packet_fix=True)
lcd.InitializeComm()
lcd.SetBrightness(level=15)
lcd.SetOrientation(Orientation.PORTRAIT)

background = f"res/backgrounds/example_{lcd.get_width()}x{lcd.get_height()}.png"
start = time.perf_counter()
lcd.DisplayBitmap(background)
print(f"background: {time.perf_counter() - start:.2f}s")

lcd.DisplayText("Hello from the Mac", 20, 80, font_size=26, font_color=(255, 255, 255), background_image=background)
lcd.DisplayText("packet fix", 37, 130, font="res/fonts/roboto/Roboto-Italic.ttf", font_size=20,
                font_color=(0, 0, 255), background_color=(255, 255, 0))

end = time.time() + SECONDS
ticks = 0
while time.time() < end:
    t = time.perf_counter()
    lcd.DisplayText(datetime.now().strftime("%H:%M:%S"), 100, 220, font="res/fonts/roboto/Roboto-Bold.ttf",
                    font_size=40, font_color=(255, 0, 0), background_image=background)
    ticks += 1
    time.sleep(max(0.0, 0.5 - (time.perf_counter() - t)))
print(f"clock updates: {ticks}")
lcd.closeSerial()
