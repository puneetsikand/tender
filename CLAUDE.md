# PhotoFerry (working name)

Mac-native ingest utility: copies photos/videos from cards and USB cameras to local folders or
network shares, using workflows built in a GUI, with parallel copies and bit-for-bit verification.
It is built standalone first, and a folder-based photo browser absorbs it later (PLAN §8A).
Read [`docs/PLAN.md`](docs/PLAN.md) before changing code.

```
swift build && swift test        # engine + tests
swift run PhotoFerry             # the app (dev)
swift run pf version             # the CLI (also: volumes, watch, cameras, scan, probe, copy, workflow, plan, run, history)
scripts/package.sh               # dist/PhotoFerry.app
```

## Layout
- `Sources/PhotoFerryCore`: the engine. **No SwiftUI/AppKit imports, no `@MainActor` in public API.**
- `Sources/IngestUI`: SwiftUI views for ingest, embeddable by a future browser app.
- `Sources/PhotoFerry`: thin app shell. `Sources/pf`: CLI front end to the engine.
- `Sources/PhotoFerryCopyService`: the XPC copy service, bundled by `package.sh`. Hosts reach the engine only through
  `CopyRunner` (`CopyRunners.preferred()`): XPC inside the app bundle, in-process otherwise. Test the XPC path with
  `dist/PhotoFerry.app/Contents/MacOS/pf copy … --runner xpc`.
- `Tests/PhotoFerryCoreTests`: Swift Testing (`@Test`/`#expect`), not XCTest. `VolumeMonitorTests` mounts a
  throwaway exFAT disk image with `hdiutil` (no sudo needed, about 2 s).
- Jobs: hosts build a `CopyJob` and run it via a `CopyRunner`; `JobExecutor` runs engine → ledger → manifests in
  whichever process does the copy. Ledger: `~/Library/Application Support/PhotoFerry/ledger.sqlite` (GRDB, typed
  columns, no JSON); `PF_LEDGER` overrides it for the in-process CLI only (the XPC service always uses the default).
- Workflows: `Workflow` → `Planner` (validate, then plan) → `CopyPlan` (= the preview) → `CopyJob`. Stored as JSON in
  `~/Library/Application Support/PhotoFerry/Workflows` (`PF_WORKFLOWS` overrides). Test against real cards with
  `PF_WORKFLOWS`/`PF_LEDGER` pointed at the scratchpad and `--runner local`, so the user's real store stays clean.
- `Packaging/`: Info.plist template (`__VERSION__` is substituted). `VERSION` holds the version.

## Rules
- Swift 6 language mode, macOS 26+. Modern APIs only: structured concurrency (no GCD/OperationQueue, except
  where an Apple API requires one: DiskArbitration in `VolumeMonitor.swift`, `dispatchMain()` in the XPC service),
  Observation, swift-system for file I/O, CryptoKit SHA-256.
- No Xcode project: SwiftPM + `scripts/package.sh`. Any XPC service (M2) is bundled by the script.
- Never write anything to a source card except an explicitly confirmed delete (PLAN §7, §3.2).
- Guard every "all verified" check against empty sets.
- A copy never gets its final name before it has passed verification. Never report a verify read as `device` unless
  `mincore` confirmed the pages were evicted.
- Benchmarks after any `diff`/`cp` of the same source are invalid: the file cache serves the reads (it showed 2.4 GB/s
  from a UHS-I card). Use fresh data, or files larger than what was read recently.
