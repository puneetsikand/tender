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
}
