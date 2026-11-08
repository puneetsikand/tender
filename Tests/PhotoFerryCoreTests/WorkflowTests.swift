import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PhotoFerryCore

@Suite struct TemplateTests {
    func render(_ t: String, file: String = "DCIM/100SIGMA/SDIM0199.DNG", meta: CaptureMetadata = CaptureMetadata(),
                date: Date? = Date(timeIntervalSince1970: 1_783_007_000), seq: Int = 7, zone: TimeZone = .gmt) throws -> String {
        let url = URL(fileURLWithPath: "/card/\(file)")
        let f = SourceFile(url: url, relativePath: file, size: 1, modificationDate: nil, kind: MediaKind(fileExtension: url.pathExtension))
        return try Template(t).render(.init(file: f, meta: meta, date: date, sequence: seq, cardLabel: "NO NAME",
                                            workflowName: "Test", formatters: DateFormatters(defaultZone: zone)))
    }

    @Test func dateTokensAndPatterns() throws {
        // 1_783_007_000 = 2026-07-02 15:43:20 UTC
        #expect(try render("{date}") == "2026-07-02")
        #expect(try render("{date:yyyyMMdd}_{time}") == "20260702_154320")
        #expect(try render("{year}/{month}/{day} {hour}{minute}{second}") == "2026/07/02 154320")
        #expect(try render("{date}", zone: TimeZone(identifier: "Asia/Tokyo")!) == "2026-07-03")   // 00:43 next day in Tokyo
    }

    @Test func recordedOffsetBeatsTheWorkflowZone() throws {
        var m = CaptureMetadata()
        m.captureUTCOffsetSeconds = -5 * 3600   // shot at 10:43 local, UTC-5
        #expect(try render("{date} {hour}", meta: m, zone: TimeZone(identifier: "Asia/Tokyo")!) == "2026-07-02 10")
    }

    @Test func fileAndCameraTokens() throws {
        var m = CaptureMetadata()
        m.cameraModel = "SIGMA fp"; m.cameraMake = "SIGMA"; m.bodySerial = "91420511"
        #expect(try render("{orig}.{ext}|{EXT}|{kind}|{KIND}") == "SDIM0199.dng|DNG|raw|RAW")
        #expect(try render("{make} {camera} #{serial}", meta: m) == "SIGMA SIGMA fp #91420511")
        #expect(try render("{seq}-{seq:2}-{seq:6}") == "0007-07-000007")
        #expect(try render("{card}/{workflow}") == "NO NAME/Test")
    }

    @Test func missingValuesUseFallbackOrUnknown() throws {
        #expect(try render("{serial|nobody}-{lens}") == "nobody-unknown")
        #expect(try render("{date|undated}", date: nil) == "undated")
    }

    @Test func valuesCannotEscapeTheirPathComponent() throws {
        var m = CaptureMetadata()
        m.cameraModel = "../evil/cam:era"
        #expect(try render("{camera}", meta: m) == "-evil-cam-era")      // no separators, no leading dots
        m.cameraModel = "..."
        #expect(try render("{camera|cam}", meta: m) == "cam")
    }

    @Test func literalBraces() throws {
        #expect(try render("{{x}} {orig}") == "{x} SDIM0199")
    }

    @Test(arguments: [
        ("{nope}", "unknown token {nope}"), ("{date", "unclosed {"), ("a}b", "unmatched }"), ("{}", "empty token {}"),
        ("{seq:0}", "{seq:0}: width must be 1–9"), ("{seq:x}", "{seq:x}: width must be 1–9"),
        ("{camera:x}", "{camera} takes no argument"), ("{date:}", "empty argument in {date:}"),
    ])
    func parseErrors(template: String, message: String) {
        #expect(throws: Template.ParseError(template: template, message: message)) { try Template(template) }
    }
}

@Suite struct PlannerTests {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pf-plan-\(UUID().uuidString)")

    /// A card with EXIF-bearing JPEGs (real metadata) and dummy RAW/XMP/video next to them.
    func card(_ layout: [(name: String, exifDate: String?, offset: String?)]) throws -> [SourceFile] {
        for f in layout {
            let url = tmp.appendingPathComponent("card/DCIM/100SIGMA/\(f.name)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if url.pathExtension.uppercased() == "JPG" {
                var exif: [CFString: Any] = [kCGImagePropertyExifBodySerialNumber: "91420511"]
                if let d = f.exifDate { exif[kCGImagePropertyExifDateTimeOriginal] = d }
                if let o = f.offset { exif[kCGImagePropertyExifOffsetTimeOriginal] = o }
                _ = try MetadataReaderTests.makeJPEG(exif: exif, tiff: [kCGImagePropertyTIFFModel: "SIGMA fp"], at: url)
            } else {
                try Data(f.name.utf8).write(to: url)
            }
        }
        return try CardScanner().scan(tmp.appendingPathComponent("card"))
    }

    func workflow(_ edit: (inout Workflow) -> Void = { _ in }) -> Workflow {
        var w = Workflow.starter(root: tmp.appendingPathComponent("lib").path)
        w.timeZone = "America/New_York"
        edit(&w)
        return w
    }

    @Test func starterSplitsAPairByTypeUnderTheDateOfWhicheverMemberHasOne() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        // The dummy DNG is the primary but has no readable EXIF; the dated JPEG supplies the date.
        let files = try card([("SDIM0200.JPG", "2026:11:06 14:17:52", nil), ("SDIM0200.DNG", nil, nil)])
        let plan = await try Planner(workflow()).plan(files, cardLabel: "NO NAME")
        #expect(Set(plan.entries.map(\.relativePath)) == ["2026/2026-11-06/RAW/SDIM0200.DNG", "2026/2026-11-06/JPEG/SDIM0200.JPG"])
        #expect(plan.entries.allSatisfy { $0.metadata.bodySerial == "91420511" })
        #expect(plan.canRun)
    }

    @Test func sidecarFollowsItsRenamedPrimary() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let files = try card([("SDIM0201.JPG", "2026:11:06 15:21:11", nil), ("SDIM0201.XMP", nil, nil)])
        let plan = await try Planner(workflow { w in
            w.routes = [.init(id: "img", name: "Images", match: .init(kinds: [.jpeg]), folder: "{date}", fileName: "{date:yyyyMMdd}_{seq:3}", destinations: ["library"])]
        }).plan(files, cardLabel: nil)
        #expect(plan.entries.map(\.relativePath).sorted() == ["2026-11-06/20261106_001.JPG", "2026-11-06/20261106_001.XMP"])
    }

    @Test func sequenceFollowsCaptureOrderNotFileNames() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let files = try card([("A.JPG", "2026:11:06 18:00:00", nil), ("B.JPG", "2026:11:06 09:00:00", nil)])
        let plan = await try Planner(workflow { w in w.routes[1].fileName = "{seq:2}_{orig}" }).plan(files, cardLabel: nil)
        #expect(plan.entries.map(\.relativePath).sorted() == ["2026/2026-11-06/JPEG/01_B.JPG", "2026/2026-11-06/JPEG/02_A.JPG"])
    }

    @Test func nameClashIsAnErrorAndBlocksTheRun() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let files = try card([("A.JPG", "2026:11:06 18:00:00", nil), ("B.JPG", "2026:11:06 09:00:00", nil)])
        let plan = await try Planner(workflow { w in w.routes[1].fileName = "{date}" }).plan(files, cardLabel: nil)
        #expect(!plan.canRun)
        #expect(plan.issues.contains { $0.severity == .error && $0.message.contains("2 files would be named 2026/2026-11-06/JPEG/2026-11-06.JPG") })
    }

    @Test func offsetTimesFileUnderLocalCaptureDateAndZoneFallbackIsUsedOtherwise() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        // 23:30 at +09:00 is 14:30 UTC / 09:30 New York; still Nov 6 where it was shot.
        let files = try card([("T.JPG", "2026:11:06 23:30:00", "+09:00"), ("N.JPG", "2026:11:06 23:30:00", nil)])
        let plan = await try Planner(workflow { w in w.routes[1].fileName = "{orig}_{time:HHmm}" }).plan(files, cardLabel: nil)
        #expect(Set(plan.entries.map(\.relativePath)) == ["2026/2026-11-06/JPEG/T_2330.JPG", "2026/2026-11-06/JPEG/N_2330.JPG"])
    }

    @Test func machineZoneFallbackIsReportedWhenTheWorkflowDoesNotPinOne() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let files = try card([("N.JPG", "2026:11:06 12:00:00", nil)])
        let plan = await try Planner(workflow { w in w.timeZone = nil }).plan(files, cardLabel: nil)
        #expect(plan.issues.contains { $0.severity == .info && $0.message.contains("Mac's zone") })
    }

    @Test func unroutedAndSkippedFilesStayOnTheCard() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let files = try card([("A.JPG", "2026:11:06 12:00:00", nil), ("C0001.MP4", nil, nil), ("X.CR3", nil, nil)])
        let plan = await try Planner(workflow { w in
            w.routes = [.init(id: "img", name: "Images", match: .init(kinds: [.jpeg]), folder: "{date}", destinations: ["library"]),
                        .init(id: "novideo", name: "No video", match: .init(kinds: [.video]), folder: "", destinations: [], skip: true)]
        }).plan(files, cardLabel: nil)
        #expect(plan.entries.map(\.file.fileName) == ["A.JPG"])
        #expect(Set(plan.skipped.map(\.fileName)) == ["C0001.MP4", "X.CR3"])
        let warning = try #require(plan.issues.first { $0.message.hasPrefix("1 file(s) matched no route") })
        #expect(warning.severity == .warning && warning.message.contains("X.CR3") && !warning.message.contains("MP4"))
    }

    @Test func emptyCardCannotRun() async throws {
        let plan = await try Planner(workflow()).plan([], cardLabel: nil)
        #expect(!plan.canRun)
    }

    @Test func planBecomesAJobWithAbsoluteDestinationsAndMetadata() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let files = try card([("A.JPG", "2026:11:06 12:00:00", nil)])
        let w = workflow { w in
            w.destinations.append(.init(id: "nas", name: "NAS", root: tmp.appendingPathComponent("nas").path))
            w.routes[1].destinations = ["library", "nas"]
        }
        let job = await try Planner(w).plan(files, cardLabel: nil).job(source: JobSource(root: tmp))
        let request = try #require(job.requests.first)
        #expect(request.destinations.map(\.path) == [
            tmp.appendingPathComponent("lib/2026/2026-11-06/JPEG/A.JPG").path,
            tmp.appendingPathComponent("nas/2026/2026-11-06/JPEG/A.JPG").path])
        #expect(request.metadata?.bodySerial == "91420511")
        #expect(job.workflowName == w.name && job.options.verify == .hash)
        #expect(job.destinationRoots.count == 2)
    }

    @Test func validationReportsEveryProblem() {
        var w = workflow()
        w.timeZone = "Mars/Olympus"
        w.routes[0].folder = "{nope}"
        w.routes[1].destinations = ["missing"]
        w.routes[2].destinations = []
        w.routes[2].fileName = "a/b"
        #expect {
            try Planner.validate(w)
        } throws: { error in
            guard case WorkflowError.invalid(let p) = error else { return false }
            return p.count == 5 && p.contains("unknown time zone \"Mars/Olympus\"")
                && p.contains { $0.contains("unknown token {nope}") }
                && p.contains("route \"jpeg\" sends files to unknown destination \"missing\"")
                && p.contains { $0.hasPrefix("route \"video\" has no destinations") }
                && p.contains { $0.contains("file name contains /") }
        }
    }
}

@Suite struct WorkflowStoreTests {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pf-store-\(UUID().uuidString)")

    @Test func savesJsonAndMarkdownAndLoadsByNameOrPath() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = WorkflowStore(folder: tmp)
        let w = Workflow.starter(name: "SIGMA fp → NAS", root: "~/Pictures/PhotoFerry")
        let url = try store.save(w)
        #expect(url.lastPathComponent == "SIGMA fp → NAS.pfflow")
        #expect(try store.load("SIGMA fp → NAS") == w)
        #expect(try store.load(url.path) == w)
        let md = try String(contentsOf: url.deletingPathExtension().appendingPathExtension("md"), encoding: .utf8)
        #expect(md.contains("# SIGMA fp → NAS"))
        #expect(md.contains("1. **RAW**: RAW files → `{date:yyyy}/{date:yyyy-MM-dd}/RAW/{orig}.<ext>` in Photo library"))
        #expect(try store.list().count == 1)
    }

    @Test func jsonIsStableAndHumanReadable() throws {
        let data = try WorkflowStore.encode(Workflow.starter())
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"folder\" : \"{date:yyyy}/{date:yyyy-MM-dd}/RAW\""))   // slashes unescaped
        #expect(try WorkflowStore.encode(WorkflowStore.decode(data)) == data)           // round-trip is byte-stable
    }

    @Test func invalidWorkflowIsNotSaved() {
        var w = Workflow.starter()
        w.destinations = []
        #expect(throws: WorkflowError.self) { try WorkflowStore(folder: tmp).save(w) }
        #expect(!FileManager.default.fileExists(atPath: tmp.path))
    }
}

@Suite struct WorkflowStoreEditingTests {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pf-store-edit-\(UUID().uuidString)")

    func files() -> Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []) }

    @Test func renameMovesBothFilesAndCannotOverwriteAnother() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = WorkflowStore(folder: tmp)
        var w = Workflow.starter(name: "A")
        try store.save(w)
        try store.save(Workflow.starter(name: "B"))
        w.name = "C"
        try store.save(w, replacing: "A")
        #expect(files() == ["B.pfflow", "B.md", "C.pfflow", "C.md"])

        w.name = "B"
        #expect(throws: WorkflowError.self) { try store.save(w, replacing: "C") }
        #expect(files() == ["B.pfflow", "B.md", "C.pfflow", "C.md"])   // nothing lost
    }

    @Test func newWorkflowCannotTakeAnExistingNameButResavingItselfIsFine() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = WorkflowStore(folder: tmp)
        var w = Workflow.starter(name: "A")
        try store.save(w)
        #expect(throws: WorkflowError.self) { try store.save(Workflow.starter(name: "A")) }
        w.verify = .paranoid
        try store.save(w, replacing: "A")
        #expect(try store.load("A").verify == .paranoid)
    }

    @Test func deleteRemovesBothFiles() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = WorkflowStore(folder: tmp)
        try store.save(Workflow.starter(name: "A"))
        try store.delete("A")
        #expect(files().isEmpty)
    }
}

@Suite struct SchemaV2Tests {
    @Test func v1FileLoadsWithV2Defaults() throws {
        // A workflow exactly as M4/M6 wrote it (schema v1, no v2 keys).
        let v1 = """
        {"destinations":[{"id":"library","name":"Photo library","root":"~/Pictures/PhotoFerry"}],
         "extensionCase":"original","name":"Old","routes":[{"destinations":["library"],"fileName":"{orig}",
         "folder":"{date}","id":"raw","match":{"kinds":["raw"]},"name":"RAW","skip":false}],
         "schemaVersion":1,"sequenceStart":1,"verify":"hash"}
        """
        let w = try WorkflowStore.decode(Data(v1.utf8))
        #expect(w.schemaVersion == 1 && w.onClash == .keepBoth && w.skipPreviouslyCopied)
        #expect(w.afterCopy == Workflow.AfterCopy() && !w.autoRun.isEnabled)
        try Planner.validate(w)
        // Saving writes the new fields (and the app writes v2 for new workflows).
        let text = String(decoding: try WorkflowStore.encode(w), as: UTF8.self)
        #expect(text.contains("\"onClash\" : \"keepBoth\"") && text.contains("\"autoRun\""))
        #expect(Workflow.starter().schemaVersion == 2)
    }
}

@Suite struct PreviouslyCopiedTests {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pf-again-\(UUID().uuidString)")

    @Test func reinsertedCardPlansOnlyNewFilesAndSurvivesMovedCopies() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let card = tmp.appendingPathComponent("card/DCIM/100SIGMA")
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        for n in 1...3 { try Data(repeating: UInt8(n), count: 50_000 * n).write(to: card.appendingPathComponent("SDIM000\(n).DNG")) }
        let ledger = try Ledger(url: tmp.appendingPathComponent("ledger.sqlite"))
        var w = Workflow.starter(root: tmp.appendingPathComponent("lib").path)
        w.routes[0].folder = "RAW"
        let planner = try Planner(w)
        let scan = { try CardScanner().scan(tmp.appendingPathComponent("card")) }

        // First run copies everything.
        let first = await planner.plan(try scan(), cardLabel: nil, ledger: ledger)
        #expect(first.entries.count == 3 && first.alreadyCopied.isEmpty)
        for await e in JobExecutor(ledger: ledger).run(first.job(source: JobSource(root: tmp))) { _ = e }

        // A new photo appears on the card: only it is planned.
        try Data(repeating: 9, count: 70_000).write(to: card.appendingPathComponent("SDIM0004.DNG"))
        let second = await planner.plan(try scan(), cardLabel: nil, ledger: ledger)
        #expect(second.entries.map(\.file.fileName) == ["SDIM0004.DNG"])
        #expect(second.alreadyCopied.count == 3 && second.canRun)
        #expect(second.issues.contains { $0.message.contains("only the 1 new file(s) will be copied") })

        // A copy that was deleted from the destination is planned again.
        try FileManager.default.removeItem(at: tmp.appendingPathComponent("lib/RAW/SDIM0002.DNG"))
        let third = await planner.plan(try scan(), cardLabel: nil, ledger: ledger)
        #expect(Set(third.entries.map(\.file.fileName)) == ["SDIM0002.DNG", "SDIM0004.DNG"])

        // Turned off, everything is planned (and the engine then skips identical files by hash).
        w.skipPreviouslyCopied = false
        #expect(await try Planner(w).plan(try scan(), cardLabel: nil, ledger: ledger).entries.count == 4)
    }

    @Test func allAlreadyCopiedIsNotAnErrorButCannotRun() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let card = tmp.appendingPathComponent("card/DCIM/100SIGMA")
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1000).write(to: card.appendingPathComponent("A.DNG"))
        let ledger = try Ledger(url: tmp.appendingPathComponent("ledger.sqlite"))
        let planner = try Planner(Workflow.starter(root: tmp.appendingPathComponent("lib").path))
        let files = try CardScanner().scan(tmp.appendingPathComponent("card"))
        for await e in JobExecutor(ledger: ledger).run(await planner.plan(files, cardLabel: nil, ledger: ledger).job(source: JobSource(root: tmp))) { _ = e }
        let again = await planner.plan(files, cardLabel: nil, ledger: ledger)
        #expect(!again.canRun && again.entries.isEmpty && again.alreadyCopied.count == 1)
        #expect(!again.issues.contains { $0.severity == .error })
    }
}

@Suite struct WholeNameSidecarTests {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pf-xmp-\(UUID().uuidString)")

    @Test func lightroomStyleSidecarsFollowTheirExactFileAndKeepThePairing() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dir = tmp.appendingPathComponent("card/DCIM/untitled folder")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in ["M10_1091.DNG", "M10_1091.DNG.xmp", "M10_1091.JPG", "M10_1091.JPG.xmp", "IMG_7.CR3", "IMG_7.xmp",
                  "ORPHAN.RAF.xmp", "X.RAF", "X.RAF.pp3"] {
            try Data(n.utf8).write(to: dir.appendingPathComponent(n))
        }
        let files = try CardScanner().scan(tmp.appendingPathComponent("card"))
        let groups = ItemGrouper().group(files)
        #expect(groups.first { $0.id.hasSuffix("/M10_1091") }?.members.count == 4)

        var w = Workflow.starter(root: tmp.appendingPathComponent("lib").path)
        w.routes[0].folder = "RAW"; w.routes[0].fileName = "LEICA_{orig}"
        w.routes[1].folder = "SOOC"; w.routes[1].fileName = "LEICA_{orig}"
        let plan = await try Planner(w).plan(files, cardLabel: nil)
        let paths = Dictionary(uniqueKeysWithValues: plan.entries.map { ($0.file.fileName, $0.relativePath) })
        #expect(paths["M10_1091.DNG.xmp"] == "RAW/LEICA_M10_1091.DNG.xmp")    // beside the RAW, pairing kept
        #expect(paths["M10_1091.JPG.xmp"] == "SOOC/LEICA_M10_1091.JPG.xmp")   // beside the JPEG, not the RAW
        #expect(paths["IMG_7.xmp"] == "RAW/LEICA_IMG_7.xmp")                  // classic naming still works
        #expect(paths["X.RAF.pp3"] == "RAW/LEICA_X.RAF.pp3")                  // RawTherapee sidecar
        #expect(plan.skipped.map(\.fileName) == ["ORPHAN.RAF.xmp"])           // its file isn't on the card
        #expect(!plan.issues.contains { $0.severity == .error })
    }
}
