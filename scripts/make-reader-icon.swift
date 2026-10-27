// Draws Prism Reader's icon: Prism's glass and spectrum made a page to
// read — a sheet of frosted glass, its lines of text bands of the spectrum,
// a ribbon marking the place, the next page waiting under it.
//
//   swift scripts/make-reader-icon.swift out.png [--dark | --tinted]
//
// The whole square, for iOS, which rounds its corners itself. `--dark`: on
// warm black. `--tinted`: greys on black, for iOS to tint.
import AppKit

let size: CGFloat = 1024
let arguments = CommandLine.arguments.dropFirst()
let dark = arguments.contains("--dark")
let tinted = arguments.contains("--tinted")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// Prism's spectrum, as its cards have it, and each one's grey, tinted.
let coral = (hex: UInt32(0xe0705f), grey: CGFloat(0.96))
let amber = (hex: UInt32(0xe6a452), grey: CGFloat(0.82))
let green = (hex: UInt32(0x7fae80), grey: CGFloat(0.68))
let blue = (hex: UInt32(0x6f97c9), grey: CGFloat(0.55))

func shade(_ band: (hex: UInt32, grey: CGFloat)) -> NSColor {
    tinted ? NSColor(white: band.grey, alpha: 1) : color(band.hex)
}

// MARK: The page

/// The page: upright, a little turned, as a sheet lying on a desk.
let page = NSRect(x: 0, y: 0, width: 600, height: 730)
let pageCorner: CGFloat = 56
let pageTurn: CGFloat = -5
/// Where it sits: centred, its weight a touch low.
let pageCentre = NSPoint(x: size / 2 + 6, y: size / 2 - 14)

func placed(_ rect: NSRect, turn: CGFloat, centre: NSPoint, corner: CGFloat) -> NSBezierPath {
    let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    var t = AffineTransform(translationByX: centre.x, byY: centre.y)
    t.rotate(byDegrees: turn)
    t.translate(x: -page.width / 2, y: -page.height / 2)
    path.transform(using: t)
    return path
}

/// Something on the page, turned with it.
func onPage(_ rect: NSRect, corner: CGFloat) -> NSBezierPath {
    placed(rect, turn: pageTurn, centre: pageCentre, corner: corner)
}

// MARK: Drawing

func drawGround(in rect: NSRect) {
    let (top, bottom): (UInt32, UInt32) = tinted ? (0x000000, 0x000000) : dark ? (0x2c2824, 0x141210) : (0xfdfbf7, 0xebe5da)
    NSGradient(starting: color(bottom), ending: color(top))!.draw(in: rect, angle: 90)
}

/// A sheet of glass: frosted white — or smoky, in the dark — a soft shadow
/// on what lies under it, a sheen down from its top, a bright rim.
func drawSheet(_ path: NSBezierPath, under: Bool) {
    let paper: NSColor = tinted ? NSColor(white: under ? 0.22 : 0.3, alpha: 1)
        : dark ? color(under ? 0x3a3530 : 0x4a443e) : color(under ? 0xf3eee6 : 0xfffdf9)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(tinted ? 0.5 : dark ? 0.45 : under ? 0.1 : 0.16)
    shadow.shadowBlurRadius = 40
    shadow.shadowOffset = NSSize(width: 0, height: -16)
    shadow.set()
    paper.withAlphaComponent(0.97).setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()
    let light = paper.blended(withFraction: dark || tinted ? 0.12 : 0.6, of: .white)!
    let deep = paper.blended(withFraction: dark || tinted ? 0.1 : 0.05, of: .black)!
    NSGradient(starting: deep, ending: light)!.draw(in: path, angle: 90 + pageTurn)
    NSGraphicsContext.current?.restoreGraphicsState()

    path.lineWidth = 4
    NSColor.white.withAlphaComponent(dark || tinted ? 0.3 : 0.9).setStroke()
    path.stroke()
}

/// A line of text as a band of glass, its colour deepening to its foot, a
/// sheen along its top — Prism's cards, small.
func drawLine(_ path: NSBezierPath, _ base: NSColor, sheen: NSBezierPath) {
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(tinted ? 0.4 : dark ? 0.35 : 0.1)
    shadow.shadowBlurRadius = 10
    shadow.shadowOffset = NSSize(width: 0, height: -4)
    shadow.set()
    base.withAlphaComponent(0.96).setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()
    let light = base.blended(withFraction: dark ? 0.22 : 0.38, of: .white)!
    let deep = base.blended(withFraction: 0.12, of: .black)!
    NSGradient(starting: deep, ending: light)!.draw(in: path, angle: 90 + pageTurn)
    NSGradient(starting: NSColor.white.withAlphaComponent(0), ending: NSColor.white.withAlphaComponent(dark ? 0.16 : 0.28))!
        .draw(in: sheen, angle: 90 + pageTurn)
    NSGraphicsContext.current?.restoreGraphicsState()

    path.lineWidth = 3
    NSColor.white.withAlphaComponent(dark ? 0.3 : 0.6).setStroke()
    path.stroke()
}

/// The ribbon marking the place: hanging from the page's top edge, its
/// foot cut in a V.
func ribbonPath() -> NSBezierPath {
    let width: CGFloat = 96, x = page.maxX - 154, top = page.maxY + 36, foot = page.maxY - 196, notch: CGFloat = 40
    let path = NSBezierPath()
    path.move(to: NSPoint(x: x, y: top))
    path.line(to: NSPoint(x: x + width, y: top))
    path.line(to: NSPoint(x: x + width, y: foot))
    path.line(to: NSPoint(x: x + width / 2, y: foot + notch))
    path.line(to: NSPoint(x: x, y: foot))
    path.close()
    var t = AffineTransform(translationByX: pageCentre.x, byY: pageCentre.y)
    t.rotate(byDegrees: pageTurn)
    t.translate(x: -page.width / 2, y: -page.height / 2)
    path.transform(using: t)
    return path
}

func drawPage() {
    // The next page, under: turned the other way, peeking out.
    drawSheet(placed(page, turn: 4, centre: NSPoint(x: pageCentre.x + 22, y: pageCentre.y + 10), corner: pageCorner), under: true)
    drawSheet(onPage(page, corner: pageCorner), under: false)

    // Its lines, the spectrum's: a heading's, then a paragraph running to
    // different lengths, its last short.
    let margin: CGFloat = 74
    let lines: [(band: (hex: UInt32, grey: CGFloat), y: CGFloat, length: CGFloat, height: CGFloat)] = [
        (coral, 572, 270, 70),
        (amber, 456, 452, 52),
        (green, 366, 420, 52),
        (blue, 276, 452, 52),
        (blue, 186, 260, 52),
    ]
    for line in lines {
        let rect = NSRect(x: margin, y: line.y, width: line.length, height: line.height)
        let sheen = onPage(rect.insetBy(dx: 6, dy: 6).offsetBy(dx: 0, dy: line.height * 0.2), corner: line.height * 0.35)
        drawLine(onPage(rect, corner: line.height / 2), shade(line.band), sheen: sheen)
    }

    // The ribbon, over the page's top: Prism's coral, deepened.
    let ribbon = ribbonPath()
    let base = tinted ? NSColor(white: 0.9, alpha: 1) : color(0xd65f4e)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(tinted ? 0.5 : dark ? 0.4 : 0.18)
    shadow.shadowBlurRadius = 16
    shadow.shadowOffset = NSSize(width: 2, height: -6)
    shadow.set()
    base.setFill()
    ribbon.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGraphicsContext.current?.saveGraphicsState()
    ribbon.addClip()
    NSGradient(starting: base.blended(withFraction: 0.15, of: .black)!, ending: base.blended(withFraction: 0.3, of: .white)!)!
        .draw(in: ribbon, angle: pageTurn)
    NSGraphicsContext.current?.restoreGraphicsState()
    ribbon.lineWidth = 3
    NSColor.white.withAlphaComponent(dark ? 0.3 : 0.55).setStroke()
    ribbon.stroke()
}

// MARK: The picture

let output = arguments.first { !$0.hasPrefix("--") } ?? "reader-icon-1024.png"
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    drawGround(in: rect)
    drawPage()
    return true
}

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("could not draw the icon") }
try png.write(to: URL(fileURLWithPath: output))
