import AppKit

/// A small popover for where a link goes, which the text does not show.
@MainActor
final class LinkEditor: NSViewController, NSTextFieldDelegate {
    private let field = NSTextField()
    private let caption: String
    private let initial: String
    private let commit: (String) -> Void
    private weak var popover: NSPopover?

    static func show(title: String, value: String, relativeTo rect: NSRect, of view: NSView,
                     commit: @escaping (String) -> Void) {
        let editor = LinkEditor(caption: title, value: value, commit: commit)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = editor
        editor.popover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        view.window?.makeFirstResponder(editor.field)
    }

    private init(caption: String, value: String, commit: @escaping (String) -> Void) {
        self.caption = caption
        initial = value
        self.commit = commit
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let label = NSTextField(labelWithString: caption + ":")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        field.stringValue = initial
        field.placeholderString = caption == "Link" ? "https://" : "Note title"
        field.target = self
        field.action = #selector(done(_:))
        field.delegate = self
        let stack = NSStackView(views: [label, field])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        view = stack
    }

    @objc private func done(_ sender: Any?) {
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        popover?.close()
        if !value.isEmpty && value != initial { commit(value) }
    }
}
