import AppKit
import GraphKit
import ReflectCore

/// Prism's outline editor, for another app to edit a page's body in —
/// Markdown in, Markdown out — its queries, embeds and callouts drawn as
/// Prism draws them. It takes the height its text needs: put it in
/// something that scrolls.
@MainActor
public final class PageOutlineEditor: NSView, NSTextViewDelegate, OutlineTextViewNavigator {
    /// Told the body's Markdown as it is edited.
    public var onChange: ((String) -> Void)?
    /// Told a `[[link]]`'s title when it is followed, and any other address.
    public var onOpenTitle: ((String) -> Void)?
    public var onOpenURL: ((URL) -> Void)?
    /// Told when the height it needs changes.
    public var onHeightChange: (() -> Void)?
    /// Rows folded or unfolded: the folds now, to keep — as Prism keeps a
    /// note's, apart from its text.
    public var onFoldsChange: (([OutlineFolds.Mark]) -> Void)?
    /// Told when the caret comes into the editor, and when it leaves.
    public var onFocusChange: ((Bool) -> Void)? {
        get { editor.onFirstResponderChange }
        set { editor.onFirstResponderChange = newValue }
    }

    private let editor: OutlineTextView
    /// What the editor does not show — a body's trailing gap — kept as it was.
    private var shell = Outline(rows: [])
    public private(set) var text = ""
    private let undo = UndoManager()

    /// Whether a body can be edited as an outline and written back as it
    /// was: what Prism would show read-only cannot.
    nonisolated public static func canEdit(_ text: String) -> Bool {
        !text.contains(OutlineText.lineSeparator) && OutlineMarkdown.serialize(OutlineMarkdown.parse(text)) == text
    }

    /// Where a top-level row's words start, in from the editor's edge: for
    /// what is drawn in line with them, such as a placeholder.
    public static func textIndent(fontSize: CGFloat = 15) -> CGFloat {
        OutlineMetrics(fontSize: fontSize).textIndent(for: .blank)
    }

    /// The notes `[[` completes from, for every outline editor.
    public static func completeLinks(from index: NoteIndex) {
        LinkCompletion.sources = SearchSources(index: index)
    }

    /// `root`: the graph's folder, where its pictures are.
    public init(text: String, fontSize: CGFloat = 15, root: URL? = nil) {
        editor = OutlineTextView(metrics: OutlineMetrics(fontSize: fontSize))
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 40))
        editor.delegate = self
        editor.navigator = self
        if let root { editor.images = ImageStore(root: root) }
        editor.onPicturesChanged = { [weak self] in self?.heightChanged() }
        addSubview(editor)
        load(text)
        NotificationCenter.default.addObserver(self, selector: #selector(storageEdited), name: NSTextStorage.didProcessEditingNotification, object: editor.textStorage)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    /// Shows a body, forgetting what was edited before — unless it is what
    /// is shown — its rows folded as `folds` say.
    public func load(_ text: String, folds: [OutlineFolds.Mark] = []) {
        guard text != self.text || editor.textStorage?.length == 0 else { return }
        self.text = text
        var outline = OutlineMarkdown.parse(text)
        let rows = outline.rows
        outline.rows = []
        shell = outline
        editor.load(rows.isEmpty ? [.blank] : folds.isEmpty ? rows : OutlineFolds.apply(folds, to: rows))
        shownFolds = OutlineFolds.marks(editor.fullRows)
        heightChanged()
    }

    /// The folds as last told.
    private var shownFolds: [OutlineFolds.Mark] = []

    /// Its rows folded as `folds` say, the words left as they are: folded
    /// elsewhere — in another window, on another device.
    public func refold(_ folds: [OutlineFolds.Mark]) {
        guard folds != shownFolds else { return }
        editor.load(OutlineFolds.apply(folds, to: Row.unfold(editor.fullRows)))
        shownFolds = OutlineFolds.marks(editor.fullRows)
        heightChanged()
    }

    /// The graph the page is in, and its title: queries are asked of it —
    /// again, `refreshing`, when the graph changed.
    public func setGraph(_ pages: PageIndex?, title: String, refreshing: Bool = false) {
        let graph = pages.map { OutlineGraph(pages: $0, title: title) }
        guard refreshing || graph?.pages !== editor.graph?.pages || graph?.title != editor.graph?.title else { return }
        editor.graph = graph
    }

    /// The caret put in, at the end.
    public func focus() {
        window?.makeFirstResponder(editor)
        editor.enter(from: .bottom, x: .greatestFiniteMagnitude, scrolling: false)
    }

    /// Whether the caret is in it.
    public var isFocused: Bool { window?.firstResponder === editor }

    /// The caret taken out.
    public func unfocus() {
        if isFocused { window?.makeFirstResponder(nil) }
    }

    // MARK: Size

    /// The height its text takes at a width.
    public func height(forWidth width: CGFloat) -> CGFloat {
        guard let layout = editor.layoutManager, let container = editor.textContainer else { return 0 }
        if abs(container.size.width - width) > 0.5 {
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
        var height = layout.usedRect(for: container).height
        if layout.extraLineFragmentTextContainer != nil { height -= layout.extraLineFragmentRect.height }
        return ceil(max(height, editor.metrics.fontSize * 1.4))
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 600))
    }

    public override func layout() {
        super.layout()
        let height = height(forWidth: bounds.width)
        editor.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
        if abs(height - bounds.height) > 0.5 { checkHeight() }
    }

    private func heightChanged() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        onHeightChange?()
    }

    /// Whatever changed the words or how they look — words dictated and
    /// not yet taken, put in by the system without an edit told; a row
    /// restyled — the height looked at again, once it is done.
    @objc private func storageEdited() { checkHeight() }

    private var checking = false
    /// The height last asked for that was not yet given.
    private var asked: CGFloat = -1

    /// The height told again when the words no longer fit what was given
    /// them — once for each height, should it not be given.
    private func checkHeight() {
        guard !checking else { return }
        checking = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            checking = false
            guard bounds.width > 0 else { return }
            let height = height(forWidth: bounds.width)
            guard abs(height - bounds.height) > 0.5 else {
                asked = -1
                return
            }
            guard height != asked else { return }
            asked = height
            heightChanged()
        }
    }

    // MARK: NSTextViewDelegate

    public func textDidChange(_ notification: Notification) {
        var outline = shell
        outline.rows = editor.fullRows
        text = outline.isBlank ? "" : OutlineMarkdown.serialize(outline)
        onChange?(text)
        // Folding is an edit to the text on screen, if not to the page.
        let folds = OutlineFolds.marks(editor.fullRows)
        if folds != shownFolds {
            shownFolds = folds
            onFoldsChange?(folds)
        }
        heightChanged()
    }

    public func undoManager(for view: NSTextView) -> UndoManager? { undo }

    // MARK: OutlineTextViewNavigator

    package func outlineView(_ view: OutlineTextView, leaveThrough edge: OutlineTextView.Edge, x: CGFloat) {}

    package func outlineView(_ view: OutlineTextView, open url: URL, inSplit: Bool) {
        if let title = url.wikiTarget { onOpenTitle?(title) } else { onOpenURL?(url) }
    }
}
