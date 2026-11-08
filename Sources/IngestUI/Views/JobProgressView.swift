import PhotoFerryCore
import SwiftUI

struct JobProgressView: View {
    let job: JobProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                status
                ProgressView(value: job.fraction)
                Text(detail).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                ForEach(job.notices.filter { !$0.hasPrefix("manifest:") }, id: \.self) { n in
                    Label(n, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            Divider()
            Table(job.rows) {
                TableColumn("") { r in stateIcon(r.state) }.width(22)
                TableColumn("File") { r in Text(r.request.source.fileName) }.width(min: 120, ideal: 160)
                TableColumn("Status") { r in stateText(r) }
                TableColumn("Size") { r in Text(Fmt.bytes(r.request.source.size)).monospacedDigit() }.width(min: 60, ideal: 80)
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let reason = job.interruption {
            Label("Copy interrupted: \(reason)", systemImage: "exclamationmark.octagon.fill")
                .font(.headline).foregroundStyle(.red)
        } else if let s = job.summary {
            if s.allSucceeded {
                Label("All \(s.results.count) files copied and verified", systemImage: "checkmark.seal.fill")
                    .font(.headline).foregroundStyle(.green)
            } else {
                Label("\(s.failed.count) of \(s.results.count) files failed. The rest are copied and verified.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange)
            }
        } else {
            Label("Copying with \(job.job.workflowName ?? "workflow")", systemImage: "doc.on.doc")
                .font(.headline)
        }
    }

    private var detail: String {
        var parts = ["\(job.filesDone) of \(job.rows.count) files", "\(Fmt.bytes(job.bytesDone)) of \(Fmt.bytes(job.totalBytes))"]
        if job.throughput > 0 { parts.append(Fmt.rate(job.throughput)) }
        if let left = job.secondsRemaining { parts.append(Fmt.remaining(left)) }
        if let s = job.summary { parts.append("took \(Fmt.duration(s.elapsed))") }
        if job.filesFailed > 0 { parts.append("\(job.filesFailed) failed") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func stateIcon(_ s: JobProgress.FileState) -> some View {
        switch s {
        case .queued: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .copying: ProgressView().controlSize(.mini)
        case .verifying: Image(systemName: "magnifyingglass").foregroundStyle(.blue)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder private func stateText(_ r: JobProgress.Row) -> some View {
        switch r.state {
        case .queued: Text("Waiting").foregroundStyle(.secondary)
        case .copying(let b):
            Text("Copying \(r.request.source.size > 0 ? Int(Double(b) / Double(r.request.source.size) * 100) : 0)%").monospacedDigit()
        case .verifying: Text("Verifying")
        case .done(let v): Text(verifiedText(v)).foregroundStyle(.secondary)
        case .failed(let reason): Text(reason).foregroundStyle(.red).lineLimit(2)
        }
    }

    private func verifiedText(_ v: DestinationVerification?) -> String {
        guard let v else { return "Copied" }
        switch v.path {
        case .device: return "Verified (\(v.mode.rawValue), read from disk)"
        case .server: return "Verified (\(v.mode.rawValue), read through the server)"
        case .possiblyCached: return "Verified (\(v.mode.rawValue), may have read from memory)"
        case .notRead: return "Size checked only"
        }
    }
}
