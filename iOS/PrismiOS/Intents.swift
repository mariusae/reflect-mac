import AppIntents
import ReflectCore

/// Prism's actions for Shortcuts, Siri and the Action button: words put
/// into today without opening the app; a new note, or today, opened.
struct AddToTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Today"
    static let description = IntentDescription("Puts words at the top of today’s note in Prism, each line a row.")

    @Parameter(title: "Words", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // The app running: through its store, which shows it at once; else straight into the graph.
        if let store = PrismStore.live, let graph = store.graph, let index = store.index {
            guard let path = try QuickNote.add(text, in: graph, index: index) else { return .result(dialog: "Nothing to add.") }
            store.noteChanged([path])
        } else {
            let root = PrismStore.defaultRoot
            guard FileManager.default.fileExists(atPath: root.path) else { return .result(dialog: "Prism has no graph yet.") }
            _ = try QuickNote.add(text, in: Graph(root: root, git: nil), index: NoteIndex(root: root))
        }
        return .result(dialog: "Added to today.")
    }
}

/// What an action that opens Prism asked for, waiting for it to be shown.
@MainActor
enum PendingIntent {
    case newNote, today
    static var pending: PendingIntent? { didSet { if pending != nil { onPending?() } } }
    static var onPending: (() -> Void)?
}

struct NewNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Note"
    static let description = IntentDescription("Opens Prism on a new note, its title to type.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingIntent.pending = .newNote
        return .result()
    }
}

struct OpenTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Today"
    static let description = IntentDescription("Opens Prism on today, a new row at its top.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingIntent.pending = .today
        return .result()
    }
}

struct PrismShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddToTodayIntent(), phrases: ["Add to today in \(.applicationName)", "Note in \(.applicationName)"],
                    shortTitle: "Add to Today", systemImageName: "sun.max")
        AppShortcut(intent: NewNoteIntent(), phrases: ["New note in \(.applicationName)"],
                    shortTitle: "New Note", systemImageName: "square.and.pencil")
        AppShortcut(intent: OpenTodayIntent(), phrases: ["Open today in \(.applicationName)"],
                    shortTitle: "Open Today", systemImageName: "calendar")
    }
}
