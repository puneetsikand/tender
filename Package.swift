// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "photoferry",
    platforms: [.macOS(.v26)],
    products: [
        // The engine. No SwiftUI/AppKit, no @MainActor in its public API (PLAN §8A.1).
        .library(name: "PhotoFerryCore", targets: ["PhotoFerryCore"]),
        // Ingest views a future browser app can embed as-is (PLAN §8A.1).
        .library(name: "IngestUI", targets: ["IngestUI"]),
        .executable(name: "PhotoFerry", targets: ["PhotoFerry"]),
        .executable(name: "pf", targets: ["pf"]),
    ],
    targets: [
        .target(name: "PhotoFerryCore"),
        .target(name: "IngestUI", dependencies: ["PhotoFerryCore"]),
        .executableTarget(name: "PhotoFerry", dependencies: ["PhotoFerryCore", "IngestUI"]),
        .executableTarget(name: "pf", dependencies: ["PhotoFerryCore"]),
        .testTarget(name: "PhotoFerryCoreTests", dependencies: ["PhotoFerryCore"]),
    ]
)
