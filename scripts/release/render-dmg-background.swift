import AppKit

// DMG background for the zPDF installer window, drawn by make-dmg.sh (the same design as
// the zMeet and zStats installers). Finder layout coordinates are in points; make-dmg.sh
// places the icons at the matching positions. A 2× PNG keeps the artwork crisp on Retina.
// Usage: swift scripts/release/render-dmg-background.swift output.png
let size = NSSize(width: 720, height: 440)
let scale = 2
guard CommandLine.arguments.count == 2,
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                                    pixelsHigh: Int(size.height) * scale, bitsPerSample: 8,
                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Usage: swift scripts/release/render-dmg-background.swift output.png")
}
bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
// zPDF palette, from the app icon: a near-black base shading into deep maroon, the red of
// the icon's "PdF" script for accents, and warm off-white text.
let brandRed = color(0xC8342A)
let light = color(0xF3ECEC)
let muted = color(0x9C8E90)
let bounds = NSRect(origin: .zero, size: size)
NSGradient(colors: [color(0x0D0B0C), color(0x241114)])!.draw(in: bounds, angle: 90)

func centeredText(_ text: String, top: CGFloat, font: NSFont, tint: NSColor) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint, .paragraphStyle: style]
    (text as NSString).draw(in: NSRect(x: 30, y: size.height - top - 40, width: size.width - 60, height: 40),
                            withAttributes: attributes)
}

// Accent bar over the wordmark.
brandRed.withAlphaComponent(0.9).setFill()
NSBezierPath(roundedRect: NSRect(x: 344, y: 393, width: 32, height: 3), xRadius: 1.5, yRadius: 1.5).fill()

// Wordmark: a light "z" and "PDF" in the brand red's lighter tint, centered as one unit.
let wordmark = NSMutableAttributedString(string: "z", attributes: [
    .font: NSFont.systemFont(ofSize: 34, weight: .bold), .foregroundColor: light,
])
wordmark.append(NSAttributedString(string: "PDF", attributes: [
    .font: NSFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: light,
]))
let wordmarkSize = wordmark.size()
wordmark.draw(at: NSPoint(x: (size.width - wordmarkSize.width) / 2, y: size.height - 88 - wordmarkSize.height / 2))

// The arrow is artwork; both the app and Applications icons stay real draggable items.
let arrowY: CGFloat = size.height - 218
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 334, y: arrowY))
arrow.line(to: NSPoint(x: 386, y: arrowY))
arrow.move(to: NSPoint(x: 376, y: arrowY + 10))
arrow.line(to: NSPoint(x: 386, y: arrowY))
arrow.line(to: NSPoint(x: 376, y: arrowY - 10))
arrow.lineWidth = 2
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
brandRed.withAlphaComponent(0.85).setStroke()
arrow.stroke()

// Finder always draws dark filename text over a custom picture; pale pills behind
// the real filenames keep them readable without faking the labels.
light.setFill()
for (centerX, width): (CGFloat, CGFloat) in [(200, 90), (520, 140)] {
    NSBezierPath(roundedRect: NSRect(x: centerX - width / 2, y: size.height - 309, width: width, height: 30),
                 xRadius: 10, yRadius: 10).fill()
}

centeredText("Drag zPDF to Applications.", top: 343,
             font: .systemFont(ofSize: 15, weight: .medium), tint: muted)
NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode background") }
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
