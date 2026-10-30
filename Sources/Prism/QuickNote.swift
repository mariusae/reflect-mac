import AppKit
import Carbon.HIToolbox
import PrismCore
import ReflectCore
import ReflectUI

/// A note for today, from anywhere: ⌃⌥Space, wherever one is. Tapped, a
/// panel to type a line in — ↩ puts it at the top of today. Held, it
/// listens — ElevenLabs online, Apple's own offline — and let go, what was
/// said goes to today, as the phone's dictation does. Said with something
/// typed already, it is added to what was typed, to be put in with ↩.
@MainActor
final class QuickNoteController: NSObject, NSTextViewDelegate {
    private let session: Session
    private let panel: QuickNotePanel
    private let glass = NSGlassEffectView()
    private let field = QuickNoteTextView()
    private let placeholder = NSTextField(labelWithString: "Add to Today")
    private let mic = CloseButton(symbol: "mic", pointSize: 15, toolTip: "Dictate (hold ⌃⌥Space)")
    private let hint = NSTextField(labelWithString: "")
    /// Beside the microphone while listening: who is writing it down.
    private let engineMark = NSImageView()
    private var engine: Dictation.Engine?
    private var hotKey: GlobalHotKey?

    private var dictation: Dictation?
    /// What was typed before listening began: what is heard goes after it.
    private var typed = ""
    /// The hot key held down, since then.
    private var pressed: Date?
    private var wasShown = false
    private var closing: DispatchWorkItem?

    private static let width: CGFloat = 600
    /// A line of the field, in the notes' own face.
    private var lineHeight: CGFloat {
        guard let font = field.font, let manager = field.layoutManager else { return 22 }
        return ceil(manager.defaultLineHeight(for: font))
    }
    /// Held longer than this, the hot key is dictation; shorter, a tap.
    private static let holdTime: TimeInterval = 0.3
    static let shortcut = "⌃⌥Space"

    init(session: Session) {
        self.session = session
        panel = QuickNotePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        build()
        if !Session.scripted {
            hotKey = GlobalHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey),
                                  pressed: { [weak self] in self?.hotKeyDown() },
                                  released: { [weak self] in self?.hotKeyUp() })
        }
    }

    private func build() {
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.onCancel = { [weak self] in self?.close() }

        let root = FlippedView()
        panel.contentView = root
        glass.cornerRadius = 22
        root.addSubview(glass)
        let content = FlippedView()
        glass.contentView = content

        field.isRichText = false
        field.drawsBackground = false
        field.font = session.metrics.body
        field.textColor = Ink.text
        field.insertionPointColor = Ink.accent
        field.textContainerInset = .zero
        field.textContainer?.lineFragmentPadding = 0
        field.isHorizontallyResizable = false
        field.isVerticallyResizable = true
        field.allowsUndo = true
        field.delegate = self
        placeholder.font = session.metrics.body
        placeholder.textColor = Ink.faint
        mic.target = self
        mic.action = #selector(micClicked(_:))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = Ink.secondary
        engineMark.isHidden = true
        for view in [field, placeholder, engineMark, mic, hint] as [NSView] { content.addSubview(view) }
        showHint()
    }

    // MARK: Showing

    /// The panel brought up — over whatever is in front, Prism not brought
    /// forward with it — on the screen the pointer is on.
    func show() {
        closing?.cancel()
        if !panel.isVisible {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                layout()
                panel.setFrameTopLeftPoint(NSPoint(x: visible.midX - Self.width / 2, y: visible.minY + visible.height * 0.72))
            }
            panel.alphaValue = 1
        }
        Dictation.prepare()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    /// The graph let go: the panel away, the hot key given up.
    func end() {
        close()
        hotKey?.unregister()
        hotKey = nil
    }

    func close() {
        if let dictation {
            dictation.cancel()
            self.dictation = nil
            listening(false)
        }
        panel.orderOut(nil)
    }

    private func layout() {
        let lines = max(1, min(6, Int(ceil(fieldHeight() / lineHeight))))
        let textHeight = CGFloat(lines) * lineHeight
        let height = 18 + textHeight + 10 + 16 + 14
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: Self.width, height: height)
        frame.origin.y = top - height
        panel.setFrame(frame, display: true)
        glass.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        let micSide: CGFloat = 32
        // Room for the engine's mark beside the microphone.
        field.frame = NSRect(x: 22, y: 18, width: Self.width - 22 - micSide - 22 - 22, height: textHeight)
        placeholder.frame = NSRect(x: 22, y: 18, width: field.frame.width, height: lineHeight)
        mic.frame = NSRect(x: Self.width - 14 - micSide, y: 14, width: micSide, height: micSide)
        engineMark.frame = NSRect(x: mic.frame.minX - 20, y: mic.frame.midY - 8, width: 16, height: 16)
        hint.frame = NSRect(x: 22, y: 18 + textHeight + 10, width: Self.width - 44, height: 16)
        placeholder.isHidden = !field.string.isEmpty
    }

    private func fieldHeight() -> CGFloat {
        guard let container = field.textContainer, let manager = field.layoutManager else { return lineHeight }
        container.containerSize = NSSize(width: Self.width - 22 - 32 - 22 - 22, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return max(lineHeight, manager.usedRect(for: container).height)
    }

    private func showHint(_ text: String? = nil) {
        hint.stringValue = text ?? "↩ Add to Today    ⇧↩ New line    Hold \(Self.shortcut) to dictate    esc Close"
    }

    func textDidChange(_ notification: Notification) { layout() }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                add(field.string)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    // MARK: Adding

    /// What was written, at the top of today — a word to say so, and gone.
    private func add(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return close() }
        do {
            try session.addToToday(text)
        } catch {
            showHint("Couldn’t add to Today: \(error.localizedDescription)")
            return
        }
        field.string = ""
        layout()
        showHint("✓ Added to Today")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; self.panel.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated {
                    self.panel.orderOut(nil)
                    self.panel.alphaValue = 1
                    self.showHint()
                }
            }
        }
        closing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    // MARK: Dictating

    private func hotKeyDown() {
        pressed = Date()
        wasShown = panel.isVisible && panel.alphaValue > 0
        show()
        beginListening()
    }

    private func hotKeyUp() {
        guard let pressed else { return }
        self.pressed = nil
        if Date().timeIntervalSince(pressed) < Self.holdTime {
            // A tap: no dictation — the panel, to type in; or, up already and empty, away.
            dictation?.cancel()
            dictation = nil
            listening(false)
            field.string = typed
            layout()
            if wasShown && typed.isEmpty { close() }
            return
        }
        // Held: what was said, into today — or after what was typed.
        finishListening(addToToday: typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @objc private func micClicked(_ sender: Any?) {
        if dictation != nil { finishListening(addToToday: false) } else { beginListening() }
    }

    private func beginListening() {
        guard dictation == nil else { return }
        // Asked of the system, from an app bundle that says why: a bare binary would be stopped.
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            return showHint("Dictation needs Prism built as an app (scripts/build-prism.sh)")
        }
        typed = field.string
        let dictation = Dictation()
        self.dictation = dictation
        listening(true)
        Task { @MainActor in
            guard await Dictation.allowed() else {
                if self.dictation === dictation { self.dictation = nil }
                listening(false)
                return showHint("Prism can’t listen: allow the microphone in System Settings ▸ Privacy & Security")
            }
            guard self.dictation === dictation else { return }
            dictation.onEngine = { engine in
                guard self.dictation === dictation else { return }
                self.show(engine)
            }
            do {
                try dictation.start(keyterms: Dictation.terms(session.index)) { heard in
                    guard self.dictation === dictation else { return }
                    self.field.string = Self.join(self.typed, heard)
                    self.layout()
                }
            } catch {
                self.dictation = nil
                listening(false)
                showHint("Dictation isn’t available right now")
            }
        }
    }

    private func finishListening(addToToday: Bool) {
        guard let dictation else { return }
        self.dictation = nil
        showHint("Writing it down…")
        Task { @MainActor in
            let heard = await dictation.stop()
            listening(false)
            let text = Self.join(typed, heard)
            if addToToday, !heard.isEmpty {
                add(text)
            } else {
                field.string = text
                field.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
                layout()
                showHint()
            }
        }
    }

    private func listening(_ on: Bool) {
        mic.image = NSImage(systemSymbolName: on ? "mic.fill" : "mic", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        mic.contentTintColor = on ? .systemRed : Ink.secondary
        placeholder.stringValue = on ? "Listening…" : "Add to Today"
        if !on { engine = nil }
        show(engine)
    }

    /// Who is writing it down, beside the microphone and in the hint: a
    /// faint waveform while ElevenLabs is asked, its waveform once it
    /// listens, Apple's mark for Apple's recognition.
    private func show(_ engine: Dictation.Engine?) {
        self.engine = engine
        engineMark.isHidden = engine == nil
        guard let engine else { return showHint() }
        engineMark.image = NSImage(systemSymbolName: engine.symbol, accessibilityDescription: engine.name)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        engineMark.contentTintColor = engine == .connecting ? Ink.faint : engine == .scribe ? Ink.accent : Ink.secondary
        engineMark.toolTip = engine.name
        let who = engine == .connecting ? "connecting to ElevenLabs" : engine == .scribe ? "with ElevenLabs" : "with Apple’s dictation, on this Mac"
        showHint("Listening \(who) — let go of \(Self.shortcut) to add it to Today")
    }

    /// The panel as it would look, for a script: off screen, over a desktop's colour.
    func viewForScript(text: String, listening on: Bool, engine: Dictation.Engine? = nil) -> NSView {
        panel.setFrameOrigin(NSPoint(x: -4000, y: 0))
        field.string = text
        layout()
        listening(on)
        if on { show(engine) }
        panel.orderBack(nil)
        return panel.contentView!
    }

    private static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        return a.isEmpty ? b : b.isEmpty ? a : a.hasSuffix("\n") ? a + b : a + " " + b
    }
}

/// The panel: key without bringing Prism forward, as Spotlight's is.
final class QuickNotePanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class QuickNoteTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }
}

/// A key held anywhere — in whichever app is in front — told when it goes
/// down and when it comes up: Carbon's hot keys, which need no permission.
@MainActor
final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private let pressed: () -> Void
    private let released: () -> Void
    private static var handler: EventHandlerRef?
    private static var keys: [UInt32: GlobalHotKey] = [:]
    private static var nextID: UInt32 = 1

    init?(keyCode: UInt32, modifiers: UInt32, pressed: @escaping () -> Void, released: @escaping () -> Void) {
        self.pressed = pressed
        self.released = released
        Self.installHandler()
        let id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x5052_534D), id: id)  // "PRSM"
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else {
            Log.shared.warning("hotkey", "Could not take the shortcut: another app may have it", detail: "status \(status)")
            return nil
        }
        Self.keys[id] = self
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        Self.keys = Self.keys.filter { $0.value !== self }
    }

    private static func installHandler() {
        guard handler == nil else { return }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let kind = GetEventKind(event)
            MainActor.assumeIsolated {
                guard let key = GlobalHotKey.keys[hotKeyID.id] else { return }
                if kind == UInt32(kEventHotKeyPressed) { key.pressed() } else { key.released() }
            }
            return noErr
        }, types.count, &types, nil, &handler)
    }
}
