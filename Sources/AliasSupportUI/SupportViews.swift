import AliasSupport
import CoreGraphics
import SwiftUI

/// A note or a comment, shown: markdown (when it says it is) inline only, links only http, https and
/// mailto, no images (nothing remote is ever fetched); plain text as it is.
public func aliasText(_ text: String, format: Format?) -> AttributedString {
    guard format == .markdown, var a = try? AttributedString(markdown: text, options: .init(
        allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible))
    else { return AttributedString(text) }
    for run in a.runs {
        if let l = run.link, !["http", "https", "mailto"].contains(l.scheme?.lowercased() ?? "") { a[run.range].link = nil }
        if run.imageURL != nil { a[run.range].imageURL = nil }
    }
    return a
}

/// The sheet to drop in: a report (with the screenshot, if you pass one, which the user can black out
/// first), and their reports with support's answers.
public struct AliasSupportView: View {
    let client: AliasClient
    let screenshot: CGImage?
    let labels: AliasLabels
    let onSent: (Ticket) -> Void

    public init(client: AliasClient, screenshot: CGImage? = nil, labels: AliasLabels = AliasLabels(), onSent: @escaping (Ticket) -> Void = { _ in }) {
        self.client = client; self.screenshot = screenshot; self.labels = labels; self.onSent = onSent
    }

    public var body: some View {
        NavigationStack {
            AliasReportView(client: client, screenshot: screenshot, labels: labels, onSent: onSent)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink(labels.yourReports) { AliasTicketsView(client: client, labels: labels) }
                    }
                }
        }
    }
}

/// A report: what happened, the screenshot (blacked out where the user chose), what goes with it (the
/// removable parts theirs to take out), and a way to reach them, if the product asks and they agree.
public struct AliasReportView: View {
    let client: AliasClient
    let screenshot: CGImage?
    let labels: AliasLabels
    let onSent: (Ticket) -> Void

    @State private var product: Product?
    @State private var note = ""
    @State private var includeShot = true
    @State private var redacted: Data?
    @State private var editing = false
    @State private var preview: TelemetryPreview?
    @State private var removed: Set<String> = []
    @State private var contact = ""
    @State private var agreed = false
    @State private var sending = false
    @State private var problem: String?
    @State private var sent: Ticket?

    public init(client: AliasClient, screenshot: CGImage? = nil, labels: AliasLabels = AliasLabels(), onSent: @escaping (Ticket) -> Void = { _ in }) {
        self.client = client; self.screenshot = screenshot; self.labels = labels; self.onSent = onSent
    }

    public var body: some View {
        Form {
            Section(labels.notePrompt) {
                TextEditor(text: $note).frame(minHeight: 120).accessibilityLabel(labels.notePrompt)
            }
            if let screenshot {
                Section(labels.screenshot) {
                    Toggle(labels.includeScreenshot, isOn: $includeShot)
                    if includeShot {
                        thumbnail(screenshot)
                        Button(labels.blackOut) { editing = true }
                    }
                }
            }
            if let preview, preview.context != nil || preview.telemetry != nil {
                Section(labels.whatsSent) {
                    ForEach(lines(preview), id: \.path) { l in
                        if preview.removable.contains(l.path) {
                            Toggle(isOn: Binding(get: { !removed.contains(l.path) }, set: { on in if on { removed.remove(l.path) } else { removed.insert(l.path) } })) {
                                line(l)
                            }
                        } else { line(l) }
                    }
                }
            }
            if let p = product, p.contact == "optional", let consent = p.contactConsent {
                Section(labels.contactTitle) {
                    TextField(labels.contactPlaceholder, text: $contact)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        #endif
                    if !contact.isEmpty {
                        Text(consent.text).font(.footnote)
                        Toggle(labels.agree, isOn: $agreed)
                    }
                }
            }
            Section {
                if let problem { Text(problem).foregroundStyle(.red) }
                if sent != nil { Text(labels.sent) }
                Button(sending ? labels.sending : labels.send) { Task { await send() } }
                    .disabled(sending || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!contact.isEmpty && !agreed))
            }
        }
        .navigationTitle(labels.reportTitle)
        .task {
            product = try? await client.product()
            preview = try? await client.previewTelemetry()
        }
        .sheet(isPresented: $editing) {
            if let screenshot {
                AliasRedactorView(image: screenshot, labels: labels) { data in
                    if let data { redacted = data }
                    editing = false
                }
                .frame(minWidth: 480, minHeight: 420)
            }
        }
    }

    @ViewBuilder private func thumbnail(_ img: CGImage) -> some View {
        if let redacted, let shown = try? RedactImage.cgImage(from: redacted, maxSide: 800) {
            Image(decorative: shown, scale: 1).resizable().scaledToFit().frame(maxHeight: 200)
        } else {
            Image(decorative: img, scale: 1).resizable().scaledToFit().frame(maxHeight: 200)
        }
    }

    private struct Line { let path: String; let label: String; let value: String }

    private func lines(_ p: TelemetryPreview) -> [Line] {
        func text(_ v: JSON) -> String {
            switch v {
            case .string(let s): return s
            default: return (try? String(decoding: JSONEncoder().encode(v), as: UTF8.self)) ?? ""
            }
        }
        let ctx = (p.context ?? [:]).sorted { $0.key < $1.key }.map { Line(path: "/context/" + $0.key, label: $0.key, value: text($0.value)) }
        let tel = (p.telemetry ?? [:]).sorted { $0.key < $1.key }.map { Line(path: "/telemetry/" + $0.key, label: $0.key, value: text($0.value)) }
        return ctx + tel
    }

    private func line(_ l: Line) -> some View {
        HStack { Text(l.label).foregroundStyle(.secondary); Spacer(); Text(l.value).lineLimit(2).font(.callout.monospaced()) }
    }

    private func send() async {
        sending = true; problem = nil
        defer { sending = false }
        do {
            var x = Extras(remove: Array(removed))
            if let screenshot, includeShot { x.screenshot = try redacted ?? RedactImage.jpeg(screenshot, []) } // (re-encoded either way: no metadata)
            let t = try await client.report(note, x)
            if !contact.isEmpty, agreed, let consent = product?.contactConsent {
                _ = try await client.setContact(kind: contact.contains("@") ? "email" : "other", value: contact, consent: consent)
            }
            sent = t; note = ""
            onSent(t)
        } catch let e as AliasError {
            problem = e.keyRevoked ? (e.reason ?? e.message) : e.message
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// The user's reports, newest first; each opens its thread.
public struct AliasTicketsView: View {
    let client: AliasClient
    let labels: AliasLabels
    @State private var tickets: [Ticket] = []
    @State private var loaded = false

    public init(client: AliasClient, labels: AliasLabels = AliasLabels()) { self.client = client; self.labels = labels }

    public var body: some View {
        List(tickets) { t in
            NavigationLink { AliasTicketView(client: client, id: t.id, labels: labels) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t.note.split(separator: "\n").first.map(String.init) ?? "").lineLimit(1)
                    Text(labels.statusWords[t.status.rawValue] ?? t.status.rawValue).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .overlay { if loaded && tickets.isEmpty { Text(labels.noReports).foregroundStyle(.secondary) } }
        .navigationTitle(labels.yourReports)
        .task {
            tickets = (try? await client.tickets()) ?? []
            loaded = true
            for await u in await client.watch() where u.kind == "answer" { tickets = (try? await client.tickets()) ?? tickets }
        }
    }
}

/// A report's thread: the user's and support's (an agent's marked), a reply, and live: asked for, or on,
/// with support typing. Answers come over the stream while it's shown and the app's in the foreground.
public struct AliasTicketView: View {
    let client: AliasClient
    let id: Int
    let labels: AliasLabels
    @Environment(\.scenePhase) private var phase
    @State private var ticket: Ticket?
    @State private var product: Product?
    @State private var reply = ""
    @State private var typing = false
    @State private var lastTyped = Date.distantPast
    @State private var problem: String?

    public init(client: AliasClient, id: Int, labels: AliasLabels = AliasLabels()) { self.client = client; self.id = id; self.labels = labels }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let t = ticket {
                        bubble(labels.you, aliasText(t.note, format: t.format), mine: true, agent: false)
                        ForEach(t.thread ?? []) { e in
                            if e.kind == "comment" {
                                bubble(e.author == "user" ? labels.you : (e.name ?? labels.support), aliasText(e.body, format: e.format),
                                       mine: e.author == "user", agent: e.agent == true)
                            } else {
                                Text(e.body).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                            }
                        }
                        if typing { Text(labels.typing).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .padding()
            }
            if let problem { Text(problem).foregroundStyle(.red).font(.footnote) }
            liveBar
            HStack {
                TextField(labels.replyPrompt, text: $reply, axis: .vertical)
                    .lineLimit(1...5)
                    .onChange(of: reply) { _ in typed() }
                Button(labels.send) { Task { await send() } }.disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .navigationTitle(ticket.map { labels.statusWords[$0.status.rawValue] ?? "" } ?? "")
        .task(id: phase == .active) {
            guard phase == .active else { return } // (the stream only while the app's in the foreground)
            await load()
            product = try? await client.product(refresh: true)
            for await u in await client.watch(pollEvery: .seconds(30)) where u.ticket == id {
                switch u.kind {
                case "typing": typing = true; Task { try? await Task.sleep(for: .seconds(4)); typing = false }
                case "read": break
                default: typing = false; await load()
                }
            }
        }
    }

    @ViewBuilder private var liveBar: some View {
        if let t = ticket, let live = product?.live {
            if t.mode == .live {
                Text(labels.liveNow).font(.footnote)
            } else if t.liveRequestedAt != nil {
                Text(labels.liveAsked).font(.footnote).foregroundStyle(.secondary)
            } else if live.userMayAsk {
                Button(labels.talkLive) { Task { if let t = try? await client.requestLive(id) { ticket = t } } }
            }
        }
    }

    private func bubble(_ who: String, _ text: AttributedString, mine: Bool, agent: Bool) -> some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            Text(who).font(.caption).foregroundStyle(.secondary)
            Text(text).padding(10).background(mine ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            if agent { Text(labels.agent).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private func load() async {
        do {
            ticket = try await client.ticket(id)
            try? await client.markRead(id)
        } catch { problem = (error as? AliasError)?.message ?? error.localizedDescription }
    }

    private func typed() {
        guard ticket?.mode == .live, Date().timeIntervalSince(lastTyped) > 2 else { return }
        lastTyped = Date()
        Task { try? await client.typing(id) }
    }

    private func send() async {
        let text = reply
        do {
            ticket = try await client.reply(id, text)
            reply = ""; problem = nil
        } catch { problem = (error as? AliasError)?.message ?? error.localizedDescription }
    }
}
