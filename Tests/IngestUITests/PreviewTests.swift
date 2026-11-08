import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import IngestUI
@testable import PhotoFerryCore
@testable import PhotoPreview

@Suite struct PreviewNavigatorTests {
    func f(_ path: String) -> SourceFile {
        let url = URL(fileURLWithPath: "/c/\(path)")
        return SourceFile(url: url, relativePath: path, size: 1, modificationDate: nil, kind: MediaKind(fileExtension: url.pathExtension))
    }

    var nav: PreviewNavigator {
        let files = ["DCIM/A.DNG", "DCIM/A.JPG", "DCIM/A.DNG.xmp", "DCIM/B.DNG", "DCIM/C.JPG", "DCIM/D.RAF", "DCIM/D.JPG"].map(f)
        var items: [String: MediaItem] = [:]
        for item in ItemGrouper().group(files) { for m in item.members { items[m.relativePath] = item } }
        return PreviewNavigator(order: files, items: items)
    }

    @Test func showsTheSelectionOrItsPartnerForTheMode() {
        #expect(nav.shown(for: "DCIM/A.DNG", mode: .raw)?.fileName == "A.DNG")
        #expect(nav.shown(for: "DCIM/A.DNG", mode: .sooc)?.fileName == "A.JPG")      // the DNG's JPEG
        #expect(nav.shown(for: "DCIM/A.JPG", mode: .raw)?.fileName == "A.DNG")       // the JPEG's DNG
        #expect(nav.shown(for: "DCIM/A.DNG.xmp", mode: .sooc)?.fileName == "A.JPG")  // a sidecar shows its photo
        #expect(nav.shown(for: "DCIM/B.DNG", mode: .sooc) == nil)                    // RAW without a JPEG
        #expect(nav.shown(for: nil, mode: .raw)?.fileName == "A.DNG")                // nothing selected: first
    }

    @Test func stepsThroughOnlyTheModesFiles() {
        let a = nav.shown(for: "DCIM/A.DNG", mode: .raw)
        #expect(nav.step(from: a, by: 1, mode: .raw)?.fileName == "B.DNG")
        #expect(nav.step(from: f("DCIM/D.RAF"), by: 1, mode: .raw) == nil)           // stops at the end
        #expect(nav.candidates(.sooc).map(\.fileName) == ["A.JPG", "C.JPG", "D.JPG"])
        #expect(nav.position(of: f("DCIM/C.JPG"), mode: .sooc)! == (1, 3))
    }
}

@Suite struct PreviewLoaderTests {
    func jpeg(width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pf-prev-\(UUID().uuidString).jpg")
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifExposureTime: 0.004, kCGImagePropertyExifFNumber: 2.8,
                                             kCGImagePropertyExifISOSpeedRatings: [200], kCGImagePropertyExifFocalLength: 35.0],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "GFX100RF"],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    @Test func decodesWithinTheSizeCapCachesAndReadsInfo() async throws {
        let url = try jpeg(width: 6000, height: 4000)
        defer { try? FileManager.default.removeItem(at: url) }
        let loader = PreviewLoader(maxPixelSize: 1500)
        let p = try #require(await loader.preview(for: url, isRaw: false))
        #expect(max(p.image.width, p.image.height) <= 1500 && p.source == .decoded)
        #expect(p.info.camera == "GFX100RF" && p.info.exposure == "ISO 200 · 1/250 s · f/2.8 · 35 mm")
        #expect(p.info.megapixels == "6000 × 4000 (24 MP)")
        #expect(await loader.isCached(url))
        let again = try #require(await loader.preview(for: url, isRaw: false))
        #expect(again.image === p.image)                                             // served from the cache
    }

    @Test func rawWhosePreviewIsTooSmallFallsBackToDecoding() async throws {
        // A RAW's "embedded preview" under 1000 px (e.g. a tiny EXIF thumbnail) isn't good enough
        // for the pane, so the loader decodes instead. A 900×700 file can't offer more than 900 px.
        let url = try jpeg(width: 900, height: 700)
        defer { try? FileManager.default.removeItem(at: url) }
        let p = try #require(await PreviewLoader(maxPixelSize: 1200).preview(for: url, isRaw: true))
        #expect(p.source == .decoded)
        #expect(p.image.width == 900)
    }

    @Test func exifDatesAreShownReadably() {
        #expect(PreviewLoader.readableExifDate("2026:09:19 12:39:06") == "2026-09-19 12:39:06")
        #expect(PreviewLoader.readableExifDate("garbage") == "garbage")
    }

    @Test func missingFileGivesNoPreviewAndCacheStaysWithinItsLimit() async throws {
        #expect(await PreviewLoader().preview(for: URL(fileURLWithPath: "/nope.JPG"), isRaw: false) == nil)
        let urls = try (0..<3).map { _ in try jpeg(width: 1000, height: 1000) }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let loader = PreviewLoader(maxPixelSize: 1000, cacheLimit: 5_000_000)        // room for one 1000² RGBA image
        for u in urls { _ = await loader.preview(for: u, isRaw: false) }
        #expect(await loader.isCached(urls[2]))
        #expect(!(await loader.isCached(urls[0])))                                   // evicted, least recently used
    }
}
