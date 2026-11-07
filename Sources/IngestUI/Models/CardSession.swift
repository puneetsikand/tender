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
    /// The volume went away (ejected or pulled).
    public internal(set) var removed = false

    private let library: WorkflowLibrary
    private let onJobFinished: @MainActor () -> Void

    init(volume: VolumeInfo, root: URL, library: WorkflowLibrary, onJobFinished: @escaping @MainActor () -> Void) {
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
        await replan()
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
            plan = await planner.plan(files, cardLabel: title)
        } catch {
            planError = "\(error)"
        }
    }

    public var canImport: Bool { plan?.canRun == true && job?.isRunning != true && !removed }

    public func startImport(runner: any CopyRunner = CopyRunners.preferred()) {
        guard canImport, let plan else { return }
        let source = JobSource(root: root, volumeLabel: volume.name, volumeUUID: volume.volumeUUID, cardKey: hardwareID?.key)
        let progress = JobProgress(job: plan.job(source: source), runnerName: runner.name)
        job = progress
        Task {
            for await event in runner.run(progress.job) { progress.apply(event) }
            onJobFinished()
        }
    }

    public func eject() async {
        ejectError = nil
        do { try await VolumeMonitor.eject(mountPoint: root) } catch { ejectError = "\(error)" }
    }
}
