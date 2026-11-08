import PhotoFerryCore
import SwiftUI

/// "Delete from card", offered only after every file verified at every destination. Always asks.
struct CardDeletionBar: View {
    let session: CardSession
    @State private var confirming = false

    var body: some View {
        if let report = session.deletion {
            bar {
                Label("Deleted \(report.deleted.count) files from the card.", systemImage: "checkmark.circle")
                if !report.kept.isEmpty {
                    Text("\(report.kept.count) kept: \(report.kept.prefix(3).map { "\($0.path) (\($0.reason))" }.joined(separator: "; "))")
                        .foregroundStyle(.orange).lineLimit(2)
                }
            }
        } else if let error = session.deletionError {
            bar { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        } else if session.canDeleteFromCard, let job = session.job, let summary = job.summary {
            bar {
                Text("Everything is copied and verified. You can now clear these files from the card.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) { confirming = true } label: {
                    Label("Delete \(summary.results.count) Files from Card…", systemImage: "trash")
                }
                .disabled(session.deleting)
            }
            .confirmationDialog("Delete \(summary.results.count) verified files from \(session.title)?", isPresented: $confirming) {
                Button("Delete from Card", role: .destructive) { Task { await session.deleteFromCard() } }
            } message: {
                Text("Every one of these files was copied to \(destinations(job)) and verified. Each is checked again before it's deleted. This can't be undone. Files this copy didn't include stay on the card.")
            }
        }
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) { content() }
            .font(.callout)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4))
    }

    private func destinations(_ job: JobProgress) -> String {
        let names = job.job.destinationRoots.map { $0.lastPathComponent }
        return names.joined(separator: " and ")
    }
}
