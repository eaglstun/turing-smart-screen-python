// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TuringScreen",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        // Hardware sensors: CPU, GPU, memory, disk, network, uptime (IOReport / SMC / IOAccelerator, no root)
        .target(name: "TuringSensors", path: "Sources/TuringSensors"),
        // Theme engine: loads res/themes/*/theme.yaml and renders it like the Python app (CoreGraphics / CoreText)
        .target(name: "TuringTheme", dependencies: ["Yams"], path: "Sources/TuringTheme"),
        // Update loop: live sensors -> theme -> changed regions -> display sink, on each stat's interval
        .target(name: "TuringMonitor", dependencies: ["TuringSensors", "TuringTheme"], path: "Sources/TuringMonitor"),
        // Runs the monitor headless for testing (PNG output, update statistics)
        .executableTarget(name: "MonitorCLI", dependencies: ["TuringMonitor"], path: "Sources/MonitorCLI"),
        // Command-line probe: prints every reading, for checking against the Python sensors
        .executableTarget(name: "Probe", dependencies: ["TuringSensors"], path: "Sources/Probe"),
        // Renders a theme with fixed sensor values to a PNG, for comparing with the Python engine
        .executableTarget(name: "RenderTheme", dependencies: ["TuringTheme"], path: "Sources/RenderTheme"),
    ],
    swiftLanguageModes: [.v5]
)
