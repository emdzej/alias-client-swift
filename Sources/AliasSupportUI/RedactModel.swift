import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One thing drawn over the screenshot, in the image's pixels (top left 0, 0): opaque, never a blur.
public enum RedactOp: Equatable, Sendable {
    case box(x: Double, y: Double, w: Double, h: Double)
    case brush(size: Double, points: [CGPoint])
}

public enum RedactTool: Sendable { case box, brush }

/// The editor's drawing, apart from any view: boxes and brush strokes, clamped to the image, undone one
/// at a time. (The TypeScript client's RedactModel, the same.)
public struct RedactModel: Sendable {
    public let width: Double, height: Double
    public var brushSize: Double
    public private(set) var ops: [RedactOp] = []
    public private(set) var current: RedactOp?
    private var start = CGPoint.zero

    /// brushSize: 3% of the shorter side, 12 at least.
    public init(width: Double, height: Double, brushSize: Double? = nil) {
        self.width = width; self.height = height
        self.brushSize = brushSize ?? max(12, (min(width, height) * 0.03).rounded())
    }

    public mutating func begin(_ tool: RedactTool, _ x: Double, _ y: Double) {
        let p = clamp(x, y)
        start = p
        current = tool == .box ? .box(x: p.x, y: p.y, w: 0, h: 0) : .brush(size: brushSize, points: [p])
    }

    public mutating func move(_ x: Double, _ y: Double) {
        guard let c = current else { return }
        let p = clamp(x, y)
        switch c {
        case .box: current = .box(x: min(start.x, p.x), y: min(start.y, p.y), w: abs(p.x - start.x), h: abs(p.y - start.y))
        case .brush(let size, let pts): current = .brush(size: size, points: pts + [p])
        }
    }

    /// The operation done (a box of no size isn't one).
    public mutating func end() {
        defer { current = nil }
        guard let c = current else { return }
        if case .box(_, _, let w, let h) = c, w < 1 || h < 1 { return }
        ops.append(c)
    }

    public mutating func undo() { if !ops.isEmpty { ops.removeLast() } }
    public mutating func clear() { ops = []; current = nil }
    /// What shows: what's done, and what's being drawn.
    public var all: [RedactOp] { current.map { ops + [$0] } ?? ops }

    private func clamp(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: max(0, min(width, x)), y: max(0, min(height, y))) }
}

/// The ops as a path, in the image's pixels (top left 0, 0), filled and stroked opaque.
public func redactPath(_ ops: [RedactOp]) -> (fill: CGPath, strokes: [(CGPath, Double)]) {
    let fill = CGMutablePath()
    var strokes: [(CGPath, Double)] = []
    for op in ops {
        switch op {
        case .box(let x, let y, let w, let h): fill.addRect(CGRect(x: x, y: y, width: w, height: h))
        case .brush(let size, let pts):
            guard let first = pts.first else { continue }
            if pts.count == 1 {
                fill.addEllipse(in: CGRect(x: first.x - size / 2, y: first.y - size / 2, width: size, height: size))
                continue
            }
            let p = CGMutablePath()
            p.addLines(between: pts)
            strokes.append((p, size))
        }
    }
    return (fill, strokes)
}

public enum RedactImageError: Error { case unreadable, unmade }

/// The screenshot, redacted: a new image drawn from the pixels and the ops, encoded fresh, so nothing of
/// the original's metadata (EXIF, location, the device) goes with it.
public enum RedactImage {
    /// An image file's pixels, upright (its EXIF orientation applied), at most maxSide on its longer side.
    public static func cgImage(from data: Data, maxSide: Int = 4096) throws -> CGImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxSide] as CFDictionary)
        else { throw RedactImageError.unreadable }
        return img
    }

    /// The image with the ops drawn over it, as a JPEG (quality 0 to 1) with no metadata.
    public static func jpeg(_ image: CGImage, _ ops: [RedactOp], quality: Double = 0.9, colour: CGColor = CGColor(gray: 0, alpha: 1)) throws -> Data {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw RedactImageError.unmade }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h)) // (the ops are top left 0, 0)
        ctx.scaleBy(x: 1, y: -1)
        let (fill, strokes) = redactPath(ops)
        ctx.setFillColor(colour)
        ctx.addPath(fill)
        ctx.fillPath()
        ctx.setStrokeColor(colour)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for (p, size) in strokes {
            ctx.setLineWidth(size)
            ctx.addPath(p)
            ctx.strokePath()
        }
        guard let out = ctx.makeImage() else { throw RedactImageError.unmade }
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw RedactImageError.unmade }
        CGImageDestinationAddImage(dst, out, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { throw RedactImageError.unmade }
        return data as Data
    }
}
