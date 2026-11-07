import DiskArbitration
import Foundation

public enum VolumeEvent: Sendable, Hashable {
    case mounted(VolumeInfo)
    case unmounted(id: String)
}

/// Streams volume mounts and unmounts. Volumes already mounted are reported first.
///
/// DiskArbitration delivers callbacks on a dispatch queue. That queue is required by the
/// API; it is the only GCD use, and it never escapes this file.
public enum VolumeMonitor {
    public static func events() -> AsyncStream<VolumeEvent> {
        AsyncStream { continuation in
            let watch = DAWatch(continuation)
            continuation.onTermination = { _ in watch.stop() }
        }
    }

    /// Describes the volume mounted at `url`, if DiskArbitration knows it.
    public static func describe(mountPoint url: URL) -> VolumeInfo? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let d = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
        return VolumeInfo(description: d)
    }
}

/// Owns one DiskArbitration session. `@unchecked Sendable`: the session is touched only on
/// `queue` (callbacks) and in `stop()`, which hops onto that queue.
private final class DAWatch: @unchecked Sendable {
    let session: DASession
    let queue = DispatchQueue(label: "photoferry.diskarbitration")
    let continuation: AsyncStream<VolumeEvent>.Continuation
    /// Volumes reported as mounted, so an unmount is only sent for something we announced.
    var mounted: Set<String> = []

    init(_ continuation: AsyncStream<VolumeEvent>.Continuation) {
        self.continuation = continuation
        session = DASessionCreate(kCFAllocatorDefault)!
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskAppearedCallback(session, nil, { disk, ctx in
            Unmanaged<DAWatch>.fromOpaque(ctx!).takeUnretainedValue().update(disk)
        }, ctx)
        DARegisterDiskDescriptionChangedCallback(session, nil,
            [kDADiskDescriptionVolumePathKey] as CFArray, { disk, _, ctx in
            Unmanaged<DAWatch>.fromOpaque(ctx!).takeUnretainedValue().update(disk)
        }, ctx)
        DARegisterDiskDisappearedCallback(session, nil, { disk, ctx in
            Unmanaged<DAWatch>.fromOpaque(ctx!).takeUnretainedValue().gone(disk)
        }, ctx)
        // Keep self alive until stop(); the callbacks hold an unretained pointer.
        _ = Unmanaged.passRetained(self)
        DASessionSetDispatchQueue(session, queue)
    }

    func update(_ disk: DADisk) {
        guard let d = DADiskCopyDescription(disk) as? [String: Any] else { return }
        let bsd = d[kDADiskDescriptionMediaBSDNameKey as String] as? String
        if let info = VolumeInfo(description: d), info.mountPoint != nil {
            if mounted.insert(info.id).inserted { continuation.yield(.mounted(info)) }
        } else if let bsd, mounted.remove(bsd) != nil {
            continuation.yield(.unmounted(id: bsd))
        }
    }

    func gone(_ disk: DADisk) {
        let d = DADiskCopyDescription(disk) as? [String: Any]
        let bsd = DADiskGetBSDName(disk).map { String(cString: $0) }
        let path = (d?[kDADiskDescriptionVolumePathKey as String] as? URL)?.path
        for id in [bsd, path].compactMap({ $0 }) where mounted.remove(id) != nil {
            continuation.yield(.unmounted(id: id))
        }
    }

    func stop() {
        queue.async { [self] in
            DASessionSetDispatchQueue(session, nil)
            Unmanaged.passUnretained(self).release()
        }
    }
}
