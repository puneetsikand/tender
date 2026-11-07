import DiskArbitration
import Foundation
import IOKit

/// Dumps the IOKit objects behind a mounted volume, from the media object up through its
/// parents (partition → media → driver → bus/controller).
///
/// This is the PLAN §3.2 experiment: it shows which hardware identifiers (SD CID fields,
/// NVMe serials, USB serials) a given reader exposes, so `CardIdentity` can be written
/// against what is really there.
public enum IORegistryProbe {
    public struct Node: Sendable {
        public let depth: Int
        public let className: String
        public let name: String
        public let properties: [(key: String, value: String)]
    }

    public static func chain(forMountPoint url: URL, maxDepth: Int = 14) -> [Node] {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else { return [] }
        var entry = DADiskCopyIOMedia(disk)
        guard entry != 0 else { return [] }

        var nodes: [Node] = []
        for depth in 0..<maxDepth {
            nodes.append(node(entry, depth: depth))
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard kr == KERN_SUCCESS, parent != 0 else { return nodes }
            entry = parent
        }
        IOObjectRelease(entry)
        return nodes
    }

    private static func node(_ entry: io_registry_entry_t, depth: Int) -> Node {
        var classBuf = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(entry, &classBuf)
        var nameBuf = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(entry, &nameBuf)

        var props: Unmanaged<CFMutableDictionary>?
        IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0)
        let dict = props?.takeRetainedValue() as? [String: Any] ?? [:]
        let flat = dict.map { (key: $0.key, value: render($0.value)) }.sorted { $0.key < $1.key }
        return Node(depth: depth,
                    className: String(decoding: classBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                    name: String(decoding: nameBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                    properties: flat)
    }

    private static func render(_ value: Any) -> String {
        switch value {
        case let d as Data:
            let hex = d.prefix(64).map { String(format: "%02x", $0) }.joined()
            return "<\(hex)\(d.count > 64 ? "…" : "")> (\(d.count) bytes)"
        case let s as String: return "\"\(s)\""
        case let dict as [String: Any]:
            return "{ " + dict.sorted { $0.key < $1.key }.map { "\($0.key)=\(render($0.value))" }.joined(separator: ", ") + " }"
        case let arr as [Any]: return "[" + arr.map(render).joined(separator: ", ") + "]"
        default: return "\(value)"
        }
    }
}
