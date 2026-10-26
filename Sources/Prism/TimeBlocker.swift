import AppKit
import ReflectCore
import ReflectUI
import PrismCore

/// A block where the week has it: its day, and the block as that day's note
/// writes it.
struct PlacedBlock: Hashable {
    var day: Day
    var block: DayBlock

    func hash(into hasher: inout Hasher) {
        hasher.combine(day)
        hasher.combine(block.row)
    }
}

extension NSPasteboard.PasteboardType {
    /// One of the graph's tasks, dragged: its note's path and which task of
    /// the note it is, a line each.
    static let prismTask = NSPasteboard.PasteboardType("com.prism.task")
}

/// A day's time blocks, as a column shows them: the day down its hours,
/// its blocks as the "Timeblocks" bullet of its note has them — dragged in
/// empty space to make one, dragged to move it, by its foot to make it
/// longer, clicked to change what it says and its checklist; a task dragged
/// from the list to an hour is moved there, out of its note.
@MainActor
final class TimeBlocksPage {
    /// What the page reads and writes the graph through: the window
    /// controller's own, so the columns open show what is changed.
    struct Store {
        /// Unsaved writing written first: before a note is read to change.
        var flush: () -> Void
        var read: (String) -> String?
        /// Notes written, at their paths, and everything shown caught up.
        var write: ([(path: String, source: String)]) -> Void
        var openNote: (String) -> Void
    }

    private let store: Store
    private(set) var day: Day
    /// The hours, as the column's one block.
    let block = BlockGridBlock()
    private var grid: WeekGrid { block.grid }
    private var editor: (popover: NSPopover, view: BlockEditor)?
    /// Told where to scroll to: the hours of the day its work starts, or now.
    var onScrollTo: ((CGFloat) -> Void)?

    init(store: Store, day: Day, typography: Typography) {
        self.store = store
        self.day = day
        setTypography(typography)
        grid.onCreate = { [weak self] day, start, end in self?.create(on: day, start: start, end: end) }
        grid.onMove = { [weak self] placed, day, start, end in self?.move(placed, to: day, start: start, end: end) }
        grid.onOpen = { [weak self] placed, rect in self?.edit(placed, at: rect) }
        grid.onToggle = { [weak self] day, row, task in self?.change(day) { DayBlocks.settingTask(row: row, to: task, in: $0) } }
        grid.onDropTask = { [weak self] path, ordinal, day, start in self?.place(task: path, ordinal: ordinal, on: day, start: start) }
        grid.onDelete = { [weak self] placed in self?.delete(placed) }
        reload()
    }

    func setTypography(_ typography: Typography) {
        grid.typography = typography
    }

    /// Another day: its blocks read, scrolled to where its work starts —
    /// today, to now.
    func show(_ day: Day) {
        let fresh = day != self.day
        self.day = day
        editor?.popover.close()
        reload()
        if fresh { scrollToWork() }
    }

    func scrollToWork() {
        var first = (grid.blocks.map(\.block.start).min() ?? 8 * 60) - 30
        // Today: now in sight, under the week, an hour or two down.
        if day == .today { first = min(max(first, Self.nowMinutes - 240), Self.nowMinutes - 150) }
        onScrollTo?(grid.y(max(0, first)))
    }

    /// The graph changed: shown again.
    func reload() {
        let source = store.read(GraphPaths.dailyPath(for: day)) ?? ""
        grid.days = [day]
        grid.blocks = DayBlocks.blocks(in: source).map { PlacedBlock(day: day, block: $0) }
        if let editor, let shown = editor.view.placed {
            if let fresh = grid.blocks.first(where: { $0.day == shown.day && $0.block.row == shown.block.row }) {
                editor.view.update(fresh)
            } else {
                editor.popover.close()
            }
        }
    }

    /// Now moved on: its line.
    func tick() { grid.nowTick() }

    static var nowMinutes: Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// The block it is now, of a day's note's: nil, none.
    static func current(in source: String, at date: Date = Date()) -> (block: DayBlock, remaining: TimeInterval)? {
        let seconds = date.timeIntervalSince(Calendar.current.startOfDay(for: date))
        let minutes = seconds / 60
        guard let block = DayBlocks.blocks(in: source).last(where: { Double($0.start) <= minutes && minutes < Double($0.end) }) else { return nil }
        return (block, Double(block.end) * 60 - seconds)
    }

    // MARK: Changes

    /// A day's note changed: read, made over, written — if it changed.
    private func change(_ day: Day, _ transform: (String) -> String?) {
        store.flush()
        let path = GraphPaths.dailyPath(for: day)
        let source = store.read(path) ?? ""
        guard let updated = transform(source), updated != source else { return }
        store.write([(path, updated)])
        reload()
    }

    private func create(on day: Day, start: Int, end: Int) {
        change(day) { DayBlocks.adding(start: start, end: end, title: "", to: $0) }
        // The new one's editor open, for what it is to be.
        if let made = grid.blocks.first(where: { $0.day == day && $0.block.start == start && $0.block.title.isEmpty }) {
            grid.selected = made
            if let rect = grid.frame(of: made) { edit(made, at: rect, naming: true) }
        }
    }

    /// A block at another time, or on another day: out of the one note,
    /// into the other.
    private func move(_ placed: PlacedBlock, to day: Day, start: Int, end: Int) {
        if day == placed.day {
            change(day) { DayBlocks.retiming(row: placed.block.row, start: start, end: end, in: $0) }
        } else {
            store.flush()
            let from = GraphPaths.dailyPath(for: placed.day), to = GraphPaths.dailyPath(for: day)
            guard let (left, subtree) = DayBlocks.removing(row: placed.block.row, from: store.read(from) ?? "") else { return }
            let placedIn = DayBlocks.inserting(subtree, start: start, end: end, into: store.read(to) ?? "")
            store.write([(from, left), (to, placedIn)])
            reload()
        }
        grid.selected = grid.blocks.first { $0.day == day && $0.block.start == start }
    }

    private func delete(_ placed: PlacedBlock) {
        editor?.popover.close()
        change(placed.day) { DayBlocks.removing(row: placed.block.row, from: $0)?.source }
        grid.selected = nil
    }

    /// A task dragged to an hour: moved out of its note — what is under it
    /// with it — into that day's blocks, an hour long.
    func place(task path: String, ordinal: Int, on day: Day, start: Int) {
        store.flush()
        let to = GraphPaths.dailyPath(for: day)
        let end = min(start + 60, WeekGrid.lastMinute)
        guard let source = store.read(path), let (left, subtree) = DayBlocks.takingTask(ordinal: ordinal, from: source) else {
            return NSSound.beep()
        }
        if path == to {
            store.write([(to, DayBlocks.inserting(subtree, start: start, end: end, into: left))])
        } else {
            store.write([(path, left), (to, DayBlocks.inserting(subtree, start: start, end: end, into: store.read(to) ?? ""))])
        }
        reload()
    }

    // MARK: The editor

    private func edit(_ placed: PlacedBlock, at rect: NSRect, naming: Bool = false) {
        editor?.popover.close()
        let view = BlockEditor()
        view.onTitle = { [weak self] placed, title in
            self?.change(placed.day) { DayBlocks.settingTitle(row: placed.block.row, to: title, in: $0) }
        }
        view.onTask = { [weak self] placed, task in
            self?.change(placed.day) { DayBlocks.settingTask(row: placed.block.row, to: task, in: $0) }
        }
        view.onItemTask = { [weak self] day, row, task in
            self?.change(day) { DayBlocks.settingTask(row: row, to: task, in: $0) }
        }
        view.onItemText = { [weak self] day, row, text in
            self?.change(day) { source in
                text.isEmpty ? DayBlocks.removing(row: row, from: source)?.source : DayBlocks.settingTitle(row: row, to: text, in: source)
            }
        }
        view.onAddItem = { [weak self] placed, text in
            self?.change(placed.day) { DayBlocks.addingItem(text, under: placed.block.row, in: $0) }
        }
        view.onDelete = { [weak self] placed in self?.delete(placed) }
        view.onMoveDay = { [weak self] placed, by in
            self?.editor?.popover.close()
            self?.move(placed, to: placed.day.adding(by), start: placed.block.start, end: placed.block.end)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = view
        view.update(placed)
        editor = (popover, view)
        popover.show(relativeTo: rect, of: grid, preferredEdge: .maxX)
        if naming || placed.block.title.isEmpty { view.focusTitle() }
    }

    // MARK: Scripts

    /// `PRISM_BLOCKS_EDIT=<n>`: the nth block's editor open.
    func editForScript(_ n: Int) {
        guard grid.blocks.indices.contains(n), let rect = grid.frame(of: grid.blocks[n]) else { return }
        grid.selected = grid.blocks[n]
        edit(grid.blocks[n], at: rect)
    }

    /// `PRISM_BLOCKS_MOVE=<n>@<day>@<minute>`: the nth block moved.
    func moveForScript(_ spec: String) {
        let parts = spec.split(separator: "@")
        guard parts.count == 3, let n = Int(parts[0]), grid.blocks.indices.contains(n), let day = Day(parts[1]), let minute = Int(parts[2]) else { return }
        let placed = grid.blocks[n]
        move(placed, to: day, start: minute, end: minute + placed.block.duration)
    }
}

@MainActor protocol TypographyTaking: AnyObject {
    var typography: Typography { get set }
}

/// The hours, as a block of a column: as tall as the day, across it — the
/// hours no wider than reads well.
final class BlockGridBlock: NSView, ColumnBlock {
    let grid = WeekGrid()
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        addSubview(grid)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func desiredHeight(width: CGFloat) -> CGFloat { WeekGrid.height }
    func scrubMarks(listed: Bool) -> [ScrubMark] { [] }

    override func layout() {
        super.layout()
        let width = min(bounds.width - 24, 820)
        grid.frame = NSRect(x: ((bounds.width - width) / 2).rounded() - 12, y: 0, width: width, height: bounds.height)
    }
}

// MARK: - The week's hours

/// The seven days down the hours: their blocks, coloured, the hours ruled,
/// now a red line across today.
final class WeekGrid: NSView, TypographyTaking {
    var typography = Typography() { didSet { needsDisplay = true } }
    var days: [Day] = [] { didSet { needsDisplay = true } }
    var blocks: [PlacedBlock] = [] {
        didSet {
            if let selected, !blocks.contains(selected) {
                self.selected = blocks.first { $0.day == selected.day && $0.block.row == selected.block.row }
            }
            needsDisplay = true
        }
    }
    var selected: PlacedBlock? { didSet { needsDisplay = true } }

    var onCreate: ((Day, Int, Int) -> Void)?
    var onMove: ((PlacedBlock, Day, Int, Int) -> Void)?
    var onOpen: ((PlacedBlock, NSRect) -> Void)?
    /// A checkbox clicked, the block's own or an item's: its day, its row,
    /// what it is to be.
    var onToggle: ((Day, Int, Row.Task?) -> Void)?
    var onDropTask: ((String, Int, Day, Int) -> Void)?
    var onDelete: ((PlacedBlock) -> Void)?

    static let hour: CGFloat = 56
    static let gutter: CGFloat = 58
    static let pad: CGFloat = 12
    static let height = pad * 2 + hour * 24
    /// The latest a block may end: a quarter to midnight, as a time is
    /// written — midnight would be the day's start.
    static let lastMinute = 24 * 60 - 15

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        registerForDraggedTypes([.prismTask])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func y(_ minutes: Int) -> CGFloat { Self.pad + CGFloat(minutes) / 60 * Self.hour }
    private func minutes(at y: CGFloat) -> Double { Double((y - Self.pad) / Self.hour * 60) }
    /// To the quarter hour before.
    private func quarter(_ y: CGFloat) -> Int { max(0, min(Self.lastMinute, Int((minutes(at: y) / 15).rounded(.down)) * 15)) }
    private func snap(_ minutes: Double) -> Int { max(0, min(Self.lastMinute, Int((minutes / 15).rounded()) * 15)) }

    private var columnWidth: CGFloat { max(1, (bounds.width - Self.gutter) / CGFloat(max(1, days.count))) }
    private func columnRect(_ i: Int) -> NSRect {
        NSRect(x: Self.gutter + CGFloat(i) * columnWidth, y: 0, width: columnWidth, height: bounds.height)
    }
    private func dayIndex(at x: CGFloat) -> Int? {
        guard x >= Self.gutter, !days.isEmpty else { return nil }
        return min(days.count - 1, Int((x - Self.gutter) / columnWidth))
    }

    // MARK: Where the blocks go

    /// Each block's lane among those it overlaps, and how many lanes.
    private var lanes: [PlacedBlock: (lane: Int, of: Int)] {
        var found: [PlacedBlock: (Int, Int)] = [:]
        for day in days {
            let list = blocks.filter { $0.day == day }.sorted { ($0.block.start, $0.block.row) < ($1.block.start, $1.block.row) }
            var cluster: [PlacedBlock] = [], ends: [Int] = [], clusterEnd = -1
            func close() {
                for placed in cluster { found[placed] = (found[placed]!.0, ends.count) }
                cluster = []; ends = []
            }
            for placed in list {
                if placed.block.start >= clusterEnd { close() }
                let lane = ends.firstIndex { $0 <= placed.block.start } ?? ends.count
                if lane == ends.count { ends.append(placed.block.end) } else { ends[lane] = placed.block.end }
                found[placed] = (lane, 0)
                cluster.append(placed)
                clusterEnd = max(clusterEnd, placed.block.end)
            }
            close()
        }
        return found
    }

    private func rect(day: Int, start: Int, end: Int, lane: Int = 0, of lanes: Int = 1) -> NSRect {
        let column = columnRect(day).insetBy(dx: 3, dy: 0)
        let width = column.width / CGFloat(max(1, lanes))
        let top = y(start), bottom = max(y(end), top + 14)
        return NSRect(x: column.minX + CGFloat(lane) * width, y: top + 1, width: width - (lane < lanes - 1 ? 2 : 0), height: bottom - top - 2)
    }

    func frame(of placed: PlacedBlock) -> NSRect? {
        guard let day = days.firstIndex(of: placed.day) else { return nil }
        let lane = lanes[placed] ?? (0, 1)
        return rect(day: day, start: placed.block.start, end: placed.block.end, lane: lane.lane, of: lane.of)
    }

    private var frames: [(placed: PlacedBlock, rect: NSRect)] {
        let lanes = lanes
        return blocks.compactMap { placed in
            guard let day = days.firstIndex(of: placed.day) else { return nil }
            let lane = lanes[placed] ?? (0, 1)
            return (placed, rect(day: day, start: placed.block.start, end: placed.block.end, lane: lane.lane, of: lane.of))
        }
    }

    // MARK: Drawing

    func nowTick() {
        let minute = TimeBlocksPage.nowMinutes
        if minute != shownMinute {
            shownMinute = minute
            needsDisplay = true
        }
    }
    private var shownMinute = -1

    /// Checkboxes drawn, where a click ticks them.
    private var boxes: [(rect: NSRect, day: Day, row: Int, task: Row.Task?)] = []

    private var hourFont: NSFont { .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular) }

    override func draw(_ dirtyRect: NSRect) {
        let today = Day.today
        if let i = days.firstIndex(of: today) {
            Ink.hover.withAlphaComponent(0.035).setFill()
            columnRect(i).fill()
        }
        let twelve = TimeStamp.localeIsTwelveHour
        // The hour's name not under now's own.
        let now = days.contains(today) ? TimeBlocksPage.nowMinutes : nil
        for hour in 0...24 {
            let y = y(hour * 60).rounded() + 0.5
            Ink.rule.setFill()
            NSRect(x: Self.gutter, y: y, width: bounds.width - Self.gutter, height: 0.5).fill()
            guard hour > 0, hour < 24, now.map({ abs($0 - hour * 60) > 12 }) ?? true else { continue }
            let label = NSAttributedString(string: Self.hourName(hour, twelveHour: twelve),
                                           attributes: [.font: hourFont, .foregroundColor: Ink.faint])
            let size = label.size()
            label.draw(at: NSPoint(x: Self.gutter - 8 - size.width, y: y - size.height / 2))
        }
        for i in 1..<max(1, days.count) {
            Ink.rule.setFill()
            NSRect(x: (Self.gutter + CGFloat(i) * columnWidth).rounded(), y: 0, width: 0.5, height: bounds.height).fill()
        }

        boxes = []
        let moving = gestureBlock
        for (placed, rect) in frames {
            drawBlock(placed.block, day: placed.day, in: rect, selected: placed == selected,
                      faded: moving.map { $0 == placed } ?? false)
        }
        if let ghost {
            drawBlock(ghost.block, day: ghost.day, in: ghost.rect, selected: true, faded: false, ghost: true)
        }

        if let i = days.firstIndex(of: today) {
            let minute = TimeBlocksPage.nowMinutes
            let y = y(minute)
            let red = Ink.now
            red.setFill()
            let column = columnRect(i)
            NSRect(x: column.minX, y: y - 0.75, width: column.width, height: 1.5).fill()
            NSBezierPath(ovalIn: NSRect(x: column.minX - 4, y: y - 4, width: 8, height: 8)).fill()
            let label = NSAttributedString(string: TimeStamp.shown(minute, twelveHour: twelve).replacingOccurrences(of: " ", with: "\u{2009}"),
                                           attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: red])
            let size = label.size()
            let tag = NSRect(x: Self.gutter - 10 - size.width, y: y - size.height / 2 - 1, width: size.width + 6, height: size.height + 2)
            Ink.paper.setFill()
            tag.insetBy(dx: -2, dy: 0).fill()
            label.draw(at: NSPoint(x: tag.minX + 3, y: tag.minY + 1))
        }
    }

    static func hourName(_ hour: Int, twelveHour: Bool) -> String {
        guard twelveHour else { return String(format: "%02d:00", hour) }
        return "\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")"
    }

    /// A block's colour: its own, from what it says, so a block keeps its
    /// colour where it goes.
    static func color(for block: DayBlock) -> NSColor {
        let key = InlineMarkup.plainText(block.title).lowercased()
        let hash = key.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return palette[Int(hash % UInt32(palette.count))]
    }

    static let palette: [NSColor] = [
        Ink.dynamic(NSColor(srgbRed: 0.24, green: 0.47, blue: 0.85, alpha: 1), NSColor(srgbRed: 0.45, green: 0.64, blue: 1, alpha: 1)),
        Ink.dynamic(NSColor(srgbRed: 0.2, green: 0.6, blue: 0.42, alpha: 1), NSColor(srgbRed: 0.38, green: 0.78, blue: 0.56, alpha: 1)),
        Ink.dynamic(NSColor(srgbRed: 0.85, green: 0.5, blue: 0.15, alpha: 1), NSColor(srgbRed: 0.98, green: 0.67, blue: 0.33, alpha: 1)),
        Ink.dynamic(NSColor(srgbRed: 0.55, green: 0.36, blue: 0.8, alpha: 1), NSColor(srgbRed: 0.72, green: 0.56, blue: 0.98, alpha: 1)),
        Ink.dynamic(NSColor(srgbRed: 0.82, green: 0.3, blue: 0.4, alpha: 1), NSColor(srgbRed: 0.98, green: 0.5, blue: 0.58, alpha: 1)),
        Ink.dynamic(NSColor(srgbRed: 0.15, green: 0.58, blue: 0.64, alpha: 1), NSColor(srgbRed: 0.35, green: 0.78, blue: 0.82, alpha: 1)),
    ]

    private func drawBlock(_ block: DayBlock, day: Day, in rect: NSRect, selected: Bool, faded: Bool, ghost: Bool = false) {
        let color = Self.color(for: block)
        let done = block.task?.isDone == true
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let shape = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        if ghost {
            NSShadow.blockLift.set()
        }
        Ink.paper.setFill()
        shape.fill()
        NSShadow().set()
        color.withAlphaComponent(faded ? 0.07 : (selected ? 0.3 : 0.17) * (done ? 0.6 : 1)).setFill()
        shape.fill()
        shape.addClip()
        color.withAlphaComponent(faded ? 0.35 : 1).setFill()
        NSRect(x: rect.minX, y: rect.minY, width: 3.5, height: rect.height).fill()
        if selected {
            color.withAlphaComponent(0.8).setStroke()
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 5.5, yRadius: 5.5)
            ring.lineWidth = 1.5
            ring.stroke()
        }
        guard !faded else { return }

        let ink = done ? Ink.secondary : Ink.text
        let titleFont = typography.face(style: "Semibold", size: 12) ?? typography.face(style: "Bold", size: 12) ?? .boldSystemFont(ofSize: 12)
        let smallFont = typography.face(style: "Regular", size: 11) ?? typography.face(style: "Book", size: 11) ?? .systemFont(ofSize: 11)
        var x = rect.minX + 9
        var y = rect.minY + 4
        let compact = rect.height < 36
        if let task = block.task {
            let box = NSRect(x: x, y: y + 2, width: 11, height: 11)
            drawBox(box, done: task.isDone, color: color)
            if !ghost { boxes.append((box.insetBy(dx: -3, dy: -3), day, block.row, task.isDone ? .open : .done("x"))) }
            x += 16
        }
        let width = rect.maxX - x - 6
        let title = InlineMarkup.plainText(block.title).isEmpty ? "New Block" : InlineMarkup.plainText(block.title)
        var titleAttributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: block.title.isEmpty ? Ink.faint : ink]
        if done { titleAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let twelve = TimeStamp.localeIsTwelveHour
        let times = TimeStamp.shown(block.start, twelveHour: twelve) + " – " + TimeStamp.shown(block.end, twelveHour: twelve)
        let timeLine = NSAttributedString(string: times, attributes: [.font: smallFont, .foregroundColor: Ink.secondary])
        let length = NSAttributedString(string: TimeStamp.length(block.duration),
                                        attributes: [.font: smallFont, .foregroundColor: color.withAlphaComponent(0.9)])
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        if compact {
            let line = NSMutableAttributedString(string: title, attributes: titleAttributes)
            line.append(NSAttributedString(string: "  " + TimeStamp.shown(block.start, twelveHour: twelve), attributes: [.font: smallFont, .foregroundColor: Ink.secondary]))
            line.draw(with: NSRect(x: x, y: y, width: width, height: 16), options: options)
            return
        }
        let titleHeight = min(rect.maxY - y - 16, ceil(titleFont.boundingRectForFont.height) * (rect.height > 70 ? 2 : 1))
        NSAttributedString(string: title, attributes: titleAttributes)
            .draw(with: NSRect(x: x, y: y, width: width, height: max(15, titleHeight)), options: options)
        let drawn = NSAttributedString(string: title, attributes: titleAttributes)
            .boundingRect(with: NSSize(width: width, height: max(15, titleHeight)), options: options)
        y += min(max(15, titleHeight), ceil(drawn.height)) + 1
        timeLine.draw(with: NSRect(x: x, y: y, width: width, height: 14), options: options)
        if rect.width > 110 {
            let size = length.size()
            if timeLine.size().width + size.width + 8 < width { length.draw(at: NSPoint(x: rect.maxX - 7 - size.width, y: y)) }
        }
        y += 18
        x = rect.minX + 9
        for item in block.items {
            guard y + 14 < rect.maxY - 2 else { break }
            var itemX = x
            if let task = item.task {
                let box = NSRect(x: itemX, y: y + 2, width: 10, height: 10)
                drawBox(box, done: task.isDone, color: color)
                if !ghost { boxes.append((box.insetBy(dx: -3, dy: -3), day, item.row, task.isDone ? .open : .done("x"))) }
                itemX += 15
            } else {
                Ink.secondary.setFill()
                NSBezierPath(ovalIn: NSRect(x: itemX + 3, y: y + 6, width: 3.5, height: 3.5)).fill()
                itemX += 13
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: item.task?.isDone == true ? Ink.secondary : Ink.text]
            if item.task?.isDone == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            NSAttributedString(string: InlineMarkup.plainText(item.text), attributes: attributes)
                .draw(with: NSRect(x: itemX, y: y, width: rect.maxX - itemX - 6, height: 15), options: options)
            y += 16
        }
    }

    private func drawBox(_ box: NSRect, done: Bool, color: NSColor) {
        let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        if done {
            color.setFill()
            path.fill()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: box.minX + box.width * 0.24, y: box.midY))
            tick.line(to: NSPoint(x: box.minX + box.width * 0.43, y: box.maxY - box.height * 0.26))
            tick.line(to: NSPoint(x: box.maxX - box.width * 0.22, y: box.minY + box.height * 0.26))
            tick.lineWidth = 1.5
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            NSColor.white.setStroke()
            tick.stroke()
        } else {
            Ink.paper.withAlphaComponent(0.7).setFill()
            path.fill()
            color.setStroke()
            path.lineWidth = 1.2
            path.stroke()
        }
    }

    // MARK: The pointer

    private enum Gesture {
        case create(day: Int, anchor: Int, current: Int)
        case move(PlacedBlock, grab: Double, day: Int, start: Int, moved: Bool)
        case resize(PlacedBlock, end: Int)
    }
    private var gesture: Gesture? { didSet { needsDisplay = true } }
    /// A task dragged in from the list, where it would go.
    private var dropping: (day: Int, start: Int)? { didSet { needsDisplay = true } }

    private var gestureBlock: PlacedBlock? {
        switch gesture {
        case .move(let placed, _, _, _, true), .resize(let placed, _): placed
        default: nil
        }
    }

    /// What is drawn where the pointer has it: a block being made, moved,
    /// lengthened, or a task about to be dropped.
    private var ghost: (block: DayBlock, day: Day, rect: NSRect)? {
        switch gesture {
        case .create(let day, let anchor, let current) where current != anchor:
            let start = min(anchor, current), end = max(anchor, current)
            let block = DayBlock(row: -1, start: start, end: end, title: "", task: nil, items: [])
            return (block, days[day], rect(day: day, start: start, end: end))
        case .move(let placed, _, let day, let start, true):
            var block = placed.block
            block.end = start + block.duration
            block.start = start
            return (block, days[day], rect(day: day, start: start, end: block.end))
        case .resize(let placed, let end):
            var block = placed.block
            block.end = end
            guard let day = days.firstIndex(of: placed.day) else { return nil }
            return (block, placed.day, rect(day: day, start: block.start, end: end))
        default:
            guard let dropping else { return nil }
            let block = DayBlock(row: -1, start: dropping.start, end: dropping.start + 60, title: droppingTitle, task: .open, items: [])
            return (block, days[dropping.day], rect(day: dropping.day, start: dropping.start, end: min(dropping.start + 60, Self.lastMinute)))
        }
    }
    private var droppingTitle = ""

    override func resetCursorRects() {
        for (_, rect) in frames {
            addCursorRect(NSRect(x: rect.minX, y: rect.maxY - 5, width: rect.width, height: 6), cursor: .resizeUpDown)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let box = boxes.last(where: { $0.rect.contains(point) }) {
            onToggle?(box.day, box.row, box.task)
            return
        }
        if let (placed, rect) = frames.last(where: { $0.rect.contains(point) }) {
            selected = placed
            if point.y > rect.maxY - 6 {
                gesture = .resize(placed, end: placed.block.end)
            } else {
                let day = days.firstIndex(of: placed.day) ?? 0
                gesture = .move(placed, grab: minutes(at: point.y) - Double(placed.block.start), day: day, start: placed.block.start, moved: false)
            }
            return
        }
        selected = nil
        guard let day = dayIndex(at: point.x) else { return }
        let start = quarter(point.y)
        if event.clickCount == 2 {
            gesture = nil
            onCreate?(days[day], start, min(start + 60, Self.lastMinute))
            return
        }
        gesture = .create(day: day, anchor: start, current: start)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        autoscroll(with: event)
        switch gesture {
        case .create(let day, let anchor, _):
            let at = snap(minutes(at: point.y))
            gesture = .create(day: day, anchor: anchor, current: at == anchor ? anchor : at)
        case .move(let placed, let grab, _, _, _):
            let start = max(0, min(Self.lastMinute - placed.block.duration, snap(minutes(at: point.y) - grab)))
            let day = dayIndex(at: point.x) ?? days.firstIndex(of: placed.day) ?? 0
            gesture = .move(placed, grab: grab, day: day, start: start, moved: true)
        case .resize(let placed, _):
            gesture = .resize(placed, end: max(placed.block.start + 15, snap(minutes(at: point.y))))
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let gesture else { return }
        self.gesture = nil
        switch gesture {
        case .create(let day, let anchor, let current):
            guard current != anchor else { return }
            onCreate?(days[day], min(anchor, current), max(anchor, current))
        case .move(let placed, _, let day, let start, let moved):
            if moved, days[day] != placed.day || start != placed.block.start {
                onMove?(placed, days[day], start, start + placed.block.duration)
            } else if let rect = frame(of: placed) {
                onOpen?(placed, rect)
            }
        case .resize(let placed, let end):
            if end != placed.block.end { onMove?(placed, placed.day, placed.block.start, end) }
        }
        window?.invalidateCursorRects(for: self)
    }

    override func keyDown(with event: NSEvent) {
        if let selected, event.keyCode == 51 || event.keyCode == 117 {
            onDelete?(selected)
        } else if event.keyCode == 53 {
            selected = nil
        } else if let selected, event.keyCode == 36, let rect = frame(of: selected) {
            onOpen?(selected, rect)
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: A task dropped

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let text = sender.draggingPasteboard.string(forType: .prismTask) else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        guard let day = dayIndex(at: point.x) else { dropping = nil; return [] }
        droppingTitle = text.split(separator: "\n", maxSplits: 2).dropFirst(2).first.map(String.init) ?? ""
        dropping = (day, quarter(point.y - 10))
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { dropping = nil }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { dropping = nil }
        guard let dropping, let text = sender.draggingPasteboard.string(forType: .prismTask) else { return false }
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard parts.count >= 2, let ordinal = Int(parts[1]) else { return false }
        let day = days[dropping.day], start = dropping.start
        // After the drag is done with: the write shows a new week.
        DispatchQueue.main.async { [weak self] in self?.onDropTask?(String(parts[0]), ordinal, day, start) }
        return true
    }
}

private extension NSShadow {
    static var blockLift: NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        return shadow
    }
}

// MARK: - Now

/// The block of today's on now: in the rail, counting down.
enum NowPill {
    struct Now: Equatable {
        var block: DayBlock
        var remaining: TimeInterval
    }
}

enum BlockerClock {
    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}



// MARK: - A block's editor

/// A block's popover: what it says, whether it is a task, its checklist —
/// each item ticked, changed, or emptied away — one added; its day opened,
/// or the block deleted.
final class BlockEditor: NSViewController, NSTextFieldDelegate {
    private(set) var placed: PlacedBlock?
    var onTitle: ((PlacedBlock, String) -> Void)?
    var onTask: ((PlacedBlock, Row.Task?) -> Void)?
    var onItemTask: ((Day, Int, Row.Task?) -> Void)?
    var onItemText: ((Day, Int, String) -> Void)?
    var onAddItem: ((PlacedBlock, String) -> Void)?
    var onDelete: ((PlacedBlock) -> Void)?
    /// Moved a day earlier, or later.
    var onMoveDay: ((PlacedBlock, Int) -> Void)?

    private let titleField = NSTextField()
    private let when = NSTextField(labelWithString: "")
    private let isTask = NSButton(checkboxWithTitle: "A task, to tick off", target: nil, action: nil)
    private let items = NSStackView()
    private let adding = NSTextField()
    private var itemRows: [Int: (box: NSButton?, field: NSTextField)] = [:]
    /// Which items are shown: the list made again only when they change.
    private var shownItems: [Int] = []

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)

        titleField.font = .systemFont(ofSize: 16, weight: .semibold)
        titleField.placeholderString = "What it is for"
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.delegate = self
        titleField.target = self
        titleField.action = #selector(titleEntered)
        when.textColor = .secondaryLabelColor
        when.font = .systemFont(ofSize: 11.5)
        isTask.target = self
        isTask.action = #selector(taskToggled)
        items.orientation = .vertical
        items.alignment = .leading
        items.spacing = 5
        adding.placeholderString = "Add a checklist item"
        adding.bezelStyle = .roundedBezel
        adding.controlSize = .small
        adding.font = .systemFont(ofSize: 12)
        adding.target = self
        adding.action = #selector(itemAdded)

        let earlier = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "A Day Earlier")!,
                               target: self, action: #selector(dayEarlier))
        let later = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "A Day Later")!,
                             target: self, action: #selector(dayLater))
        earlier.toolTip = "Move to the day before"
        later.toolTip = "Move to the day after"
        let delete = NSButton(title: "Delete", target: self, action: #selector(deleteBlock))
        for button in [earlier, later, delete] {
            button.bezelStyle = .push
            button.controlSize = .small
        }
        delete.contentTintColor = .systemRed
        let buttons = NSStackView(views: [earlier, later, NSView(), delete])
        buttons.orientation = .horizontal
        buttons.distribution = .fill

        let rule = NSBox()
        rule.boxType = .separator
        let checklist = NSTextField(labelWithString: "CHECKLIST")
        checklist.font = .systemFont(ofSize: 10, weight: .semibold)
        checklist.textColor = .tertiaryLabelColor
        for view in [titleField, when, isTask, rule, checklist, items, adding, buttons] as [NSView] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(2, after: titleField)
        stack.setCustomSpacing(12, after: when)
        stack.setCustomSpacing(12, after: isTask)
        for view in [titleField, rule, items, adding, buttons] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 300).isActive = true
        view = stack
    }

    func focusTitle() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            view.window?.makeFirstResponder(titleField)
        }
    }

    func update(_ placed: PlacedBlock) {
        _ = view
        self.placed = placed
        let block = placed.block
        if titleField.currentEditor() == nil { titleField.stringValue = block.title }
        let date = DateFormatter()
        date.setLocalizedDateFormatFromTemplate("EEE MMM d")
        let twelve = TimeStamp.localeIsTwelveHour
        when.stringValue = [placed.day.date.map(date.string) ?? "",
                            TimeStamp.shown(block.start, twelveHour: twelve) + " – " + TimeStamp.shown(block.end, twelveHour: twelve),
                            TimeStamp.length(block.duration)].joined(separator: " · ")
        isTask.state = block.task == nil ? .off : .on
        let rows = block.items.map(\.row)
        if rows != shownItems {
            shownItems = rows
            items.arrangedSubviews.forEach { $0.removeFromSuperview() }
            itemRows = [:]
            for item in block.items {
                let box: NSButton? = item.task.map { _ in
                    let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(itemToggled(_:)))
                    box.tag = item.row
                    return box
                }
                let field = NSTextField()
                field.isBordered = false
                field.drawsBackground = false
                field.focusRingType = .none
                field.font = .systemFont(ofSize: 12.5)
                field.tag = item.row
                field.delegate = self
                let row = NSStackView(views: [box ?? bullet(), field].compactMap { $0 })
                row.orientation = .horizontal
                row.spacing = 4
                items.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: items.widthAnchor).isActive = true
                itemRows[item.row] = (box, field)
            }
        }
        for item in block.items {
            guard let row = itemRows[item.row] else { continue }
            row.box?.state = item.task?.isDone == true ? .on : .off
            if row.field.currentEditor() == nil { row.field.stringValue = item.text }
        }
    }

    private func bullet() -> NSView {
        let dot = NSTextField(labelWithString: "•")
        dot.textColor = .secondaryLabelColor
        return dot
    }

    @objc private func titleEntered() { commitTitle() }

    private func commitTitle() {
        guard let placed, titleField.stringValue != placed.block.title else { return }
        onTitle?(placed, titleField.stringValue.trimmingCharacters(in: .whitespaces))
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let placed else { return }
        if field === titleField { return commitTitle() }
        guard let item = placed.block.items.first(where: { $0.row == field.tag }), item.text != field.stringValue else { return }
        onItemText?(placed.day, field.tag, field.stringValue.trimmingCharacters(in: .whitespaces))
    }

    @objc private func taskToggled() {
        guard let placed else { return }
        onTask?(placed, isTask.state == .on ? .open : nil)
    }

    @objc private func itemToggled(_ sender: NSButton) {
        guard let placed else { return }
        onItemTask?(placed.day, sender.tag, sender.state == .on ? .done("x") : .open)
    }

    @objc private func itemAdded() {
        let text = adding.stringValue.trimmingCharacters(in: .whitespaces)
        guard let placed, !text.isEmpty else { return }
        adding.stringValue = ""
        onAddItem?(placed, text)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            view.window?.makeFirstResponder(adding)
        }
    }

    @objc private func dayEarlier() { placed.map { onMoveDay?($0, -1) } }
    @objc private func dayLater() { placed.map { onMoveDay?($0, 1) } }
    @objc private func deleteBlock() { placed.map { onDelete?($0) } }
}
