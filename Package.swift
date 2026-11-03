// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lynt",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LyntCore", targets: ["LyntCore"]),
        .library(name: "LyntPlatform", targets: ["LyntPlatform"]),
        .executable(name: "Lynt", targets: ["LyntApp"])
    ],
    targets: [
        .target(name: "LyntCore"),
        .target(name: "LyntPlatform", dependencies: ["LyntCore"]),
        .executableTarget(name: "LyntApp", dependencies: ["LyntCore", "LyntPlatform"]),
        .testTarget(name: "LyntCoreTests", dependencies: ["LyntCore"], resources: [.process("Fixtures")]),
        .testTarget(name: "LyntPlatformTests", dependencies: ["LyntPlatform"]),
        .testTarget(name: "LyntAppTests", dependencies: ["LyntApp", "LyntPlatform"])
    ],
    swiftLanguageModes: [.v5]
)
