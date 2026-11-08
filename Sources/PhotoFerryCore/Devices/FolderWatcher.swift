import CoreServices
import Foundation

/// Reports changes anywhere under a folder (a card's mount point), via FSEvents.
///
/// Each element means "something changed here; rescan". Bursts are coalesced by FSEvents'
/// latency. FSEvents needs a dispatch queue; it never escapes this file.
public enum FolderWatcher {
    public static func changes(of folder: URL, latency: TimeInterval = 1.0) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let watch = FSWatch(folder.path, latency: latency, continuation)
            continuation.onTermination = { _ in watch.stop() }
        }
    }
}

/// `@unchecked Sendable`: the stream is only touched on `queue` and in `stop()`, which hops there.
private final class FSWatch: @unchecked Sendable {
    let queue = DispatchQueue(label: "photoferry.fsevents")
    let continuation: AsyncStream<Void>.Continuation
    var stream: FSEventStreamRef?

    init(_ path: String, latency: TimeInterval, _ continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            Unmanaged<FSWatch>.fromOpaque(info!).takeUnretainedValue().continuation.yield(())
        }
        guard let s = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        _ = Unmanaged.passRetained(self)                 // released in stop()
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    func stop() {
        queue.async { [self] in
            guard let s = stream else { return }
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
            Unmanaged.passUnretained(self).release()
        }
    }
}
