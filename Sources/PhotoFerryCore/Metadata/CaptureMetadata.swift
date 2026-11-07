import Foundation

/// What a file says about itself. Every field is optional: cameras disagree on what they write.
public struct CaptureMetadata: Sendable, Hashable, Codable {
    /// Capture instant. If the file carries no time-zone offset, this was interpreted in the
    /// zone passed to the reader; see `captureDateHasOffset`.
    public var captureDate: Date?
    /// True when the file recorded its own UTC offset (EXIF `OffsetTimeOriginal`, QuickTime dates).
    public var captureDateHasOffset = false
    public var cameraMake: String?
    public var cameraModel: String?
    /// Camera body serial number (EXIF `BodySerialNumber`, or the older ExifAux serial).
    /// Recognition tier C (PLAN §3.2).
    public var bodySerial: String?
    public var lensModel: String?
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public init() {}
}
