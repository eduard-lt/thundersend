// Draws the installer window background. Usage: swift dmg-background.swift <output.png> <scale>
import AppKit

// Finder pins the image to the window's top left and does not scale it. The canvas is bigger than
// the 660 pt wide window, so a window that opens larger than asked still shows no bare edge.
let width: CGFloat = 660
let size = NSSize(width: 900, height: 700)
let scale = Int(CommandLine.arguments[2])!
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900 * scale, pixelsHigh: 700 * scale,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

/// `top` is measured down from the top of the window, like Finder's icon positions.
func centered(_ text: String, top: CGFloat, font: NSFont, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let textSize = (text as NSString).size(withAttributes: attrs)
    (text as NSString).draw(at: NSPoint(x: (width - textSize.width) / 2, y: size.height - top - textSize.height),
                            withAttributes: attrs)
}

let blue = rgb(0x2F5BEA)
let ink = rgb(0x1D1D1F)
let muted = rgb(0x5F6168)
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
rgb(0xF5F6FA).setFill()
NSRect(origin: .zero, size: size).fill()

centered("Drag ThunderSend to Applications", top: 18, font: .systemFont(ofSize: 22, weight: .semibold), color: ink)
centered("Install it on both Macs, then connect them with a Thunderbolt cable.", top: 50,
         font: .systemFont(ofSize: 13), color: muted)

centered("If macOS blocks the first launch", top: 250, font: .systemFont(ofSize: 15, weight: .semibold), color: ink)
centered("ThunderSend is free and not notarized by Apple, so macOS asks you to approve it once.", top: 274,
         font: .systemFont(ofSize: 13), color: muted)
centered("Try to open the app, then go to System Settings > Privacy & Security", top: 304,
         font: .systemFont(ofSize: 13, weight: .medium), color: ink)
centered("and click Open Anyway.", top: 323, font: .systemFont(ofSize: 13, weight: .medium), color: ink)
centered("Or run this in Terminal:", top: 353, font: .systemFont(ofSize: 13), color: muted)
centered("xattr -cr /Applications/ThunderSend.app", top: 373,
         font: .monospacedSystemFont(ofSize: 13, weight: .medium), color: ink)

// A cable from the app to Applications, level with the icons at 140 from the top.
let cableY = size.height - 140
let cable = NSBezierPath()
cable.move(to: NSPoint(x: 268, y: cableY))
cable.line(to: NSPoint(x: 308, y: cableY))
cable.move(to: NSPoint(x: 352, y: cableY))
cable.line(to: NSPoint(x: 390, y: cableY))
cable.lineWidth = 3
cable.lineCapStyle = .round
blue.setStroke()
cable.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: 381, y: cableY + 10))
head.line(to: NSPoint(x: 392, y: cableY))
head.line(to: NSPoint(x: 381, y: cableY - 10))
head.lineWidth = 3
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

blue.setFill()
NSBezierPath(ovalIn: NSRect(x: 310, y: cableY - 20, width: 40, height: 40)).fill()

// The bolt from the app icon, drawn in a 24 pt box with y pointing down.
let bolt = NSBezierPath()
let points = [(13.5, 2.0), (4.5, 14.0), (10.7, 14.0), (9.5, 22.0), (19.0, 9.4), (12.6, 9.4)]
for (i, p) in points.enumerated() {
    let point = NSPoint(x: 318 + p.0, y: cableY + 12 - p.1)
    if i == 0 { bolt.move(to: point) } else { bolt.line(to: point) }
}
bolt.close()
NSColor.white.setFill()
bolt.fill()

NSGraphicsContext.current = nil
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
