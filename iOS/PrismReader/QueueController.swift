import UIKit
import ReflectCore
import PrismCore

/// The oldest link in the inbox, in the reader, and nothing else: done with,
/// the next; or snoozed, put off till later. Read to the end of the
/// queue, a rest — and when the first snoozed one comes back.
final class QueueController: UIViewController {
    private let store: PrismStore
    private var reader: ReaderController?
    /// The note read: kept while it is still to be read, whatever else comes in.
    private var shownPath: String?

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
        snoozing.title = "Snooze"
        snoozing.imagePadding = 7
        snoozing.baseForegroundColor = Ink.text
        snooze.configuration = snoozing
        snooze.showsMenuAsPrimaryAction = true
        snooze.menu = snoozeMenu()
        var finishing = UIButton.Configuration.plain()
        finishing.image = UIImage(systemName: "checkmark", withConfiguration: symbols)
        finishing.title = "Done"
        finishing.imagePadding = 7
        finishing.baseForegroundColor = Ink.text
        done.configuration = finishing
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
        let width = min(view.bounds.width - 32, 300)
        let foot = max(view.window?.safeAreaInsets.bottom ?? view.safeAreaInsets.bottom, 12) + 4
        // Placed by its centre: its sliding away moves it by its transform.
        bar.bounds = CGRect(x: 0, y: 0, width: width, height: Self.barHeight)
        bar.center = CGPoint(x: view.bounds.midX.rounded(), y: view.bounds.height - foot - Self.barHeight / 2)
        snooze.frame = CGRect(x: 0, y: 0, width: width / 2, height: Self.barHeight)
        done.frame = CGRect(x: width / 2, y: 0, width: width / 2, height: Self.barHeight)
        rule.frame = CGRect(x: (width / 2).rounded(), y: 14, width: 1, height: Self.barHeight - 28)
        let size = rest.systemLayoutSizeFitting(CGSize(width: view.bounds.width - 64, height: .greatestFiniteMagnitude))
        rest.frame = CGRect(x: 32, y: (view.bounds.height - size.height) / 2 - 20, width: view.bounds.width - 64, height: size.height)
        view.bringSubviewToFront(bar)
    }

    private static let barHeight: CGFloat = 52

    // MARK: The queue

    /// The queue as the notes now have it: the link read kept, while it is
    /// still to be read; else the oldest.
    func refresh() {
        guard isViewLoaded, let index = store.index, let root = store.graph?.root else { return }
        let (items, next) = ReadingQueue.items(index: index, root: root)
        if let shownPath, items.contains(where: { $0.path == shownPath }) { return }
        show(items.first?.path, next: next)
    }

    private func show(_ path: String?, next: Date?) {
        let old = reader
        reader = nil
        shownPath = path
        wake?.invalidate()
        wake = nil
        if let path {
            let reader = ReaderController(store: store, notePath: path, sources: ReaderController.sources(of: path, store: store))
            reader.standalone = true
            reader.footRoom = Self.barHeight + 12
            reader.onChromeHidden = { [weak self] hidden in self?.setBarHidden(hidden) }
            addChild(reader)
            reader.view.frame = view.bounds
            reader.view.alpha = old == nil ? 1 : 0
            view.insertSubview(reader.view, belowSubview: bar)
            reader.didMove(toParent: self)
            self.reader = reader
        } else {
            restDetail.text = next.map { "Snoozed links come back, the first \(Self.when($0))." } ?? "The inbox has no links left to read."
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

    /// "today at 18:00", "tomorrow at 8:00", "on Saturday at 9:00".
    private static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "today at \(time)" }
        if calendar.isDateInTomorrow(date) { return "tomorrow at \(time)" }
        if date.timeIntervalSinceNow < 6 * 86400 { return "on \(date.formatted(.dateTime.weekday(.wide))) at \(time)" }
        return "on \(date.formatted(.dateTime.month(.wide).day())) at \(time)"
    }

    // MARK: Done, or later

    /// Read: out of the inbox — unsnoozed, were it — and the next.
    private func finish() {
        guard let path = shownPath else { return }
        store.setFrontmatter(path, "inbox", nil)
        store.setFrontmatter(path, ReadingQueue.snoozeKey, nil)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        refresh()
    }

    private func snoozeMenu() -> UIMenu {
        // Its times as of when it opens.
        UIMenu(title: "Bring It Back", children: [UIDeferredMenuElement.uncached { done in
            done(ReadingQueue.Snooze.allCases.map { snooze in
                UIAction(title: snooze.title, subtitle: Self.when(snooze.until(from: Date())), image: UIImage(systemName: snooze.symbol)) { [weak self] _ in
                    self?.put(off: snooze)
                }
            })
        }])
    }

    /// Put off: back in the queue when its time comes, in its place by age.
    private func put(off snooze: ReadingQueue.Snooze) {
        guard let path = shownPath else { return }
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
