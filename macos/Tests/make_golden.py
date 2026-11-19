"""Render a theme once with the Python engine and fixed (STATIC) sensor values; save a reference PNG.

Usage (from the repo root): .venv/bin/python macos/Tests/make_golden.py <theme> <out.png>
Mirrors main.py's startup: static images, static text, then every stat updated once.
"""
import os
import sys

theme, out = sys.argv[1], os.path.abspath(sys.argv[2])
sys.path.insert(0, os.getcwd())

import library.config as config

config.CONFIG_DATA["config"]["THEME"] = theme
config.CONFIG_DATA["config"]["HW_SENSORS"] = "STATIC"
config.CONFIG_DATA["display"]["REVISION"] = "SIMU"
config.CONFIG_DATA["display"]["DISPLAY_REVERSE"] = False
config.load_theme()

from library.display import display  # noqa: E402  (builds the simulated display from the config above)
import library.stats as stats  # noqa: E402

display.initialize_display()
display.display_static_images()
display.display_static_text()
for fn in (stats.CPU.percentage, stats.CPU.frequency, stats.CPU.load, stats.CPU.temperature, stats.CPU.fan_speed,
           stats.Gpu.stats, stats.Memory.stats, stats.Disk.stats, stats.Net.stats, stats.Date.stats,
           stats.SystemUptime.stats, stats.Ping.stats, stats.Weather.stats):
    fn()
display.lcd.screen_image.save(out)
print(out)
os._exit(0)  # the simulated display starts a non-daemon web server thread
