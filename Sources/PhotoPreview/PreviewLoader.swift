import CoreGraphics
import Foundation
import ImageIO

/// Facts shown beside a preview. Read from the file's header only.
public struct PhotoInfo: Sendable, Hashable {
    public var camera: String?
    public var lens: String?
    public var iso: Int?
    public var exposureTime: Double?
    public var fNumber: Double?
    public var focalLength: Double?
    public var captured: String?
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public var exposure: String? {
        var parts: [String] = []
        if let iso { parts.append("ISO \(iso)") }
        if let t = exposureTime { parts.append(t >= 1 ? String(format: "%g s", t) : "1/\(Int((1 / t).rounded())) s") }
        if let f = fNumber { parts.append(String(format: "f/%g", f)) }
        if let fl = focalLength { parts.append(String(format: "%g mm", fl)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public var megapixels: String? {
        guard let w = pixelWidth, let h = pixelHeight else { return nil }
        return String(format: "%d × %d (%.0f MP)", w, h, Double(w * h) / 1_000_000)
    }
}

public struct PreviewImage: @unchecked Sendable {   // CGImage is immutable and thread-safe
    public enum Source: String, Sendable { case embeddedPreview, decoded }
    public let image: CGImage
    public let source: Source
    public let info: PhotoInfo
    public let decodeTime: Duration
    var bytes: Int { image.bytesPerRow * image.height }
}

/// Loads screen-size previews fast, measured on real cards (2026-11-08):
/// - RAW: use the embedded preview. GFX100RF RAF 102 MP → 4000×3000 in 70–96 ms, versus 2–4 s to
///   decode the RAW. Fuji X-E2 → 1920×1280 in 21 ms. SIGMA fp / Leica M10 DNG ≈ 150–230 ms.
/// - JPEG/HEIF/TIFF: decode at reduced size (ImageIO scales during decode).
/// A full RAW decode happens only if a RAW has no usable embedded preview.
public actor PreviewLoader {
    public let maxPixelSize: Int
    public let cacheLimit: Int
    private var cache: [URL: PreviewImage] = [:]
    private var order: [URL] = []                     // least recently used first
    private var inFlight: [URL: Task<PreviewImage?, Never>] = [:]

    public init(maxPixelSize: Int = 3000, cacheLimit: Int = 400 << 20) {
        self.maxPixelSize = maxPixelSize
        self.cacheLimit = cacheLimit
    }

    public func preview(for url: URL, isRaw: Bool) async -> PreviewImage? {
        if let hit = cache[url] { touch(url); return hit }
        if let running = inFlight[url] { return await running.value }
        let max = maxPixelSize
        let task = Task.detached(priority: .userInitiated) { Self.decode(url, isRaw: isRaw, maxPixelSize: max) }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        if let result { store(url, result) }
        return result
    }

    /// Starts loading files the user is likely to look at next. Already cached or loading files are skipped.
    public func prefetch(_ files: [(url: URL, isRaw: Bool)]) {
        for f in files where cache[f.url] == nil && inFlight[f.url] == nil {
            Task { _ = await self.preview(for: f.url, isRaw: f.isRaw) }
        }
    }

    public func isCached(_ url: URL) -> Bool { cache[url] != nil }

    private func touch(_ url: URL) {
        order.removeAll { $0 == url }
        order.append(url)
    }

    private func store(_ url: URL, _ p: PreviewImage) {
        cache[url] = p
        touch(url)
        var total = cache.values.reduce(0) { $0 + $1.bytes }
        while total > cacheLimit, order.count > 1, let oldest = order.first {
            total -= cache[oldest]?.bytes ?? 0
            cache[oldest] = nil
            order.removeFirst()
        }
    }

    static func decode(_ url: URL, isRaw: Bool, maxPixelSize: Int) -> PreviewImage? {
        let start = ContinuousClock.now
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, noCache) else { return nil }
        let info = readInfo(source)

        func thumbnail(fromImage: Bool) -> CGImage? {
            var options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if fromImage { options[kCGImageSourceCreateThumbnailFromImageAlways] = true }
            else { options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = false }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }

        if isRaw, let embedded = thumbnail(fromImage: false), max(embedded.width, embedded.height) >= 1000 {
            return PreviewImage(image: embedded, source: .embeddedPreview, info: info, decodeTime: ContinuousClock.now - start)
        }
        guard let decoded = thumbnail(fromImage: true) else { return nil }
        return PreviewImage(image: decoded, source: .decoded, info: info, decodeTime: ContinuousClock.now - start)
    }

    /// "2026:09:19 12:39:06" → "2026-09-19 12:39:06" (camera wall-clock time, as recorded).
    static func readableExifDate(_ s: String) -> String {
        guard let m = s.wholeMatch(of: /(\d{4}):(\d{2}):(\d{2})(.*)/) else { return s }
        return "\(m.1)-\(m.2)-\(m.3)\(m.4)"
    }

    static func readInfo(_ source: CGImageSource) -> PhotoInfo {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        func str(_ v: Any?) -> String? {
            (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).nilIfEmpty
        }
        var i = PhotoInfo()
        i.camera = str(tiff[kCGImagePropertyTIFFModel])
        i.lens = str(exif[kCGImagePropertyExifLensModel]) ?? str(aux[kCGImagePropertyExifAuxLensModel])
        i.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
        i.exposureTime = exif[kCGImagePropertyExifExposureTime] as? Double
        i.fNumber = exif[kCGImagePropertyExifFNumber] as? Double
        i.focalLength = exif[kCGImagePropertyExifFocalLength] as? Double
        i.captured = str(exif[kCGImagePropertyExifDateTimeOriginal]).map(Self.readableExifDate)
        i.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
        i.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int
        return i
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
