// Draws Prism's icon: a fan of glass cards dealt out from one corner, each a
// band of a quiet spectrum — light split, and the notes Prism deals out.
//
//   swift scripts/make-prism-icon.swift out.png [--full] [--dark | --tinted]
//   swift scripts/make-prism-icon.swift --svg dir
//   swift scripts/make-prism-icon.swift --icon Prism.icon
//
// `--full`: the whole square, for iOS, which rounds its corners itself; else
// the Mac's tile, inset, with its shadow. `--dark`: on warm black. `--tinted`:
// grey cards on black, for iOS to tint. `--glyph`: the fan alone on
// nothing, filling the square — a browser's toolbar icon. `--svg`: each card, and the ground,
// as a layer of its own, for Icon Composer to make glass of. `--icon`: the
// Mac's icon as Icon Composer has it — the cards as layers on the paper,
// which macOS draws light, dark, clear or tinted as Appearance asks: the
// paper warm black in the dark, each card its own grey, tinted.
import AppKit

let size: CGFloat = 1024
let arguments = CommandLine.arguments.dropFirst()
let full = arguments.contains("--full")
let dark = arguments.contains("--dark")
let tinted = arguments.contains("--tinted")
let glyph = arguments.contains("--glyph")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

// MARK: The fan

/// A card: how far round it is turned, how long, its colour.
struct Card {
    var angle: CGFloat
    var length: CGFloat
    var hex: UInt32
    /// Its shade of grey, tinted.
    var grey: CGFloat
}

/// Bottom to top: blue, green, amber, coral — shorter as they rise, as a
/// note's rows run to different lengths.
let cards = [
    Card(angle: 0, length: 690, hex: 0x6f97c9, grey: 0.55),
    Card(angle: 23, length: 640, hex: 0x7fae80, grey: 0.68),
    Card(angle: 46, length: 585, hex: 0xe6a452, grey: 0.82),
    Card(angle: 69, length: 520, hex: 0xe0705f, grey: 0.96),
]
let thickness: CGFloat = 176
/// Cards, not pills: their corners round, their ends square.
let corner: CGFloat = 40
/// Where they turn about: their shared, rounded end.
let pivot = NSPoint(x: 0, y: 0)

/// A card's shape before it is turned: its lower corner at the pivot, out
/// along x — so all turn about one shared corner, nothing showing behind it.
func cardRect(_ card: Card) -> NSRect {
    NSRect(x: 0, y: 0, width: card.length, height: thickness)
}

func transform(for card: Card, offset: NSPoint) -> AffineTransform {
    var t = AffineTransform(translationByX: offset.x, byY: offset.y)
    t.rotate(byDegrees: card.angle)
    return t
}

/// Where the fan goes: its bounds centred, a little low — its weight at the foot.
let offset: NSPoint = {
    var union = NSRect.null
    for card in cards {
        let path = NSBezierPath(roundedRect: cardRect(card), xRadius: corner, yRadius: corner)
        path.transform(using: transform(for: card, offset: .zero))
        union = union.union(path.bounds)
    }
    // Its weight is at the pivot, low at the left: centred by eye, not by bounds.
    return NSPoint(x: size / 2 - union.midX + 18, y: size / 2 - union.midY + 4)
}()

func cardPath(_ card: Card) -> NSBezierPath {
    let path = NSBezierPath(roundedRect: cardRect(card), xRadius: corner, yRadius: corner)
    path.transform(using: transform(for: card, offset: offset))
    return path
}

// MARK: Drawing

func drawGround(in rect: NSRect) {
    let (top, bottom): (UInt32, UInt32) = tinted ? (0x000000, 0x000000) : dark ? (0x2c2824, 0x141210) : (0xfdfbf7, 0xebe5da)
    NSGradient(starting: color(bottom), ending: color(top))!.draw(in: rect, angle: 90)
}

/// A card of glass: its colour deepening to one edge, a sheen across its
/// upper half, a bright rim — and a soft shadow on what lies under it.
func drawCard(_ card: Card) {
    let path = cardPath(card)
    // A glyph: flat colour, a hairline of the ground between cards — no
    // sheen or shadow, which at sixteen points are mud.
    if glyph {
        color(card.hex).setFill()
        path.fill()
        path.lineWidth = 22
        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        // The edge of the card over: cut a gap into what lies under it.
        NSColor.black.setStroke()
        path.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
        color(card.hex).setFill()
        path.fill()
        return
    }
    let base = tinted ? NSColor(white: card.grey, alpha: 1) : color(card.hex)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(tinted ? 0.5 : dark ? 0.45 : 0.16)
    shadow.shadowBlurRadius = 34
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    base.withAlphaComponent(0.96).setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()
    // Lighter along its length's upper side, deeper below: light through glass.
    let light = base.blended(withFraction: dark ? 0.22 : 0.38, of: .white)!
    let deep = base.blended(withFraction: 0.12, of: .black)!
    NSGradient(starting: deep, ending: light)!.draw(in: path, angle: card.angle + 90)
    // The sheen: a band of white across the card's upper part.
    let sheen = NSBezierPath(roundedRect: cardRect(card).insetBy(dx: 18, dy: 18).offsetBy(dx: 0, dy: thickness * 0.24),
                             xRadius: corner * 0.7, yRadius: corner * 0.7)
    sheen.transform(using: transform(for: card, offset: offset))
    NSGradient(starting: NSColor.white.withAlphaComponent(0), ending: NSColor.white.withAlphaComponent(dark ? 0.16 : 0.28))!
        .draw(in: sheen, angle: card.angle + 90)
    NSGraphicsContext.current?.restoreGraphicsState()

    path.lineWidth = 4
    NSColor.white.withAlphaComponent(dark ? 0.35 : 0.7).setStroke()
    path.stroke()
}

func drawFan() {
    for card in cards { drawCard(card) }
}

// MARK: Layers, for Icon Composer

func svgLayers(into folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func hex(_ value: UInt32) -> String { String(format: "#%06x", value) }
    // SVG runs y downward: the drawing's y turned over.
    func svg(_ body: String) -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
        <g transform="translate(0 1024) scale(1 -1)">\(body)</g>
        </svg>

        """
    }
    try svg("""
    <defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ebe5da"/><stop offset="1" stop-color="#fdfbf7"/></linearGradient></defs>
    <rect width="1024" height="1024" fill="url(#g)"/>
    """).write(to: folder.appendingPathComponent("0-ground.svg"), atomically: true, encoding: .utf8)
    for (i, card) in cards.enumerated() {
        let rect = cardRect(card)
        let body = """
        <g transform="translate(\(offset.x) \(offset.y)) rotate(\(card.angle))">
        <rect x="\(rect.minX)" y="\(rect.minY)" width="\(rect.width)" height="\(rect.height)" rx="\(corner)" fill="\(hex(card.hex))"/>
        </g>
        """
        try svg(body).write(to: folder.appendingPathComponent("\(i + 1)-card.svg"), atomically: true, encoding: .utf8)
    }
}

/// The whole `.icon`: its cards as layers, the front one first, on the
/// paper — light, or dark — each card its grey when the icon is tinted.
func iconBundle(at bundle: URL) throws {
    let assets = bundle.appendingPathComponent("Assets")
    try? FileManager.default.removeItem(at: bundle)
    try svgLayers(into: assets)
    // The paper is the icon's fill, not a layer: it changes with the appearance.
    try FileManager.default.removeItem(at: assets.appendingPathComponent("0-ground.svg"))
    func srgb(_ hex: UInt32) -> String {
        let c = color(hex)
        return String(format: "srgb:%.5f,%.5f,%.5f,1.00000", c.redComponent, c.greenComponent, c.blueComponent)
    }
    func grey(_ white: CGFloat) -> String { String(format: "srgb:%.5f,%.5f,%.5f,1.00000", white, white, white) }
    let layers = cards.enumerated().reversed().map { i, card in
        """
                {
                  "image-name": "\(i + 1)-card.svg",
                  "name": "Card \(i + 1)",
                  "fill-specializations": [
                    { "appearance": "tinted", "value": { "solid": "\(grey(card.grey))" } }
                  ]
                }
        """
    }.joined(separator: ",\n")
    let json = """
    {
      "fill-specializations": [
        { "value": { "linear-gradient": [ "\(srgb(0xfdfbf7))", "\(srgb(0xebe5da))" ] } },
        { "appearance": "dark", "value": { "linear-gradient": [ "\(srgb(0x2c2824))", "\(srgb(0x141210))" ] } }
      ],
      "groups": [
        {
          "name": "Fan",
          "layers": [
    \(layers)
          ],
          "shadow": { "kind": "neutral", "opacity": 0.5 },
          "translucency": { "enabled": false, "value": 0.5 }
        }
      ],
      "supported-platforms": { "squares": [ "macOS" ] }
    }

    """
    try json.write(to: bundle.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
}

if let at = arguments.firstIndex(of: "--icon") {
    let path = arguments.index(after: at) < arguments.endIndex ? arguments[arguments.index(after: at)] : "Prism.icon"
    try iconBundle(at: URL(fileURLWithPath: path))
    exit(0)
}

if let at = arguments.firstIndex(of: "--svg") {
    let folder = arguments.index(after: at) < arguments.endIndex ? arguments[arguments.index(after: at)] : "PrismIcon"
    try svgLayers(into: URL(fileURLWithPath: folder))
    exit(0)
}

// MARK: The picture

let output = arguments.first { !$0.hasPrefix("--") } ?? "prism-icon-1024.png"
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    if glyph {
        // The fan grown to fill the square, a margin about it, on nothing.
        let bounds = cards.map { cardPath($0).bounds }.reduce(NSRect.null) { $0.union($1) }
        let scale = size * 0.94 / max(bounds.width, bounds.height)
        let grow = NSAffineTransform()
        grow.translateX(by: size / 2, yBy: size / 2)
        grow.scale(by: scale)
        grow.translateX(by: -bounds.midX, yBy: -bounds.midY)
        grow.concat()
        drawFan()
        return true
    }
    let inset: CGFloat = full ? 0 : 100
    let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let squircle = NSBezierPath(roundedRect: tile, xRadius: full ? 0 : 185, yRadius: full ? 0 : 185)
    if !full {
        // The Mac's tile, lifted off the desktop.
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        color(0xfdfbf7).setFill()
        squircle.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
    squircle.addClip()
    drawGround(in: tile)
    // On the Mac's smaller tile, the fan drawn for the square, scaled to it.
    if !full {
        let scale = NSAffineTransform()
        scale.translateX(by: size / 2, yBy: size / 2)
        scale.scale(by: (size - 2 * inset) / size)
        scale.translateX(by: -size / 2, yBy: -size / 2)
        scale.concat()
    }
    drawFan()
    return true
}

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("could not draw the icon") }
try png.write(to: URL(fileURLWithPath: output))
