import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PhotoFerryCore

@Suite struct MetadataReaderTests {
    /// Writes a small JPEG carrying the given EXIF/TIFF properties.
    static func makeJPEG(exif: [CFString: Any], tiff: [CFString: Any], at url: URL? = nil) throws -> URL {
        let url = url ?? FileManager.default.temporaryDirectory.appendingPathComponent("pf-\(UUID().uuidString).jpg")
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff,
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    @Test func readsCameraSerialLensAndOffsetDate() async throws {
        let url = try Self.makeJPEG(
            exif: [kCGImagePropertyExifDateTimeOriginal: "2026:11:07 14:30:05",
                   kCGImagePropertyExifOffsetTimeOriginal: "-05:00",
                   kCGImagePropertyExifSubsecTimeOriginal: "25",
                   kCGImagePropertyExifBodySerialNumber: "032021001234",
                   kCGImagePropertyExifLensModel: "RF24-70mm F2.8 L IS USM"],
            tiff: [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "Canon EOS R5"])
        defer { try? FileManager.default.removeItem(at: url) }
        let file = SourceFile(url: url, relativePath: url.lastPathComponent, size: 0, modificationDate: nil, kind: .jpeg)

        let meta = await MetadataReader(fallbackTimeZone: TimeZone(identifier: "Asia/Tokyo")!).read(file)
        #expect(meta.cameraMake == "Canon")
        #expect(meta.cameraModel == "Canon EOS R5")
        #expect(meta.bodySerial == "032021001234")
        #expect(meta.lensModel == "RF24-70mm F2.8 L IS USM")
        #expect(meta.pixelWidth == 64 && meta.pixelHeight == 48)
        #expect(meta.captureDateHasOffset)
        // 14:30:05.25 at -05:00 is 19:30:05.25 UTC; the fallback zone must not be used.
        let expected = try Date("2026-11-07T19:30:05.25Z", strategy: .iso8601.year().month().day()
            .time(includingFractionalSeconds: true))
        #expect(abs(try #require(meta.captureDate).timeIntervalSince(expected)) < 0.001)
    }

    @Test func dateWithoutOffsetUsesFallbackZone() throws {
        let tz = TimeZone(identifier: "America/New_York")!
        let parsed = try #require(MetadataReader.parseExifDate("2026:07:04 12:00:00", offset: nil, subsec: nil, fallback: tz))
        #expect(!parsed.hasOffset)
        #expect(parsed.date == Date(timeIntervalSince1970: 1_783_180_800))   // 16:00 UTC (EDT)
    }

    @Test func unsetCameraClockIsNoDate() {
        #expect(MetadataReader.parseExifDate("0000:00:00 00:00:00", offset: nil, subsec: nil, fallback: .gmt) == nil)
        #expect(MetadataReader.parseExifDate("garbage", offset: nil, subsec: nil, fallback: .gmt) == nil)
    }

    @Test func sidecarsAndUnreadableFilesGiveEmptyMetadata() async {
        let missing = URL(fileURLWithPath: "/nonexistent/IMG_0001.CR3")
        let reader = MetadataReader()
        #expect(await reader.read(SourceFile(url: missing, relativePath: "x", size: 0, modificationDate: nil, kind: .raw)) == CaptureMetadata())
        #expect(await reader.read(SourceFile(url: missing, relativePath: "x", size: 0, modificationDate: nil, kind: .sidecar)) == CaptureMetadata())
    }
}
