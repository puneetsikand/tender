import Foundation

/// Decides whether an inserted card should start a workflow by itself (PLAN §3.2).
public enum AutoRunDecision: Sendable, Equatable {
    case none
    case run(workflow: String, reason: String)
    /// A rule matched but auto-run is held back; the reason is shown to the user.
    case held(reason: String)
}

public enum AutoRunMatcher {
    /// - cardKey: the card's hardware ID (tier H), if the reader exposes it.
    /// - bodySerials: camera body serials found on the card (tier C), serial → model.
    public static func decide(workflows: [Workflow], cardKey: String?, bodySerials: [String: String]) -> AutoRunDecision {
        let enabled = workflows.filter(\.autoRun.isEnabled)
        guard !enabled.isEmpty else { return .none }

        // Tier H: this exact card. Strongest, and fine even with several bodies on the card.
        if let cardKey {
            let byCard = enabled.filter { $0.autoRun.cardKeys.contains(cardKey) }
            if byCard.count == 1 { return .run(workflow: byCard[0].name, reason: "this card is set to run “\(byCard[0].name)”") }
            if byCard.count > 1 { return .held(reason: "\(byCard.count) workflows are set to run for this card; choose one") }
        }

        // Tier C: the camera that shot it. Only when the card holds a single body.
        let bySerial = enabled.filter { w in w.autoRun.bodySerials.contains { bodySerials[$0] != nil } }
        guard !bySerial.isEmpty else { return .none }
        if bodySerials.count > 1 {
            return .held(reason: "files from \(bodySerials.count) cameras are on this card; choose a workflow")
        }
        if bySerial.count > 1 { return .held(reason: "\(bySerial.count) workflows are set to run for this camera; choose one") }
        let (serial, model) = bodySerials.first!
        return .run(workflow: bySerial[0].name, reason: "photos from \(model) #\(serial) run “\(bySerial[0].name)”")
    }
}

/// Finds the camera bodies on a card by reading a sample of files' headers.
public enum CameraDetector {
    /// serial → model, from up to `sample` items spread across the card.
    public static func bodySerials(in files: [SourceFile], sample: Int = 12) async -> [String: String] {
        let items = ItemGrouper().group(files).filter { $0.primary.kind != .sidecar && $0.primary.kind != .other }
        guard !items.isEmpty else { return [:] }
        let step = max(1, items.count / sample)
        let reader = MetadataReader()
        var found: [String: String] = [:]
        for item in stride(from: 0, to: items.count, by: step).map({ items[$0] }) {
            let m = await reader.read(item.primary)
            if let s = m.bodySerial { found[s] = m.cameraModel ?? "camera" }
        }
        return found
    }
}
