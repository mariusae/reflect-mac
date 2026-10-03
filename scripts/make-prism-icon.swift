// Draws Prism's icon: a beam of light through a prism, coming out the other
// side as a spectrum that turns into lines — of a note, of a timeline.
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "prism-icon-1024.png"
/// `--full`: the whole square, for iOS, which rounds its corners itself.
let full = CommandLine.arguments.contains("--full")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let inset: CGFloat = full ? 0 : 100
    let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let squircle = NSBezierPath(roundedRect: tile, xRadius: full ? 0 : 185, yRadius: full ? 0 : 185)

    // The tile: warm black, a little lighter at the top.
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSGradient(starting: color(0x2c2824), ending: color(0x131110))!.draw(in: squircle, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()
    squircle.addClip()
    // Full-bleed, the drawing is made for the inset tile: grown to fill the square.
    if full {
        let grow = NSAffineTransform()
        grow.translateX(by: size / 2, yBy: size / 2)
        grow.scale(by: size / (size - 200))
        grow.translateX(by: -size / 2, yBy: -size / 2)
        grow.concat()
    }

    // The prism.
    let apex = NSPoint(x: 455, y: 735), left = NSPoint(x: 265, y: 405), right = NSPoint(x: 645, y: 405)
    func along(_ a: NSPoint, _ b: NSPoint, _ t: CGFloat) -> NSPoint { NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
    let entry = along(left, apex, 0.5), exit = along(apex, right, 0.5)
    let prism = NSBezierPath()
    prism.move(to: apex)
    prism.line(to: right)
    prism.line(to: left)
    prism.close()
    prism.lineJoinStyle = .round

    // The beam coming in: warm white, with a glow.
    let beam = NSBezierPath()
    beam.move(to: NSPoint(x: inset - 20, y: entry.y - 150))
    beam.line(to: entry)
    beam.lineCapStyle = .round
    NSGraphicsContext.current?.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = color(0xfaf7f2, 0.7)
    glow.shadowBlurRadius = 22
    glow.set()
    beam.lineWidth = 12
    color(0xfaf7f2).setStroke()
    beam.stroke()
    NSGraphicsContext.current?.restoreGraphicsState()

    // The spectrum going out: each colour fans to a line of its own, and
    // runs on as a line of a page — each as long as a line of writing.
    let spectrum: [(UInt32, CGFloat)] = [(0xe5484d, 830), (0xf28b38, 770), (0xf2c94c, 860), (0x5fbf77, 740), (0x4c8fe8, 810),
                                         (0x8a6be0, 700)]
    let top: CGFloat = 655, step: CGFloat = 46, turn: CGFloat = 735
    for (i, band) in spectrum.enumerated().reversed() {
        let y = top - CGFloat(i) * step
        let ray = NSBezierPath()
        ray.move(to: exit)
        ray.curve(to: NSPoint(x: turn, y: y), controlPoint1: NSPoint(x: exit.x + 90, y: exit.y + (y - exit.y) * 0.55),
                  controlPoint2: NSPoint(x: turn - 60, y: y))
        ray.line(to: NSPoint(x: band.1, y: y))
        ray.lineWidth = 20
        ray.lineCapStyle = .round
        ray.lineJoinStyle = .round
        color(band.0).setStroke()
        ray.stroke()
    }

    // The glass, over where the light meets it; inside, the beam spreading.
    color(0x1d1b18, 0.92).setFill()
    prism.fill()
    let inside = NSBezierPath()
    inside.move(to: entry)
    inside.line(to: along(exit, apex, 0.08))
    inside.line(to: along(exit, right, 0.08))
    inside.close()
    color(0xfaf7f2, 0.16).setFill()
    inside.fill()
    prism.lineWidth = 14
    color(0xece6dc).setStroke()
    prism.stroke()
    return true
}

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("could not draw the icon") }
try png.write(to: URL(fileURLWithPath: output))
