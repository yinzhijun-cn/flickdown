// Draws the app icon and writes Resources/AppIcon.icns.
//   swift scripts/make-icon.swift [output.icns] [preview.png]
//
// Artwork: an F↓ monogram on a blue squircle. The F's stem ends in the Markdown down arrow (F + ↓ = Flickdown);
// the glyph leans forward with amber speed streaks trailing behind it, for the "flick".
// Drawn on a 1024 canvas following the macOS icon grid (824 pt squircle, 100 pt margin).
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"
let preview = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The macOS squircle: a superellipse, which is what gives Apple's icon shape its continuous corners.
func squircle(in rect: NSRect, exponent n: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
    }
    path.close()
    return path
}

func polygon(_ points: [(CGFloat, CGFloat)]) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: points[0].0, y: points[0].1))
    for p in points.dropFirst() { path.line(to: NSPoint(x: p.0, y: p.1)) }
    path.close()
    return path
}

func withShadow(offsetY: CGFloat, blur: CGFloat, alpha: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: offsetY)
    shadow.shadowBlurRadius = blur
    shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func drawIcon() {
    // Background squircle with a top-to-bottom blue gradient and a soft highlight at the top.
    let tile = squircle(in: NSRect(x: 100, y: 100, width: 824, height: 824))
    withShadow(offsetY: -10, blur: 24, alpha: 0.28) {
        color(0x2F6FEB).setFill()
        tile.fill()
    }
    NSGradient(starting: color(0x4C8DFF), ending: color(0x1A4FD6))!.draw(in: tile, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 512, y: 960), radius: 0, toCenter: NSPoint(x: 512, y: 960), radius: 620, options: [])
    NSGraphicsContext.restoreGraphicsState()

    // Lean everything that follows forward by 10° around the canvas center, shifted right to balance the streaks.
    let lean = NSAffineTransform()
    lean.translateX(by: 562, yBy: 512)
    lean.transformStruct.m21 = tan(10 * .pi / 180)
    lean.translateX(by: -512, yBy: -512)
    lean.concat()

    // The F↓ glyph, drawn in one transparency layer so it casts a single shadow.
    withShadow(offsetY: -14, blur: 32, alpha: 0.28) {
        let context = NSGraphicsContext.current!.cgContext
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        NSColor.white.set()
        let f = NSBezierPath()
        f.move(to: NSPoint(x: 690, y: 724))
        f.line(to: NSPoint(x: 430, y: 724))
        f.line(to: NSPoint(x: 430, y: 424))
        f.move(to: NSPoint(x: 430, y: 554))
        f.line(to: NSPoint(x: 630, y: 554))
        f.lineWidth = 92
        f.lineCapStyle = .round
        f.lineJoinStyle = .round
        f.stroke()
        let arrow = polygon([(340, 444), (520, 444), (430, 280)])
        arrow.lineWidth = 24
        arrow.lineJoinStyle = .round
        arrow.fill()
        arrow.stroke()
        context.endTransparencyLayer()
    }

    // Speed streaks behind the glyph, fading out to the left.
    let streak = NSGradient(colors: [NSColor.white.withAlphaComponent(0), color(0xFFE7A8, 0.75), color(0xFFC53D)],
                            atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    for rect in [NSRect(x: 170, y: 706, width: 170, height: 36),
                 NSRect(x: 215, y: 536, width: 125, height: 36),
                 NSRect(x: 245, y: 366, width: 95, height: 36)] {
        streak.draw(in: NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18), angle: 0)
    }
}

func render(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    let scale = CGFloat(size) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(getpid()).iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = render(size: base * scale).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
if let preview {
    try render(size: 1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: preview))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote \(output)" : "iconutil failed")
