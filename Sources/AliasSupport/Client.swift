import Foundation

// AliasClient: the client of ALIAS, the anonymous support desk (docs/openapi.yaml). Thin: one method a
// call, named as the spec's operationIds, the same in every client.
//
//   let alias = AliasClient(url: URL(string: "https://support.example.com")!, key: productKey,
//       store: KeychainIdentityStore(account: "road-builder"), appVersion: "2.3.1",
//       telemetry: { ["fps": 60] })
//   let t = try await alias.report("The kerb is too high", Extras(screenshot: jpeg))
//   for await u in await alias.watch() where u.kind == "answer" { notify(u.ticket) }
//
// The identity is the service's: the first call that needs one asks POST /api/v1/identity and keeps what
// it gives. The client never makes an id or a secret. What's sent is redacted first, by the product's
// rules; the service applies them again.

public actor AliasClient {
    public nonisolated let url: URL
    public nonisolated let key: String
    public nonisolated let appVersion: String?
    private let store: IdentityStore
    private let session: URLSession
    private let contextOf: (@Sendable () -> JSONObject?)?
    private let telemetryOf: (@Sendable () -> JSONObject?)?
    private let redacts: Bool
    private var pending: Task<Identity, Error>?
    private var settings: Task<Product, Error>?

    /// - context, telemetry: the product's context (its fields) and telemetry for a report, asked at each.
    /// - redact: apply the product's rules before sending (the service applies them anyway).
    public init(url: URL, key: String, store: IdentityStore = MemoryIdentityStore(), appVersion: String? = nil,
                context: (@Sendable () -> JSONObject?)? = nil, telemetry: (@Sendable () -> JSONObject?)? = nil,
                redact: Bool = true, session: URLSession = .shared) {
        self.url = url; self.key = key; self.store = store; self.appVersion = appVersion
        self.contextOf = context; self.telemetryOf = telemetry; self.redacts = redact; self.session = session
    }

    // --- the identity ---

    /// The identity, asked of the service the first time (and kept in the store). If the product asks for
    /// proof of work, it's done here first: some thousands of SHA-256s.
    public func identity() async throws -> Identity {
        if let kept = try await store.load() { return kept }
        if let p = pending { return try await p.value }
        let t = Task { () throws -> Identity in
            let id = try await self.newIdentity()
            try await self.store.save(id)
            return id
        }
        pending = t
        defer { pending = nil }
        return try await t.value
    }

    /// A new identity, from the service (the proof of work done first, if asked for). identity() keeps one.
    public func newIdentity() async throws -> Identity {
        for tries in 0... {
            let c = try await identityChallenge()
            var extra: [String: String] = [:]
            if c.bits > 0, let ch = c.challenge { extra["X-Alias-Work"] = ch + ":" + solveWork(ch, bits: c.bits) }
            do {
                return try await call("POST", "/api/v1/identity", who: .none, extra: extra)
            } catch let e as AliasError where e.status == 428 && tries == 0 {
                continue // (the challenge ran out of time, or the work asked for went up meanwhile: once more)
            }
        }
        fatalError("unreachable")
    }

    /// Forget the identity here (the next call makes a new one).
    public func forget() async throws { try await store.save(nil) }

    /// Use an identity typed in (moved by hand): checked with the service before it's kept.
    public func useIdentity(_ id: Identity) async throws -> Me {
        let me: Me = try await call("GET", "/api/v1/me", who: .this(id))
        try await store.save(id)
        return me
    }

    // --- the calls (docs/openapi.yaml's operationIds) ---

    public func getProduct() async throws -> Product { try await call("GET", "/api/v1/product", who: .none) }

    /// The product's settings, asked once and kept (refresh: again).
    public func product(refresh: Bool = false) async throws -> Product {
        if refresh || settings == nil { settings = Task { try await self.getProduct() } }
        do { return try await settings!.value } catch { settings = nil; throw error }
    }

    public func identityChallenge() async throws -> Challenge { try await call("GET", "/api/v1/identity/challenge", who: .none) }
    public func me() async throws -> Me { try await call("GET", "/api/v1/me") }

    /// Erase the id and everything of it at the service, and forget it here.
    public func eraseMe() async throws -> Erased {
        let r: Erased = try await call("DELETE", "/api/v1/me")
        try await forget()
        return r
    }

    /// The user's copy of everything kept about them.
    public func myData() async throws -> JSONObject { try await call("GET", "/api/v1/me/data") }
    public func getContact() async throws -> ContactState { try await call("GET", "/api/v1/me/contact") }

    /// Give a contact, once the user has agreed to `consent` (the product's `contactConsent`), shown to
    /// them whole. An older text than the product's now is refused (409: show the new one, ask again).
    public func setContact(kind: String, value: String, consent: ConsentText) async throws -> ContactState {
        var c: JSONObject = ["version": .string(consent.version)]
        if let v = appVersion { c["app_version"] = .string(v) }
        return try await call("PUT", "/api/v1/me/contact", json: ["kind": .string(kind), "value": .string(value), "consent": .object(c)])
    }

    public func withdrawContact() async throws -> ContactState { try await call("DELETE", "/api/v1/me/contact") }
    public func newTransfer() async throws -> Transfer { try await call("POST", "/api/v1/me/transfer") }

    /// This device takes the identity a code names (with a secret of its own), and keeps it.
    public func claimTransfer(_ code: String) async throws -> Identity {
        let id: Identity = try await call("POST", "/api/v1/transfer/claim", json: ["code": .string(code)], who: .none)
        try await store.save(id)
        return id
    }

    public func report(_ note: String, _ x: Extras = Extras(), appVersion v: String? = nil) async throws -> Ticket {
        let c = try await prepare(note, x)
        var body: JSONObject = ["note": .string(c.note ?? note)]
        if let f = x.format { body["format"] = .string(f.rawValue) }
        if let ctx = c.context { body["context"] = .object(ctx) }
        if let t = c.telemetry { body["telemetry"] = .object(t) }
        if let av = v ?? appVersion { body["app_version"] = .string(av) }
        return try await send("/api/v1/tickets", body, x)
    }

    public func tickets() async throws -> [Ticket] {
        struct L: Decodable { let tickets: [Ticket] }
        let l: L = try await call("GET", "/api/v1/tickets")
        return l.tickets
    }

    public func ticket(_ id: Int) async throws -> Ticket { try await call("GET", "/api/v1/tickets/\(id)") }

    public func reply(_ id: Int, _ text: String, _ x: Extras = Extras()) async throws -> Ticket {
        let c = try await prepare(text, x)
        var body: JSONObject = ["body": .string(c.note ?? text)]
        if let f = x.format { body["format"] = .string(f.rawValue) }
        if let ctx = c.context { body["context"] = .object(ctx) }
        if let t = c.telemetry { body["telemetry"] = .object(t) }
        return try await send("/api/v1/tickets/\(id)/comments", body, x)
    }

    /// Ask to talk live: live at once if someone's at the desk (`mode` live), else asked for (`liveRequestedAt`).
    public func requestLive(_ id: Int) async throws -> Ticket { try await call("POST", "/api/v1/tickets/\(id)/live") }
    /// The user is typing (a live ticket's): call it as they type; the service passes on one every 2 s.
    public func typing(_ id: Int) async throws { let _: Empty = try await call("POST", "/api/v1/tickets/\(id)/typing") }
    /// The user has read the thread up to now: support sees it.
    public func markRead(_ id: Int) async throws { let _: Empty = try await call("POST", "/api/v1/tickets/\(id)/read") }

    /// Remote assistance requests still going, across the user's tickets.
    public func remoteRequests() async throws -> RemoteList { try await call("GET", "/api/v1/remote") }
    public func ticketRemote(_ id: Int) async throws -> RemoteList { try await call("GET", "/api/v1/tickets/\(id)/remote") }
    /// The device's answer. Yes: `relay` is its side of the session.
    public func answerRemote(_ ticket: Int, _ id: String, accept: Bool) async throws -> RemoteRequest {
        try await call("POST", "/api/v1/tickets/\(ticket)/remote/\(esc(id))", json: ["accept": .bool(accept)])
    }
    /// The device ends the session (or takes its yes back).
    public func endRemote(_ ticket: Int, _ id: String) async throws {
        let _: Empty = try await call("DELETE", "/api/v1/tickets/\(ticket)/remote/\(esc(id))")
    }

    /// One of the user's own attachments, as kept (an image without its metadata): its bytes and type.
    public func attachment(_ ticket: Int, _ id: Int) async throws -> (data: Data, type: String) {
        let (data, res) = try await raw("GET", "/api/v1/tickets/\(ticket)/attachments/\(id)", body: nil, contentType: nil,
                                        headers: headers(try await identity()))
        return (data, res.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream")
    }

    public func updates(since: String? = nil) async throws -> Updates {
        try await call("GET", "/api/v1/updates" + (since.map { "?since=" + esc($0) } ?? ""))
    }

    /// What a report would send of the context and telemetry (the callbacks', or these), after the
    /// product's rules, with the removable paths in it: show it to the user, let them pick which to take
    /// out (`Extras.remove`).
    public func previewTelemetry(context: JSONObject? = nil, telemetry: JSONObject? = nil) async throws -> TelemetryPreview {
        let p = try await product()
        let c = redact(redacts ? p.redact ?? [] : [], Redactable(context: context ?? contextOf?(), telemetry: telemetry ?? telemetryOf?()))
        return TelemetryPreview(context: c.context, telemetry: c.telemetry, removable: presentPaths(c, p.removable ?? []))
    }

    // --- answers, live ---

    /// The raw stream (/api/v1/events): each answer, and a live ticket's events, while it's open. `watch`
    /// is the one that reconnects and polls.
    public func events() async throws -> AsyncThrowingStream<Update, Error> {
        var req = URLRequest(url: url.appendingPathComponent("api/v1/events"))
        req.timeoutInterval = 90 // (the service says something every 25 s)
        for (k, v) in headers(try await identity()) { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, res) = try await session.bytes(for: req)
        guard let http = res as? HTTPURLResponse, http.statusCode == 200 else {
            throw AliasError(status: (res as? HTTPURLResponse)?.statusCode ?? 0, message: "no stream", code: nil, reason: nil)
        }
        return AsyncThrowingStream { cont in
            let t = Task {
                var p = SSEParser()
                do {
                    for try await b in bytes {
                        for ev in p.feed(b) where Self.kinds.contains(ev.event) {
                            if var u = try? JSONDecoder().decode(Update.self, from: Data(ev.data.utf8)) {
                                u.kind = ev.event
                                cont.yield(u)
                            }
                        }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }

    static let kinds: Set<String> = ["answer", "mode", "typing", "read", "remote"]

    /// Answers and a live ticket's events: from the stream (/api/v1/events) while it's open, by polling
    /// /api/v1/updates where it isn't, and once after every reconnect so nothing is missed. Each answer
    /// once. Ends when the task iterating it is cancelled (do that when the app goes to the background), or
    /// when the identity's refused. stream false: polling only.
    public func watch(pollEvery: Duration = .seconds(60), since: String? = nil, stream: Bool = true) -> AsyncStream<Update> {
        AsyncStream { cont in
            let w = Watcher(client: self, since: since, cont: cont)
            let t = Task {
                var wait = Duration.seconds(1)
                while !Task.isCancelled {
                    do {
                        try await w.poll()
                        if stream {
                            let s = try await self.events()
                            wait = .seconds(1)
                            let poller = Task { while !Task.isCancelled { try await Task.sleep(for: pollEvery); try? await w.poll() } }
                            defer { poller.cancel() }
                            for try await u in s { await w.emit(u) }
                        } else {
                            try await Task.sleep(for: pollEvery)
                            continue
                        }
                    } catch let e as AliasError where e.status == 401 || e.status == 403 {
                        break
                    } catch {
                        if Task.isCancelled { break }
                    }
                    try? await Task.sleep(for: wait)
                    wait = min(wait * 2, .seconds(60))
                }
                cont.finish()
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }

    // --- sending ---

    /// The text, context and telemetry as they'll go: the user's removals, then the product's rules.
    private func prepare(_ text: String, _ x: Extras) async throws -> Redactable {
        var c = Redactable(note: text, context: x.context ?? contextOf?(), telemetry: x.telemetry ?? telemetryOf?())
        if !x.remove.isEmpty || redacts {
            let p = try await product()
            let allowed = Set(p.removable ?? [])
            if !x.remove.isEmpty { c = removePaths(c, x.remove.filter(allowed.contains)) }
            if redacts { c = redact(p.redact ?? [], c) }
        }
        return c
    }

    /// JSON, or multipart/form-data with the files (the JSON as the part `report`).
    private func send<T: Decodable>(_ path: String, _ body: JSONObject, _ x: Extras) async throws -> T {
        var files = x.attachments
        var body = body
        if files.isEmpty {
            if let s = x.screenshot { body["screenshot"] = .string(s.base64EncodedString()) }
            return try await call("POST", path, json: body)
        }
        if let s = x.screenshot { files.insert(AttachmentInput(name: "screenshot.jpg", data: s), at: 0) }
        let boundary = "alias-" + UUID().uuidString
        var form = Data()
        func part(_ head: String, _ data: Data) {
            form.append(Data("--\(boundary)\r\n\(head)\r\n\r\n".utf8)); form.append(data); form.append(Data("\r\n".utf8))
        }
        part("Content-Disposition: form-data; name=\"report\"; filename=\"report.json\"\r\nContent-Type: application/json",
             try JSONEncoder().encode(body))
        for f in files {
            let name = f.name.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            part("Content-Disposition: form-data; name=\"attachment\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream", f.data)
        }
        form.append(Data("--\(boundary)--\r\n".utf8))
        return try await call("POST", path, body: form, contentType: "multipart/form-data; boundary=\(boundary)")
    }

    // --- the wire ---

    enum Who { case identity, none, this(Identity) }

    private func headers(_ id: Identity?) -> [String: String] {
        var h = ["X-Alias-Key": key]
        if let id { h["X-Alias-User"] = id.id; h["X-Alias-Secret"] = id.secret }
        return h
    }

    private func call<T: Decodable>(_ method: String, _ path: String, json: JSONObject? = nil, who: Who = .identity,
                                    extra: [String: String] = [:]) async throws -> T {
        try await call(method, path, body: try json.map { try JSONEncoder().encode($0) }, contentType: json == nil ? nil : "application/json",
                       who: who, extra: extra)
    }

    private func call<T: Decodable>(_ method: String, _ path: String, body: Data?, contentType: String?, who: Who = .identity,
                                    extra: [String: String] = [:]) async throws -> T {
        let id: Identity?
        switch who {
        case .identity: id = try await identity()
        case .none: id = nil
        case .this(let i): id = i
        }
        let (data, _) = try await raw(method, path, body: body, contentType: contentType, headers: headers(id).merging(extra) { $1 })
        if T.self == Empty.self { return Empty() as! T }
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw AliasError(status: 200, message: "an answer not understood: \(error)", code: nil, reason: nil)
        }
    }

    private func raw(_ method: String, _ path: String, body: Data?, contentType: String?, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        guard let u = URL(string: url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw AliasError(status: 0, message: "a bad path: \(path)", code: nil, reason: nil)
        }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.httpBody = body
        if let ct = contentType { req.setValue(ct, forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, res) = try await session.data(for: req)
        guard let http = res as? HTTPURLResponse else { throw AliasError(status: 0, message: "not HTTP", code: nil, reason: nil) }
        guard (200..<300).contains(http.statusCode) else {
            struct E: Decodable { let error: String?; let code: String?; let reason: String? }
            let e = try? JSONDecoder().decode(E.self, from: data)
            throw AliasError(status: http.statusCode, message: e?.error ?? "HTTP \(http.statusCode)", code: e?.code, reason: e?.reason)
        }
        return (data, http)
    }
}

struct Empty: Decodable {}

/// watch's state: where polling's got to, and the answers already told (each once, stream or poll).
private actor Watcher {
    let client: AliasClient
    var since: String?
    var seen = Set<String>()
    let cont: AsyncStream<Update>.Continuation

    init(client: AliasClient, since: String?, cont: AsyncStream<Update>.Continuation) {
        self.client = client; self.since = since; self.cont = cont
    }

    func emit(_ u: Update) {
        if u.kind == "answer" {
            guard seen.insert("\(u.ticket)@\(u.at)").inserted else { return }
            if seen.count > 500 { seen.removeAll() }
        }
        cont.yield(u)
    }

    func poll() async throws {
        let r = try await client.updates(since: since)
        if since != nil { r.updates.forEach(emit) } // (the first poll only sets where to start)
        since = r.now
    }
}

private func esc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/", "?", "&", "=", "+"])) ?? s }
