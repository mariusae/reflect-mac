import UIKit
import ReflectCore
import PrismCore

/// Over today's note: the day's meetings, from the calendars — each its
/// time and name, tapped, its note: made the first time, with when it is
/// and who is in it, and linked from the day. Not yet allowed to read the
/// calendars: a button to allow it, or Not Now, once.
final class MeetingsBlock: UIView, SheetBlock {
    var onHeightChange: (() -> Void)?
    var onCaretMove: (() -> Void)?
    var editors: [OutlineEditor] { [] }
    var isLive: Bool { true }
    func goLive() {}
    func save() {}
    func notesChanged(_ paths: Set<String>) {}

    /// A meeting chosen: its note, to open.
    var onMeeting: ((CalendarEvents.Event) -> Void)?
    private let metrics: PhoneMetrics
    private var rows: [UIButton] = []
    private let ask = UIButton(type: .system)
    private let notNow = UIButton(type: .system)

    /// Not Now, chosen: not asked again here.
    private static var dismissed: Bool {
        get { UserDefaults.standard.bool(forKey: "Meetings.notNow") }
        set { UserDefaults.standard.set(newValue, forKey: "Meetings.notNow") }
    }

    /// Whether there is anything to show over today: meetings, or the asking.
    static var wanted: Bool {
        let calendars = CalendarEvents.shared
        return calendars.isAllowed ? !calendars.events(on: .today).isEmpty : calendars.canAsk && !dismissed
    }

    init(metrics: PhoneMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
        var asking = UIButton.Configuration.glass()
        asking.title = "Show Today’s Meetings"
        asking.image = UIImage(systemName: "calendar", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        asking.imagePadding = 6
        asking.baseForegroundColor = Ink.text
        ask.configuration = asking
        ask.addAction(UIAction { [weak self] _ in
            Task { @MainActor in
                _ = await CalendarEvents.shared.ask()
                self?.show()
            }
        }, for: .touchUpInside)
        var later = UIButton.Configuration.plain()
        later.title = "Not Now"
        later.baseForegroundColor = Ink.secondary
        notNow.configuration = later
        notNow.addAction(UIAction { [weak self] _ in
            MeetingsBlock.dismissed = true
            self?.show()
        }, for: .touchUpInside)
        addSubview(ask)
        addSubview(notNow)
        show()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var events: [CalendarEvents.Event] = []

    private func show() {
        let calendars = CalendarEvents.shared
        events = calendars.isAllowed ? calendars.events(on: .today) : []
        let asking = !calendars.isAllowed && calendars.canAsk && !Self.dismissed
        ask.isHidden = !asking
        notNow.isHidden = !asking
        rows.forEach { $0.removeFromSuperview() }
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        rows = events.map { event in
            var style = UIButton.Configuration.plain()
            var title = AttributedString(time.string(from: event.start) + "  ")
            title.font = UIFont.monospacedDigitSystemFont(ofSize: round(metrics.size * 0.82), weight: .medium)
            title.foregroundColor = Ink.secondary
            var name = AttributedString(event.title)
            name.font = metrics.body
            name.foregroundColor = Ink.text
            style.attributedTitle = title + name
            style.titleLineBreakMode = .byTruncatingTail
            style.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
            let button = UIButton(configuration: style, primaryAction: UIAction { [weak self] _ in self?.onMeeting?(event) })
            button.contentHorizontalAlignment = .leading
            button.accessibilityLabel = "\(event.title), at \(time.string(from: event.start))"
            button.accessibilityHint = "Opens its note"
            addSubview(button)
            return button
        }
        onHeightChange?()
        setNeedsLayout()
    }

    private var rowHeight: CGFloat { ceil(metrics.size * 1.9) }

    func height(width: CGFloat) -> CGFloat {
        if !ask.isHidden { return 64 }
        return events.isEmpty ? 0 : 14 + CGFloat(events.count) * rowHeight + 6
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inner = bounds.width - 2 * NoteBlock.side
        if !ask.isHidden {
            let size = ask.intrinsicContentSize
            ask.frame = CGRect(x: NoteBlock.side - 6, y: 14, width: size.width, height: 38)
            notNow.frame = CGRect(x: ask.frame.maxX + 8, y: 14, width: notNow.intrinsicContentSize.width, height: 38)
        }
        var y: CGFloat = 14
        for row in rows {
            row.frame = CGRect(x: NoteBlock.side, y: y, width: inner, height: rowHeight)
            y += rowHeight
        }
    }
}
