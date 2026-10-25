import SwiftUI
import AuthenticationServices
import UIKit
import PhotosUI
import SafariServices
import ReflectCore
import PrismCore
import ReflectGit2

/// Prism's views, a tab each along the bottom — the days, the inbox, the
/// tasks — each a stack of sheets: going somewhere pushes one, Back or a
/// swipe from the edge pops it. Among them, a button to write in today; at
/// their right, apart, search — which, tapped, opens out into a field, the
/// tabs gathered into one button at its left to go back by.
final class ColumnsController: UITabBarController, UITabBarControllerDelegate, UINavigationControllerDelegate, UIGestureRecognizerDelegate {
    let store: PrismStore
    /// The bar along the bottom, in the system's tab bar's place.
    private lazy var bar = BottomBar()
    private var barToBottom: NSLayoutConstraint?
    /// How far the keyboard reaches up the screen, from its foot.
    private var keyboardHeight: CGFloat = 0
    /// Each column's tab, in order.
    private var columnTabs: [UITab] = []
    private var searchTab: UISearchTab?
    /// Going to a note or a day, or searching every note: in the search tab.
    private lazy var finder = FinderController(store: store, embedded: true)
    private lazy var searchNavigation = UINavigationController(rootViewController: finder)
    /// The tab shown before search: where what is found there opens.
    private var lastColumn = 0

    /// The tabs, in order, with what each shows and its icon.
    static let tabs: [(kind: SheetKind, title: String, symbol: String)] = [
        (.timeline, "Daily", "house"),
        (.inbox, "Inbox", "tray"),
    ]
    /// The inbox's tab, held, shows the pinned notes instead — and, held
    /// again, the inbox. Kept from one launch to the next.
    private static let inboxColumn = 1
    private static let pinnedTab: (kind: SheetKind, title: String, symbol: String) = (.pinned, "Pinned", "pin")
    private var showsPinned = UserDefaults.standard.bool(forKey: "InboxShowsPinned")

    /// The tab at a column, as it is now.
    private func tab(_ column: Int) -> (kind: SheetKind, title: String, symbol: String) {
        column == Self.inboxColumn && showsPinned ? Self.pinnedTab : Self.tabs[column]
    }

    init(store: PrismStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Each tab's stack.
    private(set) var columns: [UINavigationController] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        StallWatch.mark("columns loading")
        defer { StallWatch.mark("columns loaded") }
        view.backgroundColor = Ink.page
        delegate = self
        // What a name typed after `@` or `[[` could link to.
        OutlineEditor.suggest = { [weak store] query in
            guard let index = store?.index else { return [] }
            return LinkSuggestions.candidates(query, index: index)
        }
        columns = Self.tabs.indices.map(tab).map { tab in
            let navigation = UINavigationController(rootViewController: makeRoot(tab.kind))
            navigation.delegate = self
            styleBar(navigation)
            // No bar at the top: the name, back, and the menus are the bottom's.
            navigation.setNavigationBarHidden(true, animated: false)
            navigation.interactivePopGestureRecognizer?.delegate = self
            return navigation
        }
        columnTabs = zip(Self.tabs.indices.map(tab), columns).map { tab, navigation in
            UITab(title: tab.title, image: UIImage(systemName: tab.symbol), identifier: tab.title) { _ in navigation }
        }
        // Search: the finder, the field for it in the bar.
        styleBar(searchNavigation)
        finder.onChoose = { [weak self] place in self?.open(place) }
        let search = UISearchTab { [searchNavigation] _ in searchNavigation }
        searchTab = search
        tabs = columnTabs + [search]
        // The system's bar hidden: ours in its place, and the sheets kept
        // clear of it.
        setTabBarHidden(true, animated: false)
        additionalSafeAreaInsets.bottom = BottomBar.height + BottomBar.margin - 34 + BottomBar.gap
        setUpBar()
        restoreLayout()
        // Left for the background, or about to be: everything kept as it is.
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveLayout() }
            }
        }
        observe()
        observeSync()
        // A cover read: in the bar.
        NotificationCenter.default.addObserver(forName: .prismImageLoaded, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateBar() }
        }
        openForScript()
        // The tab left showing chosen before any is laid out: the others'
        // sheets not built at launch at all.
        if let page = pendingPage {
            pendingPage = nil
            select(column: page)
        }
        // A note chosen from the app's icon: opened now, or when chosen.
        QuickActions.onPending = { [weak self] in self?.openQuickAction() }
        DispatchQueue.main.async { [weak self] in self?.openQuickAction() }
        refreshQuickActions()
    }

    /// `-PrismOpen <kind>` — `search:<query>`, `backlinks:<path>`,
    /// `note:<path>`, `inbox`, `tasks`, `find`, `dictated:<text>` (added to
    /// today as dictation adds it) — at launch, for scripted checks.
    private func openForScript() {
        guard let spec = UserDefaults.standard.string(forKey: "PrismOpen"), let column = columns.first else { return }
        let (head, rest) = spec.firstIndex(of: ":").map { (String(spec[..<$0]), String(spec[spec.index(after: $0)...])) } ?? (spec, "")
        switch head {
        case "inbox": pendingPage = 1
        case "tasks": pendingPage = 2
        case "find": DispatchQueue.main.async { self.showSearch() }
        case "search": column.pushViewController(makeSheet(.search(rest)), animated: false)
        case "backlinks": column.pushViewController(makeSheet(.backlinks(rest)), animated: false)
        case "note": column.pushViewController(makeSheet(.note(rest)), animated: false)
        case "dictated": DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.addToToday(rest) }
        default: break
        }
    }

    /// Follows the store: notes changed — written here, or by a sync — are
    /// taken in by every sheet showing them.
    private func observe() {
        withObservationTracking {
            _ = store.revision
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                let changed = self.store.changed
                for column in self.columns {
                    for sheet in self.allSheets(column) { sheet.notesChanged(changed) }
                for case let host as NoteHost in column.viewControllers { host.notesChanged(changed) }
                }
                // What links where may have changed with them: counted again.
                self.backlinkCards = [:]
                self.updateBacklinks()
                self.refreshQuickActions()
                self.observe()
            }
        }
    }

    /// A sync under way: every sheet's menu button the sync arrows, turning.
    private func observeSync() {
        let syncing = withObservationTracking {
            store.isSyncing
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeSync() }
        }
        for column in columns {
            for sheet in allSheets(column) { sheet.showSyncing(syncing) }
        }
    }

    private func styleBar(_ navigation: UINavigationController) {
        let appearance = UINavigationBarAppearance()
        // No bar: the buttons float over the content, as in Threads.
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = .clear
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [.font: UIFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: Ink.text]
        navigation.navigationBar.standardAppearance = appearance
        navigation.navigationBar.scrollEdgeAppearance = appearance
        navigation.navigationBar.tintColor = Ink.text
    }

    // MARK: Writing a new note

    /// A column's tab, shown.
    private func select(column: Int) {
        guard columnTabs.indices.contains(column) else { return }
        if bar.isSearching { leaveSearch(back: false) }
        selectedTab = columnTabs[column]
        lastColumn = column
        updateBacklinks()
        updateBar()
    }

    /// The edge swiped from: back, where there is somewhere to go back to.
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        (selectedNavigation?.viewControllers.count ?? 0) > 1
    }

    /// Home: the days, back to their first sheet, at today.
    private func goHome() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if bar.isSearching { leaveSearch(back: false) }
        let days = columns[0]
        select(column: 0)
        if days.viewControllers.count > 1 { days.popToRootViewController(animated: true) }
        dayPager?.show(.today)
        setChromeHidden(false)
        layoutChanged()
    }

    /// The bar as the sheet shown is: its name and cover.
    func updateBar() {
        let navigation = selectedNavigation
        bar.canGoBack = (navigation?.viewControllers.count ?? 0) > 1
        guard let sheet = sheet(in: navigation?.topViewController) else {
            // A view with no note shown — an empty inbox: its name.
            if let host = navigation?.topViewController as? NoteHost { bar.setTitle([Self.viewTitle(host.rootKind)], symbol: Self.symbol(of: host.rootKind)) }
            return
        }
        // A day's or a week's mark is the calendar; another note's, its own.
        let path = sheet.currentNotePath
        let dated = path.map { GraphPaths.day(fromDailyPath: $0) != nil || GraphPaths.week(fromWeeklyPath: $0) != nil } ?? false
        bar.setTitle(names(of: sheet), cover: path.flatMap(cover(of:)),
                     symbol: path == nil ? Self.symbol(of: sheet.kind) : dated ? "calendar" : nil)
    }

    /// The note sheet a controller shows: itself, or the one a view of one
    /// note at a time shows.
    private func sheet(in controller: UIViewController?) -> SheetController? {
        (controller as? SheetController) ?? (controller as? NoteHost)?.sheet
    }

    /// Every note sheet in a column: its own, and those its views hold.
    private func allSheets(_ column: UINavigationController) -> [SheetController] {
        column.viewControllers.flatMap { ($0 as? SheetController).map { [$0] } ?? ($0 as? NoteHost)?.sheets ?? [] }
    }

    /// The days, a day at a time: the first column's root.
    private var dayPager: DayPager? { columns.first?.viewControllers.first as? DayPager }

    /// A column's root: the days, a page each; the inbox and the pinned, a
    /// list over the note chosen; else a sheet of notes.
    func makeRoot(_ kind: SheetKind) -> UIViewController {
        let host: NoteHost
        switch kind {
        case .timeline:
            let pager = DayPager(makeSheet: { [unowned self] kind in makeSheet(kind) },
                                 makeCalendar: { [unowned self] day in calendarController(day: day) })
            pager.marks = { [weak self] in
                guard let graph = self?.store.graph, let index = self?.store.index else { return [:] }
                return NoteCalendar.marks(graph: graph, index: index)
            }
            host = pager
        case .inbox, .pinned:
            host = NoteListController(kind: kind, store: store, makeSheet: { [unowned self] kind in makeSheet(kind) })
        default:
            return makeSheet(kind)
        }
        host.onShownChange = { [weak self] in
            self?.updateBar()
            self?.updateBacklinks()
            self?.layoutChanged()
        }
        return host
    }

    /// A view's name, with no note in it to name it.
    private static func viewTitle(_ kind: SheetKind) -> String {
        switch kind {
        case .timeline: "Daily"
        case .inbox: "Inbox"
        case .pinned: "Pinned"
        case .tasks: "Tasks"
        case .search(let query): query
        case .backlinks: "Linked Here"
        case .note: "Note"
        }
    }

    /// A view's mark, in the bar's field in a cover's stead.
    private static func symbol(of kind: SheetKind) -> String {
        switch kind {
        case .timeline: "house"
        case .inbox: "tray"
        case .pinned: "pin"
        case .tasks: "checkmark.circle"
        case .search: "magnifyingglass"
        case .backlinks: "arrow.turn.up.left"
        case .note: "doc.text"
        }
    }

    /// What a sheet is called, longest first: shorter ones where there is less room.
    private func names(of sheet: SheetController) -> [String] {
        if let path = sheet.currentNotePath { return SliceBlock.names(path, store: store) }
        switch sheet.kind {
        case .timeline: return ["Daily"]
        case .inbox: return ["Inbox"]
        case .pinned: return ["Pinned"]
        case .tasks: return ["Tasks"]
        case .search(let query): return [query]
        case .backlinks(let path): return SliceBlock.names(path, store: store).map { "Linked to " + $0 }
        case .note(let path): return SliceBlock.names(path, store: store)
        }
    }

    /// The views other than the days, for home held.
    private func viewEntries() -> [NoteFan.Entry] {
        [
            NoteFan.Entry(names: ["Inbox"], cover: nil, symbol: "tray") { [weak self] in self?.showInbox(pinned: false) },
            NoteFan.Entry(names: ["Pinned"], cover: nil, symbol: "pin") { [weak self] in self?.showInbox(pinned: true) },
            NoteFan.Entry(names: ["Tasks"], cover: nil, symbol: "checkmark.circle") { [weak self] in self?.showTasks() },
        ]
    }

    /// The inbox's column, showing the inbox or the pinned notes.
    private func showInbox(pinned: Bool) {
        if showsPinned == pinned { tabTapped(Self.inboxColumn) } else { togglePinned() }
    }

    /// The tasks, on the stack of the view shown.
    private func showTasks() {
        guard let sheet = sheet(in: selectedNavigation?.topViewController) else { return }
        if case .tasks = sheet.kind { return }
        push(.tasks, from: sheet)
    }

    /// A note's cover, small and round, as the bar and the fans show it.
    private func cover(of path: String) -> UIImage? {
        NoteCover.source(in: store.text(path)).flatMap { PhoneImages.thumbnail($0, side: NoteChip.round) }
    }

    /// The menu in the bar's pill: where to go, what can be done to the
    /// note shown, and the app's own.
    private func barMenu() -> UIMenu {
        let views: [UIMenuElement] = [
            UIAction(title: "Daily", image: UIImage(systemName: "house")) { [weak self] _ in self?.tabTapped(0) },
            UIAction(title: "Inbox", image: UIImage(systemName: "tray")) { [weak self] _ in self?.showInbox(pinned: false) },
            UIAction(title: "Pinned", image: UIImage(systemName: "pin")) { [weak self] _ in self?.showInbox(pinned: true) },
            UIAction(title: "Tasks", image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in self?.showTasks() },
            UIAction(title: "Calendar", image: UIImage(systemName: "calendar")) { [weak self] _ in self?.showCalendar() },
        ]
        var sections: [UIMenuElement] = [UIMenu(options: .displayInline, children: views)]
        guard let sheet = sheet(in: selectedNavigation?.topViewController) else { return UIMenu(children: sections) }
        if let path = sheet.currentNotePath {
            sections.append(UIMenu(title: SliceBlock.name(path, store: store), options: .displayInline,
                                   children: noteMenu(path, from: sheet).children))
        }
        sections.append(contentsOf: menu(for: sheet).children)
        return UIMenu(children: sections)
    }

    // MARK: The bar

    private func setUpBar() {
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        // At the foot; while searching, over the keyboard when it is up.
        let toBottom = bar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -BottomBar.margin)
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.keyboardMoved(note) }
        }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: BottomBar.height),
            toBottom,
        ])
        barToBottom = toBottom
        bar.onHome = { [weak self] in self?.goHome() }
        bar.onBack = { [weak self] in
            guard let navigation = self?.selectedNavigation, navigation.viewControllers.count > 1 else { return }
            navigation.popViewController(animated: true)
        }
        bar.menu = { [weak self] in self?.barMenu() ?? UIMenu() }
        bar.onWrite = { [weak self] in
            guard let self else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            writeToday()
        }
        bar.onDictateBegin = { [weak self] in self?.beginDictation() }
        bar.onDictateEnd = { [weak self] cancelled in self?.endDictation(cancelled: cancelled) }
        bar.onSearch = { [weak self] in self?.showSearch() }
        bar.onHold = { [weak self] what, state, point in self?.held(what, state, at: point) }

        bar.onLeaveSearch = { [weak self] in self?.leaveSearch(back: true) }
        bar.onQuery = { [weak self] text in self?.finder.search(text) }
        bar.onSubmit = { [weak self] in self?.finder.searchEverything() }
    }

    /// The keyboard came, went, or changed: the bar, searching, kept over it.
    private func keyboardMoved(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let local = view.convert(frame, from: nil)
        keyboardHeight = max(0, view.bounds.maxY - local.minY)
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        guard bar.isSearching else { return }
        placeBar()
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) { self.view.layoutIfNeeded() }
    }

    /// At the foot, or — searching — riding on the keyboard.
    private func placeBar() {
        let lift = bar.isSearching && keyboardHeight > 0 ? keyboardHeight + BottomBar.gap : BottomBar.margin
        barToBottom?.constant = -lift
    }

    /// A view's tab tapped: gone to; tapped again, back to its first sheet —
    /// the days, to today; any other, there already, to its top.
    private func tabTapped(_ column: Int) {
        if StallWatch.enabled { StallWatch.mark("tab tapped") }
        if column == selectedColumn, !bar.isSearching {
            let navigation = columns[column]
            if navigation.viewControllers.count > 1 {
                navigation.popToRootViewController(animated: true)
            } else if let pager = navigation.viewControllers.first as? DayPager {
                pager.show(.today)
            } else if let root = sheet(in: navigation.viewControllers.first) {
                // Its first sheet already: to the top of it.
                root.scrollToTop()
            }
        }
        select(column: column)
        setChromeHidden(false)
        layoutChanged()
    }

    /// The inbox's tab to the pinned notes, or back: its column started
    /// afresh on the other, and shown.
    private func togglePinned() {
        showsPinned.toggle()
        UserDefaults.standard.set(showsPinned, forKey: "InboxShowsPinned")
        let tab = tab(Self.inboxColumn)
        columnTabs[Self.inboxColumn].title = tab.title
        let navigation = columns[Self.inboxColumn]
        UIView.transition(with: navigation.view, duration: 0.25, options: .transitionCrossDissolve) {
            navigation.setViewControllers([self.makeRoot(tab.kind)], animated: false)
        }
        select(column: Self.inboxColumn)
        setChromeHidden(false)
        layoutChanged()
    }

    /// The column of the tab showing — or, in search, of the one before.
    private var selectedColumn: Int { selectedTab.flatMap { tab in columnTabs.firstIndex { $0 === tab } } ?? lastColumn }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.bringSubviewToFront(bar)
        if let page = pendingPage {
            pendingPage = nil
            select(column: page)
        }
    }

    // MARK: Out of the way, while reading

    /// The tab bar and the top's buttons, gone while scrolling down to read,
    /// back on scrolling up, near the top, or going anywhere.
    private(set) var chromeHidden = false

    func setChromeHidden(_ hidden: Bool) {
        guard hidden != chromeHidden else { return }
        chromeHidden = hidden
        // Gathered to the name alone, small and low, as Safari's.
        bar.setSmall(hidden)
    }

    private var selectedNavigation: UINavigationController? { columns.indices.contains(selectedColumn) ? columns[selectedColumn] : nil }

    // MARK: Sheets

    func makeSheet(_ kind: SheetKind, around ref: NoteRef? = nil) -> SheetController {
        let sheet = SheetController(kind: kind, store: store, around: ref)
        sheet.syncing = store.isSyncing
        sheet.onOpen = { [weak self, weak sheet] kind in
            guard let self, let sheet else { return }
            push(kind, from: sheet)
        }
        sheet.onOpenAt = { [weak self, weak sheet] path, row in
            guard let self, let sheet else { return }
            sheet.saveAll()
            let opened = makeSheet(.note(path))
            opened.mark(unfoldedRow: row)
            sheet.navigationController?.pushViewController(opened, animated: true)
        }
        sheet.onLink = { [weak self, weak sheet] link in
            guard let self, let sheet else { return }
            follow(link, from: sheet)
        }
        sheet.onFlag = { [weak self] path, key, value in self?.store.setFrontmatter(path, key, value) }
        sheet.onCompose = { [weak self, weak sheet] in
            guard let self, let sheet else { return }
            compose(from: sheet)
        }
        sheet.onChromeHidden = { [weak self] hidden in self?.setChromeHidden(hidden) }
        sheet.menu = { [weak self] sheet in self?.menu(for: sheet) ?? UIMenu() }
        sheet.onCurrentNote = { [weak self, weak sheet] in
            guard let self, let sheet, sheet === self.sheet(in: selectedNavigation?.topViewController) else { return }
            updateBacklinks()
            updateBar()
        }
        sheet.noteMenu = { [weak self] sheet, path in self?.noteMenu(path, from: sheet) ?? UIMenu() }
        sheet.onStateChange = { [weak self] in self?.layoutChanged() }
        sheet.onFind = { [weak self, weak sheet] in
            guard let self, let sheet else { return }
            showFinder(from: sheet)
        }
        return sheet
    }

    /// Something opened from a sheet: on its tab's stack.
    func push(_ kind: SheetKind, from sheet: SheetController) {
        sheet.saveAll()
        sheet.navigationController?.pushViewController(makeSheet(kind), animated: true)
    }

    /// A link tapped: a note by its title, a day by its date, or the web.
    func follow(_ link: String, from sheet: SheetController) {
        if link.hasPrefix("[["), link.hasSuffix("]]") {
            let title = String(link.dropFirst(2).dropLast(2)).components(separatedBy: "|")[0].trimmingCharacters(in: .whitespaces)
            if let day = Day(title) {
                push(.note(GraphPaths.dailyPath(for: day)), from: sheet)
            } else if let path = store.index?.resolve(title) {
                push(.note(path), from: sheet)
            } else if let graph = store.graph, let path = try? NoteCreation.create(title: title, in: graph.root) {
                store.noteChanged([path])
                push(.note(path), from: sheet)
            }
        } else if let url = URL(string: link), url.scheme != nil {
            openWeb(url)
        }
    }

    /// A page of the web, in Safari's own view over the app — its reader,
    /// sharing, and a button to go on in Safari itself. Mail, a call, an
    /// app's own address: to whatever opens it.
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
        var presenter: UIViewController = self
        while let next = presenter.presentedViewController { presenter = next }
        presenter.present(safari, animated: true)
    }

    /// Everything typed, in every tab, written.
    func saveAll() {
        for column in columns {
            for sheet in allSheets(column) { sheet.saveAll() }
        }
    }

    // MARK: Signing in again

    /// GitHub's sign-in, in the system's sheet; signed in, a sync.
    private func signIn(from sheet: SheetController?) {
        let host = UIHostingController(rootView: SignInRunner(account: store.account) { [weak self] error in
            guard let self else { return }
            dismiss(animated: true)
            if let error {
                sheet?.say(error)
                return
            }
            Task { @MainActor in
                await self.store.sync()
                if let error = self.store.syncError { sheet?.say(error) }
            }
        })
        host.view.backgroundColor = .clear
        host.modalPresentationStyle = .overFullScreen
        present(host, animated: false)
    }

    // MARK: The menu

    /// The ≡ menu on a tab's first sheet, and the ⋯ menu on a note: the
    /// app's — new note, tasks, the sync, the notes two devices wrote at
    /// once, settings. What can be done to the note is its title pill's.
    func menu(for sheet: SheetController) -> UIMenu {
        var sections: [UIMenuElement] = []
        var sync: [UIMenuElement] = store.isSyncing ? [
            UIAction(title: "Syncing…", image: UIImage(systemName: "arrow.triangle.2.circlepath"), attributes: .disabled) { _ in },
        ] : [
            UIAction(title: "Sync Now", image: UIImage(systemName: "arrow.triangle.2.circlepath")) { [weak self, weak sheet] _ in
                guard let self else { return }
                saveAll()
                Task { @MainActor in
                    await self.store.sync()
                    if let error = self.store.syncError { sheet?.say(error) }
                }
            },
        ]
        // Signed out — a refresh turned away, or signed out by hand: the way
        // back in, here, where the graph already is.
        if !store.account.isSignedIn {
            sync.insert(UIAction(title: "Sign In to GitHub…", image: UIImage(systemName: "person.crop.circle.badge.exclamationmark")) {
                [weak self, weak sheet] _ in
                self?.signIn(from: sheet)
            }, at: 0)
        }
        if let error = store.syncError {
            sync.append(UIAction(title: "Last sync failed", subtitle: error, attributes: .disabled) { _ in })
        } else if let synced = store.lastSynced {
            sync.append(UIAction(title: "Synced " + synced.formatted(.relative(presentation: .named)),
                                 subtitle: store.lastSyncTook.map { "Took \($0)" }, attributes: .disabled) { _ in })
        }
        sections.insert(UIMenu(options: .displayInline, children: [
            UIAction(title: "New Note", image: UIImage(systemName: "square.and.pencil")) { [weak self, weak sheet] _ in
                guard let self, let sheet else { return }
                compose(from: sheet)
            },
        ]), at: 0)
        sections.append(UIMenu(options: .displayInline, children: sync))
        if !store.conflicted.isEmpty {
            sections.append(UIMenu(title: "Edited on Two Devices", options: .displayInline, children: store.conflicted.prefix(8).map { path in
                UIAction(title: SliceBlock.name(path, store: store), image: UIImage(systemName: "arrow.triangle.merge")) { [weak self, weak sheet] _ in
                    guard let self, let sheet else { return }
                    push(.note(path), from: sheet)
                }
            }))
        }
        sections.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "Settings…", image: UIImage(systemName: "textformat")) { [weak self] _ in self?.showSettings() },
        ]))
        return UIMenu(children: sections)
    }

    // MARK: Settings

    /// The face and size notes are set in: each change shown at once, the
    /// sheets set again where they were.
    func showSettings() {
        let settings = UIHostingController(rootView: SettingsView(onChange: { [weak self] in self?.typographyChanged() },
                                                                  onDone: { [weak self] in self?.dismiss(animated: true) }))
        if let sheet = settings.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(settings, animated: true)
    }

    /// The face or size changed: every tab's sheets made again in it, each
    /// where it was read to — what is typed written first.
    private func typographyChanged() {
        saveAll()
        let layout = layoutNow
        for (c, navigation) in columns.enumerated() where layout.columns.indices.contains(c) {
            let sheets = layout.columns[c]
            let made = sheets.enumerated().map { s, sheet -> SheetController in
                let made = makeSheet(sheet.kind, around: s == 0 && sheet.kind == .timeline ? .day(.today) : nil)
                made.restore(place: sheet.place, focus: nil)
                return made
            }
            if !made.isEmpty { navigation.setViewControllers(made, animated: false) }
        }
        finder.view.setNeedsLayout()
    }

    /// What can be done to one note: what links to it, its inbox, topic and
    /// pin, a link to it copied.
    func noteMenu(_ path: String, from sheet: SheetController) -> UIMenu {
        let entry = store.index?.entry(path)
        let day = GraphPaths.day(fromDailyPath: path)
        var items: [UIMenuElement] = [
            UIAction(title: "Linked Here", image: UIImage(systemName: "link")) { [weak self, weak sheet] _ in
                guard let self, let sheet else { return }
                push(.backlinks(path), from: sheet)
            },
            UIAction(title: entry?.isInInbox == true ? "Take Out of Inbox" : "Add to Inbox",
                     image: UIImage(systemName: entry?.isInInbox == true ? "tray.and.arrow.up" : "tray.and.arrow.down")) { [weak self] _ in
                self?.store.setFrontmatter(path, "inbox", entry?.isInInbox == true ? nil : "true")
            },
        ]
        if day == nil {
            items.append(UIAction(title: entry?.isTopic == true ? "Not a Topic" : "Make a Topic", image: UIImage(systemName: "number")) { [weak self] _ in
                self?.store.setFrontmatter(path, "topic", entry?.isTopic == true ? nil : "true")
            })
            items.append(UIAction(title: entry?.pin == nil ? "Pin" : "Unpin", image: UIImage(systemName: entry?.pin == nil ? "pin" : "pin.slash")) { [weak self] _ in
                guard let self, let index = store.index else { return }
                store.setFrontmatter(path, "pinned", entry?.pin == nil ? String(index.nextPinOrder) : nil)
            })
        }
        if day == nil {
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
        if sheet.canMoveDoneToBottom(in: path) {
            items.append(UIAction(title: "Move Done to Bottom", image: UIImage(systemName: "arrow.down.to.line")) { [weak sheet] _ in
                sheet?.moveDoneToBottom(in: path)
            })
        }
        items.append(UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in
            UIPasteboard.general.string = "[[" + (day?.description ?? entry?.title ?? (path as NSString).deletingPathExtension) + "]]"
        })
        // Among others, how its card shows it.
        if sheet.listsNotes {
            let current = CardModes.mode(path)
            let modes: [(CardMode, String)] = [(.full, "doc.plaintext"), (.summary, "text.below.photo"), (.collapsed, "rectangle.compress.vertical")]
            items.append(UIMenu(title: "Show As", image: UIImage(systemName: "rectangle.stack"), children: modes.map { mode, symbol in
                UIAction(title: mode.name, image: UIImage(systemName: symbol), state: mode == current ? .on : .off) { _ in
                    CardModes.set(mode, for: path)
                }
            }))
        }
        // Last, set apart: what cannot be undone here.
        if day == nil {
            items.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "Delete Note…", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.confirmDelete(path, title: entry?.title ?? (path as NSString).lastPathComponent)
                },
            ]))
        }
        return UIMenu(options: .displayInline, children: items)
    }

    // MARK: Deleting

    /// Asks, then deletes a note: its file out of the graph, every card of
    /// it let go unwritten, every sheet of it alone off its stack.
    private func confirmDelete(_ path: String, title: String) {
        let alert = UIAlertController(title: "Delete “\(title)”?",
                                      message: "It stays in the graph’s history, and your other devices lose it when this iPhone next syncs.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in self?.delete(path) })
        var presenter: UIViewController = self
        while let next = presenter.presentedViewController { presenter = next }
        presenter.present(alert, animated: true)
    }

    private func delete(_ path: String) {
        for column in columns {
            for sheet in allSheets(column) { sheet.discard(path) }
        }
        store.delete(path)
        for column in columns {
            let kept = column.viewControllers.enumerated().filter { index, controller in
                index == 0 || (controller as? SheetController)?.kind != .note(path)
            }.map(\.element)
            if kept.count != column.viewControllers.count { column.setViewControllers(kept, animated: column === selectedNavigation) }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        layoutChanged()
    }

    // MARK: Covers

    /// The note a picture is being chosen for, as its cover.
    private var coverFor: String?

    /// A picture from Photos, for a note's cover.
    private func chooseCover(for path: String) {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        coverFor = path
        present(picker, animated: true)
    }

    /// Go to a note or a day, or search them all: the search tab, opened out.
    func showFinder(from sheet: SheetController) {
        sheet.saveAll()
        showSearch()
    }

    func showSearch() {
        guard let searchTab, !bar.isSearching else { return }
        sheet(in: selectedNavigation?.topViewController)?.saveAll()
        lastColumn = selectedColumn
        // Opened out from small or full alike, in one movement.
        bar.setSearching(true)
        setChromeHidden(false)
        selectedTab = searchTab
        placeBar()
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0) { self.view.layoutIfNeeded() }
        bar.field.becomeFirstResponder()
    }

    /// Search put away: back to the view it was opened from, when `back`.
    private func leaveSearch(back: Bool) {
        guard bar.isSearching else { return }
        bar.field.resignFirstResponder()
        bar.setSearching(false)
        placeBar()
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0) { self.view.layoutIfNeeded() }
        if back { select(column: lastColumn) }
        updateBacklinks()
    }

    /// Something found: a day in the days tab, the rest on the stack of the
    /// tab search was opened from — gone back to.
    private func open(_ place: FinderController.Place) {
        switch place {
        case .day(let day):
            if store.graph?.exists(path: GraphPaths.dailyPath(for: day)) == false { store.reveal([day]) }
            guard let days = columns.first, let pager = dayPager else { return }
            select(column: 0)
            days.popToRootViewController(animated: false)
            pager.show(day)
        case .note(let path):
            openInColumn(.note(path))
        case .search(let query):
            openInColumn(.search(query))
        }
        finder.reset()
        bar.field.text = ""
    }

    /// The notes written in last — not the days, which the days tab has —
    /// to go to, oldest first: the latest at the menu's foot, under the thumb.
    /// The note the icon's quick action chose, opened.
    private func openQuickAction() {
        guard let path = QuickActions.pending else { return }
        QuickActions.pending = nil
        if bar.isSearching { leaveSearch(back: false) }
        presentedViewController?.dismiss(animated: false)
        openInColumn(.note(path))
    }

    /// The icon's notes, as the latest are now.
    private func refreshQuickActions() {
        guard let index = store.index else { return }
        QuickActions.update(index.all
            .filter { $0.day == nil && !$0.path.hasPrefix(GraphPaths.weeklyDirectory + "/") }
            .sorted { $0.modified > $1.modified })
    }

    private func recentNotes() -> [NoteFan.Entry] {
        guard let index = store.index else { return [] }
        let recent = index.all
            .filter { $0.day == nil && !$0.path.hasPrefix(GraphPaths.weeklyDirectory + "/") }
            .sorted { $0.modified > $1.modified }
            .prefix(10)
        return recent.map { entry in
            NoteFan.Entry(names: SliceBlock.names(entry.path, store: store), cover: cover(of: entry.path), path: entry.path) { [weak self] in
                self?.openInColumn(.note(entry.path))
            }
        }
    }

    private func openInColumn(_ kind: SheetKind) {
        let column = lastColumn
        select(column: column)
        guard let sheet = sheet(in: columns[column].topViewController) else { return }
        push(kind, from: sheet)
    }

    // MARK: The calendar

    /// A month of days, the Days tab held: those with notes marked, and how
    /// far along each one's to-dos are. A day tapped is gone to.
    func showCalendar() {
        // The days' own: the month over the day shown.
        if let pager = dayPager {
            select(column: 0)
            columns[0].popToRootViewController(animated: false)
            return pager.showCalendar(true)
        }
        guard let calendar = calendarController(day: .today) else { return }
        calendar.onChoose = { [weak self, weak calendar] day in
            calendar?.dismiss(animated: true)
            self?.open(.day(day))
        }
        calendar.onChooseWeek = { [weak self, weak calendar] week in
            calendar?.dismiss(animated: true)
            self?.open(.note(GraphPaths.weeklyPath(for: week)))
        }
        if let sheet = calendar.sheetPresentationController {
            let height = calendar.preferredHeight(width: view.bounds.width)
            sheet.detents = [.custom { _ in height }]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 28
        }
        present(calendar, animated: true)
    }

    /// The month a day is in: the days with notes marked, how far along each's to-dos are.
    func calendarController(day: Day) -> CalendarController? {
        guard let graph = store.graph, let index = store.index else { return nil }
        let calendar = CalendarController(month: NoteCalendar.Month(day), marks: NoteCalendar.marks(graph: graph, index: index),
                                          weeks: NoteCalendar.weeksWithNotes(index: index))
        calendar.onChooseWeek = { [weak self] week in
            self?.dayPager?.showCalendar(false)
            self?.open(.note(GraphPaths.weeklyPath(for: week)))
        }
        return calendar
    }

    // MARK: Dictating

    private var dictation: Dictation?
    /// Asked for leave to listen, and not yet told.
    private var askingToListen = false

    /// The + held: listening, what is heard shown over the bar.
    private func beginDictation() {
        guard dictation == nil, !askingToListen else { return }
        askingToListen = true
        Task { @MainActor in
            let allowed = await Dictation.allowed()
            askingToListen = false
            // Let go meanwhile — as when first asked — nothing to hear.
            guard allowed, bar.isDictating else {
                bar.hideHeard()
                if !allowed { currentSheet?.say("Prism can’t listen: allow the microphone and speech recognition in Settings.") }
                return
            }
            let dictation = Dictation()
            do {
                try dictation.start { [weak self] text in self?.bar.showHeard(text) }
                self.dictation = dictation
            } catch {
                bar.hideHeard()
                currentSheet?.say("Dictation isn’t available right now.")
            }
        }
    }

    /// Let go: what was said, the first row of today.
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

    /// A row put first in today — not typed in: shown, and written.
    func addToToday(_ text: String) {
        sheet(in: selectedNavigation?.topViewController)?.saveAll()
        guard let days = columns.first, let pager = dayPager else { return }
        select(column: 0)
        setChromeHidden(false)
        days.popToRootViewController(animated: false)
        let today = NoteRef.day(.today)
        pager.show(.today, animated: false)
        DispatchQueue.main.async { pager.sheet?.addAtTop(of: today, text: text) }
    }

    private var currentSheet: SheetController? { sheet(in: selectedNavigation?.topViewController) }

    /// A blank note, on this tab's stack, its title to be typed.
    /// Today, in the days, a new row at its top with the caret in it.
    func writeToday() {
        sheet(in: selectedNavigation?.topViewController)?.saveAll()
        guard let days = columns.first, let pager = dayPager else { return }
        select(column: 0)
        setChromeHidden(false)
        days.popToRootViewController(animated: false)
        let today = NoteRef.day(.today)
        pager.show(.today, animated: false)
        // Once laid out where today is.
        DispatchQueue.main.async { pager.sheet?.writeAtTop(of: today) }
    }

    func compose(from sheet: SheetController) {
        sheet.saveAll()
        guard let path = store.newNote() else { return }
        let new = makeSheet(.note(path))
        sheet.navigationController?.pushViewController(new, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak new] in
            new?.blocks.first?.editors.first?.becomeFirstResponder()
        }
    }

    // MARK: Tabs

    func tabBarController(_ tabBarController: UITabBarController, didSelectTab tab: UITab, previousTab: UITab?) {
        if let column = columnTabs.firstIndex(where: { $0 === tab }) { lastColumn = column }
        setChromeHidden(false)
        layoutChanged()
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        setChromeHidden(false)
        layoutChanged()
        updateBacklinks()
        updateBar()
    }

    // MARK: What links to the note shown

    /// What links to each note, as cards, as last found; forgotten when notes change.
    private var backlinkCards: [String: [BacklinkCard]] = [:]
    private var countingBacklinks: Set<String> = []

    /// The bar's pill of what links to the note shown, kept up: found off
    /// the main thread the first time, then known.
    func updateBacklinks() {
        guard let sheet = sheet(in: selectedNavigation?.topViewController), !bar.isSearching,
              let path = sheet.currentNotePath, let index = store.index else { return bar.showBacklinks(0) }
        if let cards = backlinkCards[path] { return bar.showBacklinks(cards.count) }
        guard countingBacklinks.insert(path).inserted else { return }
        let store = store
        Task {
            let sources = await Task.detached(priority: .utility) { index.backlinks(to: path) }.value
            countingBacklinks.remove(path)
            backlinkCards[path] = sources.map { source in
                let words = source.contexts.first?.rows.map(\.text).joined(separator: " ") ?? ""
                return BacklinkCard(path: source.path, title: SliceBlock.name(source.path, store: store),
                                        snippet: InlineMarkup.plainText(words).replacingOccurrences(of: "\n", with: " ")
                                            .trimmingCharacters(in: .whitespaces),
                                        link: source.contexts.first?.link ?? "")
            }
            updateBacklinks()
        }
    }

    /// The fan dealt out by a hold, following the thumb till it lets go.
    private weak var heldFan: NoteFan?

    private func held(_ what: BottomBar.Held, _ state: UIGestureRecognizer.State, at point: CGPoint) {
        let local = view.convert(point, from: nil)
        switch state {
        case .began:
            heldFan = fan(what)
        case .changed:
            heldFan?.track(local)
        case .ended:
            heldFan?.release(at: local)
            heldFan = nil
        default:
            heldFan?.release(at: nil)
            heldFan = nil
        }
    }

    /// The notes for what was held, dealt out of it along the pill.
    private func fan(_ what: BottomBar.Held) -> NoteFan? {
        let entries: [NoteFan.Entry]
        switch what {
        case .home: entries = viewEntries()
        case .title: entries = recentNotes()
        case .backlinks: entries = backlinkEntries()
        }
        guard !entries.isEmpty else { return nil }
        // Views over the circle held; notes along the pill.
        // Over the field, each a copy of it, whatever was held.
        var column = bar.pillFrame
        // Over the panel, not on it.
        column.origin.y = bar.panelTop
        let fan = NoteFan(entries: entries, from: bar.convert(bar.frame(of: what), to: view),
                          along: bar.convert(column, to: view), in: view.bounds)
        fan.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        fan.cover = { [weak self] path in self?.cover(of: path) }
        view.insertSubview(fan, belowSubview: bar)
        fan.deal()
        return fan
    }

    /// What links to the note shown, the newest nearest the thumb; past
    /// six, the last of them all.
    private func backlinkEntries() -> [NoteFan.Entry] {
        guard let sheet = sheet(in: selectedNavigation?.topViewController), let path = sheet.currentNotePath,
              let cards = backlinkCards[path], !cards.isEmpty else { return [] }
        let most = 6
        let shown = cards.count > most ? Array(cards.prefix(most - 1)) : cards
        var entries = shown.map { card in
            NoteFan.Entry(names: SliceBlock.names(card.path, store: store), cover: cover(of: card.path), path: card.path) { [weak self, weak sheet] in
                guard let self, let sheet else { return }
                openLinking(card, from: sheet)
            }
        }
        if cards.count > shown.count {
            entries.append(NoteFan.Entry(names: ["All \(cards.count) linking here…"], cover: nil, secondary: true) { [weak self, weak sheet] in
                guard let self, let sheet else { return }
                push(.backlinks(path), from: sheet)
            })
        }
        return entries
    }

    /// A note opened from what links to another: at the link, marked a moment.
    private func openLinking(_ card: BacklinkCard, from sheet: SheetController) {
        sheet.saveAll()
        let opened = makeSheet(.note(card.path))
        let rows = Row.unfold(OutlineMarkdown.parse(store.text(card.path)).rows)
        if !card.link.isEmpty, let row = rows.firstIndex(where: { $0.text.contains(card.link) }) { opened.mark(unfoldedRow: row) }
        sheet.navigationController?.pushViewController(opened, animated: true)
    }

    // MARK: Kept across launches

    /// Everything about the tabs, kept for the next launch: each tab's
    /// sheets, bottom to top, where each was scrolled to, which tab was
    /// showing, and where the caret was.
    struct Layout: Codable {
        struct Sheet: Codable {
            var kind: SheetKind
            var place: SheetController.Place?
        }
        var columns: [[Sheet]]
        var page: Int
        var focusColumn: Int?
        var focus: SheetController.Focus?
    }

    private var layoutNow: Layout {
        var focusColumn: Int?
        var focus: SheetController.Focus?
        let columns = columns.enumerated().map { c, column in
            column.viewControllers.compactMap { controller -> Layout.Sheet? in
                // A view showing one note at a time: kept as what it is.
                if let host = controller as? NoteHost { return Layout.Sheet(kind: host.rootKind, place: nil) }
                guard let sheet = controller as? SheetController else { return nil }
                if focus == nil, sheet === column.topViewController, let found = sheet.focus {
                    focus = found
                    focusColumn = c
                }
                return Layout.Sheet(kind: sheet.kind, place: sheet.place)
            }
        }
        return Layout(columns: columns, page: selectedColumn, focusColumn: focusColumn, focus: focus)
    }

    private var saveTimer: Timer?

    /// Something moved: kept a moment after it settles.
    func layoutChanged() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveLayout() }
        }
    }

    func saveLayout() {
        saveTimer?.invalidate()
        guard !columns.isEmpty, let data = try? JSONEncoder().encode(layoutNow) else { return }
        UserDefaults.standard.set(data, forKey: "Tabs")
    }

    /// The tabs as they were left: each one's stack, where it was, the caret.
    private func restoreLayout() {
        guard let data = UserDefaults.standard.data(forKey: "Tabs"),
              let layout = try? JSONDecoder().decode(Layout.self, from: data) else { return }
        for (c, sheets) in layout.columns.enumerated() where columns.indices.contains(c) && sheets.first?.kind == tab(c).kind {
            let navigation = columns[c]
            for sheet in sheets.dropFirst() { navigation.pushViewController(makeSheet(sheet.kind), animated: false) }
            for (s, controller) in navigation.viewControllers.enumerated() where sheets.indices.contains(s) {
                guard let sheet = controller as? SheetController else { continue }
                let focus = c == layout.focusColumn && s == sheets.count - 1 ? layout.focus : nil
                sheet.restore(place: sheets[s].place, focus: focus)
            }
        }
        pendingPage = min(max(layout.page, 0), columns.count - 1)
    }

    /// The tab to show once laid out.
    private var pendingPage: Int?
}

/// The tabs, for SwiftUI.
struct ColumnsView: UIViewControllerRepresentable {
    let store: PrismStore
    let scheduler: SyncScheduler

    func makeUIViewController(context: Context) -> ColumnsController {
        let controller = ColumnsController(store: store)
        scheduler.beforeSync = { [weak controller] in controller?.saveAll() }
        return controller
    }
    func updateUIViewController(_ controller: ColumnsController, context: Context) {}
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

extension ColumnsController: PHPickerViewControllerDelegate {
    /// The picture chosen: no bigger than a cover needs, kept as a JPEG —
    /// what the Mac, and Reflect, show — and made the note's cover.
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
                    (self.sheet(in: self.selectedNavigation?.topViewController))?.say("The cover could not be kept: \(error.localizedDescription)")
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

/// A note that links to another, and where: the link as written, to find it again.
struct BacklinkCard {
    var path: String
    var title: String
    var snippet: String
    var link: String
}
