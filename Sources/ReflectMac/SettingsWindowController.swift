import AppKit

/// The app's settings (⌘,), in the Mac's manner: a pane a tab, changes
/// taking at once. Its first: Typography.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let typography = NSTabViewItem(viewController: TypographySettingsController())
        typography.label = "Typography"
        typography.image = NSImage(systemSymbolName: "textformat", accessibilityDescription: "Typography")
        tabs.addTabViewItem(typography)
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = "Typography"
        window.toolbarStyle = .preference
        window.setFrameAutosaveName("Settings")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The typefaces, the size and the spacing of the notes, each change shown
/// in every note as it is made — and in a sample, here.
final class TypographySettingsController: NSViewController {
    private let presets = NSPopUpButton()
    private let body = NSPopUpButton()
    private let heading = NSPopUpButton()
    private let monospace = NSPopUpButton()
    /// The face chosen in each family.
    private let bodyStyle = NSPopUpButton()
    private let headingStyle = NSPopUpButton()
    private let monospaceStyle = NSPopUpButton()
    private var sliders: [Slider] = []
    private let preview = NSTextField(labelWithString: "")
    private let previewBox = NSBox()

    /// A setting set by a slider: what it is, how it reads, where it goes.
    private struct Slider {
        let control: NSSlider
        let value: NSTextField
        let format: (CGFloat) -> String
        let set: (inout Typography, CGFloat) -> Void
        let get: (Typography) -> CGFloat
    }

    override func loadView() {
        let grid = NSGridView()
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false

        func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.alignment = .right
            return field
        }
        func row(_ title: String, _ control: NSView, _ trailing: NSView? = nil) {
            let row = grid.addRow(with: [label(title), control, trailing ?? NSView()])
            row.yPlacement = .center
        }

        // Shown when the settings are no preset; choosing it changes nothing.
        presets.addItem(withTitle: "Custom")
        presets.menu?.addItem(.separator())
        for preset in Typography.presets { presets.addItem(withTitle: preset.name) }
        presets.target = self
        presets.action = #selector(presetChosen(_:))
        presets.widthAnchor.constraint(equalToConstant: 240).isActive = true
        row("Preset:", presets)
        grid.addRow(with: [NSGridCell.emptyContentView]).height = 6

        let families = Typography.families
        for (popup, list) in [(body, families), (heading, families), (monospace, Typography.monospaceFamilies)] {
            popup.addItem(withTitle: popup === monospace ? "System Monospaced" : "System Font")
            popup.menu?.addItem(.separator())
            for family in list {
                popup.addItem(withTitle: family)
                // Each family shown in itself.
                if let face = Typography.Face.regular(in: Typography.Face.all(in: family)),
                   let font = NSFont(name: face.name, size: NSFont.systemFontSize) {
                    popup.lastItem?.attributedTitle = NSAttributedString(string: family, attributes: [.font: font])
                }
            }
            popup.target = self
            popup.action = #selector(fontChanged(_:))
            popup.widthAnchor.constraint(equalToConstant: 200).isActive = true
        }
        for style in [bodyStyle, headingStyle, monospaceStyle] {
            style.target = self
            style.action = #selector(styleChanged(_:))
            style.widthAnchor.constraint(equalToConstant: 150).isActive = true
        }
        // A family, and beside it its face — as the Font panel has them.
        func fontRow(_ title: String, _ family: NSPopUpButton, _ style: NSPopUpButton) {
            let pair = NSStackView(views: [family, style])
            pair.spacing = 8
            let row = grid.addRow(with: [label(title), pair, NSGridCell.emptyContentView])
            row.yPlacement = .center
            row.mergeCells(in: NSRange(location: 1, length: 2))
        }
        fontRow("Body:", body, bodyStyle)
        fontRow("Headings:", heading, headingStyle)
        fontRow("Code:", monospace, monospaceStyle)
        grid.addRow(with: [NSGridCell.emptyContentView]).height = 6

        func slider(_ title: String, _ range: ClosedRange<Double>, step: Double?, format: @escaping (CGFloat) -> String,
                    get: @escaping (Typography) -> CGFloat, set: @escaping (inout Typography, CGFloat) -> Void) {
            let control = NSSlider(value: range.lowerBound, minValue: range.lowerBound, maxValue: range.upperBound,
                                   target: self, action: #selector(sliderChanged(_:)))
            if let step {
                control.numberOfTickMarks = Int((range.upperBound - range.lowerBound) / step) + 1
                control.allowsTickMarkValuesOnly = true
                control.tickMarkPosition = .below
            }
            control.isContinuous = true
            control.widthAnchor.constraint(equalToConstant: 240).isActive = true
            let value = NSTextField(labelWithString: "")
            value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            value.textColor = .secondaryLabelColor
            value.widthAnchor.constraint(equalToConstant: 56).isActive = true
            sliders.append(Slider(control: control, value: value, format: format, set: set, get: get))
            row(title, control, value)
        }
        slider("Text size:", Double(Typography.sizes.lowerBound)...Double(Typography.sizes.upperBound), step: 1,
               format: { "\(Int($0)) pt" }, get: { $0.size }, set: { $0.size = $1.rounded() })
        slider("Line height:", 1.0...2.0, step: 0.02, format: { String(format: "%.2f×", $0) },
               get: { $0.lineHeight }, set: { $0.lineHeight = ($1 * 50).rounded() / 50 })
        slider("Between rows:", 0...1.2, step: 0.05, format: { String(format: "%.2f em", $0) },
               get: { $0.rowSpacing }, set: { $0.rowSpacing = ($1 * 20).rounded() / 20 })
        slider("Heading size:", 1.0...2.2, step: 0.05, format: { String(format: "%.2f×", $0) },
               get: { $0.headingScale }, set: { $0.headingScale = ($1 * 20).rounded() / 20 })
        slider("Line length:", 480...1200, step: 20, format: { "\(Int($0)) pt" },
               get: { $0.lineLength }, set: { $0.lineLength = ($1 / 20).rounded() * 20 })
        grid.column(at: 0).xPlacement = .trailing

        previewBox.title = "Preview"
        previewBox.titlePosition = .noTitle
        previewBox.contentViewMargins = NSSize(width: 14, height: 12)
        preview.maximumNumberOfLines = 0
        preview.lineBreakMode = .byWordWrapping
        preview.preferredMaxLayoutWidth = 420
        previewBox.contentView = preview
        previewBox.translatesAutoresizingMaskIntoConstraints = false

        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults(_:)))
        reset.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        for view in [grid, previewBox, reset] as [NSView] { container.addSubview(view) }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            previewBox.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 18),
            previewBox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            previewBox.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            previewBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            reset.topAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: 16),
            reset.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            reset.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            container.widthAnchor.constraint(equalToConstant: 520),
        ])
        view = container
        show(.current)
        NotificationCenter.default.addObserver(self, selector: #selector(changedElsewhere(_:)), name: Typography.didChange, object: nil)
    }

    // MARK: Showing

    /// Sets every control to some settings, and the sample to them.
    /// Fills a style menu with a family's faces, each shown in itself, and
    /// chooses the one in use — for the system's font, just its own.
    private func showStyles(_ popup: NSPopUpButton, family: String?, face: String?, heading: Bool) {
        popup.removeAllItems()
        guard let family else {
            popup.addItem(withTitle: heading ? "Bold" : "Regular")
            popup.isEnabled = false
            return
        }
        popup.isEnabled = true
        let faces = Typography.Face.all(in: family)
        for face in faces {
            popup.addItem(withTitle: face.style)
            popup.lastItem?.representedObject = face.name
            if let font = NSFont(name: face.name, size: NSFont.systemFontSize) {
                popup.lastItem?.attributedTitle = NSAttributedString(string: face.style, attributes: [.font: font])
            }
        }
        let current = face.flatMap { name in faces.first { $0.name == name } }
            ?? (heading ? Typography.Face.bold(in: faces) : Typography.Face.regular(in: faces))
        if let current, let index = faces.firstIndex(of: current) { popup.selectItem(at: index) }
    }

    private func show(_ typography: Typography) {
        // The preset these are, or Custom.
        if let name = typography.preset { presets.selectItem(withTitle: name) } else { presets.selectItem(at: 0) }
        for (popup, family) in [(body, typography.bodyFamily), (heading, typography.headingFamily), (monospace, typography.monospaceFamily)] {
            if let family, popup.item(withTitle: family) != nil { popup.selectItem(withTitle: family) } else { popup.selectItem(at: 0) }
        }
        showStyles(bodyStyle, family: typography.bodyFamily, face: typography.bodyFace, heading: false)
        showStyles(headingStyle, family: typography.headingFamily, face: typography.headingFace, heading: true)
        showStyles(monospaceStyle, family: typography.monospaceFamily, face: typography.monospaceFace, heading: false)
        for slider in sliders {
            slider.control.doubleValue = Double(slider.get(typography))
            slider.value.stringValue = slider.format(slider.get(typography))
        }
        showPreview(typography)
    }

    /// A few rows set as the notes will be: a heading, text, a nested
    /// row, and code.
    private func showPreview(_ typography: Typography) {
        let metrics = OutlineMetrics(typography: typography)
        let text = NSMutableAttributedString()
        func paragraph(indent: CGFloat = 0, after: CGFloat, bullet: Bool = true) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = typography.lineHeight
            style.paragraphSpacing = after
            // The bullet hangs; wrapped lines line up with the text.
            style.firstLineHeadIndent = indent
            style.headIndent = indent + (bullet ? 16 : 0)
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 16)]
            return style
        }
        // Set smaller than in a note, so the sample fits; the proportions hold.
        let scale = min(1, 14 / typography.size)
        func scaled(_ font: NSFont) -> NSFont { font.withSize(round(font.pointSize * scale)) }
        let spacing = metrics.rowSpacing * scale
        text.append(NSAttributedString(string: "Reading Notes\n", attributes: [
            .font: scaled(metrics.heading(1)), .paragraphStyle: paragraph(after: spacing + 4, bullet: false), .foregroundColor: NSColor.labelColor]))
        text.append(NSAttributedString(string: "•\tThe quick brown fox jumps over the lazy dog, and keeps on going to show how lines wrap.\n", attributes: [
            .font: scaled(metrics.body), .paragraphStyle: paragraph(after: spacing), .foregroundColor: NSColor.labelColor]))
        text.append(NSAttributedString(string: "•\tA nested thought, with ", attributes: [
            .font: scaled(metrics.body), .paragraphStyle: paragraph(indent: 18, after: spacing), .foregroundColor: NSColor.labelColor]))
        text.append(NSAttributedString(string: "some_code()", attributes: [
            .font: scaled(metrics.code), .paragraphStyle: paragraph(indent: 18, after: spacing), .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.15)]))
        text.append(NSAttributedString(string: " in it.", attributes: [
            .font: scaled(metrics.body), .paragraphStyle: paragraph(indent: 18, after: spacing), .foregroundColor: NSColor.labelColor]))
        preview.attributedStringValue = text
    }

    // MARK: Changing

    private func change(_ edit: (inout Typography) -> Void) {
        var typography = Typography.current
        edit(&typography)
        guard typography != .current else { return }
        Typography.current = typography
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        let family = sender.indexOfSelectedItem == 0 ? nil : sender.titleOfSelectedItem
        change { typography in
            // A new family starts at its own regular (for headings, bold).
            if sender === body { typography.bodyFamily = family; typography.bodyFace = nil }
            if sender === heading { typography.headingFamily = family; typography.headingFace = nil }
            if sender === monospace { typography.monospaceFamily = family; typography.monospaceFace = nil }
        }
    }

    @objc private func styleChanged(_ sender: NSPopUpButton) {
        let face = sender.selectedItem?.representedObject as? String
        change { typography in
            if sender === bodyStyle { typography.bodyFace = face }
            if sender === headingStyle { typography.headingFace = face }
            if sender === monospaceStyle { typography.monospaceFace = face }
        }
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard let slider = sliders.first(where: { $0.control === sender }) else { return }
        change { slider.set(&$0, CGFloat(sender.doubleValue)) }
    }

    @objc private func presetChosen(_ sender: NSPopUpButton) {
        guard let preset = Typography.presets.first(where: { $0.name == sender.titleOfSelectedItem }) else { return }
        Typography.current = preset.typography
    }

    @objc private func restoreDefaults(_ sender: Any?) {
        Typography.current = .defaults
    }

    @objc private func changedElsewhere(_ notification: Notification) {
        // ⌘+ and ⌘− change the size too.
        show(.current)
    }
}
