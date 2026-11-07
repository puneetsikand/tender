import Foundation
import ImageCaptureCore

/// A camera connected over USB in PTP/MTP mode (one that does not mount as a disk).
public struct CameraInfo: Sendable, Hashable, Codable {
    /// ImageCaptureCore's per-connection identifier.
    public let id: String
    public let name: String?
    public let productKind: String?
    /// Body serial as the camera reports it over PTP. Recognition tier D (PLAN §3.2).
    public let serialNumber: String?
    /// ImageCaptureCore's persistent ID, stable across reconnects of the same body.
    public let persistentID: String?
    public let usbVendorID: Int
    public let usbProductID: Int
    public let transport: String?
}

public enum CameraEvent: Sendable, Hashable {
    case connected(CameraInfo)
    case disconnected(id: String)
}

/// Streams PTP/MTP camera connections. Cameras already connected are reported first.
///
/// Content listing and downloads (opening a PTP session) arrive with the copy engine (M2).
/// Until then only discovery is implemented, which is all recognition needs.
public enum CameraMonitor {
    public static func events() -> AsyncStream<CameraEvent> {
        AsyncStream { continuation in
            Task { @MainActor in
                let browser = CameraBrowser(continuation)
                continuation.onTermination = { _ in Task { @MainActor in browser.stop() } }
            }
        }
    }
}

/// ImageCaptureCore delivers delegate calls on the main thread; this class lives there.
@MainActor
private final class CameraBrowser: NSObject, ICDeviceBrowserDelegate {
    let browser = ICDeviceBrowser()
    let continuation: AsyncStream<CameraEvent>.Continuation
    private var retainSelf: CameraBrowser?

    init(_ continuation: AsyncStream<CameraEvent>.Continuation) {
        self.continuation = continuation
        super.init()
        retainSelf = self   // released in stop()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
    }

    func stop() {
        browser.stop()
        browser.delegate = nil
        retainSelf = nil
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        let info = CameraInfo(
            id: device.uuidString ?? device.name ?? "camera",
            name: device.name,
            productKind: device.productKind,
            serialNumber: device.serialNumberString,
            persistentID: device.persistentIDString,
            usbVendorID: Int(device.usbVendorID),
            usbProductID: Int(device.usbProductID),
            transport: device.transportType)
        continuation.yield(.connected(info))   // continuation is Sendable
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        let id = device.uuidString ?? device.name ?? "camera"
        continuation.yield(.disconnected(id: id))
    }
}
