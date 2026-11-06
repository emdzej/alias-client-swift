import CryptoKit
import Foundation

/// Server-Sent Events, a byte at a time: the events each blank line ends.
public struct SSEParser: Sendable {
    public struct Event: Sendable, Equatable { public let event: String; public let data: String }
    private var line = [UInt8]()
    private var event = "message"
    private var data = [String]()

    public init() {}

    public mutating func feed(_ b: UInt8) -> [Event] {
        guard b == 0x0A else {
            if b != 0x0D { line.append(b) }
            return []
        }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty { // (the blank line: the event's end)
            defer { event = "message"; data.removeAll() }
            return data.isEmpty ? [] : [Event(event: event, data: data.joined(separator: "\n"))]
        }
        let s = String(decoding: line, as: UTF8.self)
        if s.hasPrefix("event:") { event = s.dropFirst(6).trimmingCharacters(in: .whitespaces) }
        else if s.hasPrefix("data:") { var d = s.dropFirst(5); if d.first == " " { d = d.dropFirst() }; data.append(String(d)) }
        return []
    }

    public mutating func feed<S: Sequence>(_ bytes: S) -> [Event] where S.Element == UInt8 { bytes.flatMap { feed($0) } }
}

/// The proof of work: a nonce such that SHA-256(challenge + ":" + nonce) begins with `bits` zero bits
/// (2^bits hashes on average).
public func solveWork(_ challenge: String, bits: Int) -> String {
    for n in 0... {
        let sum = SHA256.hash(data: Data((challenge + ":" + String(n)).utf8))
        var zeros = 0
        for byte in sum {
            if byte == 0 { zeros += 8; continue }
            zeros += byte.leadingZeroBitCount
            break
        }
        if zeros >= bits { return String(n) }
    }
    fatalError("unreachable")
}

/// The attachments a note's markdown shows (`![…](attachment:name)` and `[…](attachment:name)`), each once.
public func attachmentRefs(_ markdown: String) -> [String] {
    let re = try! NSRegularExpression(pattern: #"\]\(attachment:([A-Za-z0-9._-]+)\)"#)
    var out: [String] = []
    for m in re.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)) {
        if let r = Range(m.range(at: 1), in: markdown), !out.contains(String(markdown[r])) { out.append(String(markdown[r])) }
    }
    return out
}
