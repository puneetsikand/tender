import Foundation
import Observation
import PhotoFerryCore

/// A workflow being edited: the working copy, what's selected in the editor, validation, and a
/// live preview against an inserted card.
@Observable @MainActor
public final class WorkflowDraft {
    public enum Selection: Hashable {
        case settings
        case route(String)
        case destination(String)
    }

    public var workflow: Workflow {
        didSet { if workflow != oldValue { changed() } }
    }
    public private(set) var saved: Workflow
    public var selection: Selection
    public private(set) var problems: [String] = []
    public private(set) var preview: CopyPlan?
    public private(set) var previewing = false
    /// The card the preview runs against.
    public private(set) weak var previewSource: CardSession?
    private var previewTask: Task<Void, Never>?

    init(saved: Workflow) {
        self.saved = saved
        workflow = saved
        selection = saved.routes.first.map { .route($0.id) } ?? .settings
        validate()
    }

    public var savedName: String { saved.name }
    public var isDirty: Bool { workflow != saved }
    public var canSave: Bool { isDirty && problems.isEmpty }

    func markSaved() { saved = workflow }

    public func revert() {
        workflow = saved
        if case .route(let id) = selection, !workflow.routes.contains(where: { $0.id == id }) { selection = .settings }
        if case .destination(let id) = selection, !workflow.destinations.contains(where: { $0.id == id }) { selection = .settings }
    }

    // MARK: Routes

    public func route(_ id: String) -> Workflow.Route? { workflow.routes.first { $0.id == id } }

    public func updateRoute(_ id: String, _ edit: (inout Workflow.Route) -> Void) {
        guard let i = workflow.routes.firstIndex(where: { $0.id == id }) else { return }
        edit(&workflow.routes[i])
    }

    @discardableResult
    public func addRoute() -> String {
        let id = Self.uniqueID("route", taken: workflow.routes.map(\.id))
        workflow.routes.append(.init(id: id, name: "New route", match: .init(), folder: "{date:yyyy-MM-dd}",
                                     destinations: workflow.destinations.first.map { [$0.id] } ?? []))
        selection = .route(id)
        return id
    }

    public func removeRoute(_ id: String) {
        workflow.routes.removeAll { $0.id == id }
        if selection == .route(id) { selection = workflow.routes.first.map { .route($0.id) } ?? .settings }
    }

    /// Moves a route earlier (−1) or later (+1). Order matters: the first match wins.
    public func moveRoute(_ id: String, by delta: Int) {
        guard let i = workflow.routes.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard workflow.routes.indices.contains(j) else { return }
        workflow.routes.swapAt(i, j)
    }

    // MARK: Destinations

    public func destination(_ id: String) -> Workflow.Destination? { workflow.destinations.first { $0.id == id } }

    public func updateDestination(_ id: String, _ edit: (inout Workflow.Destination) -> Void) {
        guard let i = workflow.destinations.firstIndex(where: { $0.id == id }) else { return }
        edit(&workflow.destinations[i])
    }

    @discardableResult
    public func addDestination(root: String = "") -> String {
        let id = Self.uniqueID("destination", taken: workflow.destinations.map(\.id))
        workflow.destinations.append(.init(id: id, name: "New destination", root: root))
        selection = .destination(id)
        return id
    }

    /// Removes a destination and every route's reference to it.
    public func removeDestination(_ id: String) {
        workflow.destinations.removeAll { $0.id == id }
        for i in workflow.routes.indices { workflow.routes[i].destinations.removeAll { $0 == id } }
        if selection == .destination(id) { selection = .settings }
    }

    static func uniqueID(_ base: String, taken: [String]) -> String {
        var id = base
        var n = 2
        while taken.contains(id) { id = "\(base)-\(n)"; n += 1 }
        return id
    }

    // MARK: Validation and preview

    public func setPreviewSource(_ card: CardSession?) {
        guard card !== previewSource else { return }
        previewSource = card
        schedulePreview(delay: .zero)
    }

    /// The planned path of the first file each route takes on the preview card.
    public func example(forRoute id: String) -> String? {
        preview?.entries.first { $0.routeID == id }?.relativePath
    }

    public func count(forRoute id: String) -> Int {
        preview?.entries.count { $0.routeID == id } ?? 0
    }

    private func changed() {
        validate()
        schedulePreview(delay: .milliseconds(300))
    }

    private func validate() {
        do {
            try Planner.validate(workflow)
            problems = []
        } catch WorkflowError.invalid(let p) {
            problems = p
        } catch {
            problems = ["\(error)"]
        }
    }

    private func schedulePreview(delay: Duration) {
        previewTask?.cancel()
        guard let card = previewSource, problems.isEmpty, let planner = try? Planner(workflow) else {
            preview = nil
            return
        }
        let files = card.files
        let label = card.title
        previewTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            previewing = true
            let plan = await planner.plan(files, cardLabel: label)
            guard !Task.isCancelled else { return }
            preview = plan
            previewing = false
        }
    }
}
