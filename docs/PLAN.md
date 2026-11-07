# PhotoFerry — Plan

> Working name. Started 2026-11-07. Status: **plan only, no code yet.**

A Mac-native utility that copies photos and videos off SD/CFexpress cards and USB-attached cameras
into folders on the Mac or on a network share. You set up how each copy works in a graphical
workflow editor: renaming, folder layout, sorting by format, duplicate checks, verification and
deleting from the card. Speed and verified integrity are the two things it has to get right.

---

## 1. Goals / non-goals

**Goals**
- Copy from card readers (mounted volumes) and from cameras over USB (PTP/MTP) with one engine.
- Fast copies: read the source once, send it to several destinations in parallel, and hash while reading.
- Bit-for-bit verification you can prove, with a manifest written next to the files.
- Copy rules live in workflows built in a GUI and saved as human-readable files.
- Handle duplicates and re-inserted cards safely, and never delete from a card unless every destination has verified.

**Non-goals (v1)**
- Not a photo browser, culler or editor (Photo Mechanic and Lightroom already do this).
- No cloud upload targets. Network share means a mounted SMB/AFP/NFS volume.
- No Photos.app library import.

## 2. Stack (modern only)

| Concern | Choice | Notes |
|---|---|---|
| Language | **Swift 6.x** (toolchain 6.4.2 installed), strict concurrency on | No Objective-C or C sources of our own |
| UI | **SwiftUI** + Observation (`@Observable`) | AppKit only via thin representables, and only where SwiftUI has a gap |
| Minimum OS | **macOS 26** | Builds on Xcode 27.2. Lets us use current SwiftUI and Liquid Glass |
| Concurrency | Structured concurrency (`TaskGroup`, `AsyncSequence`, actors) | No GCD queues or OperationQueue in new code |
| File I/O | **swift-system** `FileDescriptor` + `fcntl` (`F_NOCACHE`, `F_FULLFSYNC`, `F_PREALLOCATE`) | Not `FileManager.copyItem`, because it can't hash inline or skip the cache |
| Hashing | **CryptoKit SHA-256** (hardware-accelerated on Apple Silicon, ~2 GB/s per core, faster than any card) | Decided, see §9 |
| Volumes | **DiskArbitration** (appear/disappear/eject/unmount) + `NSWorkspace` mount notifications | Spot cards by their `DCIM/` folder (the DCF standard) |
| Cameras (PTP) | **ImageCaptureCore** (`ICDeviceBrowser`, `ICCameraDevice`) | The only supported path for cameras that don't mount as a disk |
| Metadata | **ImageIO** (`CGImageSource`, covers RAW formats Apple supports: CR3/NEF/ARW/RAF/DNG/ORF…), **AVFoundation** async `load()` for video | Capture date, body serial, shutter count where present |
| Ledger/index | SQLite through **GRDB** | Records what was ingested from which card, by hash |
| Tests | **Swift Testing** (`@Test`, `#expect`) | Not XCTest |
| Project | **SwiftPM only** (no Xcode project, same as weirdprinter): `PhotoFerryCore` engine, `IngestUI`, app + `pf` CLI executables; `scripts/package.sh` assembles the .app | The engine can be tested from the CLI without the app. The XPC service gets bundled by the script at M2 |

## 3. Architecture

```
┌────────────── App (SwiftUI) ──────────────┐
│ Device sidebar · Job queue · Workflow editor│
└───────────────┬────────────────────────────┘
                │ async API
┌───────────────▼──────── PhotoFerryCore ──────────────────────────┐
│ SourceProvider (protocol)                                        │
│   ├─ VolumeSource      (mounted card / mass-storage camera)      │
│   └─ PTPCameraSource   (ImageCaptureCore)                        │
│ Scanner → ItemGrouper → MetadataReader                           │
│ WorkflowCompiler (workflow file → validated ExecutionPlan)       │
│ CopyEngine  (actor; read-once → hash → fan-out writers)          │
│ Verifier    (re-read dest with no cache, compare)                │
│ Ledger      (SQLite: ingests, file hashes, card identities)      │
│ ManifestWriter (ASC MHL / sidecar checksum file)                 │
│ PostActions (eject, delete-from-source, notify, open in Finder)  │
└──────────────────────────────────────────────────────────────────┘
```

### 3.1 Items, not files
The grouper bundles related files so they get the same name and the same fate:
RAW+JPEG pairs, video + sidecars (`.XML`, `.THM`, `.LRF`, `.WAV`), and `.XMP` sidecars. Rename
templates apply to the group, keeping each file's extension.

### 3.2 Card & camera recognition (drives auto-run)

A card's label and its volume serial/UUID are both rewritten on format, so neither can be the
identity. Recognition uses layers of signals, and the strongest one available wins:

| Tier | Signal | Survives format? | Where it's readable |
|---|---|---|---|
| **H — hardware** | SD **CID** register (manufacturer ID, OEM, product name, product serial, mfg date). CFexpress/NVMe controller serial + model | ✅ Yes, burned into the card | **Built-in PCIe SD slot only (to be confirmed).** This Mac (Mac17,6) has a Genesys GL9755 PCIe SD host, and macOS has historically shown card CID fields in System Information for PCIe readers. **USB card readers usually hide it.** They report the *reader's* USB serial, not the card's. NVMe-over-USB bridges vary. |
| **C — content** | EXIF `BodySerialNumber` + camera model from the first few files' headers (ImageIO, reading only the header). DCF folder/prefix patterns (`100EOSR5`, custom file prefix) | ✅ Yes, as soon as the camera writes to it | Any reader, any camera |
| **D — device** | PTP camera: `ICCameraDevice` serial number + model. Mass-storage camera: USB vendor/product/serial | ✅ Yes (it's the camera body) | Camera connected directly by USB |
| **V — volume** | Volume UUID/serial + label + DCIM listing hash | ❌ No, only until the next format | Always |

How each tier is used:
- **Auto-run rules match on H, C or D**, never on V alone. A rule says something like "camera body serial = 032021…" or
  "card hardware ID = SanDisk/…/0x1A2B3C4D", and runs the workflow bound to it. In practice the useful binding is usually
  **"which camera shot this"** (tier C/D), because that's what decides how a card should be processed, whatever the
  physical card is. Tier H is for "this exact card", e.g. a dedicated video card.
- **V is used only for "seen this card since its last format?"**, i.e. to offer "only new files". The real duplicate
  protection is still the hash ledger (§6), which doesn't depend on recognition at all.
- **Mixed or ambiguous** (files from two bodies, or two rules match): don't auto-run. Show a picker.
- **Freshly formatted, empty card:** nothing to ingest, so no identity needed.
- **Auto-run never deletes from the card.** The delete post-action always waits for a click, even inside an auto-run
  workflow. (Auto-run copy + verify + eject is fine.)
- **Write no marker files to cards.** Formatting erases them, and some cameras complain about unknown files.

**M1 probe task:** with a card in the built-in slot, then in a USB reader, dump `system_profiler SPCardReaderDataType`,
`ioreg -l` for the SD host and the USB bridge, and `diskutil info`. This records which hardware IDs are really
reachable through public APIs (IOKit registry reads are allowed without the sandbox). If tier H turns out unreachable, auto-run
still works on tier C/D.

## 4. Copy engine (speed + integrity)

**Pipeline per file**
1. Open the source with `F_NOCACHE` and read in large chunks (4–8 MB, tune in M2).
2. Each chunk goes to (a) the running hasher and (b) one writer task per destination, through a bounded async channel so a slow destination applies backpressure.
3. Writers write to `<name>.pfpartial`, preallocated with `F_PREALLOCATE`, then `F_FULLFSYNC`.
4. Verify (§5), then rename the partial to its final name atomically, then set mtime/creation date and copy xattrs.
5. Record in the ledger.

**Parallelism, adaptive per device class**
- Card reader read side: 1–3 files in flight. SD cards are sequential devices and too many reads just thrash. CFexpress/NVMe readers tolerate more.
- Destinations: always parallel with each other, because we read once and write N times.
- Network shares: 2–4 streams per share (SMB gains from several streams), separate from local disk concurrency.
- PTP cameras: effectively serial (one PTP session). ImageCaptureCore downloads to a staging dir on the fastest local destination, then the engine takes over.
- Benchmark mode at M2: measure MB/s per source and destination and pick defaults. Users can override in the workflow.

**Throughput targets:** stay within ~90% of the slowest device's raw speed. That's about 280 MB/s for UHS-II V90 and 1.5 GB/s or more for CFexpress Type B into an internal SSD.

## 5. Verification modes

| Mode | What it proves | Cost |
|---|---|---|
| **Size + existence** | File landed at full size | Nearly free |
| **Hash (default)** | Destination re-read from disk, bypassing the page cache, matches the source hash taken during the read | One extra read of each destination |
| **Paranoid** | Also re-reads the **source** and checks it matches the first read. Catches a flaky reader or card returning bad data the first time, which a single-read hash can't see | Two source reads |
| **Byte compare** | Literal byte-by-byte source vs. destination, no hash involved | Same as paranoid, for people who don't want to rely on a hash |

Notes:
- Destination re-reads use `F_NOCACHE`. Writes use `F_NOCACHE` + `F_FULLFSYNC`, so the verify reads come from the device and not from RAM.
- **Network shares:** we can't force the server to bypass its own cache. The UI labels network verification as "verified via server" so it doesn't claim more than we can prove.
- Write a checksum manifest per destination (ASC MHL v2 if we adopt xxh128/sha256 there, otherwise a simple `.sha256` file) so the copy can be checked again later and independently.

## 6. Duplicates / "already exists"

Workflow option per destination:
- **Match on**: name+size (fast), content hash (exact), or capture time + body serial + original name (works across renames).
- **On match**: skip, rename with a suffix, overwrite only if the hashes differ, or ask.
- The ledger makes hash matching cheap. If an ingest was done by hand before, offer a "build index from existing folder" step.

## 7. Delete-from-card safety gate

Deleting is a post-action that only runs if **every** file in the job verified at **every** required destination.
Guard against empty sets: an empty job must not count as "all verified". The action names
the counts ("Delete 412 verified files from EOS_DIGITAL?"). For cameras the default
suggestion is "format in camera" instead, with deletion through PTP as opt-in. A failed or partial verify blocks deletion with no override in v1.

## 8. Workflows

### 8.1 Model: a pipeline with branches, not a free-form graph
Ingest is naturally a sequence of stages, with routing branches by file type. A general DAG editor adds complexity (cycles, merge rules) that we don't need. The editor shows it graphically, but the model is:

```
Source filter → Route (by kind / extension / camera / date) ─┬─ branch: RAW    → Rename → Folder → Destinations[]
                                                            ├─ branch: JPEG   → …
                                                            └─ branch: Video  → …
→ Verify policy → Duplicate policy → Post-actions
```

### 8.2 Tokens (rename + folder templates)
`{date:yyyy-MM-dd}` `{time:HHmmss}` `{camera}` `{serial}` `{lens}` `{seq:4}` `{orig}` `{ext}` `{kind}`
`{job}` `{card}` `{shutterCount}` plus literal text. Live preview against the card that's inserted.
Dates come from EXIF/QuickTime capture time with fallback to file mtime. Time zone comes from the workflow setting, defaulting to the system zone.

### 8.3 Storage format
**Recommendation:** each workflow is one **JSON** file (`*.pfflow`), Codable, with a `schemaVersion` and
stable step IDs. Native to Swift, it diffs cleanly with sorted keys and pretty printing, and parses unambiguously.
Markdown is easy for people to read but a weak format for the app to parse back. So the app also **generates** a read-only
`*.md` summary next to each workflow ("Copies RAW to /Volumes/NAS/Raw/{date}…") for humans, and never parses it.

**Location:** saving into the `.app` bundle won't work. It breaks the code signature, gets wiped on every
update, and is read-only under the sandbox. Use `~/Library/Application Support/PhotoFerry/Workflows/`
instead, with "Reveal in Finder", import/export, and an optional user-chosen folder (e.g. a synced folder) through a
security-scoped bookmark.

## 8A. Standalone now, built to be integrated later

Ingest ships first as its own app, and is built so that a future folder-based photo **browser** (fast 100MP+
viewing, XMP-sidecar ratings, no catalog) can absorb it without a rewrite. The boundaries are fixed now:

1. **The package is the product, the app is a thin shell.** `PhotoFerryCore` (later renamed `IngestKit`) holds the engine,
   recognition, workflows and ledger. It has no SwiftUI, no AppKit, and no `@MainActor` in its public API. The standalone app is
   device sidebar + job queue + workflow editor on top. The editor's views go in a separate `IngestUI` package, so the
   browser can embed them as-is.
2. **The engine runs in a bundled XPC service** (from M2). Whichever app hosts it, a crash or memory spike in the
   UI can't kill a copy halfway through. The host talks to it only through a small Codable request/event protocol (`startJob`,
   `progress`, `fileVerified`, `jobFinished`), which is the integration seam.
3. **Ingest's output contract = plain folders + manifests + an "ingest finished" event.** No browser-specific
   behaviour gets baked in. In standalone mode the event is also written as a per-job JSON report under Application Support,
   so any later app (or script) can pick up what arrived. Inside the browser it's just an in-process `AsyncStream`.
4. **Ingest owns its own database.** It's a separate GRDB file holding the ledger, card identities and hashes. The browser later
   gets its own index database and *reads* the ingest ledger (hashes, capture metadata) instead of sharing one schema.
   Neither database is the source of truth for photos: the folders are.
5. **Workflows and data live under one Application Support folder**, keyed to a stable app-group-style identifier
   rather than the app's bundle ID, so renaming or merging apps doesn't orphan workflows.
6. **Extension points, defined now but mostly unused:** post-action protocol (`IngestPostAction`) so the browser can
   add "build previews" or "open in browser" steps; a metadata-reader protocol so the browser and ingest share
   ImageIO/AVFoundation readers.

**Integration path, decided later:** either (a) the standalone app *becomes* the browser (same bundle, browser
added as the main window, no migration), or (b) two apps share the packages and the XPC service. (a) is simpler and
is the default unless there's a reason to keep a lightweight ingest-only app.

## 9. Decisions

Decided 2026-11-07:
1. **Distribution: Developer ID, notarized, direct download.** No App Sandbox. Hardened Runtime is still required for
   notarization. The TCC prompts for *Removable Volumes* and *Network Volumes* still appear and need usage strings in Info.plist.
   Updates ship through Sparkle 2 (a Swift Package), or we add that later.
2. **Hash: SHA-256 (CryptoKit).** No hashing dependency. MHL manifests use the `sha256` hash type, which ASC MHL v2 allows.
3. **Ledger: GRDB.**
4. **Auto-run: yes, for recognized cards/cameras** by the rules in §3.2. It never deletes from a card without a click.

Still open:
5. **Name:** "PhotoFerry" is a placeholder.

## 10. Milestones

- **M0 – Skeleton:** ✅ 2026-11-07. SwiftPM package (`PhotoFerryCore`, `IngestUI`, `PhotoFerry` app, `pf` CLI), Swift Testing, `MediaKind` classifier, `scripts/package.sh`.
- **M1 – Sources:** DiskArbitration volume detection + DCIM scan; ImageCaptureCore camera browse/list; item grouping; metadata reader. CLI `pf scan /Volumes/X`.
- **M2 – Copy engine:** read-once fan-out, `.pfpartial` + atomic rename, adaptive concurrency, benchmark mode. CLI `pf copy`.
- **M3 – Verification + manifests:** all four modes, cache bypass, MHL/sha256 manifest, ledger.
- **M4 – Workflow model:** schema, compiler/validator, token engine with preview, JSON + generated MD. Hand-written workflows run through the CLI.
- **M5 – App UI:** device sidebar, job queue with per-file/per-destination progress and throughput, history.
- **M6 – Workflow editor:** graphical pipeline/branch editor in SwiftUI, live preview against the inserted card.
- **M7 – Duplicates + delete gate + eject/notify post-actions; network-share hardening (disconnects, resume).**
- **M8 – Polish:** resume interrupted jobs, error reporting, signing/notarization or App Store submission.

## 11. Test strategy
- Fixture "cards": disk images (`hdiutil create -fs ExFAT`) with real DCIM layouts from several brands, mounted in tests.
- Fault injection: a writer that corrupts one byte or truncates, a source that returns different data on the second read. Verify must catch every one.
- Throughput regression benchmarks on a real UHS-II card and a real SMB share.

## 12. Prior art to benchmark against
Hedge/OffShoot, ShotPut Pro, Photo Mechanic Ingest, Lightroom Import. Their feature lists set the minimum
bar for verification modes and MHL support.
