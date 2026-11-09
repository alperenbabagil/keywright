// Renders the Keywright app icon and builds Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (from the repo root; needs sips + iconutil)
import AppKit
import CoreGraphics

let size = 1024.0
let out = URL(fileURLWithPath: "Resources")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Work in top-left, y-down coordinates like the rest of Keywright.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

// Body: Apple's macOS icon grid — 824pt rounded square inset 100pt, with a soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(bodyPath); ctx.setFillColor(color(0x1E1B4B)); ctx.fillPath()
ctx.restoreGState()

// Background gradient: indigo (top-left) → cyan (bottom-right), plus a gentle top sheen.
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [color(0x4338CA), color(0x2563EB), color(0x06B6D4)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: body.minX, y: body.minY), end: CGPoint(x: body.maxX, y: body.maxY), options: [])
let sheen = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.midY), options: [])

// Faint display-grid lines: the Mac being driven.
ctx.setStrokeColor(color(0xFFFFFF, 0.07)); ctx.setLineWidth(3)
for i in 1..<6 {
    let t = body.minX + Double(i) * body.width / 6
    ctx.move(to: CGPoint(x: t, y: body.minY)); ctx.addLine(to: CGPoint(x: t, y: body.maxY))
    ctx.move(to: CGPoint(x: body.minX, y: t - body.minX + body.minY)); ctx.addLine(to: CGPoint(x: body.maxX, y: t - body.minX + body.minY))
}
ctx.strokePath()
ctx.restoreGState()

// The pointer: classic arrow outline in 12×20 units, tip at `tip`.
func arrow(tip: CGPoint, unit: Double) -> CGPath {
    let pts: [(Double, Double)] = [(0, 0), (0, 17), (4, 13.2), (6.9, 20), (9.9, 18.7), (7.1, 12.2), (12.3, 12.2)]
    let p = CGMutablePath()
    p.addLines(between: pts.map { CGPoint(x: tip.x + $0.0 * unit, y: tip.y + $0.1 * unit) })
    p.closeSubpath()
    return p
}

let tip = CGPoint(x: 470, y: 250)
let unit = 24.0

// Motion trail: dotted arc sweeping in from the lower left to the tip — scripted movement.
let trail = CGMutablePath()
trail.move(to: CGPoint(x: 215, y: 760))
trail.addCurve(to: CGPoint(x: tip.x - 6, y: tip.y + 40), control1: CGPoint(x: 230, y: 520), control2: CGPoint(x: 330, y: 330))
ctx.saveGState()
ctx.addPath(trail)
ctx.setLineCap(.round)
ctx.setLineWidth(22)
ctx.setLineDash(phase: 0, lengths: [0.1, 52])
ctx.setStrokeColor(color(0xFFFFFF, 0.55))
ctx.strokePath()
ctx.restoreGState()

// A ghost pointer partway along: the previous position.
ctx.saveGState()
ctx.addPath(arrow(tip: CGPoint(x: 295, y: 450), unit: 13))  // tip on the trail (Bezier t = 0.5)
ctx.setFillColor(color(0xFFFFFF, 0.32)); ctx.fillPath()
ctx.restoreGState()

// Main pointer with shadow, white fill and a dark outline.
let main = arrow(tip: tip, unit: unit)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 10, height: 22), blur: 30, color: color(0x0B1033, 0.5))
ctx.addPath(main); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(main)
ctx.setLineJoin(.round)
ctx.setLineWidth(18)
ctx.setStrokeColor(color(0x111827))
ctx.strokePath()
ctx.addPath(main); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()

// Click ripple at the tip: the pointer is acting, not just moving.
ctx.setLineCap(.round)
for (r, a) in [(70.0, 0.85), (112.0, 0.45)] {
    ctx.addArc(center: tip, radius: r, startAngle: .pi * 0.98, endAngle: .pi * 1.52, clockwise: false)
    ctx.setStrokeColor(color(0xFFFFFF, a)); ctx.setLineWidth(16); ctx.strokePath()
}

// Write the 1024 master, then the iconset sizes and the .icns.
let master = out.appendingPathComponent("AppIcon-1024.png")
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: master)

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func run(_ tool: String, _ args: [String]) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    try! p.run(); p.waitUntilExit()
    precondition(p.terminationStatus == 0, "\(tool) failed")
}
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        run("/usr/bin/sips", ["-z", "\(px)", "\(px)", master.path, "--out", iconset.appendingPathComponent(name).path])
    }
}
run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path])
print("Wrote Resources/AppIcon-1024.png and Resources/AppIcon.icns")
