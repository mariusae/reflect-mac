import AppKit
import PrismCore
import ReflectUI

/// Prism ▸ Settings (⌘,): the font set, and how it is set — its faces, size,
/// line height, the space between rows, the outline's indent, the line's
/// length, the headings' size, and font smoothing. Each set keeps its own;
/// the window follows every change as it is made.
@MainActor
final class SettingsWindowController: NSWindowController {
    private weak var prism: PrismWindowController?
    private let faces = NSPopUpButton()
    private let textStyle = NSPopUpButton()
    private let headingStyle = NSPopUpButton()
    private let smoothing = NSButton(checkboxWithTitle: "Font smoothing", target: nil, action: nil)
    private let reset = NSButton(title: "Reset to Defaults", target: nil, action: nil)
    private var sliders: [Measure: (slider: NSSlider, value: NSTextField)] = [:]

    /// The settings set by a slider: its range, its steps, and how its value reads.
    private enum Measure: CaseIterable {
        case size, lineHeight, rowSpacing, indent, lineLength, headingScale

        var title: String {
            switch self {
            case .size: "Size"
            case .lineHeight: "Line height"
            case .rowSpacing: "Space between rows"
            case .indent: "Outline indent"
            case .lineLength: "Line length"
            case .headingScale: "Heading size"
            }
        }

        var range: ClosedRange<Double> {
            switch self {
            case .size: 11...28
            case .lineHeight: 1.0...2.4
            case .rowSpacing: 0...1.2
            case .indent: 0.6...3
            case .lineLength: 400...1200
            case .headingScale: 1...2.2
            }
        }

        var step: Double {
            switch self {
            case .size: 0.5
            case .lineLength: 10
            default: 0.01
            }
        }

        func text(_ value: Double) -> String {
            switch self {
            case .size: String(format: value == value.rounded() ? "%.0f pt" : "%.1f pt", value)
            case .lineLength: String(format: "%.0f pt", value)
            case .headingScale: String(format: "%.2f×", value)
            default: String(format: "%.2f em", value)
            }
        }

        func value(in settings: Typeface.Settings) -> Double {
            switch self {
            case .size: settings.size
            case .lineHeight: settings.lineHeight
            case .rowSpacing: settings.rowSpacing
            case .indent: settings.indent
            case .lineLength: settings.lineLength
            case .headingScale: settings.headingScale
            }
        }

        func set(_ value: Double, in settings: inout Typeface.Settings) {
            switch self {
            case .size: settings.size = value
            case .lineHeight: settings.lineHeight = value
            case .rowSpacing: settings.rowSpacing = value
            case .indent: settings.indent = value
            case .lineLength: settings.lineLength = value
            case .headingScale: settings.headingScale = value
            }
        }
    }

    init(prism: PrismWindowController) {
        self.prism = prism
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Typography"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        faces.target = self
        faces.action = #selector(chooseFace)
        for popup in [textStyle, headingStyle] {
            popup.target = self
            popup.action = #selector(chooseStyle)
        }
        smoothing.target = self
        smoothing.action = #selector(changeSmoothing)
        reset.target = self
        reset.action = #selector(resetFace)

        var rows: [[NSView]] = [
            [label("Font set"), faces, NSView()],
            [label("Text"), textStyle, NSView()],
            [label("Headings"), headingStyle, NSView()],
        ]
        for measure in Measure.allCases {
            let slider = NSSlider(value: measure.range.lowerBound, minValue: measure.range.lowerBound,
                                  maxValue: measure.range.upperBound, target: self, action: #selector(slide(_:)))
            slider.isContinuous = true
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            let value = NSTextField(labelWithString: "")
            value.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            value.textColor = .secondaryLabelColor
            value.widthAnchor.constraint(equalToConstant: 64).isActive = true
            sliders[measure] = (slider, value)
            rows.append([label(measure.title), slider, value])
        }
        rows.append([NSView(), smoothing, NSView()])
        rows.append([NSView(), reset, NSView()])
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        // Room between the faces and the measures.
        grid.row(at: 3).topPadding = 10
        grid.row(at: rows.count - 2).topPadding = 6
        grid.row(at: rows.count - 1).topPadding = 6
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
        ])
        window.contentView = content
        window.center()

        NotificationCenter.default.addObserver(self, selector: #selector(typographyChanged), name: .prismTypographyChanged, object: nil)
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text + ":")
        label.alignment = .right
        return label
    }

    // MARK: Showing what is set

    private var loading = false

    /// Shows how the face is set now.
    private func load() {
        guard let prism else { return }
        loading = true
        defer { loading = false }
        let face = prism.face
        faces.removeAllItems()
        for option in Typeface.available {
            faces.addItem(withTitle: option.title)
            faces.lastItem?.representedObject = option.rawValue
        }
        faces.selectItem(at: Typeface.available.firstIndex(of: face) ?? 0)
        let settings = face.settings
        fill(textStyle, face.textStyles, chosen: settings.textStyle)
        fill(headingStyle, face.headingStyles, chosen: settings.headingStyle)
        for (measure, controls) in sliders {
            let value = measure.value(in: settings)
            controls.slider.doubleValue = value
            controls.value.stringValue = measure.text(value)
        }
        smoothing.state = settings.smoothing ? .on : .off
        reset.isEnabled = settings != face.defaults
    }

    /// A family's styles to choose from — the first, its own regular, or bold.
    private func fill(_ popup: NSPopUpButton, _ styles: [String], chosen: String?) {
        popup.removeAllItems()
        popup.addItem(withTitle: popup === headingStyle ? "Family’s Bold" : "Family’s Regular")
        for style in styles {
            popup.addItem(withTitle: style)
            popup.lastItem?.representedObject = style
        }
        if let chosen, let item = popup.itemArray.first(where: { ($0.representedObject as? String) == chosen }) {
            popup.select(item)
        } else {
            popup.selectItem(at: 0)
        }
        popup.isEnabled = !styles.isEmpty
    }

    @objc private func typographyChanged() {
        guard !loading, !applying else { return }
        load()
    }

    // MARK: Changing it

    /// Whether a change made here is being passed on, not to be shown back.
    private var applying = false
    private var pending = false

    /// Changes how the face is set, and has the window follow — once a
    /// turn of the run loop, however fast a slider is dragged.
    private func change(_ edit: (inout Typeface.Settings) -> Void) {
        guard let prism, !loading else { return }
        var settings = prism.face.settings
        edit(&settings)
        prism.face.settings = settings
        reset.isEnabled = settings != prism.face.defaults
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            pending = false
            applying = true
            self.prism?.typographyChanged()
            applying = false
        }
    }

    @objc private func chooseFace() {
        guard let raw = faces.selectedItem?.representedObject as? String, let face = Typeface(rawValue: raw) else { return }
        prism?.face = face
        load()
    }

    @objc private func chooseStyle() {
        let text = textStyle.selectedItem?.representedObject as? String
        let heading = headingStyle.selectedItem?.representedObject as? String
        change { settings in
            settings.textStyle = text
            settings.headingStyle = heading
        }
    }

    @objc private func slide(_ sender: NSSlider) {
        guard let (measure, controls) = sliders.first(where: { $0.value.slider === sender }) else { return }
        let value = (sender.doubleValue / measure.step).rounded() * measure.step
        controls.value.stringValue = measure.text(value)
        change { measure.set(value, in: &$0) }
    }

    @objc private func changeSmoothing() {
        let on = smoothing.state == .on
        change { $0.smoothing = on }
    }

    @objc private func resetFace() {
        guard let prism else { return }
        prism.face.settings = prism.face.defaults
        prism.typographyChanged()
        load()
    }
}
