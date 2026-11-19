// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TuringScreen",
    platforms: [.macOS(.v14)],
    targets: [
        // Hardware sensors: CPU, GPU, memory, disk, network, uptime (IOReport / SMC / IOAccelerator, no root)
        .target(name: "TuringSensors", path: "Sources/TuringSensors"),
        // Command-line probe: prints every reading, for checking against the Python sensors
        .executableTarget(name: "Probe", dependencies: ["TuringSensors"], path: "Sources/Probe"),
    ],
    swiftLanguageModes: [.v5]
)
