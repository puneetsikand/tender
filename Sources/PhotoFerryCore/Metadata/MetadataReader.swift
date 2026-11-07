import AVFoundation
import Foundation
import ImageIO

/// Reads capture metadata from file headers only. Image data is never decoded.
public struct MetadataReader: Sendable {
    /// Zone used for EXIF times that carry no offset (most cameras without GPS).
    public let fallbackTimeZone: TimeZone

    public init(fallbackTimeZone: TimeZone = .current) {
        self.fallbackTimeZone = fallbackTimeZone
    }

    public func read(_ file: SourceFile) async -> CaptureMetadata {
        switch file.kind {
        case .raw, .jpeg, .heif, .tiff: readImage(at: file.url)
        case .video: await readVideo(at: file.url)
        case .sidecar, .other: CaptureMetadata()
        }
    }

    // MARK: Stills (ImageIO)

    func readImage(at url: URL) -> CaptureMetadata {
        var meta = CaptureMetadata()
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, noCache),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, noCache) as? [CFString: Any]
        else { return meta }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

        meta.cameraMake = Self.clean(tiff[kCGImagePropertyTIFFMake])
        meta.cameraModel = Self.clean(tiff[kCGImagePropertyTIFFModel])
        meta.bodySerial = Self.clean(exif[kCGImagePropertyExifBodySerialNumber])
            ?? Self.clean(aux[kCGImagePropertyExifAuxSerialNumber])
        meta.lensModel = Self.clean(exif[kCGImagePropertyExifLensModel])
            ?? Self.clean(aux[kCGImagePropertyExifAuxLensModel])
        meta.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
        meta.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int

        if let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String
                  ?? tiff[kCGImagePropertyTIFFDateTime] as? String {
            let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
            let subsec = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String
            if let parsed = Self.parseExifDate(raw, offset: offset, subsec: subsec, fallback: fallbackTimeZone) {
                meta.captureDate = parsed.date
                meta.captureDateHasOffset = parsed.hasOffset
            }
        }
        return meta
    }

    /// Parses EXIF `yyyy:MM:dd HH:mm:ss`, with optional `±HH:MM` offset and sub-second digits.
    static func parseExifDate(_ raw: String, offset: String?, subsec: String?,
                              fallback: TimeZone) -> (date: Date, hasOffset: Bool)? {
        guard let m = raw.trimmingCharacters(in: .whitespaces)
            .wholeMatch(of: /(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})/) else { return nil }
        var parts = DateComponents()
        parts.year = Int(m.1); parts.month = Int(m.2); parts.day = Int(m.3)
        parts.hour = Int(m.4); parts.minute = Int(m.5); parts.second = Int(m.6)
        guard parts.year != 0 else { return nil }   // "0000:00:00 00:00:00" = clock never set

        var zone = fallback
        var hasOffset = false
        if let offset, let o = offset.trimmingCharacters(in: .whitespaces)
            .wholeMatch(of: /([+-])(\d{2}):(\d{2})/),
           let tz = TimeZone(secondsFromGMT: (o.1 == "-" ? -1 : 1) * (Int(o.2)! * 3600 + Int(o.3)! * 60)) {
            zone = tz
            hasOffset = true
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard var date = calendar.date(from: parts) else { return nil }
        if let subsec, let digits = subsec.trimmingCharacters(in: .whitespaces).wholeMatch(of: /\d+/),
           let value = Double("0." + digits.output) {
            date += value
        }
        return (date, hasOffset)
    }

    // MARK: Video (AVFoundation)

    func readVideo(at url: URL) async -> CaptureMetadata {
        var meta = CaptureMetadata()
        let asset = AVURLAsset(url: url)
        if let item = try? await asset.load(.creationDate),
           let date = try? await item.load(.dateValue) {
            meta.captureDate = date
            meta.captureDateHasOffset = true   // QuickTime creation dates are absolute instants
        }
        if let common = try? await asset.load(.commonMetadata) {
            meta.cameraMake = await Self.string(in: common, key: .commonKeyMake)
            meta.cameraModel = await Self.string(in: common, key: .commonKeyModel)
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            meta.pixelWidth = Int(size.width.rounded())
            meta.pixelHeight = Int(size.height.rounded())
        }
        return meta
    }

    private static func string(in items: [AVMetadataItem], key: AVMetadataKey) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: items, withKey: key, keySpace: .common).first
        else { return nil }
        return clean(try? await item.load(.stringValue))
    }

    private static func clean(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)),
              !s.isEmpty else { return nil }
        return s
    }
}
