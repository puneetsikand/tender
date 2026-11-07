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
