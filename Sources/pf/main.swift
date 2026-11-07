import Foundation
import PhotoFerryCore

// Command-line front end to the engine. `pf copy` arrives with M2.
setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered, so `pf watch | tee` and logs see events live
let args = Array(CommandLine.arguments.dropFirst())
let usage = """
usage: pf version
       pf kind <file>...       classify files by media kind
       pf volumes              list mounted volumes; * marks cards (a DCIM or known video root)
       pf watch                stream volume mount/unmount events (Ctrl-C to stop)
       pf cameras              stream USB/PTP camera connections (Ctrl-C to stop)
       pf scan <path>          list media items on a card or folder, with capture metadata
       pf copy <source> --to <dir> [--to <dir>…] [--flat] [--chunk <MB>] [--inflight <n>] [--no-sync]
                               copy media (reading each file once) into every destination;
                               keeps the card's folder layout unless --flat
       pf probe <mount>        dump DiskArbitration + IOKit details behind a volume (card ID experiment)
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(64)
}

func describe(_ v: VolumeInfo) -> String {
    let card = v.mountPoint.map { CardScanner().looksLikeCard($0) } ?? false
    let hw = card ? v.mountPoint.flatMap(CardIdentity.hardwareID(forMountPoint:)).map { "  id=\($0.key)" } ?? "" : ""
    let flags = [v.isRemovable ? "removable" : nil, v.isEjectable ? "ejectable" : nil,
                 v.isInternalDevice ? "internal" : nil, v.isNetwork ? "network" : nil].compactMap { $0 }
    return "\(card ? "*" : " ") \(v.mountPoint?.path ?? "-")  [\(v.name ?? "?")]  \(v.fileSystem ?? "?")  "
        + "\(v.deviceProtocol ?? "?")  \(v.deviceVendor ?? "") \(v.deviceModel ?? "")  \(flags.joined(separator: ","))\(hw)"
}

let sizeFormat = ByteCountFormatStyle(style: .file)

switch args.first {
case "version", "--version", "-v":
    print("pf \(PhotoFerryCore.version)")

case "kind":
    for path in args.dropFirst() {
        print("\(MediaKind(fileExtension: (path as NSString).pathExtension).rawValue)\t\(path)")
    }

case "volumes":
    let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
    for url in urls {
        if let v = VolumeMonitor.describe(mountPoint: url) { print(describe(v)) }
    }

case "watch":
    for await event in VolumeMonitor.events() {
        switch event {
        case .mounted(let v): print("mounted   \(describe(v))")
        case .unmounted(let id): print("unmounted \(id)")
        }
    }

case "cameras":
    for await event in CameraMonitor.events() {
        switch event {
        case .connected(let c):
            print("connected    \(c.name ?? "?")  kind=\(c.productKind ?? "?")  serial=\(c.serialNumber ?? "-")  "
                  + "persistentID=\(c.persistentID ?? "-")  usb=\(String(format: "%04x:%04x", c.usbVendorID, c.usbProductID))  \(c.transport ?? "")")
        case .disconnected(let id): print("disconnected \(id)")
        }
    }

case "scan":
    guard args.count == 2 else { fail(usage) }
    let root = URL(fileURLWithPath: args[1], isDirectory: true)
    let files = try CardScanner().scan(root)
    let items = ItemGrouper().group(files)
    let reader = MetadataReader()
    let dateFormat = Date.ISO8601FormatStyle(timeZone: .current).year().month().day().time(includingFractionalSeconds: false)
    var serials: [String: Int] = [:]
    for item in items {
        let meta = await reader.read(item.primary)
        if let s = meta.bodySerial { serials["\(meta.cameraModel ?? "?") #\(s)", default: 0] += 1 }
        let kinds = item.members.map { "\($0.url.pathExtension.uppercased())" }.joined(separator: "+")
        let date = meta.captureDate.map { dateFormat.format($0) + (meta.captureDateHasOffset ? "" : " (no offset)") } ?? "-"
        print("\(item.id)  \(kinds)  \(item.totalSize.formatted(sizeFormat))  \(date)  "
              + "\(meta.cameraModel ?? "-")  \(meta.bodySerial.map { "#\($0)" } ?? "")")
    }
    let total = files.reduce(Int64(0)) { $0 + $1.size }
    print("\(items.count) items, \(files.count) files, \(total.formatted(sizeFormat))")
    for (body, n) in serials.sorted(by: { $0.value > $1.value }) { print("  camera \(body): \(n) items") }

case "copy":
    var rest = args.dropFirst()
    guard let sourcePath = rest.popFirst() else { fail(usage) }
    var roots: [URL] = []
    var flat = false
    let sourceURL = URL(fileURLWithPath: sourcePath, isDirectory: true)
    var options = CopyOptions.defaults(for: VolumeMonitor.describe(mountPoint: sourceURL))
    while let flag = rest.popFirst() {
        switch flag {
        case "--to": guard let d = rest.popFirst() else { fail(usage) }; roots.append(URL(fileURLWithPath: d, isDirectory: true))
        case "--flat": flat = true
        case "--chunk": guard let v = rest.popFirst().flatMap(Int.init) else { fail(usage) }; options.chunkSize = v << 20
        case "--inflight": guard let v = rest.popFirst().flatMap(Int.init) else { fail(usage) }; options.filesInFlight = v
        case "--no-sync": options.fullSync = false
        default: fail(usage)
        }
    }
    guard !roots.isEmpty else { fail("pf copy: at least one --to is required") }
    let files = try CardScanner().scan(sourceURL)
    let requests = files.map { f in
        CopyRequest(source: f, destinations: roots.map { $0.appendingPathComponent(flat ? f.fileName : f.relativePath) })
    }
    let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
    print("copying \(files.count) files (\(totalBytes.formatted(sizeFormat))) to \(roots.count) destination(s), "
          + "chunk \(options.chunkSize >> 20) MB, \(options.filesInFlight) in flight, sync \(options.fullSync ? "on" : "off")")
    for await event in CopyEngine(options: options).run(requests) {
        switch event {
        case .fileFinished(_, let r) where !r.succeeded:
            print("FAILED \(r.request.source.relativePath): \(r.sourceError ?? "")")
            for case let .failed(url, reason) in r.destinations { print("    \(url.path): \(reason)") }
        case .finished(let s):
            print(String(format: "%d files, %@ in %.2f s = %.0f MB/s read (%.0f MB/s written)",
                         s.results.count, s.bytesRead.formatted(sizeFormat),
                         Double(s.elapsed.components.seconds) + Double(s.elapsed.components.attoseconds) / 1e18,
                         s.megabytesPerSecond, s.megabytesPerSecond * Double(roots.count)))
            print(s.allSucceeded ? "all files copied" : "\(s.failed.count) file(s) failed")
            if !s.allSucceeded { exit(1) }
        default: break
        }
    }

case "probe":
    guard args.count == 2 else { fail(usage) }
    let url = URL(fileURLWithPath: args[1], isDirectory: true)
    guard let v = VolumeMonitor.describe(mountPoint: url) else { fail("not a mounted volume: \(args[1])") }
    print(describe(v))
    print("volume UUID: \(v.volumeUUID ?? "-")   media: \(v.mediaName ?? "-")")
    if let hw = CardIdentity.hardwareID(forMountPoint: url) {
        print("card hardware ID: \(hw.key)  (\(hw.cardType ?? "?"), made \(hw.manufacturingDate ?? "?"))\n")
    } else {
        print("card hardware ID: not exposed by this reader\n")
    }
    for node in IORegistryProbe.chain(forMountPoint: url) {
        let pad = String(repeating: "  ", count: node.depth)
        print("\(pad)\(node.className)  \"\(node.name)\"")
        for p in node.properties { print("\(pad)    \(p.key) = \(p.value)") }
    }

default:
    print(usage)
    exit(args.isEmpty ? 0 : 64)
}
