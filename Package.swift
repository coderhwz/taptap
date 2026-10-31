// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TapTap",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TapTap", targets: ["TapTap"])],
    targets: [
        .target(name: "GestureCore"),
        .executableTarget(name: "TapTap", dependencies: ["GestureCore"]),
        .testTarget(name: "GestureCoreTests", dependencies: ["GestureCore"]),
        .testTarget(name: "TapTapTests", dependencies: ["TapTap", "GestureCore"], resources: [.copy("Fixtures")])
    ]
)
