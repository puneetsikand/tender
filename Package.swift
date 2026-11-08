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
        // Fast previews (embedded RAW previews, reduced-size decodes, cache). Shared with the future browser.
        .library(name: "PhotoPreview", targets: ["PhotoPreview"]),
        .executable(name: "PhotoFerry", targets: ["PhotoFerry"]),
        .executable(name: "pf", targets: ["pf"]),
        .executable(name: "PhotoFerryCopyService", targets: ["PhotoFerryCopyService"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "PhotoFerryCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "PhotoPreview"),
        .target(name: "IngestUI", dependencies: ["PhotoFerryCore", "PhotoPreview"]),
        .executableTarget(name: "PhotoFerry", dependencies: ["PhotoFerryCore", "IngestUI"]),
        .executableTarget(name: "pf", dependencies: ["PhotoFerryCore"]),
        // Bundled by scripts/package.sh as Contents/XPCServices/local.photoferry.copyservice.xpc.
        .executableTarget(name: "PhotoFerryCopyService", dependencies: ["PhotoFerryCore"]),
        .testTarget(name: "PhotoFerryCoreTests", dependencies: ["PhotoFerryCore"]),
        .testTarget(name: "IngestUITests", dependencies: ["IngestUI", "PhotoFerryCore", "PhotoPreview"]),
    ]
)
