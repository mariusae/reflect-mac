// Draws the app icon: a page of outline, bullets and all, on a warm squircle.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let inset: CGFloat = 100
    let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let squircle = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSGradient(starting: NSColor(calibratedRed: 0.98, green: 0.55, blue: 0.25, alpha: 1),
               ending: NSColor(calibratedRed: 0.82, green: 0.26, blue: 0.20, alpha: 1))!
        .draw(in: squircle, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // The page.
    let page = NSRect(x: 270, y: 210, width: 440, height: 580)
    NSGraphicsContext.current?.saveGraphicsState()
    let pageShadow = NSShadow()
    pageShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    pageShadow.shadowBlurRadius = 30
    pageShadow.shadowOffset = NSSize(width: 0, height: -12)
    pageShadow.set()
    NSColor(calibratedWhite: 0.99, alpha: 1).setFill()
    NSBezierPath(roundedRect: page, xRadius: 28, yRadius: 28).fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // A date, and an outline under it.
    NSColor(calibratedRed: 0.82, green: 0.26, blue: 0.20, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 320, y: 690, width: 230, height: 36), xRadius: 18, yRadius: 18).fill()
    for (index, row) in [(0, 300.0), (1, 240), (1, 200), (0, 280), (1, 220), (2, 150)].enumerated() {
        let y = 612 - CGFloat(index) * 66
        let x = 330 + CGFloat(row.0) * 44
        NSColor(calibratedWhite: 0.45, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 7, y: y - 1, width: 18, height: 18)).fill()
        NSColor(calibratedWhite: 0.75, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: x + 28, y: y, width: row.1 - CGFloat(row.0) * 30, height: 16), xRadius: 8, yRadius: 8).fill()
    }
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
