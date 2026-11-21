// swift-tools-version:5.7
// Cyber Rakshak error monitoring for iOS (and macOS), as a Swift package. Built and tested by CI: see README.md.
import PackageDescription

let package = Package(
    name: "CyberRakshakMonitor",
    platforms: [
        // The library uses Foundation only (URLSession, FileManager, NSRegularExpression, NSSetUncaughtExceptionHandler,
        // ISO8601DateFormatter, DispatchQueue): nothing newer than these.
        .iOS(.v13),
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "CyberRakshakMonitor", targets: ["CyberRakshakMonitor"]),
    ],
    targets: [
        .target(
            name: "CyberRakshakMonitor",
            path: "Sources/CyberRakshakMonitor"
        ),
        .testTarget(
            name: "CyberRakshakMonitorTests",
            dependencies: ["CyberRakshakMonitor"],
            path: "Tests/CyberRakshakMonitorTests",
            // fake-server.mjs and scrub-vectors.json are read from the source folder (#filePath), not bundled.
            exclude: ["Fixtures"]
        ),
    ]
)
