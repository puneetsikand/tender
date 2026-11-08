import Foundation
import Observation
import PhotoFerryCore

/// One inserted card: its scan, the plan for the chosen workflow, and its job.
@Observable @MainActor
public final class CardSession: Identifiable {
    public nonisolated let id: String
    public let volume: VolumeInfo
    public let hardwareID: CardHardwareID?
    public let root: URL

    public private(set) var files: [SourceFile] = []
    public private(set) var scanning = true
    public private(set) var scanError: String?
    public var workflowName: String? {
        didSet { if workflowName != oldValue { Task { await replan() } } }
    }
    public private(set) var plan: CopyPlan?
    public private(set) var planning = false
    public private(set) var planError: String?
    public private(set) var job: JobProgress?
    public private(set) var ejectError: String?
    /// Why the current job started by itself, when auto-run started it.
    public private(set) var autoRunReason: String?
    public private(set) var deletion: CardCleaner.Report?
    public private(set) var deletionError: String?
    public private(set) var deleting = false
    private var jobTask: Task<Void, Never>?
    /// Camera bodies found on the card (serial → model).
    public private(set) var bodySerials: [String: String] = [:]
    /// Why auto-run didn't start, when a rule matched but was held back.
    public private(set) var autoRunNote: String?
    /// Inserted while the app was running (cards present at launch never auto-run).
    let insertedLive: Bool
    /// Photos and videos outside DCIM, which aren't included (shown so nothing is silently missed).
    public private(set) var outsideMedia = CardScanner.OutsideMedia()
    /// Files outside DCIM (photos, videos, sidecars), offered folder by folder.
    public private(set) var outsideFiles: [SourceFile] = []
    /// Folders outside DCIM the user chose to include in this copy (not saved in the workflow).
    public private(set) var includedOutsideFolders: Set<String> = []
    /// Files the user unticked for this copy, by relative path. Survives a refresh.
    public private(set) var excludedFiles: Set<String> = []
    public private(set) var lastScanned: Date?
    /// The card changed while a copy was running; rescan when it finishes.
    public private(set) var changedDuringCopy = false
    private var watchTask: Task<Void, Never>?
    /// The volume went away (ejected or pulled).
    public internal(set) var removed = false

    private let library: WorkflowLibrary
    let ledger: Ledger?
    private let onJobFinished: @MainActor () -> Void

    init(volume: VolumeInfo, root: URL, library: WorkflowLibrary, ledger: Ledger?, insertedLive: Bool = false,
         onJobFinished: @escaping @MainActor () -> Void) {
        self.ledger = ledger
        self.insertedLive = insertedLive
        id = volume.id
        self.volume = volume
        self.root = root
        self.library = library
        self.onJobFinished = onJobFinished
        hardwareID = CardIdentity.hardwareID(forMountPoint: root)
        workflowName = library.workflows.first?.name
    }

    public var title: String { volume.name ?? root.lastPathComponent }
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Camera bodies seen in the plan's metadata, most items first ("SIGMA fp #91420511").
    public var cameras: [String] {
        guard let plan else { return [] }
        var counts: [String: Int] = [:]
        var seen = Set<String>()
        for e in plan.entries where seen.insert(e.itemID).inserted {
            guard let model = e.metadata.cameraModel else { continue }
            counts[model + (e.metadata.bodySerial.map { " #\($0)" } ?? ""), default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }

    func scan() async {
        await readCard()
        await autoRunIfMatched()
        if plan == nil { await replan() }
        watchForChanges()
    }

    /// Re-reads the card (files added or removed in Finder, say) and replans. Never auto-runs.
    public func refresh() async {
        guard job?.isRunning != true else { changedDuringCopy = true; return }
        changedDuringCopy = false
        await readCard()
        await replan()
    }

    private func readCard() async {
        scanning = true
        scanError = nil
        let root = root
        do {
            let (found, outside, outsideFound) = try await Task.detached {
                (try CardScanner().scan(root), CardScanner().mediaOutsideRoots(root), CardScanner().scanOutsideRoots(root))
            }.value
            files = found
            outsideMedia = outside
            outsideFiles = outsideFound
        } catch {
            scanError = error.localizedDescription
        }
        scanning = false
        lastScanned = .now
        bodySerials = await CameraDetector.bodySerials(in: files)
    }

    /// Rescans by itself when the card's contents change.
    private func watchForChanges() {
        guard watchTask == nil else { return }
        let root = root
        watchTask = Task { [weak self] in
            for await _ in FolderWatcher.changes(of: root) {
                guard let self, !self.removed else { return }
                await self.refresh()
            }
        }
    }

    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
    }

    /// Starts a workflow by itself if exactly one auto-run rule matches this card.
    private func autoRunIfMatched() async {
        guard insertedLive else { return }
        switch AutoRunMatcher.decide(workflows: library.workflows, cardKey: hardwareID?.key, bodySerials: bodySerials) {
        case .none:
            return
        case .held(let reason):
            autoRunNote = "Not started automatically: \(reason)."
        case let .run(name, reason):
            workflowName = name
            await replan()
            if canImport {
                startImport(autoRunReason: "Started automatically: \(reason).")
            } else {
                autoRunNote = plan?.alreadyCopied.isEmpty == false && plan?.entries.isEmpty == true
                    ? "“\(name)” matched, but everything on this card is already copied."
                    : "“\(name)” matched, but its plan can't run; check the issues below."
            }
        }
    }

    public func replan() async {
        guard !scanning, job?.isRunning != true else { return }
        plan = nil
        planError = nil
        guard let workflow = library.workflow(named: workflowName) else { return }
        planning = true
        defer { planning = false }
        do {
            let planner = try Planner(workflow)
            plan = await planner.plan(filesToPlan, cardLabel: title, ledger: ledger)
        } catch {
            planError = "\(error)"
        }
    }

    /// What the plan is made from: DCIM files and the included outside folders, minus unticked files.
    var filesToPlan: [SourceFile] {
        let outside = outsideFiles.filter { includedOutsideFolders.contains(CardFileList.folderKey(of: $0)) }
        return (files + outside).filter { !excludedFiles.contains($0.relativePath) }
    }

    /// Ticks or unticks one file for this copy.
    public func setIncluded(_ included: Bool, file: SourceFile) {
        if included { excludedFiles.remove(file.relativePath) } else { excludedFiles.insert(file.relativePath) }
        Task { await replan() }
    }

    /// Ticks or unticks every file in a folder. For a folder outside DCIM this also opts it in or out.
    public func setIncluded(_ included: Bool, folder: CardFileList.Folder) {
        if folder.isOutsideDCIM {
            if included { includedOutsideFolders.insert(folder.id) } else { includedOutsideFolders.remove(folder.id) }
        }
        for row in folder.rows {
            if included { excludedFiles.remove(row.file.relativePath) } else if !folder.isOutsideDCIM { excludedFiles.insert(row.file.relativePath) }
        }
        Task { await replan() }
    }

    /// The card's files grouped for the list, with what will happen to each.
    public var fileList: CardFileList {
        CardFileList(files: files, outside: outsideFiles, plan: plan, excluded: excludedFiles, includedOutside: includedOutsideFolders)
    }

    public var canImport: Bool { plan?.canRun == true && job?.isRunning != true && !removed }

    public func startImport(runner: any CopyRunner = CopyRunners.preferred(), autoRunReason: String? = nil) {
        guard canImport, let plan else { return }
        let source = JobSource(root: root, volumeLabel: volume.name, volumeUUID: volume.volumeUUID, cardKey: hardwareID?.key)
        let progress = JobProgress(job: plan.job(source: source), runnerName: runner.name)
        let after = plan.workflow.afterCopy
        job = progress
        self.autoRunReason = autoRunReason
        deletion = nil
        deletionError = nil
        jobTask = Task {
            for await event in runner.run(progress.job) { progress.apply(event) }
            if Task.isCancelled { progress.markCancelled() }
            onJobFinished()
            if changedDuringCopy { await refresh() } else { await replan() }   // what's left to copy now
            await afterCopy(progress, after)
        }
    }

    /// Stops the copy. Files already finished stay copied and verified; the rest are not copied.
    public func cancelImport() {
        jobTask?.cancel()
    }

    private func afterCopy(_ progress: JobProgress, _ after: Workflow.AfterCopy) async {
        let ok = progress.summary?.allSucceeded == true
        if after.notify { Notifier.post(for: progress, card: title) }
        if ok && after.eject { await eject() }
    }

    /// True when "Delete from card" may be offered: the last job verified every file everywhere.
    public var canDeleteFromCard: Bool {
        job?.summary?.allSucceeded == true && deletion == nil && !removed && !deleting
    }

    /// Deletes the last job's verified source files from the card. Call only after confirmation.
    public func deleteFromCard() async {
        guard canDeleteFromCard, let job, let summary = job.summary else { return }
        deleting = true
        defer { deleting = false }
        let root = root, id = job.job.id, ledger = ledger
        do {
            deletion = try await Task.detached {
                try CardCleaner.deleteVerifiedSources(of: summary, cardRoot: root, jobID: id, ledger: ledger)
            }.value
            files = (try? CardScanner().scan(root)) ?? files
        } catch {
            deletionError = "\(error)"
        }
    }

    public func eject() async {
        ejectError = nil
        do { try await VolumeMonitor.eject(mountPoint: root) } catch { ejectError = "\(error)" }
    }
}
