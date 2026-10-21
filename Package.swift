// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MiHeaterBar",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "HeaterKit", targets: ["HeaterKit"]),
        .executable(name: "MiHeaterBar", targets: ["MiHeaterBar"]),
    ],
    targets: [
        .target(name: "HeaterKit"),
        .executableTarget(name: "MiHeaterBar", dependencies: ["HeaterKit"]),
        .testTarget(name: "HeaterKitTests", dependencies: ["HeaterKit"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
