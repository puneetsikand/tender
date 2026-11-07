# PhotoFerry (working name)

Mac-native ingest utility: copies photos/videos from cards and USB cameras to local folders or
network shares, using workflows built in a GUI, with parallel copies and bit-for-bit verification.
It is built standalone first, and a folder-based photo browser absorbs it later (PLAN §8A).
Read [`docs/PLAN.md`](docs/PLAN.md) before changing code.

```
swift build && swift test        # engine + tests
swift run PhotoFerry             # the app (dev)
swift run pf version             # the CLI
scripts/package.sh               # dist/PhotoFerry.app
```

## Layout
- `Sources/PhotoFerryCore`: the engine. **No SwiftUI/AppKit imports, no `@MainActor` in public API.**
- `Sources/IngestUI`: SwiftUI views for ingest, embeddable by a future browser app.
- `Sources/PhotoFerry`: thin app shell. `Sources/pf`: CLI front end to the engine.
- `Tests/PhotoFerryCoreTests`: Swift Testing (`@Test`/`#expect`), not XCTest.
- `Packaging/`: Info.plist template (`__VERSION__` is substituted). `VERSION` holds the version.

## Rules
- Swift 6 language mode, macOS 26+. Modern APIs only: structured concurrency (no GCD/OperationQueue),
  Observation, swift-system for file I/O, CryptoKit SHA-256.
- No Xcode project: SwiftPM + `scripts/package.sh`. Any XPC service (M2) is bundled by the script.
- Never write anything to a source card except an explicitly confirmed delete (PLAN §7, §3.2).
- Guard every "all verified" check against empty sets.
