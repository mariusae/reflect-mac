import AppKit
import ReflectCore
import ReflectGit2
import ReflectUI

/// Graph ▸ Sync Status (⌥⌘R): whether this Mac keeps the graph in step,
/// and how it has gone — the last sync and what it did, the last failure
/// and what it said, the repository against GitHub, the relay that tells
/// of pushes, when each device last pushed, and the sync's own log. A
/// report of it all copies, to set beside another Mac's.
final class SyncStatusWindow: NSWindowController, NSWindowDelegate {
    let session: Session
    private var health: SyncHealth?
    private var checking = false

    private let dot = NSView()
    private let headline = NSTextField(labelWithString: "")
    private let subline = NSTextField(wrappingLabelWithString: "")
    private let body = NSStackView()
    private let syncNow = NSButton(title: "Sync Now", target: nil, action: nil)
    private var clock: Timer?
    private var logObserver: NSObjectProtocol?
    private var refreshPending = false

    /// A line of the report: what, and how it stands.
    private struct Line {
        enum Tone { case plain, good, warn, bad }
        var label: String
        var value: String
        var tone: Tone = .plain
    }

    private struct Section {
        var title: String
        var lines: [Line]
    }

    init(session: Session) {
        self.session = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Sync Status"
        window.minSize = NSSize(width: 480, height: 400)
        window.backgroundColor = Ink.paper
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        if !window.setFrameUsingName("SyncStatus") { window.center() }
        window.setFrameAutosaveName("SyncStatus")
        build()
        refresh()
        check()
        clock = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        logObserver = NotificationCenter.default.addObserver(forName: Log.didAdd, object: nil, queue: .main) { [weak self] note in
            guard let entry = note.object as? Log.Entry, Self.shows(entry) else { return }
            MainActor.assumeIsolated { self?.setNeedsRefresh() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        clock?.invalidate()
        if let logObserver { NotificationCenter.default.removeObserver(logObserver) }
        session.syncStatusClosed(self)
    }

    /// The sync said something: shown, and the repository looked at again once it is done.
    func syncChanged(_ status: SyncController.Status) {
        refresh()
        switch status {
        case .synced, .failed: check()
        default: break
        }
    }

    // MARK: Building

    private static let categories: Set<String> = ["sync", "git", "relay"]

    /// What the sync said: not each git command, unless it went wrong.
    private static func shows(_ entry: Log.Entry) -> Bool {
        guard categories.contains(entry.category) else { return false }
        return !(entry.category == "git" && entry.level == .info && entry.message.hasPrefix("git ") && !entry.message.contains("— exit "))
    }
    private static let labelWidth: CGFloat = 150

    private func build() {
        guard let content = window?.contentView else { return }
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 6
        headline.font = session.metrics.typography.headingFont(size: 20, weight: .bold)
        headline.textColor = Ink.text
        subline.font = .systemFont(ofSize: 13)
        subline.textColor = Ink.secondary
        subline.isSelectable = true
        let head = NSStackView(views: [dot, headline])
        head.spacing = 10
        head.alignment = .centerY
        dot.widthAnchor.constraint(equalToConstant: 12).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 12).isActive = true

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 6
        let top = NSStackView(views: [head, subline, body])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 6
        top.setCustomSpacing(18, after: subline)
        top.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        top.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(top)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false

        syncNow.target = self
        syncNow.action = #selector(syncNowClicked(_:))
        syncNow.keyEquivalent = "r"
        syncNow.keyEquivalentModifierMask = .command
        let copy = NSButton(title: "Copy Report", target: self, action: #selector(copyReport(_:)))
        let log = NSButton(title: "Show Log File", target: self, action: #selector(showLogFile(_:)))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [log, spacer, copy, syncNow])
        buttons.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 14, right: 20)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false

        for view in [scroll, rule, buttons] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rule.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: rule.bottomAnchor),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            top.topAnchor.constraint(equalTo: document.topAnchor),
            top.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            top.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            subline.widthAnchor.constraint(equalTo: top.widthAnchor, constant: -48),
            body.widthAnchor.constraint(equalTo: top.widthAnchor, constant: -48),
        ])
    }

    // MARK: Looking

    /// The repository looked at again: off the main thread, after any cycle under way.
    private func check() {
        guard !checking else { return }
        checking = true
        refresh()
        Task { [weak self] in
            guard let self else { return }
            let health = await session.syncHealth()
            self.health = health
            checking = false
            refresh()
        }
    }

    private func setNeedsRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refreshPending = false
            self?.refresh()
        }
    }

    func refresh() {
        let (title, detail, tone) = summary()
        headline.stringValue = title
        subline.stringValue = detail
        subline.isHidden = detail.isEmpty
        dot.layer?.backgroundColor = color(tone).cgColor
        syncNow.isEnabled = session.graph.git != nil && session.syncRunning == nil

        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for section in sections() {
            body.addArrangedSubview(heading(section.title))
            for line in section.lines { body.addArrangedSubview(row(line)) }
            if let last = body.arrangedSubviews.last { body.setCustomSpacing(20, after: last) }
        }
        body.addArrangedSubview(heading("Activity"))
        body.addArrangedSubview(activity())
    }

    // MARK: What it says

    /// The one line on top: how syncing stands here, now.
    private func summary() -> (String, String, Line.Tone) {
        guard session.graph.git != nil else {
            return ("Not Syncing", "This graph’s folder is not a git repository: nothing here is backed up or shared.", .bad)
        }
        let record = session.syncRecord
        if session.syncRunning != nil { return ("Syncing…", lastSynced(record), .plain) }
        if case .failed(let message) = session.syncStatus { return ("Sync Failed", Git.subject(of: message), .bad) }
        if !session.ownsSync {
            return ("Prism Doesn’t Sync This Graph", "This folder is kept in step by another app — Reflect, or git by hand. Prism syncs it only when you choose Sync Now. " + lastSynced(record), .warn)
        }
        guard let success = record.lastSuccess else { return ("Not Synced Yet", "No sync has finished on this Mac.", .warn) }
        // Kept in step only while in front: long without taking in others' changes is worth saying.
        if let full = record.lastFullSuccess, Date().timeIntervalSince(full) > 6 * 3600 {
            return ("Synced \(Self.ago(success))",
                    "Other devices’ changes last taken in \(Self.ago(full)). Prism fetches when it comes to the front and every 5 minutes while it is in front.", .warn)
        }
        return ("Synced \(Self.ago(success))", "", .good)
    }

    private func lastSynced(_ record: SyncController.Record) -> String {
        record.lastSuccess.map { "Last synced \(Self.ago($0))." } ?? "No sync has finished on this Mac."
    }

    private func sections() -> [Section] {
        let record = session.syncRecord
        let stats = session.syncStats
        var mac: [Line] = [
            Line(label: "Device", value: Git.device ?? "Unnamed"),
            Line(label: "Graph", value: session.graph.root.path),
            session.ownsSync
                ? Line(label: "Kept in step", value: "By Prism: at launch, on coming to the front, every 5 minutes while in front, and 10 s after writing")
                : Line(label: "Kept in step", value: "Not by Prism — only when you choose Sync Now", tone: .warn),
            relayLine(),
            Line(label: "Last sync", value: record.lastSuccess.map(Self.when) ?? "Never", tone: record.lastSuccess == nil ? .warn : .plain),
        ]
        if let report = record.lastReport {
            mac.append(Line(label: "It did", value: report + (record.lastTiming.map { " — \($0)" } ?? "")))
        }
        mac.append(Line(label: "Last took in changes", value: record.lastFullSuccess.map(Self.when) ?? "Never",
                        tone: record.lastFullSuccess == nil ? .warn : .plain))
        if let failed = record.lastFailure {
            let recovered = record.lastSuccess.map { $0 > failed } ?? false
            mac.append(Line(label: "Last failure", value: Self.when(failed) + (recovered ? " (synced since)" : ""), tone: recovered ? .plain : .bad))
            if let message = record.lastFailureMessage { mac.append(Line(label: "It said", value: message, tone: recovered ? .plain : .bad)) }
        }
        var since = "\(stats.syncs) \(stats.syncs == 1 ? "sync" : "syncs"), \(stats.failures) failed, \(stats.pulled) \(stats.pulled == 1 ? "file" : "files") taken in"
        if stats.conflicts > 0 { since += ", \(stats.conflicts) with conflicts" }
        mac.append(Line(label: "Since launch", value: since + " — \(Self.ago(stats.since))", tone: stats.failures > 0 ? .warn : .plain))
        if !session.toReview.isEmpty {
            mac.append(Line(label: "To review", value: "\(session.toReview.count) \(session.toReview.count == 1 ? "note" : "notes") with both sides of a conflict", tone: .warn))
        }
        var result = [Section(title: "This Mac", lines: mac)]
        guard session.graph.git != nil else { return result }

        guard let health else {
            result.append(Section(title: "Repository", lines: [Line(label: "", value: checking ? "Looking…" : "—")]))
            return result
        }
        var repository: [Line] = [
            Line(label: "Remote", value: health.remote ?? "None — commits stay on this Mac", tone: health.remote == nil ? .bad : .plain),
            Line(label: "Branch", value: health.branch.map { name in name + (health.head.map { " at " + String($0.prefix(8)) } ?? "") } ?? "None — a detached HEAD",
                 tone: health.branch == nil ? .bad : .plain),
        ]
        if health.remote != nil {
            if !health.hasRemoteBranch {
                repository.append(Line(label: "Against the remote", value: "Never fetched", tone: .bad))
            } else {
                var parts: [String] = []
                if health.ahead > 0 { parts.append("\(health.ahead) \(health.ahead == 1 ? "commit" : "commits") to push") }
                if health.behind > 0 { parts.append("\(health.behind) to take in") }
                repository.append(Line(label: "Against the remote", value: (parts.isEmpty ? "Up to date" : parts.joined(separator: ", ")) + ", as last fetched",
                                       tone: parts.isEmpty ? .good : .warn))
            }
        }
        if let operation = health.operation {
            repository.append(Line(label: "In the way", value: "The repository is in the middle of \(operation)", tone: .bad))
        }
        if let age = health.lockAge {
            repository.append(Line(label: "In the way", value: "A git lock, left \(Self.duration(age)) ago", tone: age > 90 ? .bad : .warn))
        }
        result.append(Section(title: "Repository", lines: repository))

        if health.hasRemoteBranch {
            var devices: [Line] = []
            if let newest = health.newest {
                devices.append(Line(label: "Remote’s latest", value: "\(Self.when(newest.date)) — \(Git.subject(of: newest.message))"))
            }
            for device in health.devices {
                let here = device.name == Git.device
                devices.append(Line(label: device.name + (here ? " (this Mac)" : ""), value: "Pushed \(Self.when(device.last))",
                                    tone: Date().timeIntervalSince(device.last) > 3 * 86400 ? .warn : .plain))
            }
            if let unnamed = health.unnamed {
                devices.append(Line(label: "Unnamed", value: "\(Self.when(unnamed.date)) — Reflect, the phone, or Prism before it named devices"))
            }
            if health.devices.isEmpty {
                devices.append(Line(label: "", value: "No commit names its device yet. Each Mac names itself from its next sync, with this version of Prism."))
            }
            result.append(Section(title: "Devices, by the Remote’s History", lines: devices))
        }
        return result
    }

    private func relayLine() -> Line {
        guard let relay = session.relay else {
            return Line(label: "Told of pushes", value: session.ownsSync ? "No relay — other devices’ changes come in only when Prism syncs" : "No")
        }
        let last = relay.lastPush.map { "; last told \(Self.ago($0))" } ?? ""
        switch relay.state {
        case .listening(let since): return Line(label: "Told of pushes", value: "Listening since \(Self.ago(since))\(last)", tone: .good)
        case .connecting: return Line(label: "Told of pushes", value: "Connecting…")
        case .stopped: return Line(label: "Told of pushes", value: "Stopped", tone: .warn)
        case .waiting(let until, let failures, let reason):
            return Line(label: "Told of pushes", value: "Not listening (\(failures) \(failures == 1 ? "try" : "tries")); again \(Self.ago(until))" + (reason.map { ": \($0)" } ?? ""), tone: .bad)
        }
    }

    // MARK: Views

    private func heading(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = Ink.label
        return label
    }

    private func row(_ line: Line) -> NSView {
        let label = NSTextField(wrappingLabelWithString: line.label)
        label.font = .systemFont(ofSize: 13)
        label.textColor = Ink.secondary
        label.alignment = .right
        let value = NSTextField(wrappingLabelWithString: line.value)
        value.font = .systemFont(ofSize: 13)
        value.textColor = line.tone == .plain ? Ink.text : color(line.tone)
        value.isSelectable = true
        let row = NSStackView(views: [label, value])
        row.alignment = .firstBaseline
        row.spacing = 12
        label.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    /// The sync's own log, the newest first: problems coloured.
    private func activity() -> NSView {
        let text = NSMutableAttributedString()
        let entries = Log.shared.entries.filter(Self.shows).suffix(60).reversed()
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        for entry in entries {
            let ink: NSColor = entry.level == .error ? color(.bad) : entry.level == .warning ? color(.warn) : Ink.text
            text.append(NSAttributedString(string: Self.stamp.string(from: entry.date) + "  ", attributes: [.font: font, .foregroundColor: Ink.secondary]))
            text.append(NSAttributedString(string: "\(entry.category): \(entry.message)\n", attributes: [.font: font, .foregroundColor: ink]))
            if let detail = entry.detail, entry.level != .info {
                let indented = detail.split(separator: "\n").prefix(6).map { "          " + $0 }.joined(separator: "\n")
                text.append(NSAttributedString(string: indented + "\n", attributes: [.font: font, .foregroundColor: Ink.secondary]))
            }
        }
        if entries.isEmpty {
            text.append(NSAttributedString(string: "Nothing yet, since launch.", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Ink.secondary]))
        }
        let label = NSTextField(labelWithAttributedString: text)
        label.isSelectable = true
        label.lineBreakMode = .byCharWrapping
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func color(_ tone: Line.Tone) -> NSColor {
        switch tone {
        case .plain: Ink.faint
        case .good: .systemGreen
        case .warn: .systemOrange
        case .bad: .systemRed
        }
    }

    // MARK: Actions

    @objc private func syncNowClicked(_ sender: Any?) {
        session.syncNow()
        refresh()
    }

    /// Everything said here, as text: to compare with another Mac's.
    @objc private func copyReport(_ sender: Any?) {
        let (title, detail, _) = summary()
        var text = "Prism sync status — \(Self.absolute.string(from: Date()))\n\(title)\n"
        if !detail.isEmpty { text += detail + "\n" }
        for section in sections() {
            text += "\n\(section.title)\n"
            for line in section.lines { text += line.label.isEmpty ? "  \(line.value)\n" : "  \(line.label): \(line.value)\n" }
        }
        text += "\nActivity\n"
        for entry in Log.shared.entries.filter(Self.shows).suffix(100) {
            text += "  \(Self.absolute.string(from: entry.date)) [\(entry.level.rawValue)] \(entry.category): \(entry.message)\n"
            if let detail = entry.detail { text += detail.split(separator: "\n").map { "      \($0)\n" }.joined() }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func showLogFile(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([Log.shared.fileURL])
    }

    // MARK: Times

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let absolute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm:ss"
        return formatter
    }()

    /// "2 minutes ago"; "just now", within a few seconds.
    static func ago(_ date: Date) -> String {
        abs(date.timeIntervalSinceNow) < 5 ? "just now" : relative.localizedString(for: date, relativeTo: Date())
    }

    /// "2 minutes ago (Oct 28, 2026 at 8:07:12 PM)".
    static func when(_ date: Date) -> String { "\(ago(date)) (\(absolute.string(from: date)))" }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? "\(Int(seconds)) s"
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
