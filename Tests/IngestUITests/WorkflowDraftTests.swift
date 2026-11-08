import Foundation
import Testing
@testable import IngestUI
@testable import PhotoFerryCore

@MainActor @Suite struct WorkflowDraftTests {
    func draft() -> WorkflowDraft { WorkflowDraft(saved: Workflow.starter()) }

    @Test func startsCleanWithTheFirstRouteSelected() {
        let d = draft()
        #expect(!d.isDirty && !d.canSave && d.problems.isEmpty)
        #expect(d.selection == .route("raw"))
    }

    @Test func addedRoutesAndDestinationsGetUniqueIDsAndAreSelected() {
        let d = draft()
        let r1 = d.addRoute(), r2 = d.addRoute()
        #expect(r1 == "route" && r2 == "route-2")
        #expect(d.selection == .route("route-2"))
        #expect(d.route(r1)?.destinations == ["library"])     // defaults to the first destination
        let dest = d.addDestination(root: "/Volumes/NAS")
        #expect(dest == "destination" && d.selection == .destination(dest))
        #expect(d.isDirty && d.canSave)
    }

    @Test func removingADestinationStripsItFromEveryRoute() {
        let d = draft()
        let nas = d.addDestination(root: "/Volumes/NAS")
        for r in d.workflow.routes { d.updateRoute(r.id) { $0.destinations.append(nas) } }
        d.removeDestination(nas)
        #expect(d.workflow.routes.allSatisfy { !$0.destinations.contains(nas) })
        #expect(d.selection == .settings)
    }

    @Test func movingRoutesStopsAtTheEnds() {
        let d = draft()
        d.moveRoute("raw", by: -1)
        #expect(d.workflow.routes.map(\.id) == ["raw", "jpeg", "video"])
        d.moveRoute("raw", by: 1)
        #expect(d.workflow.routes.map(\.id) == ["jpeg", "raw", "video"])
        d.moveRoute("video", by: 1)
        #expect(d.workflow.routes.map(\.id) == ["jpeg", "raw", "video"])
    }

    @Test func problemsAppearAsYouEditAndBlockSaving() {
        let d = draft()
        d.updateRoute("jpeg") { $0.fileName = "{nope}" }
        #expect(d.isDirty && !d.canSave)
        #expect(d.problems.contains { $0.contains("unknown token {nope}") })
        d.updateRoute("jpeg") { $0.fileName = "{orig}" }
        #expect(d.problems.isEmpty && !d.isDirty)               // back to the saved state
    }

    @Test func revertRestoresAndFixesASelectionThatNoLongerExists() {
        let d = draft()
        let r = d.addRoute()
        #expect(d.selection == .route(r))
        d.revert()
        #expect(!d.isDirty && d.selection == .settings)
    }

    @Test func libraryCommitRenamesFilesAndRekeysTheDraft() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pf-lib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let library = WorkflowLibrary(store: WorkflowStore(folder: tmp))
        let name = try library.createWorkflow()
        #expect(name == "New workflow")
        #expect(try library.createWorkflow() == "New workflow 2")

        let d = try #require(library.draft(for: name))
        d.workflow.name = "Renamed"
        #expect(try library.commit(d) == "Renamed")
        #expect(!d.isDirty && d.savedName == "Renamed")
        #expect(library.workflows.map(\.name).sorted() == ["New workflow 2", "Renamed"])
        #expect(library.draft(for: "Renamed") === d)

        try library.delete(d)
        #expect(library.workflows.map(\.name) == ["New workflow 2"])
    }
}
