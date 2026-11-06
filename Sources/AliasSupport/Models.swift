import Foundation

// What the service sends and takes (docs/openapi.yaml's schemas), named as there.

public enum Status: String, Codable, Sendable, CaseIterable {
    case open, inProgress = "in_progress", waiting, resolved, closed
}

/// tickets: request and response; live: a conversation, as it happens.
public enum Mode: String, Codable, Sendable { case tickets, live }

/// How a note or a comment is written. Markdown: CommonMark with GFM's tables, strikethrough and
/// autolinks; show it with no raw HTML and no images but `![](attachment:name)` (nothing remote).
public enum Format: String, Codable, Sendable {
    case plain = "text/plain", markdown = "text/markdown"
}

public struct Identity: Codable, Sendable, Equatable {
    public let id: String
    public let secret: String
    public init(id: String, secret: String) { self.id = id; self.secret = secret }
}

public struct Field: Codable, Sendable {
    public let name: String
    public let label: String?
    public let type: String
    public let template: String?
}

public struct AttachmentLimits: Codable, Sendable {
    public let max: Int
    public let bytes: Int
    public let types: [String]
}

/// The product's text for giving a contact: show it whole by the field, and send nothing until the user agrees.
public struct ConsentText: Codable, Sendable, Equatable {
    public let text: String
    public let version: String
    public init(text: String, version: String) { self.text = text; self.version = version }
}

public struct Branding: Codable, Sendable {
    /// An https URL, or the image itself as a data: URL.
    public let logo: String?
    public let colour: String?
    public let accent: String?
}

public struct Product: Codable, Sendable {
    public let id: String
    public let name: String
    public let privacyURL: String?
    public let branding: Branding?
    public let fields: [Field]
    /// off, optional
    public let contact: String
    public let contactKinds: [String]
    public let contactConsent: ConsentText?
    /// Applied before anything's sent (`report`, `reply` do it), and again by the service.
    public let redact: [RedactRule]?
    /// What the user may take out before sending (paths as a rule's).
    public let removable: [String]?
    public let attachments: AttachmentLimits?
    public let formats: [Format]?
    public let telemetryMax: Int?
    public let conversations: Conversations?
    /// Live now: offer "Talk live" when `userMayAsk`; `available`: someone at the desk is taking them.
    public let live: Live?

    public struct Conversations: Codable, Sendable {
        public let mode: Mode
        public let `switch`: String
        public let idleMinutes: Int
        enum CodingKeys: String, CodingKey { case mode, `switch`, idleMinutes = "idle_minutes" }
    }
    public struct Live: Codable, Sendable, Equatable {
        public let mode: Mode
        public let userMayAsk: Bool
        public let available: Bool
        enum CodingKeys: String, CodingKey { case mode, userMayAsk = "user_may_ask", available }
    }
    enum CodingKeys: String, CodingKey {
        case id, name, privacyURL = "privacy_url", branding, fields, contact, contactKinds = "contact_kinds",
             contactConsent = "contact_consent", redact, removable, attachments, formats, telemetryMax = "telemetry_max",
             conversations, live
    }
}

/// A file sent with a report or a reply, as the service lists it.
public struct Attachment: Codable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let type: String
    public let size: Int
    public let createdAt: String
    enum CodingKeys: String, CodingKey { case id, name, type, size, createdAt = "created_at" }
}

/// What the user agreed to, as the service recorded it.
public struct Consent: Codable, Sendable {
    public let id: Int
    public let purpose: String
    public let version: String
    public let text: String
    public let kind: String
    public let appVersion: String?
    public let givenAt: String
    public let endedAt: String?
    /// withdrawn, replaced
    public let ended: String?
    enum CodingKeys: String, CodingKey {
        case id, purpose, version, text, kind, appVersion = "app_version", givenAt = "given_at", endedAt = "ended_at", ended
    }
}

public struct Contact: Codable, Sendable {
    /// email, other
    public let kind: String
    public let value: String
    public let givenAt: String
    public let consent: Consent?
    enum CodingKeys: String, CodingKey { case kind, value, givenAt = "given_at", consent }
}

public struct ContactState: Codable, Sendable {
    public let contact: Contact?
    public let policy: String?
    public let kinds: [String]?
    public let consent: ConsentText?
}

public struct Me: Codable, Sendable {
    public let id: String
    public let createdAt: String
    public let devices: Int
    public let contact: Contact?
    enum CodingKeys: String, CodingKey { case id, createdAt = "created_at", devices, contact }
}

public struct Entry: Codable, Sendable, Identifiable {
    public let id: Int
    /// user, support
    public let author: String
    public let name: String?
    /// comment, status, mode
    public let kind: String
    public let body: String
    public let format: Format?
    public let createdAt: String
    public let context: JSONObject?
    public let attachments: [Attachment]?
    public let hasScreenshot: Bool?
    /// Support's, but written by an agent (an AI agent, a script), not a person: show the user it was.
    public let agent: Bool?
    enum CodingKeys: String, CodingKey {
        case id, author, name, kind, body, format, createdAt = "created_at", context, attachments, hasScreenshot = "has_screenshot", agent
    }
}

public struct Ticket: Codable, Sendable, Identifiable {
    public let id: Int
    public let product: String
    public let status: Status
    public let note: String
    public let format: Format?
    public let context: JSONObject?
    public let telemetry: JSONObject?
    public let appVersion: String
    public let attachments: [Attachment]?
    public let hasScreenshot: Bool
    public let createdAt: String
    public let updatedAt: String
    public let supportAt: String?
    public let thread: [Entry]?
    public let mode: Mode?
    public let liveRequestedAt: String?
    public let userReadAt: String?
    public let supportReadAt: String?
    enum CodingKeys: String, CodingKey {
        case id, product, status, note, format, context, telemetry, appVersion = "app_version", attachments, hasScreenshot = "has_screenshot",
             createdAt = "created_at", updatedAt = "updated_at", supportAt = "support_at", thread, mode,
             liveRequestedAt = "live_requested_at", userReadAt = "user_read_at", supportReadAt = "support_read_at"
    }
}

/// answer: support answered or changed the ticket. On a live ticket's stream also mode, typing, read; remote: a request's state.
public struct Update: Codable, Sendable, Equatable {
    public var kind: String
    public let ticket: Int
    public let status: Status?
    public let at: String
    public let mode: Mode?
    public let who: String?
    public let name: String?
    public let agent: Bool?
    public let remote: String?
    public let channel: String?
    public let state: String?
}

public struct Updates: Codable, Sendable {
    public let updates: [Update]
    public let now: String
}

/// Support asking to open a channel (shell: SSH; screen: VNC) on this device. Nothing connects until it accepts.
public struct RemoteRequest: Codable, Sendable {
    public let id: String
    public let ticket: Int
    public let channel: String
    public let state: String
    public let askedBy: String
    public let askedAt: String
    public let deadline: String
    public let endReason: String?
    public let relay: Relay?
    public struct Relay: Codable, Sendable { public let url: String; public let token: String }
    enum CodingKeys: String, CodingKey {
        case id, ticket, channel, state, askedBy = "asked_by", askedAt = "asked_at", deadline, endReason = "end_reason", relay
    }
}

public struct RemoteList: Codable, Sendable {
    public let remote: [RemoteRequest]
    public let offered: Bool
}

public struct Transfer: Codable, Sendable {
    public let code: String
    public let expiresAt: String
    enum CodingKeys: String, CodingKey { case code, expiresAt = "expires_at" }
}

public struct Challenge: Codable, Sendable {
    public let bits: Int
    public let challenge: String?
    public let expiresAt: String?
    enum CodingKeys: String, CodingKey { case bits, challenge, expiresAt = "expires_at" }
}

public struct Erased: Codable, Sendable {
    public let erased: String
    public let tickets: Int
}

/// A file to send: its name (what `![](attachment:name)` names) and its bytes. Its type is told from them.
public struct AttachmentInput: Sendable {
    public let name: String
    public let data: Data
    public init(name: String, data: Data) { self.name = name; self.data = data }
}

/// What a report or a reply sends besides its text.
public struct Extras: Sendable {
    public var format: Format?
    public var attachments: [AttachmentInput]
    /// A JPEG: sent first, as screenshot.jpg.
    public var screenshot: Data?
    /// Instead of the client's `context` callback's.
    public var context: JSONObject?
    /// Instead of the client's `telemetry` callback's.
    public var telemetry: JSONObject?
    /// Paths the user chose to take out (of the product's `removable`; others are ignored).
    public var remove: [String]
    public init(format: Format? = nil, attachments: [AttachmentInput] = [], screenshot: Data? = nil,
                context: JSONObject? = nil, telemetry: JSONObject? = nil, remove: [String] = []) {
        self.format = format; self.attachments = attachments; self.screenshot = screenshot
        self.context = context; self.telemetry = telemetry; self.remove = remove
    }
}

/// What would be sent: redacted, and which of the product's removable paths are in it.
public struct TelemetryPreview: Sendable {
    public let context: JSONObject?
    public let telemetry: JSONObject?
    public let removable: [String]
}

/// A refusal. `code` says what kind (`key_revoked`: this build's key was revoked); `reason` is support's
/// words for the user, when they gave some: show it as it is.
public struct AliasError: Error, Sendable, CustomStringConvertible {
    public let status: Int
    public let message: String
    public let code: String?
    public let reason: String?
    /// This build's key was revoked: nothing more will reach support from it.
    public var keyRevoked: Bool { code == "key_revoked" }
    public var description: String { "\(message) (\(status))" }
}
