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
        scanning = true
        let root = root
        do {
            files = try await Task.detached { try CardScanner().scan(root) }.value
        } catch {
            scanError = error.localizedDescription
        }
        scanning = false
        bodySerials = await CameraDetector.bodySerials(in: files)
        await autoRunIfMatched()
        if plan == nil { await replan() }
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
            plan = await planner.plan(files, cardLabel: title, ledger: ledger)
        } catch {
            planError = "\(error)"
        }
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
            await replan()        // what's left to copy now (usually nothing)
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
