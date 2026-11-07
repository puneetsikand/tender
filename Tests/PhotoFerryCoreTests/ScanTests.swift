import Foundation
import Testing
@testable import PhotoFerryCore

/// A throwaway folder laid out like a card.
struct FakeCard: ~Copyable {
    let root: URL

    init(_ paths: [String]) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pf-card-\(UUID().uuidString)", isDirectory: true)
        for path in paths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(path.utf8).write(to: url)
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

@Suite struct CardScannerTests {
    @Test func scansOnlyMediaRoots() throws {
        let card = try FakeCard([
            "DCIM/100EOSR5/IMG_0001.CR3",
            "DCIM/100EOSR5/IMG_0001.JPG",
            "DCIM/100EOSR5/._IMG_0001.JPG",
            "DCIM/100EOSR5/.hidden",
            "MISC/settings.dat",
            "PRIVATE/M4ROOT/CLIP/C0001.MP4",
            "PRIVATE/M4ROOT/CLIP/C0001M01.XML",
            "PRIVATE/M4ROOT/THMBNL/C0001T01.JPG",
        ])
        let files = try CardScanner().scan(card.root)
        #expect(files.map(\.relativePath) == [
            "DCIM/100EOSR5/IMG_0001.CR3",
            "DCIM/100EOSR5/IMG_0001.JPG",
            "PRIVATE/M4ROOT/CLIP/C0001.MP4",
            "PRIVATE/M4ROOT/CLIP/C0001M01.XML",
        ])
        #expect(files[0].kind == .raw)
        #expect(files[0].size == Int64("DCIM/100EOSR5/IMG_0001.CR3".utf8.count))
    }

    @Test func mediaRootsMatchCaseInsensitively() throws {
        let card = try FakeCard(["dcim/100_FUJI/DSCF0001.RAF"])
        #expect(CardScanner().looksLikeCard(card.root))
        #expect(try CardScanner().scan(card.root).count == 1)
    }

    @Test func folderWithoutMediaRootIsNotACard() throws {
        let card = try FakeCard(["Documents/notes.txt"])
        #expect(!CardScanner().looksLikeCard(card.root))
        #expect(try CardScanner().scan(card.root).isEmpty)
    }
}

@Suite struct ItemGrouperTests {
    func items(_ paths: [String]) throws -> [MediaItem] {
        let card = try FakeCard(paths)
        return ItemGrouper().group(try CardScanner().scan(card.root))
    }

    @Test func rawJpegPairIsOneItemWithRawPrimary() throws {
        let result = try items(["DCIM/100EOSR5/IMG_0001.JPG", "DCIM/100EOSR5/IMG_0001.CR3",
                                "DCIM/100EOSR5/IMG_0001.xmp", "DCIM/100EOSR5/IMG_0002.CR3"])
        #expect(result.count == 2)
        #expect(result[0].primary.fileName == "IMG_0001.CR3")
        #expect(result[0].members.map(\.fileName) == ["IMG_0001.CR3", "IMG_0001.JPG", "IMG_0001.xmp"])
    }

    @Test func sameStemInDifferentFoldersStaysSeparate() throws {
        let result = try items(["DCIM/100EOSR5/IMG_0001.CR3", "DCIM/101EOSR5/IMG_0001.CR3"])
        #expect(result.count == 2)
    }

    @Test func sonyClipGroupsWithItsXml() throws {
        let result = try items(["PRIVATE/M4ROOT/CLIP/C0001.MP4", "PRIVATE/M4ROOT/CLIP/C0001M01.XML"])
        #expect(result.count == 1)
        #expect(result[0].primary.fileName == "C0001.MP4")
    }

    @Test func goProChapterGroupsMp4ThmAndLrf() throws {
        let result = try items(["DCIM/100GOPRO/GX010001.MP4", "DCIM/100GOPRO/GX010001.THM",
                                "DCIM/100GOPRO/GL010001.LRF", "DCIM/100GOPRO/GX020001.MP4"])
        #expect(result.count == 2)
        #expect(result[0].members.map(\.fileName) == ["GX010001.MP4", "GL010001.LRF", "GX010001.THM"])
    }

    @Test func emptyInputGivesNoItems() {
        #expect(ItemGrouper().group([]).isEmpty)
    }
}
