import Foundation

/// A naming template: literal text plus `{token}`, `{token:arg}` and `{token|fallback}` parts.
/// `{{` and `}}` are literal braces. Parsed when a workflow is validated, so a typo is
/// reported before anything is copied.
public struct Template: Sendable, Hashable {
    public enum Part: Sendable, Hashable {
        case literal(String)
        case token(Token, arg: String?, fallback: String?)
    }

    public enum Token: String, Sendable, CaseIterable {
        case date, time, year, month, day, hour, minute, second
        case camera, make, serial, lens
        case orig, ext, EXT, kind, KIND
        case seq, card, workflow

        public var help: String {
            switch self {
            case .date: "capture date; optional pattern, default yyyy-MM-dd (e.g. {date:yyyyMMdd})"
            case .time: "capture time; optional pattern, default HHmmss"
            case .year, .month, .day, .hour, .minute, .second: "one capture date/time field, zero-padded"
            case .camera: "camera model (e.g. SIGMA fp)"
            case .make: "camera maker"
            case .serial: "camera body serial number"
            case .lens: "lens model"
            case .orig: "original file name without extension"
            case .ext: "original extension, lowercase"
            case .EXT: "original extension, uppercase"
            case .kind: "file type: raw, jpeg, heif, tiff, video, sidecar, other"
            case .KIND: "file type in capitals: RAW, JPEG …"
            case .seq: "item number within the job; optional width, default 4 (e.g. {seq:3})"
            case .card: "source volume name"
            case .workflow: "workflow name"
            }
        }
    }

    public let source: String
    public let parts: [Part]

    public struct ParseError: Error, Hashable, CustomStringConvertible {
        public let template: String
        public let message: String
        public var description: String { "\(message) in \"\(template)\"" }
    }

    public init(_ source: String) throws {
        self.source = source
        var parts: [Part] = []
        var literal = ""
        var i = source.startIndex
        func error(_ m: String) -> ParseError { ParseError(template: source, message: m) }

        while i < source.endIndex {
            let c = source[i]
            let next = source.index(after: i)
            if c == "{", next < source.endIndex, source[next] == "{" { literal.append("{"); i = source.index(after: next); continue }
            if c == "}", next < source.endIndex, source[next] == "}" { literal.append("}"); i = source.index(after: next); continue }
            if c == "}" { throw error("unmatched }") }
            if c != "{" { literal.append(c); i = next; continue }

            guard let close = source[next...].firstIndex(of: "}") else { throw error("unclosed {") }
            let body = String(source[next..<close])
            if body.contains("{") { throw error("{ inside a token") }
            var spec = Substring(body)
            var fallback: String?
            if let bar = spec.firstIndex(of: "|") { fallback = String(spec[spec.index(after: bar)...]); spec = spec[..<bar] }
            var arg: String?
            if let colon = spec.firstIndex(of: ":") { arg = String(spec[spec.index(after: colon)...]); spec = spec[..<colon] }
            guard let token = Token(rawValue: String(spec)) else {
                throw error(spec.isEmpty ? "empty token {}" : "unknown token {\(spec)}")
            }
            if let arg, arg.isEmpty { throw error("empty argument in {\(body)}") }
            if token == .seq, let arg, Int(arg).map({ !(1...9).contains($0) }) ?? true {
                throw error("{seq:\(arg)}: width must be 1–9")
            }
            if arg != nil, ![.date, .time, .seq].contains(token) { throw error("{\(token.rawValue)} takes no argument") }
            if !literal.isEmpty { parts.append(.literal(literal)); literal = "" }
            parts.append(.token(token, arg: arg, fallback: fallback))
            i = source.index(after: close)
        }
        if !literal.isEmpty { parts.append(.literal(literal)) }
        self.parts = parts
    }

    /// Values for one file. Missing values fall back to the token's `|fallback`, else "unknown".
    struct Context {
        var file: SourceFile
        var meta: CaptureMetadata
        /// Capture date, or the file's date when the file has none.
        var date: Date?
        var sequence: Int
        var cardLabel: String?
        var workflowName: String
        var formatters: DateFormatters
    }

    func render(_ c: Context) -> String {
        parts.map { part -> String in
            switch part {
            case .literal(let s): return s
            case let .token(token, arg, fallback):
                let value = Self.value(token, arg, c).flatMap { Self.sanitize($0) }
                return value ?? fallback.flatMap { Self.sanitize($0) } ?? "unknown"
            }
        }.joined()
    }

    private static func value(_ t: Token, _ arg: String?, _ c: Context) -> String? {
        // Local time where the photo was taken when the file says; otherwise the workflow's zone.
        let zone = c.meta.captureUTCOffsetSeconds.flatMap(TimeZone.init(secondsFromGMT:)) ?? c.formatters.defaultZone
        func date(_ pattern: String) -> String? { c.date.map { c.formatters.string($0, pattern, in: zone) } }
        switch t {
        case .date: return date(arg ?? "yyyy-MM-dd")
        case .time: return date(arg ?? "HHmmss")
        case .year: return date("yyyy")
        case .month: return date("MM")
        case .day: return date("dd")
        case .hour: return date("HH")
        case .minute: return date("mm")
        case .second: return date("ss")
        case .camera: return c.meta.cameraModel
        case .make: return c.meta.cameraMake
        case .serial: return c.meta.bodySerial
        case .lens: return c.meta.lensModel
        case .orig: return c.file.stem
        case .ext: return c.file.url.pathExtension.lowercased()
        case .EXT: return c.file.url.pathExtension.uppercased()
        case .kind: return c.file.kind.rawValue
        case .KIND: return c.file.kind.rawValue.uppercased()
        case .seq:
            let width = arg.flatMap(Int.init) ?? 4
            let digits = String(c.sequence)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        case .card: return c.cardLabel
        case .workflow: return c.workflowName
        }
    }

    /// Makes a token's value safe as (part of) one path component: no separators, no
    /// control characters, no leading dot (which would hide the file).
    static func sanitize(_ s: String) -> String? {
        var out = String(s.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" || CharacterSet.controlCharacters.contains(scalar) { return "-" }
            return Character(scalar)
        }).trimmingCharacters(in: .whitespaces)
        while out.hasPrefix(".") { out.removeFirst() }
        return out.isEmpty ? nil : out
    }
}

/// Caches one DateFormatter per pattern for a planning run. DateFormatter is the only
/// Foundation API that formats from a runtime pattern string.
final class DateFormatters {
    let defaultZone: TimeZone
    private var cache: [String: DateFormatter] = [:]

    init(defaultZone: TimeZone) {
        self.defaultZone = defaultZone
    }

    func string(_ date: Date, _ pattern: String, in zone: TimeZone) -> String {
        let key = "\(zone.secondsFromGMT(for: date))|\(zone.identifier)|\(pattern)"
        let f = cache[key] ?? {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = Calendar(identifier: .gregorian)
            f.timeZone = zone
            f.dateFormat = pattern
            cache[key] = f
            return f
        }()
        return f.string(from: date)
    }
}
