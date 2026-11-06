# AliasSupport for Swift

The ALIAS client for iOS 16+ and macOS 13+. It follows [the spec](https://github.com/emdzej/alias-releases/blob/main/spec/openapi.yaml): one method
per operation, named as its operationId, as in every client. Two libraries:

- **AliasSupport**: the client. No UI, no dependencies beyond the system's (Foundation, CryptoKit, Security).
- **AliasSupportUI**: SwiftUI views to drop in: the report (with the screenshot, blacked out where the
  user chooses), their reports and support's answers, live mode.

```swift
// Package.swift: .package(url: "https://github.com/emdzej/alias-client-swift", from: "0.4.1")
import AliasSupport
import AliasSupportUI

let alias = AliasClient(
    url: URL(string: "https://support.example.com")!, key: productKey,
    store: KeychainIdentityStore(account: "road-builder"),     // keep the identity between runs
    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
    context: { ["level": .string(level.name)] },
    telemetry: { ["fps": .number(fps)] })

// the sheet: a report with the screenshot (the user can black out parts first), and their reports
.sheet(isPresented: $reporting) { AliasSupportView(client: alias, screenshot: screenshot) }

// or your own screen, over the client
let preview = try await alias.previewTelemetry()      // what will be sent; preview.removable: theirs to untick
let ticket = try await alias.report("The door won't open: ![](attachment:door.jpg)",
    Extras(format: .markdown, attachments: [AttachmentInput(name: "door.jpg", data: redactedJPEG)], remove: unticked))

for await u in await alias.watch() where u.kind == "answer" { notify("Support answered #\(u.ticket)") }
```

## The identity

The service makes it (an id and a secret, from a secure random source); the client asks for it the first
time it's needed and keeps it in the store. With the product's proof of work on, the client does it first
(some thousands of SHA-256s). `KeychainIdentityStore` keeps it in the Keychain, this device only, readable
after the first unlock:

- **`accessGroup`**: a keychain access group your apps share, so a second app of yours (the standalone
  reporter, say) uses the same identity, and the user's tickets stay one thread.
- **`dataProtection`** (on by default): macOS's data protection keychain, as iOS has. It needs the app
  signed with a keychain entitlement; off, the login keychain (command line tools, tests).

`newTransfer` and `claimTransfer` move it to another device by a short code; `useIdentity` takes one typed
in, checked first. `eraseMe` erases it and everything of it at the service, and forgets it here.

## Redaction

`report` and `reply` apply the product's rules (GET /api/v1/product's `redact`) before anything leaves
the device; the service applies them again. Same paths, strategies and results as the service and every
client ([redact-vectors.json](https://github.com/emdzej/alias-releases/blob/main/spec/redact-vectors.json) holds them to it). `registerRedactor("name") { value, rule in … }` is
your own strategy, for a rule naming `client:name`; return nil to drop the value. `previewTelemetry()`
shows what will be sent and which of the product's removable paths are in it; `Extras(remove:)` takes the
user's choice.

The screenshot editor (`AliasRedactorView`, inside the sheet too) draws solid boxes and a brush, never a
blur, and Done gives a new JPEG drawn from the pixels: no EXIF, no location, no device. A screenshot sent
without editing is re-encoded the same way. `RedactImage.cgImage(from:)` reads an image file upright.

## Answers and live

`watch()` is an `AsyncStream` of updates: answers (each once) from the stream (/api/v1/events) while it's
open, by polling /api/v1/updates where it isn't and after each reconnect; on a live ticket also `mode`,
`typing`, `read`. It ends when the task iterating it is cancelled: do that when the app goes to the
background (the views do, by the scene's phase). `stream: false` polls only.

`requestLive` asks to talk live (live at once if someone's at the desk), `typing` and `markRead` tell
support. An answer written by an agent, not a person, has `agent` set: show it (the views do).

## Markdown

`aliasText(text, format:)` gives an `AttributedString` to show a note or a comment: Markdown inline only,
links only http, https and mailto, no images, so nothing remote is ever fetched; plain text as it is.

## Errors

Every call throws `AliasError`: the status and the service's words (a telemetry schema miss says which
field). `keyRevoked`: this build's key was revoked; `reason` is support's words for the user, show it as
it is.

## Remote assistance

`remoteRequests`, `ticketRemote`, `answerRemote` and `endRemote` are here, for a macOS app that runs an
SSH or VNC server itself; bridging the relay's session (as alias-agent and the TypeScript client do) is
not, yet.

## Tests

`swift test` (here, in clients/swift) builds alias-support from this repository with Go and runs against
it: every operation, the identity and proof of work, reports with attachments, redaction, answers and
live, contact, transfers, a revoked key. And on the device: the redaction vectors, the editor's drawing,
the screenshot's metadata gone, the stream's parsing, the keychain.
