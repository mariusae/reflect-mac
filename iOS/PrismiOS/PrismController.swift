import SwiftUI
import AuthenticationServices
import UIKit
import PhotosUI
import SafariServices
import ReflectCore
import PrismCore
import ReflectGit2

/// Prism on the phone: the lenses — Daily, the inbox, the tasks, the
/// pinned, search — each its own stack: its list at the foot, a note
/// opened over it, swiped back from. A note's pane goes on from note to
/// note as links are followed, back and forward, as a browser's tab does.
/// Wide — an iPad — the lens's list in a sidebar on glass at the left, the
/// note beside it the rest of the height; a link note's page in a column
/// at the note's right.
final class PrismController: UIViewController, UINavigationControllerDelegate, UIGestureRecognizerDelegate {
    let store: PrismStore
    private let bar = BottomBar()
    private var barToBottom: NSLayoutConstraint?
    private var barLeading: NSLayoutConstraint?
    private var barTrailing: NSLayoutConstraint?
    private var keyboardHeight: CGFloat = 0
    /// Each lens's stack, made when first shown.
    private var stacks: [Lens: UINavigationController] = [:]
    private(set) var lens: Lens = .daily
    /// The lens shown before search: back to it when search is put away.
    private var lensBeforeSearch: Lens = .daily
    private lazy var finder = FinderController(store: store, embedded: true)

    init(store: PrismStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Ink.page
        OutlineEditor.suggest = { [weak store] query in
            guard let index = store?.index else { return [] }
            return LinkSuggestions.candidates(query, index: index)
        }
        finder.onChoose = { [weak self] place in self?.chose(place) }
        additionalSafeAreaInsets.bottom = BottomBar.height + BottomBar.margin - 34 + BottomBar.gap
        setUpBar()
        restoreLayout()
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.saveAll()
                    self?.saveLayout()
                }
            }
        }
        observe()
        startNow()
        NotificationCenter.default.addObserver(forName: .prismReader, object: nil, queue: .main) { [weak self] note in
            let reading = note.object as? Bool ?? false
            MainActor.assumeIsolated {
                // Wide, the page is in a column: the bar stays, in the sidebar.
                guard self?.isWide != true else { return }
                UIView.animate(withDuration: 0.25) { self?.bar.alpha = reading ? 0 : 1 }
                self?.bar.isUserInteractionEnabled = !reading
            }
        }
        openForScript()
        QuickActions.onPending = { [weak self] in self?.openQuickAction() }
        DispatchQueue.main.async { [weak self] in self?.openQuickAction() }
        refreshQuickActions()
    }

    // MARK: The lenses

    /// A lens's stack: its page at the foot.
    private func stack(_ lens: Lens) -> UINavigationController {
        if let made = stacks[lens] { return made }
        let navigation = UINavigationController(rootViewController: makeRoot(lens))
        navigation.delegate = self
        navigation.setNavigationBarHidden(true, animated: false)
        navigation.interactivePopGestureRecognizer?.delegate = self
        stacks[lens] = navigation
        return navigation
    }

    private var shownStack: UINavigationController { stack(lens) }

    private func makeRoot(_ lens: Lens) -> UIViewController {
        switch lens {
        case .daily:
            let pager = DayPager(store: store, makePage: { [unowned self] place, open in makePage(place, open: open) })
            pager.onOpen = { [weak self] place, row in self?.open(place, row: row) }
            pager.makeCalendar = { [weak self] day in self?.calendarController(day: day) }
            pager.onChooseWeek = { [weak pager] week in pager?.show(week) }
            pager.marks = { [weak self] in
                guard let graph = self?.store.graph, let index = self?.store.index else { return [:] }
                return NoteCalendar.marks(graph: graph, index: index)
            }
            pager.menu = { [weak self, weak pager] place in
                guard let self else { return UIMenu() }
                return menu(for: place, sheet: pager?.sheet, calendar: { pager?.showCalendar(true) })
            }
            pager.onChange = { [weak self] in
                self?.updateBarTitle()
                self?.layoutChanged()
            }
            return pager
        case .inbox, .pinned:
            let list = NoteListController(lens: lens, store: store)
            list.onOpen = { [weak self] place in self?.open(place) }
            list.menu = { [weak self] in self?.appMenu() ?? UIMenu() }
            return list
        case .tasks:
            let tasks = TasksController(sheet: makeSheet(.tasks, open: { [weak self] place, row in self?.open(place, row: row) }))
            tasks.menu = { [weak self] in self?.appMenu() ?? UIMenu() }
            return tasks
        case .search:
            let search = SearchController(store: store, finder: finder, makeResults: { [unowned self] query in
                makeSheet(.search(query), open: { [weak self] place, row in self?.open(place, row: row) })
            })
            search.menu = { [weak self] in self?.appMenu() ?? UIMenu() }
            return search
        }
    }

    private var dayPager: DayPager? { stacks[.daily]?.viewControllers.first as? DayPager }

    /// A lens shown — the one shown chosen again: back to its start.
    func show(_ lens: Lens) {
        if bar.isSearching, lens != .search { leaveSearch(back: false) }
        if lens == self.lens {
            let navigation = shownStack
            if navigation.viewControllers.count > 1 {
                navigation.popToRootViewController(animated: true)
            } else if lens == .daily {
                dayPager?.show(.today)
            }
            return
        }
        saveAll()
        self.lens = lens
        bar.lens = lens == .search ? lensBeforeSearch : lens
        arrange()
        setChromeHidden(false)
        view.setNeedsLayout()
        updateBarTitle()
        layoutChanged()
    }

    /// What a place is shown by: a day's hours, or a note's sheet — links
    /// followed from it opened by `open`.
    private func makePage(_ place: PanePlace, open: @escaping (PanePlace, Int?) -> Void) -> UIViewController {
        if place.face == .schedule, let day = GraphPaths.day(fromDailyPath: place.path) {
            return ScheduleController(day: day, store: store)
        }
        return makeSheet(.note(place.path), open: open)
    }

    private func makeSheet(_ kind: SheetKind, open: @escaping (PanePlace, Int?) -> Void) -> SheetController {
        let sheet = SheetController(kind: kind, store: store)
        sheet.onOpen = { path, row in open(PanePlace(path: path), row) }
        sheet.onLink = { [weak self, weak sheet] link in
            sheet?.saveAll()
            self?.follow(link, open: open)
        }
        sheet.onFlag = { [weak self] path, key, value in self?.store.setFrontmatter(path, key, value) }
        sheet.onChromeHidden = { [weak self] hidden in self?.setChromeHidden(hidden) }
        return sheet
    }

    // MARK: Opening notes

    /// A note opened from a lens: in the note pane beside it, wide; else
    /// over it, on its stack.
    func open(_ place: PanePlace, row: Int? = nil) {
        if bar.isSearching { leaveSearch(back: false) }
        saveAll()
        if isWide, lens == .daily {
            // Daily, wide: a day shown by the days beside; a note gone on to, over them.
            let daily = stack(.daily)
            if let day = GraphPaths.day(fromDailyPath: place.path) {
                daily.popToRootViewController(animated: false)
                if place.face != dayPager?.face { dayPager?.setFace(place.face) }
                dayPager?.show(day)
                markChosen()
                return
            }
            let note = makeNoteController(PaneHistory(place), inStack: true)
            daily.pushViewController(note, animated: true)
            if let row { DispatchQueue.main.async { note.sheet?.mark(unfoldedRow: row) } }
            return
        }
        if isWide {
            showDetail(place, row: row)
            return
        }
        let note = makeNoteController(PaneHistory(place), inStack: true)
        shownStack.pushViewController(note, animated: true)
        if let row { DispatchQueue.main.async { note.sheet?.mark(unfoldedRow: row) } }
    }

    private func makeNoteController(_ history: PaneHistory, inStack: Bool) -> NoteController {
        let note = NoteController(store: store, history: history, makePage: { [unowned self] place, open in makePage(place, open: open) })
        note.menu = { [weak self, weak note] place in
            guard let self else { return UIMenu() }
            return menu(for: place, sheet: note?.sheet, calendar: nil)
        }
        if inStack {
            note.onLeave = { [weak note] in note?.navigationController?.popViewController(animated: true) }
        }
        note.onChange = { [weak self] in
            self?.updateBarTitle()
            self?.markChosen()
            self?.layoutChanged()
        }
        return note
    }

    /// A link tapped: a note by its title — made, when there is none — a
    /// day by its date, or the web.
    private func follow(_ link: String, open: @escaping (PanePlace, Int?) -> Void) {
        if link.hasPrefix("[["), link.hasSuffix("]]") {
            let title = String(link.dropFirst(2).dropLast(2)).components(separatedBy: "|")[0].trimmingCharacters(in: .whitespaces)
            if let day = Day(title) {
                open(PanePlace(path: GraphPaths.dailyPath(for: day)), nil)
            } else if let path = store.index?.resolve(title) {
                open(PanePlace(path: path), nil)
            } else if let graph = store.graph, let path = try? NoteCreation.create(title: title, in: graph.root) {
                store.noteChanged([path])
                open(PanePlace(path: path), nil)
            }
        } else if let url = URL(string: link), url.scheme != nil {
            openWeb(url)
        }
    }

    func openWeb(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased()) else {
            UIApplication.shared.open(url)
            return
        }
        let configuration = SFSafariViewController.Configuration()
        configuration.barCollapsingEnabled = true
        let safari = SFSafariViewController(url: url, configuration: configuration)
        safari.preferredControlTintColor = Ink.text
        safari.dismissButtonStyle = .close
        topPresenter.present(safari, animated: true)
    }

    private var topPresenter: UIViewController {
        var presenter: UIViewController = self
        while let next = presenter.presentedViewController { presenter = next }
        return presenter
    }

    // MARK: Wide: the lens and a note, side by side

    /// The widest the screen is with one pane: wider, the lens on the left
    /// and a note on the right. `-PrismPairWidth` to try it narrower.
    private var pairWidth: CGFloat {
        let set = UserDefaults.standard.double(forKey: "PrismPairWidth")
        return set > 0 ? CGFloat(set) : 680
    }
    private(set) var isWide = false
    /// The note pane, wide: on the right.
    private var detail: NoteController?
    private let detailRule = UIView()
    private let emptyDetail = UILabel()

    private func showDetail(_ place: PanePlace, row: Int? = nil) {
        if let detail {
            detail.go(place, row: row)
            return
        }
        let note = makeNoteController(PaneHistory(place), inStack: false)
        detail = note
        detailLens = lens
        arrange()
        view.setNeedsLayout()
        if let row { DispatchQueue.main.async { note.sheet?.mark(unfoldedRow: row) } }
        markChosen()
    }

    private func removeDetail() -> PaneHistory? {
        guard let detail else { return nil }
        detail.sheet?.saveAll()
        detach(detail)
        self.detail = nil
        return detail.history
    }

    /// Wide, or not: the note moved from over the lens to beside it, or back.
    private func setWide(_ wide: Bool) {
        guard wide != isWide else { return }
        isWide = wide
        if wide {
            closeReaderColumn()
            let navigation = shownStack
            // Daily keeps what is over its days: the days are beside them now.
            if lens != .daily, let note = navigation.topViewController as? NoteController {
                note.sheet?.saveAll()
                let history = note.history
                navigation.popToRootViewController(animated: false)
                showDetail(history.current)
                detail?.replaceHistory(history)
            }
        } else {
            closeReaderColumn()
            let owner = detailLens ?? lens
            if let history = removeDetail() {
                let note = makeNoteController(history, inStack: true)
                stack(owner).pushViewController(note, animated: false)
            }
        }
        arrange()
        markChosen()
    }

    /// Wide, the note beside a list: its row marked.
    private func markChosen() {
        let chosen = isWide ? detail?.place.path : nil
        for lens in [Lens.inbox, .pinned] { (stacks[lens]?.viewControllers.first as? NoteListController)?.chosen = chosen }
        daySidebar?.chosen = isWide ? dayPager?.place.path : nil
    }

    // MARK: The iPad's sidebar, the note, the page

    /// Which lens's stack the note beside was opened from: back onto it, narrow.
    private var detailLens: Lens?
    /// Daily's list, wide: the month and the days, the day itself beside.
    private var daySidebar: DaySidebarController?
    /// The sidebar out, wide — or put away, the note the whole width.
    private var sidebarShown = UserDefaults.standard.object(forKey: "PadSidebar") as? Bool ?? true
    private let sidebarGlass = UIVisualEffectView(effect: UIGlassEffect())
    private let sidebarButton = SidebarButton()
    /// A link note's page, wide: in a column at the note's right — over it, in portrait.
    private var readerColumn: ReaderController?

    private func makeDaySidebar() -> DaySidebarController {
        if let daySidebar { return daySidebar }
        let sidebar = DaySidebarController(store: store)
        sidebar.onDay = { [weak self] day in
            guard let self else { return }
            saveAll()
            stack(.daily).popToRootViewController(animated: false)
            dayPager?.show(day)
            markChosen()
        }
        sidebar.onWeek = { [weak self] week in
            self?.stack(.daily).popToRootViewController(animated: false)
            self?.dayPager?.show(week)
        }
        sidebar.menu = { [weak self] in self?.appMenu() ?? UIMenu() }
        daySidebar = sidebar
        return sidebar
    }

    /// What is shown, and where: narrow, the lens's stack, the whole of it;
    /// wide, the lens's list in the sidebar and the note beside — Daily's
    /// days beside its stack of the day — and the page, when it is open.
    private func arrange(laying: Bool = false) {
        var wanted: [UIViewController] = []
        if isWide {
            if sidebarShown { wanted.append(lens == .daily ? makeDaySidebar() : stack(lens)) }
            if lens == .daily { wanted.append(stack(.daily)) } else if let detail { wanted.append(detail) }
            if let readerColumn { wanted.append(readerColumn) }
        } else {
            wanted.append(stack(lens))
        }
        let all: [UIViewController] = Array(stacks.values) + [detail, daySidebar, readerColumn].compactMap { $0 }
        for controller in all where controller.parent === self && !wanted.contains(where: { $0 === controller }) { detach(controller) }
        for controller in wanted where controller.parent !== self { attach(controller) }
        // In the sidebar, on its glass: no ground of their own.
        let sidebar: UIViewController? = isWide && sidebarShown ? (lens == .daily ? daySidebar : stacks[lens]) : nil
        for controller in all where controller !== daySidebar { setGround(controller, clear: controller === sidebar) }
        // Asked from layout itself: not laid out again for it.
        if !laying { view.setNeedsLayout() }
    }

    /// The grounds a controller's views had, before the sidebar's glass showed through them.
    private var grounds: [ObjectIdentifier: UIColor?] = [:]

    /// A controller's ground — and its children's, down — cleared to the glass, or as it was.
    private func setGround(_ controller: UIViewController, clear: Bool) {
        guard controller.isViewLoaded else { return }
        let key = ObjectIdentifier(controller.view)
        if clear {
            if grounds[key] == nil { grounds[key] = .some(controller.view.backgroundColor) }
            controller.view.backgroundColor = .clear
        } else if let ground = grounds.removeValue(forKey: key) {
            controller.view.backgroundColor = ground
        }
        controller.children.forEach { setGround($0, clear: clear) }
    }

    private func attach(_ controller: UIViewController) {
        addChild(controller)
        view.insertSubview(controller.view, belowSubview: bar)
        controller.didMove(toParent: self)
    }

    private func detach(_ controller: UIViewController) {
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    /// The sidebar out, or put away: ⌥⌘L, or the button by the window's edge.
    @objc func flipSidebar() {
        guard isWide else { return }
        sidebarShown.toggle()
        UserDefaults.standard.set(sidebarShown, forKey: "PadSidebar")
        arrange()
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0) {
            self.view.layoutIfNeeded()
        }
    }

    /// A link note's page, wide: in its column.
    private func presentReader(_ reader: ReaderController) -> Bool {
        guard isWide else { return false }
        closeReaderColumn()
        reader.onClose = { [weak self] in self?.closeReaderColumn() }
        readerColumn = reader
        arrange()
        return true
    }

    private func closeReaderColumn() {
        guard let reader = readerColumn else { return }
        readerColumn = nil
        detach(reader)
        view.setNeedsLayout()
    }

    /// The widths: the sidebar's, inset on its glass; the note's; the page's.
    private var sidebarWidth: CGFloat { min(380, max(300, (view.bounds.width * 0.3).rounded())) }
    private static let inset: CGFloat = 8

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        setWide(bounds.width >= pairWidth)
        if ReaderController.present == nil {
            ReaderController.present = { [weak self] reader in self?.presentReader(reader) ?? false }
        }
        arrange(laying: true)
        if sidebarGlass.superview == nil {
            sidebarGlass.cornerConfiguration = .uniformCorners(radius: .fixed(26))
            view.insertSubview(sidebarGlass, at: 0)
            sidebarButton.onTap = { [weak self] in self?.flipSidebar() }
            view.addSubview(sidebarButton)
        }
        guard isWide else {
            stack(lens).view.frame = bounds
            sidebarGlass.isHidden = true
            sidebarButton.isHidden = true
            emptyDetail.isHidden = true
            detailRule.isHidden = true
            PaneBar.edgeRoom = 0
            barLeading?.constant = 0
            barTrailing?.constant = 0
            view.bringSubviewToFront(bar)
            return
        }
        let inset = Self.inset
        let side = sidebarShown ? sidebarWidth : 0
        let sidebarFrame = CGRect(x: inset, y: inset, width: side, height: bounds.height - 2 * inset)
        sidebarGlass.isHidden = !sidebarShown
        sidebarGlass.frame = sidebarShown ? sidebarFrame : .zero
        if sidebarShown { (lens == .daily ? daySidebar : stacks[lens])?.view.frame = sidebarFrame }
        let left = sidebarShown ? sidebarFrame.maxX + inset / 2 : 0
        var main = CGRect(x: left, y: 0, width: bounds.width - left, height: bounds.height)
        // The page: beside the note when there is room for both, else over it.
        if let readerColumn {
            if main.width >= 900 {
                let width = (main.width * 0.5).rounded()
                readerColumn.view.frame = CGRect(x: main.maxX - width, y: 0, width: width, height: bounds.height)
                main.size.width -= width
                detailRule.isHidden = false
                detailRule.frame = CGRect(x: main.maxX - 0.5, y: 0, width: 1 / max(view.traitCollection.displayScale, 1), height: bounds.height)
            } else {
                readerColumn.view.frame = main
                detailRule.isHidden = true
            }
        } else {
            detailRule.isHidden = true
        }
        if detailRule.superview == nil {
            detailRule.backgroundColor = Ink.rule
            view.addSubview(detailRule)
        }
        let shownDetail: UIViewController? = lens == .daily ? stacks[.daily] : detail
        shownDetail?.view.frame = main
        if emptyDetail.superview == nil {
            emptyDetail.text = "Choose a note"
            emptyDetail.font = Typeface.current.body(17)
            emptyDetail.textColor = Ink.faint
            emptyDetail.textAlignment = .center
            view.insertSubview(emptyDetail, at: 0)
        }
        emptyDetail.isHidden = shownDetail != nil
        emptyDetail.frame = main
        // The sidebar's button, by the window's left edge; the bars beside it keep clear.
        let top = view.safeAreaInsets.top
        sidebarButton.isHidden = false
        sidebarButton.onGlass = sidebarShown
        sidebarButton.frame = CGRect(x: 16 + (sidebarShown ? inset : 0), y: top + (PaneBar.height - 44) / 2, width: 44, height: 44)
        PaneBar.edgeRoom = 52
        // The bar at the sidebar's foot — put away, floating at the window's, left.
        let barWidth = sidebarShown ? side : min(400, bounds.width - 32)
        barLeading?.constant = sidebarShown ? inset : 8
        barTrailing?.constant = -(bounds.width - (barLeading?.constant ?? 0) - barWidth)
        view.bringSubviewToFront(bar)
        view.bringSubviewToFront(sidebarButton)
    }

    // MARK: The keyboard

    /// A hardware keyboard's: the Mac's keys, held ⌘ listing them.
    override var keyCommands: [UIKeyCommand]? {
        var commands = Lens.allCases.enumerated().map { i, lens in
            UIKeyCommand(title: lens.title, action: #selector(keyLens(_:)), input: "\(i + 1)", modifierFlags: .command,
                         propertyList: lens.rawValue)
        }
        commands += [
            UIKeyCommand(title: "Go to…", action: #selector(keySearch), input: "k", modifierFlags: .command),
            UIKeyCommand(title: "New Note", action: #selector(keyNewNote), input: "n", modifierFlags: .command),
            UIKeyCommand(title: "Today", action: #selector(keyToday), input: "d", modifierFlags: .command),
            UIKeyCommand(title: "Back", action: #selector(keyBack), input: "[", modifierFlags: .command),
            UIKeyCommand(title: "Forward", action: #selector(keyForward), input: "]", modifierFlags: .command),
            UIKeyCommand(title: "Read Note", action: #selector(keyPage), input: "r", modifierFlags: [.command, .shift]),
        ]
        if isWide {
            commands.append(UIKeyCommand(title: sidebarShown ? "Hide Sidebar" : "Show Sidebar", action: #selector(flipSidebar),
                                         input: "l", modifierFlags: [.command, .alternate]))
        }
        if readerColumn != nil {
            commands += [
                UIKeyCommand(title: "Reader", action: #selector(keyReader), input: "e", modifierFlags: [.command, .shift]),
                UIKeyCommand(title: "Highlight Passage", action: #selector(keyHighlight), input: "h", modifierFlags: [.command, .shift]),
                UIKeyCommand(title: "Close Reader", action: #selector(keyClosePage), input: "w", modifierFlags: .command),
            ]
        }
        // Over the text being typed in: these first, before it takes the keys.
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    /// The note worked in: beside the list, wide; else on top of the lens's stack.
    private var currentNote: NoteController? {
        if isWide, lens != .daily { return detail }
        return shownStack.topViewController as? NoteController
    }

    @objc private func keyLens(_ command: UIKeyCommand) {
        guard let raw = command.propertyList as? String, let lens = Lens(rawValue: raw) else { return }
        if lens == .search { showSearch() } else { show(lens) }
    }

    @objc private func keySearch() { showSearch() }
    @objc private func keyNewNote() { compose() }

    @objc private func keyToday() {
        if bar.isSearching { leaveSearch(back: false) }
        show(.daily)
        shownStack.popToRootViewController(animated: false)
        dayPager?.show(.today)
        markChosen()
    }

    @objc private func keyBack() { currentNote?.back() }
    @objc private func keyForward() { currentNote?.goForward() }

    @objc private func keyPage() {
        if readerColumn != nil { return closeReaderColumn() }
        guard let note = currentNote else { return }
        note.sheet?.saveAll()
        ReaderController.open(notePath: note.place.path, store: store, from: note)
    }

    @objc private func keyReader() { readerColumn?.toggleReading() }
    @objc private func keyHighlight() { readerColumn?.highlightSelection() }
    @objc private func keyClosePage() { closeReaderColumn() }

    // MARK: The bar

    private func setUpBar() {
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        let toBottom = bar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -BottomBar.margin)
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.keyboardMoved(note) }
        }
        let leading = bar.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        let trailing = bar.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        NSLayoutConstraint.activate([leading, trailing, bar.heightAnchor.constraint(equalToConstant: BottomBar.height), toBottom])
        barToBottom = toBottom
        barLeading = leading
        barTrailing = trailing
        bar.onLens = { [weak self] lens in self?.show(lens) }
        bar.onWrite = { [weak self] in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.writeToday()
        }
        bar.onDictateBegin = { [weak self] in self?.beginDictation() }
        bar.onDictateEnd = { [weak self] cancelled in self?.endDictation(cancelled: cancelled) }
        bar.onSearch = { [weak self] in self?.showSearch() }
        bar.onLeaveSearch = { [weak self] in self?.leaveSearch(back: true) }
        bar.onQuery = { [weak self] text in (self?.stacks[.search]?.viewControllers.first as? SearchController)?.search(text) }
        bar.onSubmit = { [weak self] in
            guard let self else { return }
            bar.field.resignFirstResponder()
            (stacks[.search]?.viewControllers.first as? SearchController)?.searchEverything(bar.field.text ?? "")
        }
    }

    private func keyboardMoved(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let local = view.convert(frame, from: nil)
        keyboardHeight = max(0, view.bounds.maxY - local.minY)
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        guard bar.isSearching else { return }
        placeBar()
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) { self.view.layoutIfNeeded() }
    }

    private func placeBar() {
        let lift = bar.isSearching && keyboardHeight > 0 ? keyboardHeight + BottomBar.gap : BottomBar.margin
        barToBottom?.constant = -lift
    }

    /// Read down into a page: the bar gathered to the name of what is shown.
    func setChromeHidden(_ hidden: Bool) {
        bar.setSmall(hidden)
        // The floating controls over the page with it.
        NotificationCenter.default.post(name: .prismChromeHidden, object: hidden)
    }

    /// The name of what is shown, for the bar gathered small.
    private func updateBarTitle() {
        let path: String?
        if isWide, lens != .daily, let detail { path = detail.place.path } else if let note = shownStack.topViewController as? NoteController {
            path = note.place.path
        } else if lens == .daily, let pager = dayPager {
            path = pager.place.path
        } else {
            path = nil
        }
        bar.setTitle(path.map { SliceBlock.names($0, store: store) } ?? [lens.title])
    }

    // MARK: Search

    func showSearch() {
        guard !bar.isSearching else { return }
        saveAll()
        if lens != .search { lensBeforeSearch = lens }
        bar.setSearching(true)
        // Searching always opens on searching: not on a note found the last time, left on top of it.
        stacks[.search]?.popToRootViewController(animated: false)
        show(.search)
        placeBar()
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0) { self.view.layoutIfNeeded() }
        bar.field.becomeFirstResponder()
    }

    private func leaveSearch(back: Bool) {
        guard bar.isSearching else { return }
        bar.field.resignFirstResponder()
        bar.setSearching(false)
        placeBar()
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0) { self.view.layoutIfNeeded() }
        if back { show(lensBeforeSearch) }
    }

    /// Something found by name: a day in Daily; a note, opened; the words,
    /// looked for in every note.
    private func chose(_ place: FinderController.Place) {
        switch place {
        case .day(let day):
            if store.graph?.exists(path: GraphPaths.dailyPath(for: day)) == false { store.reveal([day]) }
            leaveSearch(back: false)
            show(.daily)
            shownStack.popToRootViewController(animated: false)
            dayPager?.show(day)
            bar.field.text = ""
            finder.reset()
        case .note(let path):
            open(PanePlace(path: path))
            bar.field.text = ""
            finder.reset()
        case .search(let query):
            bar.field.resignFirstResponder()
            (stacks[.search]?.viewControllers.first as? SearchController)?.searchEverything(query)
        }
    }

    // MARK: The block on now

    private var nowTimer: Timer?

    /// The block of today's on now, looked for each second: a ring about Daily, running down.
    private func startNow() {
        tickNow()
        nowTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickNow() }
        }
    }

    private func tickNow() {
        // Today's note read each time: however it changed — typed in, moved
        // on the hours, synced — the ring as it is.
        let text = store.text(GraphPaths.dailyPath(for: .today))
        let date = Date()
        let seconds = date.timeIntervalSince(Calendar.current.startOfDay(for: date))
        let minutes = seconds / 60
        guard let block = DayBlocks.blocks(in: text).last(where: { Double($0.start) <= minutes && minutes < Double($0.end) }) else {
            if bar.now != nil { bar.now = nil }
            return
        }
        bar.now = (Double(block.end) * 60 - seconds, Double(block.duration) * 60, InlineMarkup.plainText(block.title))
    }

    // MARK: Keeping up

    private func observe() {
        withObservationTracking {
            _ = store.revision
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                let changed = self.store.changed
                for navigation in self.stacks.values {
                    for controller in navigation.viewControllers { self.notesChanged(changed, in: controller) }
                }
                if let detail = self.detail { self.notesChanged(changed, in: detail) }
                self.updateBarTitle()
                self.refreshQuickActions()
                self.observe()
            }
        }
    }

    private func notesChanged(_ paths: Set<String>, in controller: UIViewController) {
        switch controller {
        case let page as LensPage: page.notesChanged(paths)
        case let pager as DayPager:
            pager.notesChanged(paths)
            for page in pager.shownPages { notesChanged(paths, inPage: page) }
        case let note as NoteController:
            note.refreshTitle()
            if let page = note.page { notesChanged(paths, inPage: page) }
        default: break
        }
    }

    private func notesChanged(_ paths: Set<String>, inPage page: UIViewController) {
        (page as? SheetController)?.notesChanged(paths)
        (page as? ScheduleController)?.notesChanged(paths)
    }

    /// Every sheet shown, written.
    func saveAll() {
        for navigation in stacks.values {
            for controller in navigation.viewControllers {
                switch controller {
                case let page as LensPage: page.saveAll()
                case let pager as DayPager: pager.shownPages.forEach { ($0 as? SheetController)?.saveAll() }
                case let note as NoteController: note.sheet?.saveAll()
                default: break
                }
            }
        }
        detail?.sheet?.saveAll()
    }

    /// Every note pane, wherever it is.
    private var notePanes: [NoteController] {
        stacks.values.flatMap { $0.viewControllers.compactMap { $0 as? NoteController } } + (detail.map { [$0] } ?? [])
    }

    // MARK: Navigation

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        (shownStack.viewControllers.count) > 1
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        setChromeHidden(false)
        updateBarTitle()
        layoutChanged()
    }

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        // A note left — popped — named after its title, or gone when blank.
        for case let note as NoteController in notePanes where !navigationController.viewControllers.contains(note) && note !== detail {
            note.sheet?.settle()
        }
    }

    // MARK: Writing in today

    /// Today, in Daily, as its note: a new row at its top, the caret in it.
    func writeToday() {
        saveAll()
        guard let pager = todayShown() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { pager.sheet?.writeAtTop() }
    }

    /// A row put first in today — dictated — shown, and written.
    func addToToday(_ text: String) {
        saveAll()
        guard let pager = todayShown() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { pager.sheet?.addAtTop(text: text) }
    }

    private func todayShown() -> DayPager? {
        if bar.isSearching { leaveSearch(back: false) }
        show(.daily)
        shownStack.popToRootViewController(animated: false)
        guard let pager = dayPager else { return nil }
        setChromeHidden(false)
        pager.setFace(.outline)
        pager.show(.today, animated: false)
        view.layoutIfNeeded()
        pager.view.layoutIfNeeded()
        // Today's page made and laid out, to write in at once.
        pager.sheet?.loadViewIfNeeded()
        pager.sheet?.view.layoutIfNeeded()
        return pager
    }

    /// A blank note, its title to be typed.
    func compose() {
        saveAll()
        guard let path = store.newNote() else { return }
        open(PanePlace(path: path))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            let note = isWide && lens != .daily ? detail : shownStack.topViewController as? NoteController
            note?.sheet?.focusFirst()
        }
    }

    // MARK: Menus

    /// The app's own: a new note, the sync, notes edited on two devices, settings.
    func appMenu() -> UIMenu {
        var sections: [UIMenuElement] = [UIMenu(options: .displayInline, children: [
            UIAction(title: "New Note", image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in self?.compose() },
        ])]
        var sync: [UIMenuElement] = store.isSyncing ? [
            UIAction(title: "Syncing…", image: UIImage(systemName: "arrow.triangle.2.circlepath"), attributes: .disabled) { _ in },
        ] : [
            UIAction(title: "Sync Now", image: UIImage(systemName: "arrow.triangle.2.circlepath")) { [weak self] _ in
                guard let self else { return }
                saveAll()
                Task { @MainActor in
                    await self.store.sync()
                    if let error = self.store.syncError { self.say(error) }
                }
            },
        ]
        if !store.account.isSignedIn {
            sync.insert(UIAction(title: "Sign In to GitHub…", image: UIImage(systemName: "person.crop.circle.badge.exclamationmark")) { [weak self] _ in
                self?.signIn()
            }, at: 0)
        }
        if let error = store.syncError {
            sync.append(UIAction(title: "Last sync failed", subtitle: error, attributes: .disabled) { _ in })
        } else if let synced = store.lastSynced {
            sync.append(UIAction(title: "Synced " + synced.formatted(.relative(presentation: .named)),
                                 subtitle: store.lastSyncTook.map { "Took \($0)" }, attributes: .disabled) { _ in })
        }
        sections.append(UIMenu(options: .displayInline, children: sync))
        if !store.conflicted.isEmpty {
            sections.append(UIMenu(title: "Edited on Two Devices", options: .displayInline, children: store.conflicted.prefix(8).map { path in
                UIAction(title: SliceBlock.name(path, store: store), image: UIImage(systemName: "arrow.triangle.merge")) { [weak self] _ in
                    self?.open(PanePlace(path: path))
                }
            }))
        }
        sections.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "Settings…", image: UIImage(systemName: "textformat")) { [weak self] _ in self?.showSettings() },
        ]))
        return UIMenu(children: sections)
    }

    /// A place's ⋯: what can be done to its note, then the app's.
    func menu(for place: PanePlace, sheet: SheetController?, calendar: (() -> Void)?) -> UIMenu {
        var sections: [UIMenuElement] = []
        if let calendar {
            sections.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "Calendar", image: UIImage(systemName: "calendar")) { _ in calendar() },
            ]))
        }
        sections.append(noteMenu(place.path, sheet: sheet))
        sections.append(contentsOf: appMenu().children)
        return UIMenu(children: sections)
    }

    /// What can be done to one note: its inbox, topic and pin, its cover,
    /// a link to it copied, deleted.
    func noteMenu(_ path: String, sheet: SheetController?) -> UIMenu {
        let entry = store.index?.entry(path)
        let day = GraphPaths.day(fromDailyPath: path)
        var items: [UIMenuElement] = []
        // A note linking to a page, or holding a PDF: that, to read.
        if !ReaderController.sources(of: path, store: store).isEmpty {
            items.append(UIAction(title: "Read Note", image: UIImage(systemName: "globe")) { [weak self, weak sheet] _ in
                guard let self else { return }
                sheet?.saveAll()
                let from: UIViewController = sheet?.parent ?? shownStack.topViewController ?? self
                ReaderController.open(notePath: path, store: store, from: from)
            })
        }
        items += [
            UIAction(title: entry?.isInInbox == true ? "Take Out of Inbox" : "Add to Inbox",
                     image: UIImage(systemName: entry?.isInInbox == true ? "tray.and.arrow.up" : "tray.and.arrow.down")) { [weak self] _ in
                self?.store.setFrontmatter(path, "inbox", entry?.isInInbox == true ? nil : "true")
            },
        ]
        if day == nil {
            items.append(UIAction(title: entry?.pin == nil ? "Pin" : "Unpin", image: UIImage(systemName: entry?.pin == nil ? "pin" : "pin.slash")) { [weak self] _ in
                guard let self, let index = store.index else { return }
                store.setFrontmatter(path, "pinned", entry?.pin == nil ? String(index.nextPinOrder) : nil)
            })
            items.append(UIAction(title: entry?.isTopic == true ? "Not a Topic" : "Make a Topic", image: UIImage(systemName: "number")) { [weak self] _ in
                self?.store.setFrontmatter(path, "topic", entry?.isTopic == true ? nil : "true")
            })
            items.append(UIAction(title: entry?.cover == nil ? "Add Cover…" : "Change Cover…", image: UIImage(systemName: "photo.artframe")) { [weak self, weak sheet] _ in
                sheet?.saveAll()
                self?.chooseCover(for: path)
            })
            if entry?.cover != nil {
                items.append(UIAction(title: "Remove Cover", image: UIImage(systemName: "rectangle.slash")) { [weak self, weak sheet] _ in
                    sheet?.saveAll()
                    self?.store.setCover(path, nil)
                })
            }
        }
        if let sheet, sheet.canMoveDoneToBottom(in: path) {
            items.append(UIAction(title: "Move Done to Bottom", image: UIImage(systemName: "arrow.down.to.line")) { [weak sheet] _ in
                sheet?.moveDoneToBottom(in: path)
            })
        }
        items.append(UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in
            UIPasteboard.general.string = "[[" + (day?.description ?? entry?.title ?? (path as NSString).deletingPathExtension) + "]]"
        })
        if day == nil {
            items.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "Delete Note…", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.confirmDelete(path, title: entry?.title ?? (path as NSString).lastPathComponent)
                },
            ]))
        }
        return UIMenu(title: SliceBlock.name(path, store: store), options: .displayInline, children: items)
    }

    /// Something gone wrong, said for a moment over the foot of the page.
    private func say(_ message: String) {
        let label = PaddedLabel()
        label.text = message
        label.numberOfLines = 3
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = Ink.paper
        label.backgroundColor = Ink.text.withAlphaComponent(0.9)
        label.layer.cornerRadius = 12
        label.layer.masksToBounds = true
        let size = label.sizeThatFits(CGSize(width: view.bounds.width - 64, height: 200))
        label.frame = CGRect(x: (view.bounds.width - min(size.width, view.bounds.width - 32)) / 2,
                             y: bar.frame.minY - size.height - 12, width: min(size.width, view.bounds.width - 32), height: size.height)
        view.addSubview(label)
        UIView.animate(withDuration: 0.3, delay: 3, options: []) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
    }

    // MARK: Deleting

    private func confirmDelete(_ path: String, title: String) {
        let alert = UIAlertController(title: "Delete “\(title)”?",
                                      message: "It stays in the graph’s history, and your other devices lose it when this iPhone next syncs.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in self?.delete(path) })
        topPresenter.present(alert, animated: true)
    }

    private func delete(_ path: String) {
        for note in notePanes {
            note.sheet?.discard(path)
            note.forget(path)
        }
        store.delete(path)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        layoutChanged()
    }

    // MARK: Covers

    private var coverFor: String?

    private func chooseCover(for path: String) {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        coverFor = path
        present(picker, animated: true)
    }

    // MARK: Settings, signing in

    func showSettings() {
        let settings = UIHostingController(rootView: SettingsView(onChange: { [weak self] in self?.typographyChanged() },
                                                                  onDone: { [weak self] in self?.dismiss(animated: true) }))
        if let sheet = settings.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(settings, animated: true)
    }

    /// The face or size changed: every lens made again in it, where it was.
    private func typographyChanged() {
        saveAll()
        saveLayout()
        for navigation in stacks.values {
            navigation.willMove(toParent: nil)
            navigation.view.removeFromSuperview()
            navigation.removeFromParent()
        }
        stacks = [:]
        _ = removeDetail()
        restoreLayout()
        view.setNeedsLayout()
    }

    private func signIn() {
        let host = UIHostingController(rootView: SignInRunner(account: store.account) { [weak self] error in
            guard let self else { return }
            dismiss(animated: true)
            if let error { return say(error) }
            Task { @MainActor in
                await self.store.sync()
                if let error = self.store.syncError { self.say(error) }
            }
        })
        host.view.backgroundColor = .clear
        host.modalPresentationStyle = .overFullScreen
        present(host, animated: false)
    }

    // MARK: The calendar

    func calendarController(day: Day) -> CalendarController? {
        guard let graph = store.graph, let index = store.index else { return nil }
        return CalendarController(month: NoteCalendar.Month(day), marks: NoteCalendar.marks(graph: graph, index: index),
                                  weeks: NoteCalendar.weeksWithNotes(index: index))
    }

    // MARK: Dictating

    private var dictation: Dictation?
    private var askingToListen = false

    private func beginDictation() {
        guard dictation == nil, !askingToListen else { return }
        askingToListen = true
        Task { @MainActor in
            let allowed = await Dictation.allowed()
            askingToListen = false
            guard allowed, bar.isDictating else {
                bar.hideHeard()
                if !allowed { say("Prism can’t listen: allow the microphone and speech recognition in Settings.") }
                return
            }
            let dictation = Dictation()
            do {
                try dictation.start { [weak self] text in self?.bar.showHeard(text) }
                self.dictation = dictation
            } catch {
                bar.hideHeard()
                say("Dictation isn’t available right now.")
            }
        }
    }

    private func endDictation(cancelled: Bool) {
        guard let dictation else {
            bar.hideHeard()
            return
        }
        self.dictation = nil
        Task { @MainActor in
            let text = await dictation.stop()
            bar.hideHeard()
            guard !cancelled, !text.isEmpty else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            addToToday(text)
        }
    }

    // MARK: The icon's quick actions

    private func openQuickAction() {
        guard let path = QuickActions.pending else { return }
        QuickActions.pending = nil
        if bar.isSearching { leaveSearch(back: false) }
        presentedViewController?.dismiss(animated: false)
        open(PanePlace(path: path))
    }

    private func refreshQuickActions() {
        guard let index = store.index else { return }
        QuickActions.update(index.all
            .filter { $0.day == nil && !$0.path.hasPrefix(GraphPaths.weeklyDirectory + "/") }
            .sorted { $0.modified > $1.modified })
    }

    // MARK: Scripted checks

    /// `-PrismOpen <what>` at launch: `inbox`, `pinned`, `tasks`,
    /// `schedule`, `search:<words>`, `find:<words>`, `note:<path>`,
    /// `dictated:<text>`.
    /// `-PrismOpen <step>[;<step>…]`: each step after the one before.
    private func openForScript() {
        guard let specs = UserDefaults.standard.string(forKey: "PrismOpen") else { return }
        for (i, spec) in specs.components(separatedBy: ";").enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2 * Double(i)) { self.openStepForScript(spec) }
        }
    }

    private func openStepForScript(_ spec: String) {
        let (head, rest) = spec.firstIndex(of: ":").map { (String(spec[..<$0]), String(spec[spec.index(after: $0)...])) } ?? (spec, "")
        DispatchQueue.main.async { [self] in
            switch head {
            case "inbox": show(.inbox)
            case "pinned": show(.pinned)
            case "tasks": show(.tasks)
            case "schedule":
                show(.daily)
                dayPager?.setFace(.schedule)
            case "find":
                showSearch()
                bar.field.text = rest
                (stacks[.search]?.viewControllers.first as? SearchController)?.search(rest)
            case "search":
                showSearch()
                bar.field.text = rest
                bar.field.resignFirstResponder()
                (stacks[.search]?.viewControllers.first as? SearchController)?.searchEverything(rest)
            case "note": open(PanePlace(path: rest))
            // A link note opened, and its page read.
            case "reader":
                open(PanePlace(path: rest))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let note = self.isWide && self.lens != .daily ? self.detail : self.shownStack.topViewController
                    if let note { ReaderController.open(notePath: rest, store: self.store, from: note) }
                }
            case "dictated": DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.addToToday(rest) }
            case "sidebar": flipSidebar()
            case "readermode": readerColumn?.toggleReading()
            case "turn":
                let shown = readerColumn ?? shownStack.topViewController as? ReaderController ?? presentedViewController as? ReaderController
                shown?.turn(Int(rest) ?? 1)
            default: break
            }
        }
    }

    // MARK: Kept across launches

    /// The lens shown, the note open over each, the note beside, the day.
    struct Layout: Codable {
        var lens: Lens
        var notes: [String: PaneHistory]
        var detail: PaneHistory?
        var face: DayFace?
    }

    private var layoutNow: Layout {
        var notes: [String: PaneHistory] = [:]
        for (lens, navigation) in stacks {
            if let note = navigation.viewControllers.last(where: { $0 is NoteController }) as? NoteController {
                notes[lens.rawValue] = note.history
            }
        }
        return Layout(lens: lens == .search ? lensBeforeSearch : lens, notes: notes, detail: detail?.history, face: dayPager?.face)
    }

    private var saveTimer: Timer?

    func layoutChanged() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveLayout() }
        }
    }

    func saveLayout() {
        saveTimer?.invalidate()
        guard let data = try? JSONEncoder().encode(layoutNow) else { return }
        UserDefaults.standard.set(data, forKey: "Lenses")
    }

    /// The lenses as they were left: the one shown, the note over each.
    private func restoreLayout() {
        let layout = UserDefaults.standard.data(forKey: "Lenses").flatMap { try? JSONDecoder().decode(Layout.self, from: $0) }
        let exists = { [store] (history: PaneHistory) in store.graph?.exists(path: history.current.path) != false }
        lens = layout?.lens ?? .daily
        bar.lens = lens
        let navigation = stack(lens)
        if let face = layout?.face { dayPager?.setFace(face) }
        for (key, history) in layout?.notes ?? [:] {
            guard let lens = Lens(rawValue: key), exists(history) else { continue }
            stack(lens).pushViewController(makeNoteController(history, inStack: true), animated: false)
        }
        if let history = layout?.detail, exists(history) {
            pendingDetail = history
        }
        _ = navigation
        arrange()
        updateBarTitle()
    }

    /// The note beside, wide, put back once it is known to be wide.
    private var pendingDetail: PaneHistory? {
        didSet {
            guard let history = pendingDetail else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingDetail != nil else { return }
                self.pendingDetail = nil
                if self.isWide, self.detail == nil {
                    self.showDetail(history.current)
                    self.detail?.replaceHistory(history)
                }
            }
        }
    }
}

extension NoteController {
    /// Its history, as another pane's was: moved over whole.
    func replaceHistory(_ history: PaneHistory) {
        guard history.current == self.history.current else { return }
        setHistory(history)
    }
}

/// The root, for SwiftUI.
struct PrismView: UIViewControllerRepresentable {
    let store: PrismStore
    let scheduler: SyncScheduler

    func makeUIViewController(context: Context) -> PrismController {
        let controller = PrismController(store: store)
        scheduler.beforeSync = { [weak controller] in controller?.saveAll() }
        return controller
    }
    func updateUIViewController(_ controller: PrismController, context: Context) {}
}

/// Runs GitHub's sign-in, which wants SwiftUI's session to show its sheet,
/// and says how it went: nil, signed in.
private struct SignInRunner: View {
    let account: GitHubAccount
    let done: (String?) -> Void
    @Environment(\.webAuthenticationSession) private var session

    var body: some View {
        Color.clear.task {
            do {
                try await account.signIn(session.github)
                done(nil)
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                done(nil)
            } catch {
                done(error.localizedDescription)
            }
        }
    }
}

extension PrismController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let path = coverFor, let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
        coverFor = nil
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage, let data = Self.coverData(image) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                do {
                    try self.store.setCover(path, picture: data, extension: "jpg")
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } catch {
                    self.say("The cover could not be kept: \(error.localizedDescription)")
                }
            }
        }
    }

    /// A picture at most 2400 points on its longer side, as a JPEG.
    nonisolated static func coverData(_ image: UIImage) -> Data? {
        let longest: CGFloat = 2400
        let scale = min(1, longest / max(image.size.width, image.size.height, 1))
        guard scale < 1 else { return image.jpegData(compressionQuality: 0.85) }
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.85)
    }
}
