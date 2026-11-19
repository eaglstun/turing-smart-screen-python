import Foundation
import TuringDevice
import TuringTheme

// Draws the red / green / blue test pattern with a white bar down the left edge (portrait 320x480).
// Usage: DeviceTest [flip]   (flip = blue on top, to tell runs apart)
do {
    let display = try RevADisplay()
    print("opened the display's USB interface")
    try display.screenOn()
    try display.setBrightness(15)
    try display.setOrientation(.portrait, width: 320, height: 480)
    Thread.sleep(forTimeInterval: 0.05)

    let flip = CommandLine.arguments.contains("flip")
    var img = Bitmap(width: 320, height: 480)
    img.fillRect(x0: 0, y0: 0, x1: 319, y1: 159, flip ? RGB(0, 0, 255) : RGB(255, 0, 0))
    img.fillRect(x0: 0, y0: 160, x1: 319, y1: 319, RGB(0, 255, 0))
    img.fillRect(x0: 0, y0: 320, x1: 319, y1: 479, flip ? RGB(255, 0, 0) : RGB(0, 0, 255))
    img.fillRect(x0: 0, y0: 0, x1: 39, y1: 479, RGB(255, 255, 255))
    let start = Date()
    try display.draw(img, x: 0, y: 0)
    print(String(format: "drew a full frame in %.2f s", Date().timeIntervalSince(start)))
} catch {
    print("error: \(error)")
    exit(1)
}
