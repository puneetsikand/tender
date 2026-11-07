import PhotoFerryCore
import SwiftUI

struct HistoryView: View {
    let history: HistoryStore

    var body: some View {
        Group {
            if history.jobs.isEmpty {
                ContentUnavailableView("No imports yet", systemImage: "clock.arrow.circlepath",
                                       description: Text(history.error ?? "Finished imports are listed here."))
            } else {
                Table(history.jobs) {
                    TableColumn("Started") { j in Text(j.startedAt.formatted(date: .abbreviated, time: .shortened)) }
                        .width(min: 130, ideal: 150)
                    TableColumn("Workflow") { j in Text(j.workflowName ?? "—") }
                    TableColumn("Card") { j in Text(j.volumeLabel ?? j.sourceRoot) }
                    TableColumn("Files") { j in Text("\(j.filesRecorded)/\(j.filesTotal)").monospacedDigit() }.width(60)
                    TableColumn("Failed") { j in
                        Text(j.filesFailed.map(String.init) ?? "—").foregroundStyle((j.filesFailed ?? 0) > 0 ? .red : .secondary)
                    }.width(50)
                    TableColumn("Size") { j in Text(j.bytesRead.map(Fmt.bytes) ?? "—").monospacedDigit() }.width(min: 60, ideal: 80)
                    TableColumn("Verify") { j in Text(j.verifyMode) }.width(60)
                    TableColumn("Status") { j in statusLabel(j.status) }.width(min: 90, ideal: 100)
                }
            }
        }
        .navigationTitle("History")
        .toolbar {
            Button { history.reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .onAppear { history.reload() }
    }

    @ViewBuilder func statusLabel(_ s: JobStatus) -> some View {
        switch s {
        case .finished: Label("Finished", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .running: Label("Running", systemImage: "arrow.triangle.2.circlepath")
        case .cancelled: Label("Cancelled", systemImage: "xmark.circle").foregroundStyle(.secondary)
        case .interrupted: Label("Interrupted", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}

extension JobRecord: Identifiable {}
