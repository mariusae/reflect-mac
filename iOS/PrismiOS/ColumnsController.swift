import SwiftUI
import UIKit
import ReflectCore
import PrismCore

/// Prism's views, a tab each along the bottom — the days, the inbox, the
/// tasks, the pinned notes — each a stack of sheets: going somewhere pushes
/// one, Back or a swipe from the edge pops it. Over them, a button to write
/// a new note; on top of every sheet, the menu and search.
final class ColumnsController: UITabBarController, UITabBarControllerDelegate, UINavigationControllerDelegate {
    let store: PrismStore
    private let compose = UIButton(type: .system)

    /// The tabs, in order, with what each shows and its icon.
    static let tabs: [(kind: SheetKind, title: String, symbol: String)] = [
        (.timeline, "Days", "house"),
        (.inbox, "Inbox", "tray"),
        (.tasks, "Tasks", "checkmark.circle"),
        (.pinned, "Pinned", "pin"),
    ]

    init(store: PrismStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Each tab's stack.
    var columns: [UINavigationController] { (viewControllers ?? []).compactMap { $0 as? UINavigationController } }

    override func viewDidLoad() {
        super.viewDidLoad()
        StallWatch.mark("columns loading")
        defer { StallWatch.mark("columns loaded") }
        view.backgroundColor = Ink.paper
        delegate = self
        // What a name typed after `@` or `[[` could link to.
        OutlineEditor.suggest = { [weak store] query in
            guard let index = store?.index else { return [] }
            return LinkSuggestions.candidates(query, index: index)
        }
        viewControllers = Self.tabs.map { tab in
            let navigation = UINavigationController(rootViewController: makeSheet(tab.kind, around: tab.kind == .timeline ? .day(.today) : nil))
            navigation.delegate = self
            // An icon alone, as Threads has it; its name for VoiceOver.
            navigation.tabBarItem = UITabBarItem(title: nil, image: UIImage(systemName: tab.symbol),
                                                 selectedImage: UIImage(systemName: tab.symbol + ".fill"))
            navigation.tabBarItem.accessibilityLabel = tab.title
            styleBar(navigation)
            return navigation
        }
        tabBar.tintColor = Ink.text
        tabBar.unselectedItemTintColor = Ink.faint
        setUpCompose()
        restoreLayout()
        // Left for the background, or about to be: everything kept as it is.
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveLayout() }
            }
        }
        // The keyboard up, the compose button out of its way.
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setComposeShown(false) }
        }
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setComposeShown(true) }
        }
        observe()
        observeSync()
        openForScript()
        // The tab left showing chosen before any is laid out: the others'
        // sheets not built at launch at all.
        if let page = pendingPage {
            pendingPage = nil
            selectedIndex = page
        }
    }

    /// `-PrismOpen <kind>` — `search:<query>`, `backlinks:<path>`,
    /// `note:<path>`, `inbox`, `tasks`, `pinned` — at launch, for scripted
    /// checks.
    private func openForScript() {
        guard let spec = UserDefaults.standard.string(forKey: "PrismOpen"), let column = columns.first else { return }
        let (head, rest) = spec.firstIndex(of: ":").map { (String(spec[..<$0]), String(spec[spec.index(after: $0)...])) } ?? (spec, "")
        switch head {
        case "inbox": pendingPage = 1
        case "tasks": pendingPage = 2
        case "pinned": pendingPage = 3
        case "search": column.pushViewController(makeSheet(.search(rest)), animated: false)
        case "backlinks": column.pushViewController(makeSheet(.backlinks(rest)), animated: false)
        case "note": column.pushViewController(makeSheet(.note(rest)), animated: false)
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

    /// The floating button, bottom right, over the tab bar.
    private func setUpCompose() {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .medium))
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = Ink.composeBack
        configuration.baseForegroundColor = Ink.composeInk
        compose.configuration = configuration
        compose.accessibilityLabel = "New Note"
        compose.layer.shadowColor = UIColor.black.cgColor
        compose.layer.shadowOpacity = 0.18
        compose.layer.shadowRadius = 12
        compose.layer.shadowOffset = CGSize(width: 0, height: 4)
        compose.addAction(UIAction { [weak self] _ in
            guard let self, let sheet = (selectedViewController as? UINavigationController)?.topViewController as? SheetController else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self.compose(from: sheet)
        }, for: .touchUpInside)
        view.addSubview(compose)
    }

    private func setComposeShown(_ shown: Bool) {
        UIView.animate(withDuration: 0.2) { self.compose.alpha = shown ? 1 : 0 }
        compose.isUserInteractionEnabled = shown
    }

    /// How big the compose button is; sheets keep their scrubber above it.
    static let composeSize: CGFloat = 60

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = Self.composeSize
        compose.frame = CGRect(x: view.bounds.width - size - 18, y: tabBar.frame.minY - size - 14, width: size, height: size)
        view.bringSubviewToFront(compose)
        if let page = pendingPage {
            pendingPage = nil
            selectedIndex = page
        }
    }

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
        if let error = store.syncError {
            sync.append(UIAction(title: "Last sync failed", subtitle: error, attributes: .disabled) { _ in })
        } else if let synced = store.lastSynced {
            sync.append(UIAction(title: "Synced " + synced.formatted(.relative(presentation: .named)), attributes: .disabled) { _ in })
        }
        sections.append(UIMenu(options: .displayInline, children: sync))
        if !store.conflicted.isEmpty {
            sections.append(UIMenu(title: "Edited on Two Devices", options: .displayInline, children: store.conflicted.prefix(8).map { path in
                UIAction(title: SliceBlock.name(path, store: store), image: UIImage(systemName: "arrow.triangle.merge")) { [weak self, weak sheet] _ in
                    guard let self, let sheet else { return }
                    push(.note(path), from: sheet)
                }
            }))
        }
        return UIMenu(children: sections)
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
        return UIMenu(options: .displayInline, children: items)
    }

    /// Go to a note or a day, or search them all: a day in the days tab, the
    /// rest on this tab's stack.
    func showFinder(from sheet: SheetController) {
        sheet.saveAll()
        let finder = FinderController(store: store)
        finder.onChoose = { [weak self, weak sheet] place in
            guard let self, let sheet else { return }
            switch place {
            case .day(let day):
                if self.store.graph?.exists(path: GraphPaths.dailyPath(for: day)) == false { self.store.reveal([day]) }
                guard let days = self.columns.first, let root = days.viewControllers.first as? SheetController else { return }
                self.selectedIndex = 0
                days.popToRootViewController(animated: false)
                root.show(.day(day), asLeft: true)
            case .note(let path):
                self.push(.note(path), from: sheet)
            case .search(let query):
                self.push(.search(query), from: sheet)
            }
        }
        present(finder, animated: true)
    }

    /// A blank note, on this tab's stack, its title to be typed.
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

    /// The days tab, tapped while showing them: back to today.
    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        if StallWatch.enabled { StallWatch.mark("tab tapped") }
        if viewController === selectedViewController, let navigation = viewController as? UINavigationController,
           navigation.viewControllers.count == 1, let root = navigation.viewControllers.first as? SheetController, root.kind == .timeline {
            root.show(.day(.today))
        }
        return true
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        layoutChanged()
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
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
        return Layout(columns: columns, page: selectedIndex, focusColumn: focusColumn, focus: focus)
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
