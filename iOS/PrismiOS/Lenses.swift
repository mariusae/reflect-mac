import UIKit
import ReflectCore
import PrismCore

/// A lens's own page: its bar over what it gathers. Each is a list that
/// leads to notes — tapped, a note opened.
protocol LensPage: UIViewController {
    var lens: Lens { get }
    var bar: PaneBar { get }
    func notesChanged(_ paths: Set<String>)
    /// Everything typed in it, written.
    func saveAll()
}

extension LensPage {
    /// The bar at the top, the rest under it.
    func layOutBar() -> CGFloat {
        let top = view.safeAreaInsets.top
        bar.top = top
        bar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: top + PaneBar.height)
        view.bringSubviewToFront(bar)
        return bar.contentTop
    }
}

// MARK: - The inbox, the pinned

/// The inbox, or the pinned notes: each in a line or two — its cover, its
/// name, its first words, how long since — tapped, opened. In the inbox,
/// each with its Done at the right, to take it out.
final class NoteListController: UIViewController, LensPage {
    let lens: Lens
    let bar = PaneBar()
    private let store: PrismStore
    var onOpen: ((PanePlace) -> Void)?
    var menu: (() -> UIMenu)?
    /// The Inbox's Read Next: its links, one at a time, the oldest first.
    var onReadNext: (() -> Void)?

    private let list = UIScrollView()
    /// Over the inbox's notes, while any has something to read: Read Next, and how many.
    private let readNext = UIButton(type: .system)
    private var rows: [NoteSummaryRow] = []
    private let empty = UILabel()
    private var paths: [String] = []
    /// The note open beside, when there is room for one: its row marked.
    var chosen: String? { didSet { markChosen() } }

    init(lens: Lens, store: PrismStore) {
        self.lens = lens
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Ink.page
        list.alwaysBounceVertical = true
        list.contentInsetAdjustmentBehavior = .never
        view.addSubview(list)
        view.addSubview(bar)
        bar.menu = { [weak self] in self?.menu?() ?? UIMenu() }
        empty.text = lens == .inbox ? "Nothing to deal with" : "Pin a note from its ⋯ menu"
        empty.font = Typeface.current.body(17)
        empty.textColor = Ink.secondary
        empty.textAlignment = .center
        view.addSubview(empty)
        if lens == .inbox {
            readNext.addAction(UIAction { [weak self] _ in self?.onReadNext?() }, for: .touchUpInside)
            readNext.isHidden = true
            list.addSubview(readNext)
        }
        reload()
    }

    /// Read Next, saying how many links wait — hidden, with none.
    private func showReadNext() {
        guard lens == .inbox, let index = store.index, let root = store.graph?.root else { return }
        let count = ReadingQueue.items(index: index, root: root).items.count
        var style = UIButton.Configuration.glass()
        style.image = UIImage(systemName: "book", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        style.imagePadding = 8
        style.title = "Read Next"
        style.subtitle = "\(count) \(count == 1 ? "link" : "links") to read"
        style.titleAlignment = .leading
        style.baseForegroundColor = Ink.text
        readNext.configuration = style
        readNext.isHidden = count == 0
        view.setNeedsLayout()
    }

    func notesChanged(_ paths: Set<String>) { reload() }
    func saveAll() {}

    private func reload() {
        guard isViewLoaded, let index = store.index else { return }
        let now = (lens == .inbox ? index.inbox : index.pinned).map(\.path)
        if now != paths {
            paths = now
            rows.forEach { $0.removeFromSuperview() }
            rows = paths.map { path in
                let row = NoteSummaryRow(path: path, store: store, done: lens == .inbox)
                row.addAction(UIAction { [weak self] _ in self?.onOpen?(PanePlace(path: path)) }, for: .touchUpInside)
                row.onDone = { [weak self, weak row] in
                    guard let self, let row else { return }
                    takeOut(row)
                }
                list.addSubview(row)
                return row
            }
        } else {
            rows.forEach { $0.refresh() }
        }
        bar.show(title: lens.title, detail: paths.isEmpty ? nil : "\(paths.count) \(paths.count == 1 ? "note" : "notes")")
        empty.isHidden = !paths.isEmpty
        markChosen()
        view.setNeedsLayout()
        showReadNext()
    }

    /// Done with a note in the inbox: its ring filled, the row swept off,
    /// those under it closing up.
    private func takeOut(_ row: NoteSummaryRow) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIView.animate(withDuration: 0.3, delay: 0.25, options: [.curveEaseIn]) {
            row.transform = CGAffineTransform(translationX: -row.bounds.width, y: 0)
            row.alpha = 0
        } completion: { [weak self] _ in
            self?.store.setFrontmatter(row.path, "inbox", nil, undoName: "Take Out of Inbox")
        }
    }

    private func markChosen() {
        for row in rows { row.isChosen = row.path == chosen }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = layOutBar()
        let width = view.bounds.width
        var y: CGFloat = 8
        if lens == .inbox, !readNext.isHidden {
            readNext.frame = CGRect(x: NoteBlock.side - 8, y: y + 4, width: width - 2 * (NoteBlock.side - 8), height: 54)
            y += 66
        }
        for row in rows {
            row.transform = .identity
            row.frame = CGRect(x: 0, y: y, width: width, height: NoteSummaryRow.height)
            y += NoteSummaryRow.height
        }
        list.frame = CGRect(x: 0, y: top, width: width, height: view.bounds.height - top)
        // Under the floating controls at first; scrolled up under them.
        list.contentInset.top = PaneBar.height
        list.verticalScrollIndicatorInsets.top = PaneBar.height
        list.contentSize = CGSize(width: width, height: y + 140)
        empty.frame = CGRect(x: 20, y: top + PaneBar.height + 60, width: width - 40, height: 30)
    }
}

/// A note, short: its cover — or a note's mark — small and square, its name,
/// its first words, and how long since it changed; in the inbox, its Done.
final class NoteSummaryRow: UIControl {
    static let height: CGFloat = 68

    let path: String
    private let store: PrismStore
    private let picture = UIImageView()
    private let name = UILabel()
    private let words = UILabel()
    private let age = UILabel()
    private let doneButton = UIButton(type: .system)
    private let hasDone: Bool
    var onDone: (() -> Void)?

    var isChosen = false { didSet { backgroundColor = isChosen ? Ink.hover : .clear } }

    init(path: String, store: PrismStore, done: Bool) {
        self.path = path
        self.store = store
        hasDone = done
        super.init(frame: .zero)
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.layer.cornerRadius = 6
        picture.layer.cornerCurve = .continuous
        picture.tintColor = Ink.secondary
        name.font = Typeface.current.heading(16, weight: .semibold)
        name.textColor = Ink.text
        words.font = Typeface.current.body(14)
        words.textColor = Ink.secondary
        for view in [picture, name, words, age] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        if done {
            doneButton.setImage(UIImage(systemName: "checkmark.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .light)),
                                for: .normal)
            doneButton.tintColor = Ink.secondary
            doneButton.accessibilityLabel = "Take Out of Inbox"
            doneButton.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                doneButton.setImage(UIImage(systemName: "checkmark.circle.fill",
                                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .light)), for: .normal)
                doneButton.tintColor = Ink.text
                doneButton.imageView?.addSymbolEffect(.bounce.up)
                onDone?()
            }, for: .touchUpInside)
            addSubview(doneButton)
        }
        refresh()
        // One thing to VoiceOver: the note, to open — taken out of the inbox by its action.
        isAccessibilityElement = true
        accessibilityTraits = .button
        if done {
            accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Take Out of Inbox") { [weak self] _ in
                self?.doneButton.sendActions(for: .touchUpInside)
                return true
            }]
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let text = store.text(path)
        name.text = SliceBlock.name(path, store: store)
        // A private note's words kept out of lists: said to be private, no more.
        let entry = store.index?.entry(path)
        words.text = entry?.isPrivate == true ? "Private" : Self.firstWords(of: text)
        accessibilityLabel = name.text
        accessibilityValue = [Card.meta(for: path, store: store), words.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        age.attributedText = NSAttributedString(string: (Card.meta(for: path, store: store) ?? "").uppercased(),
                                                attributes: Card.label(size: 15))
        if let cover = NoteCover.source(in: text).flatMap({ PhoneImages.thumbnail($0, side: 44) }) {
            picture.image = cover
            picture.contentMode = .scaleAspectFill
            picture.backgroundColor = .clear
        } else if GraphPaths.day(fromDailyPath: path) != nil {
            // A day: by its name alone — the month over the days says what it is.
            picture.image = nil
        } else {
            picture.image = UIImage(systemName: "doc.text", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular))
            picture.contentMode = .center
            picture.backgroundColor = Ink.text.withAlphaComponent(0.05)
        }
        setNeedsLayout()
    }

    private static func firstWords(of text: String) -> String {
        let rows = OutlineMarkdown.parse(text).rows
        let shown = rows.lazy.map { InlineMarkup.plainText($0.text).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let first = { if case .heading = rows.first?.kind { return true } else { return false } }() ? shown.dropFirst().first : shown.first
        return first ?? ""
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side: CGFloat = 44, x = NoteBlock.side
        picture.isHidden = picture.image == nil
        picture.frame = CGRect(x: x, y: (bounds.height - side) / 2, width: picture.isHidden ? 0 : side, height: side)
        let right = hasDone ? bounds.width - 56 : bounds.width - NoteBlock.side
        doneButton.frame = CGRect(x: bounds.width - 56, y: 0, width: 48, height: bounds.height)
        let ageSize = age.intrinsicContentSize
        age.frame = CGRect(x: right - ageSize.width, y: 15, width: ageSize.width, height: ageSize.height)
        let textX = picture.isHidden ? x : picture.frame.maxX + 14
        name.frame = CGRect(x: textX, y: 13, width: age.frame.minX - 10 - textX, height: 21)
        words.frame = CGRect(x: textX, y: 35, width: right - textX, height: 19)
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? Ink.rule : isChosen ? Ink.hover : .clear }
    }
}

// MARK: - The tasks

/// Every open task, in Reflect's groups, each with what is under it —
/// ticked, changed, written where it is, in its own note.
final class TasksController: UIViewController, LensPage {
    let lens = Lens.tasks
    let bar = PaneBar()
    let sheet: SheetController
    var menu: (() -> UIMenu)?

    init(sheet: SheetController) {
        self.sheet = sheet
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Ink.page
        addChild(sheet)
        view.addSubview(sheet.view)
        sheet.didMove(toParent: self)
        view.addSubview(bar)
        bar.menu = { [weak self] in self?.menu?() ?? UIMenu() }
        count()
    }

    private func count() {
        let open = sheet.store.index?.tasks().count ?? 0
        bar.show(title: "Tasks", detail: open == 0 ? nil : "\(open) to do")
    }

    func notesChanged(_ paths: Set<String>) {
        sheet.notesChanged(paths)
        count()
    }

    func saveAll() { sheet.saveAll() }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = layOutBar()
        sheet.additionalSafeAreaInsets.top = PaneBar.height
        sheet.view.frame = CGRect(x: 0, y: top, width: view.bounds.width, height: view.bounds.height - top)
    }
}

// MARK: - Search

/// What is typed in the bar's field, looked for: notes and days by their
/// names as it is typed; the words in every note, asked for.
final class SearchController: UIViewController, LensPage {
    let lens = Lens.search
    let bar = PaneBar()
    private let store: PrismStore
    let finder: FinderController
    /// The words found in every note, once asked for: over the finder.
    private var results: SheetController?
    private let makeResults: (String) -> SheetController
    var menu: (() -> UIMenu)?

    init(store: PrismStore, finder: FinderController, makeResults: @escaping (String) -> SheetController) {
        self.store = store
        self.finder = finder
        self.makeResults = makeResults
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Ink.paper
        addChild(finder)
        view.addSubview(finder.view)
        finder.didMove(toParent: self)
        view.addSubview(bar)
        bar.menu = { [weak self] in self?.menu?() ?? UIMenu() }
        bar.show(title: "Search", detail: nil)
    }

    /// Typed: names found; what was found in every note put away.
    func search(_ text: String) {
        loadViewIfNeeded()
        showResults(nil)
        finder.search(text)
        bar.show(title: "Search", detail: nil)
    }

    /// The words, in every note.
    func searchEverything(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        showResults(query)
        bar.show(title: "“\(query)”", detail: "In every note")
    }

    private func showResults(_ query: String?) {
        if let results {
            results.saveAll()
            results.willMove(toParent: nil)
            results.view.removeFromSuperview()
            results.removeFromParent()
            self.results = nil
        }
        guard let query else { return }
        let sheet = makeResults(query)
        addChild(sheet)
        view.insertSubview(sheet.view, belowSubview: bar)
        sheet.didMove(toParent: self)
        results = sheet
        view.setNeedsLayout()
    }

    func notesChanged(_ paths: Set<String>) { results?.notesChanged(paths) }
    func saveAll() { results?.saveAll() }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = layOutBar()
        let rest = CGRect(x: 0, y: top, width: view.bounds.width, height: view.bounds.height - top)
        finder.additionalSafeAreaInsets.top = PaneBar.height
        results?.additionalSafeAreaInsets.top = PaneBar.height
        finder.view.frame = rest
        results?.view.frame = rest
    }
}
