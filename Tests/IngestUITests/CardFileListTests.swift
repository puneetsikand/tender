import Foundation
import Testing
@testable import IngestUI
@testable import PhotoFerryCore

@Suite struct CardFileListTests {
    func f(_ path: String) -> SourceFile {
        let url = URL(fileURLWithPath: "/card/\(path)")
        return SourceFile(url: url, relativePath: path, size: 10, modificationDate: nil, kind: MediaKind(fileExtension: url.pathExtension))
    }

    func plan(_ entries: [SourceFile], copied: [SourceFile] = [], skipped: [(SourceFile, String)] = []) -> CopyPlan {
        let e = { (s: SourceFile) in CopyPlan.Entry(file: s, itemID: s.stem, routeID: "raw", relativePath: "2026/RAW/\(s.fileName)",
                                                     destinationIDs: ["library"], metadata: CaptureMetadata()) }
        return CopyPlan(workflow: .starter(), entries: entries.map(e), alreadyCopied: copied.map(e), skipped: skipped.map(\.0),
                        notCopiedReasons: Dictionary(uniqueKeysWithValues: skipped.map { ($0.0.relativePath, $0.1) }), issues: [])
    }

    @Test func groupsByFolderWithStatusesAndPutsWorkFirstAndOutsideLast() {
        let new = f("DCIM/101LEICA/M10_1.DNG"), old = f("DCIM/100SIGMA/SDIM1.DNG"), pp3 = f("DCIM/IRPC1.RAF.pp3")
        let outside = f("soocjpeg/IRPC1.JPG")
        let list = CardFileList(files: [old, new, pp3], outside: [outside],
                                plan: plan([new], copied: [old], skipped: [(pp3, "its file IRPC1.RAF isn't on the card")]),
                                excluded: [], includedOutside: [])
        #expect(list.folders.map(\.id) == ["DCIM/101LEICA", "DCIM", "DCIM/100SIGMA", "soocjpeg"])
        #expect(list.folders.map(\.title) == ["DCIM/101LEICA", "DCIM (top level)", "DCIM/100SIGMA", "soocjpeg"])
        #expect(list.folders[0].rows[0].status == .toCopy("2026/RAW/M10_1.DNG"))
        #expect(list.folders[1].rows[0].status == .notCopied("its file IRPC1.RAF isn't on the card"))
        #expect(list.folders[2].summary == "all already copied")
        #expect(list.folders[3].isOutsideDCIM && list.folders[3].summary == "not included")
        #expect(list.folders[3].rows[0].status == CardFileList.Status.outsideNotIncluded)
        #expect(!list.folders[3].rows[0].isIncluded)
        let counts: [Int] = CardFileList.Filter.allCases.map { list.count($0) }
        #expect(counts == [1, 1, 1, 1])
    }

    @Test func untickedFilesAndIncludedOutsideFolders() {
        let a = f("DCIM/100A/A.JPG"), b = f("DCIM/100A/B.JPG"), o = f("soocjpeg/O.JPG")
        let list = CardFileList(files: [a, b], outside: [o], plan: plan([b, o]), excluded: [a.relativePath], includedOutside: ["soocjpeg"])
        let folder = list.folders.first { $0.id == "DCIM/100A" }!
        #expect(folder.rows.first(where: { $0.file == a })?.status == CardFileList.Status.excluded)
        #expect(folder.included == 1 && folder.summary == "1 to copy · 1 not copied")
        let outside = list.folders.first(where: \.isOutsideDCIM)!
        #expect(outside.rows[0].status == .toCopy("2026/RAW/O.JPG"))
    }

    @Test func noPlanYetMeansPending() {
        let list = CardFileList(files: [f("DCIM/100A/A.JPG")], outside: [], plan: nil, excluded: [], includedOutside: [])
        #expect(list.folders[0].rows[0].status == CardFileList.Status.pending)
        #expect(list.count(.toCopy) == 0)
    }
}

@Suite struct ScanOutsideTests {
    @Test func scansPhotosAndSidecarsOutsideDCIMButNotHiddenFoldersOrDCIM() throws {
        let card = try FakeCardUI(["DCIM/100A/A.JPG", "soocjpeg/B.JPG", "soocjpeg/B.JPG.xmp", "C.RAF", "notes.txt",
                                   ".Trashes/501/D.JPG", "._C.RAF"])
        let files = CardScanner().scanOutsideRoots(card.root).map(\.relativePath)
        #expect(files == ["C.RAF", "soocjpeg/B.JPG", "soocjpeg/B.JPG.xmp"])
    }
}

/// Minimal fake card for this test target.
struct FakeCardUI: ~Copyable {
    let root: URL
    init(_ paths: [String]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pf-ui-card-\(UUID().uuidString)", isDirectory: true)
        for path in paths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: url)
        }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}
