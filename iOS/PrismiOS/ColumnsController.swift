import SwiftUI
import AuthenticationServices
import UIKit
import ReflectCore
import PrismCore
import ReflectGit2

/// Prism's views, a tab each along the bottom — the days, the inbox, the
/// tasks — each a stack of sheets: going somewhere pushes one, Back or a
/// swipe from the edge pops it. Among them, a button to write in today; at
/// their right, apart, search — which, tapped, opens out into a field, the
/// tabs gathered into one button at its left to go back by.
final class ColumnsController: UITabBarController, UITabBarControllerDelegate, UINavigationControllerDelegate {
    let store: PrismStore
    /// The bar along the bottom, in the system's tab bar's place.
    private lazy var bar = BottomBar(items: Self.tabs.map { BottomBar.Item(title: $0.title, symbol: $0.symbol) })
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
        (.timeline, "Days", "house"),
        (.inbox, "Inbox", "tray"),
        (.tasks, "Tasks", "checkmark.circle"),
    ]

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
        columns = Self.tabs.map { tab in
            let navigation = UINavigationController(rootViewController: makeSheet(tab.kind, around: tab.kind == .timeline ? .day(.today) : nil))
            navigation.delegate = self
            styleBar(navigation)
            return navigation
        }
        columnTabs = zip(Self.tabs, columns).map { tab, navigation in
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
        openForScript()
        // The tab left showing chosen before any is laid out: the others'
        // sheets not built at launch at all.
        if let page = pendingPage {
            pendingPage = nil
            select(column: page)
        }
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
                    for case let sheet as SheetController in column.viewControllers { sheet.notesChanged(changed) }
                }
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
            for case let sheet as SheetController in column.viewControllers { sheet.showSyncing(syncing) }
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
        bar.selected = column
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
        bar.onSelect = { [weak self] column in self?.tabTapped(column) }
        bar.onHold = { [weak self] column in
            guard let self, Self.tabs[column].kind == .timeline else { return }
            showCalendar()
        }
        bar.onWrite = { [weak self] in
            guard let self else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            writeToday()
        }
        bar.onDictateBegin = { [weak self] in self?.beginDictation() }
        bar.onDictateEnd = { [weak self] cancelled in self?.endDictation(cancelled: cancelled) }
        bar.onSearch = { [weak self] in self?.showSearch() }
        bar.recents = { [weak self] in self?.recentNotes() ?? [] }
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
            } else if let root = navigation.viewControllers.first as? SheetController, root.kind == .timeline {
                root.show(.day(.today))
            } else if let root = navigation.viewControllers.first as? SheetController {
                // Its first sheet already: to the top of it.
                root.scrollToTop()
            }
        }
        select(column: column)
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
        let bar = selectedNavigation?.navigationBar
        let bottom = self.bar
        let drop = BottomBar.height + BottomBar.margin + 20
        UIView.animate(withDuration: 0.28, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
            bottom.transform = hidden ? CGAffineTransform(translationX: 0, y: drop) : .identity
            bottom.alpha = hidden ? 0 : 1
            bar?.alpha = hidden ? 0 : 1
        }
        bar?.isUserInteractionEnabled = !hidden
        bottom.isUserInteractionEnabled = !hidden
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
            UIApplication.shared.open(url)
        }
    }

    /// Everything typed, in every tab, written.
    func saveAll() {
        for column in columns {
            for case let sheet as SheetController in column.viewControllers { sheet.saveAll() }
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

    /// The ≡ menu on a tab's first sheet, and the ⋯ menu on a note: what can
    /// be done to the note, then the sync — now, how it went — and the notes
    /// two devices wrote at once.
    func menu(for sheet: SheetController) -> UIMenu {
        var sections: [UIMenuElement] = []
        if case .note(let path) = sheet.kind { sections.append(noteMenu(path, from: sheet)) }
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
        return UIMenu(options: .displayInline, children: items)
    }

    /// Go to a note or a day, or search them all: the search tab, opened out.
    func showFinder(from sheet: SheetController) {
        sheet.saveAll()
        showSearch()
    }

    func showSearch() {
        guard let searchTab, !bar.isSearching else { return }
        selectedNavigation?.topViewController.flatMap { $0 as? SheetController }?.saveAll()
        lastColumn = selectedColumn
        setChromeHidden(false)
        selectedTab = searchTab
        bar.setSearching(true)
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
    }

    /// Something found: a day in the days tab, the rest on the stack of the
    /// tab search was opened from — gone back to.
    private func open(_ place: FinderController.Place) {
        switch place {
        case .day(let day):
            if store.graph?.exists(path: GraphPaths.dailyPath(for: day)) == false { store.reveal([day]) }
            guard let days = columns.first, let root = days.viewControllers.first as? SheetController else { return }
            select(column: 0)
            days.popToRootViewController(animated: false)
            root.show(.day(day), asLeft: true)
        case .note(let path):
            openInColumn(.note(path))
        case .search(let query):
            openInColumn(.search(query))
        }
        finder.reset()
        bar.field.text = ""
    }

    /// The notes written in last — not the days, which the days tab has —
    /// to go to, oldest first: in a menu rising from the bar, the latest is
    /// nearest the thumb.
    private func recentNotes() -> [UIMenuElement] {
        guard let index = store.index else { return [] }
        let recent = index.all
            .filter { $0.day == nil && !$0.path.hasPrefix(GraphPaths.weeklyDirectory + "/") }
            .sorted { $0.modified > $1.modified }
            .prefix(10)
        return recent.reversed().map { entry in
            // A line each: a menu taller than the screen opens at its top,
            // and the latest, at its foot, would be out of sight.
            UIAction(title: entry.title.isEmpty ? (entry.path as NSString).lastPathComponent : entry.title,
                     image: UIImage(systemName: "doc.text")) { [weak self] _ in
                self?.openInColumn(.note(entry.path))
            }
        }
    }

    private func openInColumn(_ kind: SheetKind) {
        let column = lastColumn
        select(column: column)
        guard let sheet = columns[column].topViewController as? SheetController else { return }
        push(kind, from: sheet)
    }

    // MARK: The calendar

    /// A month of days, the Days tab held: those with notes marked, and how
    /// far along each one's to-dos are. A day tapped is gone to.
    func showCalendar() {
        guard let graph = store.graph, let index = store.index else { return }
        let days = columns.first?.viewControllers.first as? SheetController
        let shown = days?.place?.path.flatMap(GraphPaths.day(fromDailyPath:)) ?? .today
        let calendar = CalendarController(month: NoteCalendar.Month(shown), marks: NoteCalendar.marks(graph: graph, index: index))
        calendar.onChoose = { [weak self, weak calendar] day in
            calendar?.dismiss(animated: true)
            self?.open(.day(day))
        }
        if let sheet = calendar.sheetPresentationController {
            let height = calendar.preferredHeight(width: view.bounds.width)
            sheet.detents = [.custom { _ in height }]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 28
        }
        present(calendar, animated: true)
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
        selectedNavigation?.topViewController.flatMap { $0 as? SheetController }?.saveAll()
        guard let days = columns.first, let root = days.viewControllers.first as? SheetController else { return }
        select(column: 0)
        setChromeHidden(false)
        days.popToRootViewController(animated: false)
        let today = NoteRef.day(.today)
        root.show(today)
        DispatchQueue.main.async { root.addAtTop(of: today, text: text) }
    }

    private var currentSheet: SheetController? { selectedNavigation?.topViewController as? SheetController }

    /// A blank note, on this tab's stack, its title to be typed.
    /// Today, in the days, a new row at its top with the caret in it.
    func writeToday() {
        selectedNavigation?.topViewController.flatMap { $0 as? SheetController }?.saveAll()
        guard let days = columns.first, let root = days.viewControllers.first as? SheetController else { return }
        select(column: 0)
        setChromeHidden(false)
        days.popToRootViewController(animated: false)
        let today = NoteRef.day(.today)
        root.show(today)
        // Once laid out where today is.
        DispatchQueue.main.async { root.writeAtTop(of: today) }
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
            column.viewControllers.compactMap { $0 as? SheetController }.map { sheet -> Layout.Sheet in
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
        for (c, sheets) in layout.columns.enumerated() where columns.indices.contains(c) && sheets.first?.kind == Self.tabs[c].kind {
            let navigation = columns[c]
            for sheet in sheets.dropFirst() { navigation.pushViewController(makeSheet(sheet.kind), animated: false) }
            for (s, sheet) in navigation.viewControllers.compactMap({ $0 as? SheetController }).enumerated() where sheets.indices.contains(s) {
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
