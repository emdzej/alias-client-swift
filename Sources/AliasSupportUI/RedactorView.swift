import CoreGraphics
import SwiftUI

/// The words the views show: English by default, yours to translate.
public struct AliasLabels: Sendable {
    public var redactTitle = "Black out what you don't want to send"
    public var box = "Box"
    public var brush = "Brush"
    public var undo = "Undo"
    public var clear = "Clear"
    public var cancel = "Cancel"
    public var done = "Done"
    public var reportTitle = "Report a problem"
    public var notePrompt = "What happened?"
    public var screenshot = "Screenshot"
    public var includeScreenshot = "Send the screenshot"
    public var blackOut = "Black out parts"
    public var whatsSent = "What's sent with it"
    public var nothingElse = "Nothing else."
    public var contactTitle = "A way to reach you (optional)"
    public var contactPlaceholder = "you@example.com"
    public var agree = "I agree"
    public var send = "Send"
    public var sending = "Sending…"
    public var sent = "Sent. You'll see support's answer here."
    public var yourReports = "Your reports"
    public var noReports = "No reports yet."
    public var replyPrompt = "Write a reply"
    public var talkLive = "Talk live"
    public var liveAsked = "Asked: someone will join when they can."
    public var liveNow = "Live: support is here."
    public var typing = "Support is typing…"
    public var agent = "Answered by an agent, not a person"
    public var support = "Support"
    public var you = "You"
    public var statusWords: [String: String] = ["open": "Open", "in_progress": "In progress", "waiting": "Waiting on you",
                                                 "resolved": "Resolved", "closed": "Closed"]
    public init() {}
}

/// The screenshot editor: solid boxes and a brush over the image, undo and clear; Done gives the redacted
/// JPEG (a new image: no metadata), Cancel nil.
public struct AliasRedactorView: View {
    let image: CGImage
    let labels: AliasLabels
    let quality: Double
    let onFinish: (Data?) -> Void
    @State private var model: RedactModel
    @State private var tool: RedactTool = .box
    @State private var problem: String?

    public init(image: CGImage, labels: AliasLabels = AliasLabels(), quality: Double = 0.9, onFinish: @escaping (Data?) -> Void) {
        self.image = image; self.labels = labels; self.quality = quality; self.onFinish = onFinish
        _model = State(initialValue: RedactModel(width: Double(image.width), height: Double(image.height)))
    }

    public var body: some View {
        VStack(spacing: 12) {
            Text(labels.redactTitle).font(.headline)
            GeometryReader { geo in
                let scale = min(geo.size.width / Double(image.width), geo.size.height / Double(image.height))
                let size = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
                ZStack {
                    Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                    Canvas { ctx, _ in
                        ctx.scaleBy(x: scale, y: scale)
                        let (fill, strokes) = redactPath(model.all)
                        ctx.fill(Path(fill), with: .color(.black))
                        for (p, w) in strokes {
                            ctx.stroke(Path(p), with: .color(.black), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if model.current == nil { model.begin(tool, g.startLocation.x / scale, g.startLocation.y / scale) }
                            model.move(g.location.x / scale, g.location.y / scale)
                        }
                        .onEnded { _ in model.end() })
                    .accessibilityLabel(labels.redactTitle)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            Picker("", selection: $tool) {
                Text(labels.box).tag(RedactTool.box)
                Text(labels.brush).tag(RedactTool.brush)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
            if let problem { Text(problem).foregroundStyle(.red).font(.footnote) }
            HStack {
                Button(labels.undo) { model.undo() }.disabled(model.ops.isEmpty)
                Button(labels.clear) { model.clear() }.disabled(model.ops.isEmpty)
                Spacer()
                Button(labels.cancel, role: .cancel) { onFinish(nil) }
                Button(labels.done) {
                    do { onFinish(try RedactImage.jpeg(image, model.ops, quality: quality)) } catch { problem = "\(error)" }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}
