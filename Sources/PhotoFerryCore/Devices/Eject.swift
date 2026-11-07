import DiskArbitration
import Foundation

public enum EjectError: Error, CustomStringConvertible {
    case notAVolume
    case dissented(String)

    public var description: String {
        switch self {
        case .notAVolume: "not a mounted volume"
        case .dissented(let why): why
        }
    }
}

extension VolumeMonitor {
    /// Unmounts every volume on the card's disk, then ejects the media, like Finder's Eject.
    public static func eject(mountPoint: URL) async throws {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let volume = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, mountPoint as CFURL),
              let whole = DADiskCopyWholeDisk(volume) else { throw EjectError.notAVolume }
        let queue = DispatchQueue(label: "photoferry.eject")   // DiskArbitration requires a queue
        DASessionSetDispatchQueue(session, queue)
        defer { DASessionSetDispatchQueue(session, nil) }

        try await DACall { ctx, done in
            DADiskUnmount(whole, DADiskUnmountOptions(kDADiskUnmountOptionWhole), done, ctx)
        }
        try await DACall { ctx, done in
            DADiskEject(whole, DADiskEjectOptions(kDADiskEjectOptionDefault), done, ctx)
        }
    }
}

/// Bridges one DiskArbitration completion callback to async/await.
private func DACall(_ start: (UnsafeMutableRawPointer, @escaping DADiskUnmountCallback) -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let box = Unmanaged.passRetained(Box(continuation)).toOpaque()
        start(box) { _, dissenter, ctx in
            let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
            if let dissenter {
                let status = DADissenterGetStatus(dissenter)
                let why = DADissenterGetStatusString(dissenter).map { $0 as String } ?? "error 0x\(String(status, radix: 16))"
                box.continuation.resume(throwing: EjectError.dissented(why))
            } else {
                box.continuation.resume()
            }
        }
    }
}

private final class Box {
    let continuation: CheckedContinuation<Void, any Error>
    init(_ c: CheckedContinuation<Void, any Error>) { continuation = c }
}
