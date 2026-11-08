import Foundation
import Observation
import PhotoFerryCore

/// The saved workflows, for pickers. Reloaded on demand (the folder can be edited by hand).
@Observable @MainActor
public final class WorkflowLibrary {
    public let store: WorkflowStore
    public private(set) var workflows: [Workflow] = []
    public private(set) var unreadable: [URL] = []

    public init(store: WorkflowStore = WorkflowStore()) {
        self.store = store
        reload()
    }

    public func reload() {
        let all = (try? store.list()) ?? []
        workflows = all.compactMap(\.workflow)
        unreadable = all.filter { $0.workflow == nil }.map(\.url)
    }

    public func workflow(named name: String?) -> Workflow? {
        workflows.first { $0.name == name }
    }

    public func save(_ w: Workflow) throws {
        try store.save(w)
        reload()
    }

    // MARK: Editing

    /// Open editor drafts by the workflow's saved name, so unsaved edits survive switching views.
    private var drafts: [String: WorkflowDraft] = [:]

    public func draft(for name: String) -> WorkflowDraft? {
        if let d = drafts[name] { return d }
        guard let w = workflow(named: name) else { return nil }
        let d = WorkflowDraft(saved: w)
        drafts[name] = d
        return d
    }

    /// Saves a draft (renaming its files if the name changed). Returns the saved name.
    @discardableResult
    func commit(_ draft: WorkflowDraft) throws -> String {
        let oldName = draft.savedName
        try store.save(draft.workflow, replacing: oldName)
        drafts[oldName] = nil
        drafts[draft.workflow.name] = draft
        draft.markSaved()
        reload()
        return draft.workflow.name
    }

    func delete(_ draft: WorkflowDraft) throws {
        try store.delete(draft.savedName)
        drafts[draft.savedName] = nil
        reload()
    }

    /// Creates and saves a new workflow from the starter, with a unique name.
    func createWorkflow() throws -> String {
        var name = "New workflow"
        var n = 2
        while workflows.contains(where: { $0.name == name }) { name = "New workflow \(n)"; n += 1 }
        try store.save(Workflow.starter(name: name))
        reload()
        return name
    }
}
