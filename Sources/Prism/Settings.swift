import AppKit
import PrismCore
import ReflectCore
import ReflectUI

/// Prism ▸ Settings (⌘,): the style notes are set in — Ideal Sans, New
/// York, the system's — and how large. Each style is set as it comes; the
/// window follows every change as it is made.
@MainActor
final class SettingsWindowController: NSWindowController {
    private weak var prism: Session?
    private var choices: [(face: Typeface, button: NSButton)] = []
    private let size = NSSlider(value: 15, minValue: 11, maxValue: 26, target: nil, action: nil)
    private let sizeValue = NSTextField(labelWithString: "")
    private let reset = NSButton(title: "Actual Size", target: nil, action: nil)

    init(session prism: Session) {
        self.prism = prism
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Typography"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let styles = NSStackView()
        styles.orientation = .vertical
        styles.alignment = .leading
        styles.spacing = 10
        for face in Typeface.available {
            let button = NSButton(radioButtonWithTitle: face.title, target: self, action: #selector(chooseFace(_:)))
            button.font = face.font(size: 15, weight: .medium)
            let detail = NSTextField(labelWithString: face.detail)
            detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            detail.textColor = .secondaryLabelColor
            let pair = NSStackView(views: [button, detail])
            pair.orientation = .vertical
            pair.alignment = .leading
            pair.spacing = 2
            // Under the button's words, not its circle.
            detail.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 20).isActive = true
            styles.addArrangedSubview(pair)
            choices.append((face, button))
        }
        size.target = self
        size.action = #selector(slide)
        size.isContinuous = true
        size.numberOfTickMarks = 0
        size.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        sizeValue.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        sizeValue.textColor = .secondaryLabelColor
        sizeValue.widthAnchor.constraint(equalToConstant: 56).isActive = true
        reset.target = self
        reset.action = #selector(resetSize)

        let grid = NSGridView(views: [
            [label("Style"), styles, NSView()],
            [label("Size"), size, sizeValue],
            [NSView(), reset, NSView()],
        ])
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.row(at: 0).yPlacement = .top
        grid.row(at: 1).topPadding = 8
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

    private func load() {
        guard let prism else { return }
        loading = true
        defer { loading = false }
        for (face, button) in choices { button.state = face == prism.face ? .on : .off }
        size.doubleValue = Double(prism.size)
        sizeValue.stringValue = Self.text(Double(prism.size))
        reset.isEnabled = Double(prism.size) != prism.face.defaults.size
    }

    private static func text(_ value: Double) -> String {
        String(format: value == value.rounded() ? "%.0f pt" : "%.1f pt", value)
    }

    @objc private func typographyChanged() {
        guard !loading else { return }
        load()
    }

    // MARK: Changing it

    @objc private func chooseFace(_ sender: NSButton) {
        guard let face = choices.first(where: { $0.button === sender })?.face else { return }
        prism?.face = face
        load()
    }

    @objc private func slide() {
        let value = (size.doubleValue * 2).rounded() / 2
        sizeValue.stringValue = Self.text(value)
        prism?.size = CGFloat(value)
    }

    @objc private func resetSize() {
        guard let prism else { return }
        prism.size = CGFloat(prism.face.defaults.size)
        load()
    }
}
