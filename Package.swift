// swift-tools-version: 6.2
import PackageDescription

// Everything runs on the main actor unless it says otherwise: the app is AppKit UI plus a few
// small services that all feed the Touch Bar.
let settings: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "BarDeck",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "BarDeck",
            path: "Sources/BarDeck",
            swiftSettings: settings
        ),
        .testTarget(
            name: "BarDeckTests",
            dependencies: ["BarDeck"],
            path: "Tests/BarDeckTests",
            swiftSettings: settings
        ),
    ]
)
