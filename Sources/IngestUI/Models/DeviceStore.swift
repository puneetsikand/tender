import Foundation
import Observation
import PhotoFerryCore

/// Cards and cameras as they come and go.
@Observable @MainActor
public final class DeviceStore {
    public private(set) var cards: [CardSession] = []
    public private(set) var cameras: [CameraInfo] = []
    public let library: WorkflowLibrary
    public let history: HistoryStore
    private var started = false
    /// Volumes mounted before the app started watching; they never auto-run.
    private var presentAtLaunch: Set<String> = []

    public init(library: WorkflowLibrary = WorkflowLibrary(), history: HistoryStore = HistoryStore()) {
        self.library = library
        self.history = history
    }

    public func start() {
        guard !started else { return }
        started = true
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        presentAtLaunch = Set(mounted.map(\.standardizedFileURL.path))
        Task { for await e in VolumeMonitor.events() { handle(e) } }
        Task {
            for await e in CameraMonitor.events() {
                switch e {
                case .connected(let c): if !cameras.contains(where: { $0.id == c.id }) { cameras.append(c) }
                case .disconnected(let id): cameras.removeAll { $0.id == id }
                }
            }
        }
    }

    private func handle(_ event: VolumeEvent) {
        switch event {
        case .mounted(let v):
            guard !v.isNetwork, let root = v.mountPoint, !cards.contains(where: { $0.id == v.id }),
                  CardScanner().looksLikeCard(root) else { return }
            let live = !presentAtLaunch.contains(root.standardizedFileURL.path)
            let session = CardSession(volume: v, root: root, library: library, ledger: history.ledger, insertedLive: live) { [weak self] in
                self?.history.reload()
            }
            cards.append(session)
            Task { await session.scan() }
        case .unmounted(let id):
            guard let session = cards.first(where: { $0.id == id }) else { return }
            presentAtLaunch.remove(session.root.standardizedFileURL.path)   // a re-insert is a live insert
            if session.job?.isRunning == true {
                session.removed = true      // keep it on screen: the job will report what didn't copy
            } else {
                cards.removeAll { $0.id == id }
            }
        }
    }

    /// For previews and snapshots.
    func insert(_ session: CardSession) { cards.append(session) }
}

/// Recent jobs from the ledger.
@Observable @MainActor
public final class HistoryStore {
    public private(set) var jobs: [JobRecord] = []
    public private(set) var error: String?
    let ledger: Ledger?

    public init(ledger: Ledger? = try? Ledger()) {
        self.ledger = ledger
        if ledger == nil { error = "History database unavailable" }
        reload()
    }

    public func reload() {
        guard let ledger else { return }
        do { jobs = try ledger.recentJobs(limit: 200) } catch { self.error = "\(error)" }
    }
}
