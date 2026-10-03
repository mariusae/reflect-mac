import SwiftUI
import UIKit
import ReflectCore
import PrismCore

/// The columns, side by side as pages: one on screen at a time, swiped
/// between, dots at the foot saying which. Each column is a stack of
/// sheets — going somewhere pushes one, swiping from the edge goes back.
final class ColumnsController: UIViewController, UIScrollViewDelegate {
    let store: PrismStore
    private let pager = UIScrollView()
    private let dots = UIPageControl()
    private(set) var columns: [UINavigationController] = []
    private var lastRevision = -1

    init(store: PrismStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Ink.paper
        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.delegate = self
        pager.contentInsetAdjustmentBehavior = .never
        view.addSubview(pager)
        dots.currentPageIndicatorTintColor = Ink.text
        dots.pageIndicatorTintColor = Ink.faint
        dots.hidesForSinglePage = true
        dots.isUserInteractionEnabled = false
        view.addSubview(dots)
        for kind in Self.savedLayout { addColumn(kind, around: kind == .timeline ? .day(.today) : nil) }
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.cancelsTouchesInView = false
        view.addGestureRecognizer(pinch)
        // While typing, a swipe moves a row in or out, not to another column.
        NotificationCenter.default.addObserver(forName: UITextView.textDidBeginEditingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pager.isScrollEnabled = false }
        }
        NotificationCenter.default.addObserver(forName: UITextView.textDidEndEditingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pager.isScrollEnabled = true }
        }
        observe()
        openForScript()
    }

    /// `-PrismOpen <kind>` — `search:<query>`, `backlinks:<path>`,
    /// `note:<path>`, `inbox`, `tasks` — a sheet opened on the first
    /// column at launch, for scripted checks.
    private func openForScript() {
        guard let spec = UserDefaults.standard.string(forKey: "PrismOpen"), let column = columns.first,
              let sheet = column.viewControllers.first as? SheetController else { return }
        let (head, rest) = spec.firstIndex(of: ":").map { (String(spec[..<$0]), String(spec[spec.index(after: $0)...])) } ?? (spec, "")
        let kind: SheetKind? = switch head {
        case "search": .search(rest)
        case "backlinks": .backlinks(rest)
        case "note": .note(rest)
        case "inbox": .inbox
        case "tasks": .tasks
        default: nil
        }
        if let kind { column.pushViewController(makeSheet(kind), animated: false) }
        _ = sheet
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

    // MARK: Columns

    @discardableResult
    func addColumn(_ kind: SheetKind, around ref: NoteRef? = nil) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: makeSheet(kind, around: ref))
        styleBar(navigation)
        addChild(navigation)
        pager.addSubview(navigation.view)
        navigation.didMove(toParent: self)
        columns.append(navigation)
        dots.numberOfPages = columns.count
        view.setNeedsLayout()
        return navigation
    }

    private func styleBar(_ navigation: UINavigationController) {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = Ink.paper
        appearance.titleTextAttributes = [.font: Typeface.current.heading(16, weight: .semibold), .foregroundColor: Ink.text]
        navigation.navigationBar.standardAppearance = appearance
        navigation.navigationBar.scrollEdgeAppearance = appearance
        navigation.navigationBar.tintColor = Ink.text
    }

    func makeSheet(_ kind: SheetKind, around ref: NoteRef? = nil) -> SheetController {
        let sheet = SheetController(kind: kind, store: store, around: ref)
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
        return sheet
    }

    // MARK: The menu

    private static let views: [(String, String, SheetKind)] = [
        ("Days", "calendar", .timeline),
        ("Inbox", "tray", .inbox),
        ("Tasks", "checklist", .tasks),
        ("Search", "magnifyingglass", .search("")),
    ]

    /// A sheet's menu: about its note, then where to go — here, or in a
    /// column of its own — then the columns.
    func menu(for sheet: SheetController) -> UIMenu {
        var sections: [UIMenuElement] = []
        if case .note(let path) = sheet.kind {
            let entry = store.index?.entry(path)
            let isDay = GraphPaths.day(fromDailyPath: path) != nil
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
            if !isDay {
                items.append(UIAction(title: entry?.isTopic == true ? "Not a Topic" : "Make a Topic", image: UIImage(systemName: "number")) { [weak self] _ in
                    self?.store.setFrontmatter(path, "topic", entry?.isTopic == true ? nil : "true")
                })
                items.append(UIAction(title: entry?.pin == nil ? "Pin" : "Unpin", image: UIImage(systemName: entry?.pin == nil ? "pin" : "pin.slash")) { [weak self] _ in
                    guard let self, let index = store.index else { return }
                    store.setFrontmatter(path, "pinned", entry?.pin == nil ? String(index.nextPinOrder) : nil)
                })
            }
            sections.append(UIMenu(options: .displayInline, children: items))
        }
        sections.append(UIMenu(title: "Open", options: .displayInline, children: Self.views.map { title, symbol, kind in
            UIAction(title: title, image: UIImage(systemName: symbol)) { [weak self, weak sheet] _ in
                guard let self, let sheet else { return }
                if kind == .timeline, let root = sheet.navigationController?.viewControllers.first as? SheetController, root.kind == .timeline {
                    // The days are at the bottom of every stack that starts with them.
                    sheet.navigationController?.popToRootViewController(animated: true)
                    root.show(.day(.today))
                } else {
                    push(kind, from: sheet)
                }
            }
        }))
        var columnItems: [UIMenuElement] = [
            UIMenu(title: "New Column", image: UIImage(systemName: "rectangle.stack.badge.plus"), children: Self.views.map { title, symbol, kind in
                UIAction(title: title, image: UIImage(systemName: symbol)) { [weak self] _ in self?.openColumn(kind) }
            }),
            UIAction(title: "All Columns", image: UIImage(systemName: "square.grid.2x2")) { [weak self] _ in self?.showOverview() },
        ]
        if columns.count > 1, let column = sheet.navigationController {
            columnItems.append(UIAction(title: "Close Column", image: UIImage(systemName: "xmark.rectangle"), attributes: .destructive) { [weak self] _ in
                self?.closeColumn(column)
            })
        }
        sections.append(UIMenu(options: .displayInline, children: columnItems))
        if let error = store.syncError {
            sections.append(UIMenu(title: "Sync: " + error, options: .displayInline, children: []))
        } else if let synced = store.lastSynced {
            sections.append(UIMenu(title: "Synced " + synced.formatted(.relative(presentation: .named)), options: .displayInline, children: []))
        }
        return UIMenu(children: sections)
    }

    /// A blank note, on the column's stack, its title to be typed.
    func compose(from sheet: SheetController) {
        sheet.saveAll()
        guard let path = store.newNote() else { return }
        let new = makeSheet(.note(path))
        sheet.navigationController?.pushViewController(new, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak new] in
            new?.blocks.first?.editors.first?.becomeFirstResponder()
        }
    }

    /// A column of its own, at the end, gone to.
    func openColumn(_ kind: SheetKind) {
        current?.viewControllers.forEach { ($0 as? SheetController)?.saveAll() }
        addColumn(kind, around: kind == .timeline ? .day(.today) : nil)
        view.layoutIfNeeded()
        go(to: columns.count - 1, animated: true)
        saveLayout()
    }

    func closeColumn(_ column: UINavigationController) {
        guard columns.count > 1, let i = columns.firstIndex(of: column) else { return }
        for case let sheet as SheetController in column.viewControllers {
            sheet.saveAll()
            if case .note(let path) = sheet.kind { store.settleNewNote(path) }
        }
        column.willMove(toParent: nil)
        column.view.removeFromSuperview()
        column.removeFromParent()
        columns.remove(at: i)
        dots.numberOfPages = columns.count
        view.setNeedsLayout()
        view.layoutIfNeeded()
        go(to: min(i, columns.count - 1), animated: false)
        saveLayout()
    }

    func go(to page: Int, animated: Bool) {
        pager.setContentOffset(CGPoint(x: CGFloat(page) * pager.bounds.width, y: 0), animated: animated)
        dots.currentPage = page
    }

    // MARK: The columns, kept

    /// Each column's first sheet, kept for the next launch.
    private func saveLayout() {
        let kinds = columns.compactMap { ($0.viewControllers.first as? SheetController)?.kind }
        if let data = try? JSONEncoder().encode(kinds) { UserDefaults.standard.set(data, forKey: "Columns") }
    }

    private static var savedLayout: [SheetKind] {
        guard let data = UserDefaults.standard.data(forKey: "Columns"),
              let kinds = try? JSONDecoder().decode([SheetKind].self, from: data), !kinds.isEmpty else { return [.timeline] }
        return kinds
    }

    // MARK: The card file

    /// All the columns at once, small, side by side: one tapped to go to it.
    func showOverview() {
        let cards = columns.map { column -> (UIImage, String) in
            let renderer = UIGraphicsImageRenderer(bounds: column.view.bounds)
            let image = renderer.image { _ in column.view.drawHierarchy(in: column.view.bounds, afterScreenUpdates: false) }
            return (image, column.topViewController?.title ?? "")
        }
        let overview = OverviewController(cards: cards, current: dots.currentPage)
        overview.onPick = { [weak self] page in self?.go(to: page, animated: false) }
        overview.onClose = { [weak self] page in
            guard let self, columns.indices.contains(page) else { return }
            closeColumn(columns[page])
        }
        overview.onAdd = { [weak self] kind in self?.openColumn(kind) }
        overview.modalPresentationStyle = .overFullScreen
        overview.modalTransitionStyle = .crossDissolve
        present(overview, animated: true)
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began, gesture.scale < 1, presentedViewController == nil { showOverview() }
    }

    /// Something opened from a sheet: on its column's stack.
    func push(_ kind: SheetKind, from sheet: SheetController) {
        sheet.saveAll()
        sheet.navigationController?.pushViewController(makeSheet(kind), animated: true)
    }

    /// A link tapped: a note by its title — a day goes to the day in the
    /// timeline beneath, when there is one — or the web.
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

    /// Everything typed, in every column, written.
    func saveAll() {
        for column in columns {
            for case let sheet as SheetController in column.viewControllers { sheet.saveAll() }
        }
    }

    var current: UINavigationController? {
        let page = Int((pager.contentOffset.x / max(pager.bounds.width, 1)).rounded())
        return columns.indices.contains(page) ? columns[page] : columns.first
    }

    // MARK: Layout

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        pager.frame = view.bounds
        for (i, column) in columns.enumerated() {
            column.view.frame = CGRect(x: CGFloat(i) * view.bounds.width, y: 0, width: view.bounds.width, height: view.bounds.height)
        }
        pager.contentSize = CGSize(width: view.bounds.width * CGFloat(columns.count), height: view.bounds.height)
        dots.frame = CGRect(x: 0, y: view.bounds.height - view.safeAreaInsets.bottom - 8, width: view.bounds.width, height: 16)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        dots.currentPage = Int((pager.contentOffset.x / max(pager.bounds.width, 1)).rounded())
    }
}

/// The columns, for SwiftUI.
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
