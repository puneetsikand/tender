import Foundation

enum Fmt {
    static func bytes(_ n: Int64) -> String { n.formatted(.byteCount(style: .file)) }

    static func rate(_ bytesPerSecond: Double) -> String {
        Int64(bytesPerSecond).formatted(.byteCount(style: .file)) + "/s"
    }

    static func remaining(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s left" }
        return "\(s / 60) min \(s % 60) s left"
    }

    static func duration(_ d: Duration) -> String {
        let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return s < 60 ? String(format: "%.1f s", s) : "\(Int(s) / 60) min \(Int(s) % 60) s"
    }
}
