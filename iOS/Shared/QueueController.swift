import UIKit
import ReflectCore
import PrismCore

/// The oldest link in the inbox, in the reader, and nothing else: done with,
/// the next; or snoozed, put off till later. Read to the end of the
/// queue, a rest — and when the first snoozed one comes back. Prism
/// Reader's whole; in Prism, the Inbox's Read Next, closed with ×.
final class QueueController: UIViewController {
    /// In Prism: its × — the reader's, or under All Read — back to the Inbox.
    var onClose: (() -> Void)?
    private let closeRest = UIButton(type: .system)

    private let store: PrismStore
    private var reader: ReaderController?
    /// The note shown.
    private var shownPath: String?
    /// The note begun — scrolled — kept in front till it
    /// is done or snoozed, whatever comes back from snoozing older; across
    /// launches too. This reader's own: another device has its own.
    private var begun: String? {
        get { UserDefaults.standard.string(forKey: "Queue.begun") }
        set { UserDefaults.standard.set(newValue, forKey: "Queue.begun") }
    }

    /// At the foot, on glass: Snooze, and Done.
    private let bar = UIVisualEffectView(effect: UIGlassEffect())
    private let snooze = UIButton(type: .system)
    private let done = UIButton(type: .system)
    private let rule = UIView()
    private var barHidden = false

    /// Nothing left to read.
    private let rest = UIStackView()
    private let restTitle = UILabel()
    private let restDetail = UILabel()
    /// The first snoozed link back, while there is nothing to read: shown then.
    private var wake: Timer?

    init(store: PrismStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Ink.paper

        let mark = UIImageView(image: UIImage(systemName: "checkmark.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .light)))
        mark.tintColor = Ink.secondary
        restTitle.font = Typeface.current.body(22, weight: .semibold)
        restTitle.textColor = Ink.text
        restTitle.text = "All Read"
        restDetail.font = Typeface.current.body(15)
        restDetail.textColor = Ink.secondary
        restDetail.numberOfLines = 0
        restDetail.textAlignment = .center
        for view in [mark, restTitle, restDetail] { rest.addArrangedSubview(view) }
        if let onClose {
            var style = UIButton.Configuration.glass()
            style.title = "Back to the Inbox"
            closeRest.configuration = style
            closeRest.addAction(UIAction { _ in onClose() }, for: .touchUpInside)
            rest.addArrangedSubview(closeRest)
            rest.setCustomSpacing(24, after: restDetail)
        }
        rest.axis = .vertical
        rest.alignment = .center
        rest.spacing = 10
        rest.setCustomSpacing(16, after: mark)
        rest.isHidden = true
        view.addSubview(rest)

        bar.cornerConfiguration = .capsule()
        let symbols = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        var snoozing = UIButton.Configuration.plain()
        snoozing.image = UIImage(systemName: "clock", withConfiguration: symbols)
        snoozing.baseForegroundColor = Ink.text
        snooze.configuration = snoozing
        snooze.showsMenuAsPrimaryAction = true
        snooze.menu = snoozeMenu()
        var finishing = UIButton.Configuration.plain()
        finishing.image = UIImage(systemName: "checkmark", withConfiguration: symbols)
        finishing.baseForegroundColor = Ink.text
        done.configuration = finishing
        snooze.accessibilityLabel = "Snooze"
        done.accessibilityLabel = "Done"
        done.accessibilityHint = "Takes it out of the inbox, and shows the next"
        done.addAction(UIAction { [weak self] _ in self?.finish() }, for: .touchUpInside)
        for button in [snooze, done] {
            button.isPointerInteractionEnabled = true
            bar.contentView.addSubview(button)
        }
        rule.backgroundColor = Ink.rule
        bar.contentView.addSubview(rule)
        view.addSubview(bar)
        refresh()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        reader?.view.frame = view.bounds
        // At the foot's right, in a row with the reader's ‹ › at its left.
        let button: CGFloat = 52
        let width = button * 2
        let foot = max(view.window?.safeAreaInsets.bottom ?? view.safeAreaInsets.bottom, 12) + 4
        // Placed by its centre: its sliding away moves it by its transform.
        bar.bounds = CGRect(x: 0, y: 0, width: width, height: Self.barHeight)
        bar.center = CGPoint(x: view.bounds.width - 16 - width / 2, y: view.bounds.height - foot - Self.barHeight / 2)
        snooze.frame = CGRect(x: 0, y: 0, width: button, height: Self.barHeight)
        done.frame = CGRect(x: button, y: 0, width: button, height: Self.barHeight)
        rule.frame = CGRect(x: button, y: 12, width: 1, height: Self.barHeight - 24)
        let size = rest.systemLayoutSizeFitting(CGSize(width: view.bounds.width - 64, height: .greatestFiniteMagnitude))
        rest.frame = CGRect(x: 32, y: (view.bounds.height - size.height) / 2 - 20, width: view.bounds.width - 64, height: size.height)
        view.bringSubviewToFront(bar)
    }

    /// As tall as the reader's ‹ ›, beside it.
    private static let barHeight: CGFloat = 44

    // MARK: The queue

    /// The queue as the notes now have it: the link begun, while it is
    /// still to be read; else the oldest.
    func refresh() {
        guard isViewLoaded, let index = store.index, let root = store.graph?.root else { return }
        let (items, next) = ReadingQueue.items(index: index, root: root)
        // Let go of only by Done or Snooze here: out of the queue for a
        // moment — the graph still loading, or syncing — it is still begun.
        let path = begun.flatMap { begun in items.contains { $0.path == begun } ? begun : nil } ?? items.first?.path
        if path != nil, path == shownPath { return }
        show(path, next: next)
    }

    private func show(_ path: String?, next: Date?) {
        let old = reader
        reader = nil
        shownPath = path
        wake?.invalidate()
        wake = nil
        if let path {
            let reader = ReaderController(store: store, notePath: path, sources: ReaderController.sources(of: path, store: store))
            // In Prism, its × closes the queue; in Prism Reader, there is nothing to close to.
            if let onClose { reader.onClose = onClose } else { reader.standalone = true }
            reader.footRoom = Self.barHeight + 12
            reader.carouselAtLeft = true
            reader.onChromeHidden = { [weak self] hidden in self?.setBarHidden(hidden) }
            // Scrolled, and it is begun.
            reader.onScrolledByHand = { [weak self] in
                guard let self, self.shownPath == path, self.begun != path else { return }
                self.begun = path
            }
            addChild(reader)
            reader.view.frame = view.bounds
            reader.view.alpha = old == nil ? 1 : 0
            view.insertSubview(reader.view, belowSubview: bar)
            reader.didMove(toParent: self)
            self.reader = reader
        } else {
            restDetail.text = ReadingQueue.restDetail(next: next)
            // Back on its own when the first is due, the app open.
            if let next {
                wake = Timer.scheduledTimer(withTimeInterval: max(1, next.timeIntervalSinceNow + 1), repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            }
        }
        rest.isHidden = path != nil
        bar.isHidden = path == nil
        setBarHidden(false)
        view.setNeedsLayout()
        UIView.animate(withDuration: 0.25) {
            self.reader?.view.alpha = 1
            old?.view.alpha = 0
        } completion: { _ in
            old?.willMove(toParent: nil)
            old?.view.removeFromSuperview()
            old?.removeFromParent()
        }
    }

    // MARK: Done, or later

    /// Read: out of the inbox — unsnoozed, were it — and the next.
    private func finish() {
        guard let path = shownPath else { return }
        begun = nil
        store.setFrontmatter(path, "inbox", nil)
        store.setFrontmatter(path, ReadingQueue.snoozeKey, nil)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        refresh()
    }

    private func snoozeMenu() -> UIMenu {
        // Its times as of when it opens.
        UIMenu(title: "Bring It Back", children: [UIDeferredMenuElement.uncached { done in
            done(ReadingQueue.Snooze.allCases.map { snooze in
                UIAction(title: snooze.title, subtitle: ReadingQueue.when(snooze.until(from: Date())), image: UIImage(systemName: snooze.symbol)) { [weak self] _ in
                    self?.put(off: snooze)
                }
            })
        }])
    }

    /// Put off: back in the queue when its time comes, in its place by age.
    private func put(off snooze: ReadingQueue.Snooze) {
        guard let path = shownPath else { return }
        begun = nil
        store.setFrontmatter(path, ReadingQueue.snoozeKey, ReadingQueue.written(snooze.until(from: Date())))
        UISelectionFeedbackGenerator().selectionChanged()
        refresh()
    }

    /// Out of the way as the page is read down, with the reader's own.
    private func setBarHidden(_ hidden: Bool) {
        guard hidden != barHidden else { return }
        barHidden = hidden
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) { [self] in
            bar.alpha = hidden ? 0 : 1
            bar.transform = hidden ? CGAffineTransform(translationX: 0, y: view.bounds.height - bar.center.y + Self.barHeight / 2) : .identity
        }
    }
}

