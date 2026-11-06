import Foundation

// Redaction: a product's rules (GET /api/v1/product's `redact`) applied to what the user sends, before it
// leaves the device. The service applies them again as it comes in (internal/desk/redact.go): the same
// paths, the same strategies, the same results (docs/redact-vectors.json holds every client to it), and
// each idempotent, so twice is as once.

/// A rule, as GET /api/v1/product lists it.
public struct RedactRule: Codable, Sendable, Equatable {
    /// /telemetry/… (a JSON pointer; * is every key or element), /context/<field>, or /note.
    public var path: String
    /// drop, mask, truncate, round, coarsen, regex, hash (the service's only), or client:<name>.
    public var strategy: String
    /// The service applies it alone (hash: its secret isn't the client's): skipped here.
    public var serverOnly: Bool?
    public var keep: Int?
    public var max: Int?
    public var step: Double?
    public var digits: Int?
    public var pattern: String?
    public var replace: String?

    public init(path: String, strategy: String, keep: Int? = nil, max: Int? = nil, step: Double? = nil,
                digits: Int? = nil, pattern: String? = nil, replace: String? = nil) {
        self.path = path; self.strategy = strategy; self.keep = keep; self.max = max; self.step = step
        self.digits = digits; self.pattern = pattern; self.replace = replace
    }
    enum CodingKeys: String, CodingKey { case path, strategy, serverOnly = "server_only", keep, max, step, digits, pattern, replace }
}

/// What a rule applies to: a report's (or a reply's) text, context and telemetry.
public struct Redactable: Sendable, Equatable {
    public var note: String?
    public var context: JSONObject?
    public var telemetry: JSONObject?
    public init(note: String? = nil, context: JSONObject? = nil, telemetry: JSONObject? = nil) {
        self.note = note; self.context = context; self.telemetry = telemetry
    }
}

/// An app's own strategy (`client:<name>`): the value redacted, or nil to drop it.
public typealias Redactor = @Sendable (JSON, RedactRule) -> JSON?

private final class Redactors: @unchecked Sendable {
    private let lock = NSLock()
    private var byName: [String: Redactor] = [:]
    func set(_ name: String, _ f: Redactor?) { lock.lock(); byName[name] = f; lock.unlock() }
    func get(_ name: String) -> Redactor? { lock.lock(); defer { lock.unlock() }; return byName[name] }
}
private let redactors = Redactors()

/// The app's own strategy, for the product's rules naming `client:<name>` (nil: unregistered).
public func registerRedactor(_ name: String, _ f: Redactor?) {
    redactors.set(name.hasPrefix("client:") ? String(name.dropFirst(7)) : name, f)
}

private enum Out { case value(JSON), drop }
private let maskChar = "•"

private func strategy(_ r: RedactRule) -> ((JSON) -> Out)? {
    if r.serverOnly == true || r.strategy == "hash" { return nil }
    if r.strategy.hasPrefix("client:") {
        guard let f = redactors.get(String(r.strategy.dropFirst(7))) else { return nil }
        return { v in f(v, r).map(Out.value) ?? .drop }
    }
    switch r.strategy {
    case "drop": return { _ in .drop }
    case "mask":
        return { v in
            guard let s = leafString(v) else { return .value(v) }
            var rest = Substring(s)
            while rest.hasPrefix(maskChar) { rest = rest.dropFirst() }
            let runes = Array(rest.unicodeScalars)
            let keep = min(r.keep ?? 0, runes.count)
            var out = String(repeating: maskChar, count: 4)
            out.unicodeScalars.append(contentsOf: runes.suffix(keep))
            return .value(.string(out))
        }
    case "truncate":
        return { v in
            guard case .string(let s) = v else { return .value(v) }
            let runes = Array(s.unicodeScalars), n = r.max ?? 0
            guard runes.count > n else { return .value(v) }
            var out = ""
            out.unicodeScalars.append(contentsOf: runes.prefix(n))
            return .value(.string(out))
        }
    case "round":
        return { v in
            guard case .number(let n) = v, let step = r.step, step > 0 else { return .value(v) }
            let p = pow(10, Double(decimals(step)))
            return .value(.number((goRound(n / step) * step * p).rounded() / p))
        }
    case "coarsen":
        return { v in
            let p = pow(10, Double(r.digits ?? 0))
            let c = { (n: Double) in goRound(n * p) / p }
            switch v {
            case .number(let n): return .value(.number(c(n)))
            case .object(var o):
                for k in ["lat", "lon"] { if case .number(let n)? = o[k] { o[k] = .number(c(n)) } }
                return .value(.object(o))
            default: return .value(v)
            }
        }
    case "regex":
        return { v in
            guard let re = try? NSRegularExpression(pattern: r.pattern ?? "") else { return .value(v) }
            let with = (r.replace?.isEmpty ?? true) ? "[redacted]" : r.replace!
            return .value(replaceIn(v, re, NSRegularExpression.escapedTemplate(for: with)))
        }
    default: return nil
    }
}

/// A path's segments, its root first (telemetry, context or note); nil: not a path a rule may have.
public func parsePath(_ p: String) -> [String]? {
    guard p.hasPrefix("/") else { return nil }
    let segs = p.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        .map { $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }
    switch segs.first {
    case "note" where segs.count == 1: return segs
    case "telemetry": return segs
    case "context" where segs.count >= 2: return segs
    default: return nil
    }
}

/// The rules applied, in their order (an emptied context or telemetry is left out).
public func redact(_ rules: [RedactRule], _ input: Redactable) -> Redactable {
    var note = input.note, context = input.context, telemetry = input.telemetry
    for r in rules {
        guard let f = strategy(r), let segs = parsePath(r.path) else { continue }
        switch segs[0] {
        case "note":
            if let n = note, case .value(let v) = f(.string(n)) { note = v.string ?? "" }
        case "context": context = redactRoot(context, Array(segs.dropFirst()), f)
        default: telemetry = redactRoot(telemetry, Array(segs.dropFirst()), f)
        }
    }
    return Redactable(note: note, context: context?.isEmpty == false ? context : nil,
                      telemetry: telemetry?.isEmpty == false ? telemetry : nil)
}

/// What's left once the user took these paths out (/telemetry/… or /context/<field>).
public func removePaths(_ input: Redactable, _ paths: [String]) -> Redactable {
    redact(paths.map { RedactRule(path: $0, strategy: "drop") }, input)
}

/// Of these paths, those with something there (a * matches if any does).
public func presentPaths(_ input: Redactable, _ paths: [String]) -> [String] {
    paths.filter { p in
        guard let segs = parsePath(p), segs[0] != "note" else { return false }
        guard let root = segs[0] == "context" ? input.context : input.telemetry else { return false }
        return present(.object(root), Array(segs.dropFirst()))
    }
}

private func present(_ v: JSON, _ segs: [String]) -> Bool {
    guard let s = segs.first else { return true }
    let rest = Array(segs.dropFirst())
    switch v {
    case .array(let a):
        return a.enumerated().contains { i, x in (s == "*" || s == String(i)) && x != .null && present(x, rest) }
    case .object(let o):
        return o.contains { k, x in (s == "*" || s == k) && present(x, rest) }
    default: return false
    }
}

private func redactRoot(_ m: JSONObject?, _ segs: [String], _ f: (JSON) -> Out) -> JSONObject? {
    guard let m else { return nil }
    if segs.isEmpty || segs == [""] {
        switch f(.object(m)) {
        case .drop: return nil
        case .value(let v): return v.object ?? m
        }
    }
    guard case .value(.object(let out)) = redactAt(.object(m), segs, f) else { return m }
    return out.isEmpty ? nil : out
}

private func redactAt(_ v: JSON, _ segs: [String], _ f: (JSON) -> Out) -> Out {
    guard let s = segs.first else { return f(v) }
    let rest = Array(segs.dropFirst())
    switch v {
    case .array(let a):
        // dropped: gone under *, null at an index (so a second pass drops nothing more)
        var out: [JSON] = []
        for (i, x) in a.enumerated() {
            if s == "*" {
                if case .value(let nv) = redactAt(x, rest, f) { out.append(nv) }
            } else if s == String(i) {
                if case .value(let nv) = redactAt(x, rest, f) { out.append(nv) } else { out.append(.null) }
            } else { out.append(x) }
        }
        return .value(.array(out))
    case .object(var o):
        for k in o.keys.sorted() where s == "*" || s == k {
            switch redactAt(o[k]!, rest, f) {
            case .drop: o.removeValue(forKey: k)
            case .value(let nv): o[k] = nv
            }
        }
        return .value(.object(o))
    default: return .value(v)
    }
}

// --- as Go does it ---

/// Go's math.Round: halves away from zero.
private func goRound(_ n: Double) -> Double { n.rounded(.toNearestOrAwayFromZero) }

/// The decimals of a step written as short as it goes (0.01: 2).
private func decimals(_ step: Double) -> Int {
    let s = "\(step)"
    if let e = s.range(of: "e-") {
        let mant = s[..<e.lowerBound]
        return (Int(s[e.upperBound...]) ?? 0) + (mant.split(separator: ".").dropFirst().first?.count ?? 0)
    }
    guard let dot = s.firstIndex(of: ".") else { return 0 }
    let frac = s[s.index(after: dot)...]
    return frac == "0" ? 0 : frac.count
}

/// A number as JavaScript and Go's %v write it (60, not 60.0).
func numberText(_ n: Double) -> String {
    if n.rounded() == n, abs(n) < 1e15 { return String(Int64(n)) }
    return "\(n)"
}

private func leafString(_ v: JSON) -> String? {
    switch v {
    case .string(let s): return s
    case .number(let n): return numberText(n)
    case .bool(let b): return b ? "true" : "false"
    default: return nil
    }
}

private func replaceIn(_ v: JSON, _ re: NSRegularExpression, _ template: String) -> JSON {
    switch v {
    case .string(let s):
        return .string(re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template))
    case .array(let a): return .array(a.map { replaceIn($0, re, template) })
    case .object(let o): return .object(o.mapValues { replaceIn($0, re, template) })
    default: return v
    }
}
