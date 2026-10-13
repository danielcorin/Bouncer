#!/usr/bin/env swift
// Bouncer's app icon: a white shield with a "no entry" bar cut through it, on a
// deep teal gradient (calm protection rather than alarm red). Generated from the app-icon
// skill template. Run from the repo root:
//   swift scripts/generate-app-icon.swift
//
// Outputs:
// - Sources/App/AppIcon.icon/Assets/glyph.svg — the Liquid Glass foreground
//   layer used by the Icon Composer package (icon.json lives alongside it).
//   The system supplies the squircle mask, lighting, and appearance modes,
//   so the layer is full-bleed with no baked-in shape or shadow.
// - Sources/App/Assets.xcassets/AppIcon.appiconset — legacy macOS (15 and
//   earlier) PNGs: same artwork inside the HIG rounded rect with margins
//   and a drop shadow, re-rendered per size so small sizes stay crisp.
// - Sources/App/Assets.xcassets/AppIcon-iOS.appiconset — legacy iOS
//   full-bleed 1024 for a future iOS target.

import AppKit
import UniformTypeIdentifiers

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

struct RGB {
    let r: CGFloat, g: CGFloat, b: CGFloat
    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }
    func cg(_ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

let gradientTop = RGB(0x2EC4B6)
let gradientBottom = RGB(0x0A6F73)
let glyphWhite = RGB(0xFFFFFF)

// Glyph geometry in unit coordinates with y pointing DOWN (SVG convention),
// shared by the Liquid Glass SVG layer and the legacy PNGs.
enum Segment {
    case move(CGFloat, CGFloat)
    case line(CGFloat, CGFloat)
    case curve(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
    case close
}

/// Classic heater shield: shallow peaked top, straight sides, tapered point.
let shield: [Segment] = [
    .move(0.500, 0.180),
    .curve(0.600, 0.240, 0.690, 0.262, 0.770, 0.262),
    .line(0.770, 0.470),
    .curve(0.770, 0.665, 0.650, 0.775, 0.500, 0.838),
    .curve(0.350, 0.775, 0.230, 0.665, 0.230, 0.470),
    .line(0.230, 0.262),
    .curve(0.310, 0.262, 0.400, 0.240, 0.500, 0.180),
    .close,
]

/// The "no entry" bar, punched out of the shield (even-odd fill).
let bar = CGRect(x: 0.335, y: 0.462, width: 0.330, height: 0.090)

func barSegments() -> [Segment] {
    // Rounded-end bar as an explicit closed contour (shared with the SVG).
    let r = bar.height / 2, k: CGFloat = 0.5523 * r
    let l = bar.minX, t = bar.minY, rt = bar.maxX, b = bar.maxY, cy = bar.midY
    return [
        .move(l + r, t), .line(rt - r, t),
        .curve(rt - r + k, t, rt, cy - k, rt, cy),
        .curve(rt, cy + k, rt - r + k, b, rt - r, b),
        .line(l + r, b),
        .curve(l + r - k, b, l, cy + k, l, cy),
        .curve(l, cy - k, l + r - k, t, l + r, t),
        .close,
    ]
}

func cgPath(_ segments: [Segment], in content: CGRect) -> CGPath {
    let s = content.width
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: content.minX + x * s, y: content.minY + (1 - y) * s) }
    let path = CGMutablePath()
    for segment in segments {
        switch segment {
        case .move(let x, let y): path.move(to: p(x, y))
        case .line(let x, let y): path.addLine(to: p(x, y))
        case .curve(let x1, let y1, let x2, let y2, let x, let y): path.addCurve(to: p(x, y), control1: p(x1, y1), control2: p(x2, y2))
        case .close: path.closeSubpath()
        }
    }
    return path
}

func drawGlyph(_ ctx: CGContext, in content: CGRect) {
    ctx.setFillColor(glyphWhite.cg())
    ctx.addPath(cgPath(shield, in: content))
    ctx.addPath(cgPath(barSegments(), in: content))
    ctx.fillPath(using: .evenOdd)
}

func render(pixels: Int, macStyle: Bool) -> CGImage {
    let S = CGFloat(pixels)
    let ctx = CGContext(data: nil, width: pixels, height: pixels,
                        bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    let content: CGRect
    let bgPath: CGPath
    if macStyle {
        let inset = S * 100 / 1024
        content = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
        let radius = content.width * 185 / 824
        bgPath = CGPath(roundedRect: content, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.010), blur: S * 0.022,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.30))
        ctx.addPath(bgPath)
        ctx.setFillColor(gradientBottom.cg())
        ctx.fillPath()
        ctx.restoreGState()
    } else {
        content = CGRect(x: 0, y: 0, width: S, height: S)
        bgPath = CGPath(rect: content, transform: nil)
    }

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: srgb,
                        colors: [gradientTop.cg(), gradientBottom.cg()] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg,
                           start: CGPoint(x: content.midX, y: content.maxY),
                           end: CGPoint(x: content.midX, y: content.minY),
                           options: [])
    drawGlyph(ctx, in: content)
    ctx.restoreGState()

    return ctx.makeImage()!
}

func write(_ data: Data, to path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try! data.write(to: url)
    print("wrote \(path)")
}

func writePNG(_ image: CGImage, to path: String) {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("failed to encode \(path)") }
    write(data as Data, to: path)
}

let root = FileManager.default.currentDirectoryPath
let macSet = "\(root)/Sources/App/Assets.xcassets/AppIcon.appiconset"
let iosSet = "\(root)/Sources/App/Assets.xcassets/AppIcon-iOS.appiconset"

for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    writePNG(render(pixels: pixels, macStyle: true), to: "\(macSet)/icon_\(pixels).png")
}
writePNG(render(pixels: 1024, macStyle: false), to: "\(iosSet)/icon_1024.png")

// Liquid Glass foreground layer for AppIcon.icon: one closed even-odd path.
func svgPath(_ segments: [Segment]) -> String {
    func n(_ v: CGFloat) -> String { String(format: "%.1f", v * 1024) }
    return segments.map { segment in
        switch segment {
        case .move(let x, let y): "M\(n(x)) \(n(y))"
        case .line(let x, let y): "L\(n(x)) \(n(y))"
        case .curve(let x1, let y1, let x2, let y2, let x, let y): "C\(n(x1)) \(n(y1)) \(n(x2)) \(n(y2)) \(n(x)) \(n(y))"
        case .close: "Z"
        }
    }.joined(separator: " ")
}
let svg = """
<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">
  <path fill="#FFFFFF" fill-rule="evenodd" d="\(svgPath(shield)) \(svgPath(barSegments()))"/>
</svg>
"""
write(Data(svg.utf8), to: "\(root)/Sources/App/AppIcon.icon/Assets/glyph.svg")
