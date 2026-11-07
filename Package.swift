// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "mac-display-guard",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "mac-display-guard", targets: ["mac-display-guard"]),
    ],
    targets: [
        // Pure logic (mode specs, config, decisions, log parsing): no CoreGraphics, fully testable.
        .target(name: "DisplayGuardCore"),
        // The command-line tool and the background guard.
        .executableTarget(name: "mac-display-guard", dependencies: ["DisplayGuardCore"]),
        .testTarget(name: "DisplayGuardCoreTests", dependencies: ["DisplayGuardCore"]),
    ]
)
