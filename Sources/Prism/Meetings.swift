import AppKit
import ReflectCore
import ReflectUI
import PrismCore

/// Under today's note: the day's meetings, from the calendars — each its
/// time and name, clicked, its note: made the first time, with when it is
/// and who is in it, and linked from the day. Not yet allowed to read the
/// calendars: a button to allow it, or Not Now, once.
final class MeetingsBlock: NSView, ColumnBlock {
    var onMeeting: ((CalendarEvents.Event) -> Void)?
    var onHeightChange: (() -> Void)?
    private let metrics: OutlineMetrics
    private var rows: [NSButton] = []
    private var events: [CalendarEvents.Event] = []
    private let ask = NSButton(title: "Show Today’s Meetings", target: nil, action: nil)
    private let notNow = NSButton(title: "Not Now", target: nil, action: nil)

    override var isFlipped: Bool { true }

    private static var dismissed: Bool {
        get { UserDefaults.standard.bool(forKey: "Meetings.notNow") }
        set { UserDefaults.standard.set(newValue, forKey: "Meetings.notNow") }
    }

    /// Whether there is anything to show over today: meetings, or the asking.
    static var wanted: Bool {
        let calendars = CalendarEvents.shared
        return calendars.isAllowed ? !calendars.events(on: .today).isEmpty : calendars.canAsk && !dismissed
    }

    init(metrics: OutlineMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
        ask.bezelStyle = .glass
        ask.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)
        ask.imagePosition = .imageLeading
        ask.target = self
        ask.action = #selector(askClicked)
        notNow.isBordered = false
        notNow.contentTintColor = Ink.secondary
        notNow.target = self
        notNow.action = #selector(notNowClicked)
        addSubview(heading)
        addSubview(ask)
        addSubview(notNow)
        show()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func askClicked() {
        Task { @MainActor in
            _ = await CalendarEvents.shared.ask()
            show()
        }
    }

    @objc private func notNowClicked() {
        Self.dismissed = true
        show()
    }

    private func show() {
        let calendars = CalendarEvents.shared
        events = calendars.isAllowed ? calendars.events(on: .today) : []
        let asking = !calendars.isAllowed && calendars.canAsk && !Self.dismissed
        ask.isHidden = !asking
        notNow.isHidden = !asking
        rows.forEach { $0.removeFromSuperview() }
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        let typography = metrics.typography
        rows = events.map { event in
            let title = NSMutableAttributedString(string: time.string(from: event.start) + "  ", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: round(metrics.fontSize * 0.82), weight: .medium), .foregroundColor: Ink.secondary,
            ])
            title.append(NSAttributedString(string: event.title, attributes: [
                .font: Typography.font(typography.bodyFamily, face: typography.bodyFace, size: metrics.fontSize), .foregroundColor: Ink.text,
            ]))
            let button = MeetingButton(title: "", target: nil, action: nil)
            button.attributedTitle = title
            button.isBordered = false
            button.alignment = .left
            button.toolTip = "Open its note — made the first time, with who is in it"
            button.run = { [weak self] in self?.onMeeting?(event) }
            addSubview(button)
            return button
        }
        needsLayout = true
        onHeightChange?()
    }

    private var rowHeight: CGFloat { ceil(metrics.fontSize * 1.8) }

    private func column(_ width: CGFloat) -> NSRect {
        let column = min(metrics.columnWidth, width - 48)
        return NSRect(x: ((width - column) / 2).rounded(), y: 0, width: column, height: 0)
    }

    /// Under a heading of its own, as Still open is.
    private var top: CGFloat { round(metrics.fontSize * 3.2) }
    private lazy var heading = ColumnLabel("Meetings", metrics: metrics)

    func desiredHeight(width: CGFloat) -> CGFloat {
        if !ask.isHidden { return top + 40 }
        return events.isEmpty ? 0 : top + CGFloat(events.count) * rowHeight + 4
    }

    override func layout() {
        super.layout()
        let column = column(bounds.width)
        let x = column.minX + metrics.indent - 2
        heading.frame = NSRect(x: x, y: round(metrics.fontSize * 1.6), width: column.maxX - x, height: heading.intrinsicContentSize.height)
        if !ask.isHidden {
            ask.sizeToFit()
            ask.frame.origin = NSPoint(x: x, y: top)
            notNow.sizeToFit()
            notNow.frame.origin = NSPoint(x: ask.frame.maxX + 8, y: top + (ask.frame.height - notNow.frame.height) / 2)
        }
        var y = top
        for row in rows {
            row.frame = NSRect(x: x, y: y, width: column.maxX - x, height: rowHeight)
            y += rowHeight
        }
    }
}

/// A meeting's row: clicked, its note.
private final class MeetingButton: NSButton {
    var run: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        target = self
        action = #selector(clicked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
    }

    @objc private func clicked() { run?() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
