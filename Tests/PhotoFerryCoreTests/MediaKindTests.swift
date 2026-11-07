import Testing
@testable import PhotoFerryCore

@Suite struct MediaKindTests {
    @Test(arguments: [
        ("CR3", MediaKind.raw), ("nef", .raw), (".ARW", .raw), ("raf", .raw), ("dng", .raw), ("3FR", .raw),
        ("JPG", .jpeg), ("jpeg", .jpeg), ("HIF", .heif), ("heic", .heif), ("tif", .tiff),
        ("MP4", .video), ("mov", .video), ("braw", .video),
        ("XMP", .sidecar), ("THM", .sidecar), ("wav", .sidecar),
    ])
    func classifies(ext: String, expected: MediaKind) {
        #expect(MediaKind(fileExtension: ext) == expected)
    }

    @Test func unknownAndEmptyAreOther() {
        #expect(MediaKind(fileExtension: "") == .other)
        #expect(MediaKind(fileExtension: "ctg") == .other)   // Canon catalog file in DCIM
    }
}
