// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReddeCalendarMCP",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ReddeCalendarMCP",
            path: "Sources/ReddeCalendarMCP",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
