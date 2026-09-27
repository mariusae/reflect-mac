import SwiftUI
import ReflectCore

/// A place in the graph a navigation stack can go.
enum Route: Hashable {
    case note(String)
    case tag(String)
    /// A `[[link]]` to a note that does not exist.
    case missing(String)
}

/// A navigation stack through the graph: it follows the app's links —
/// `[[notes]]` and `#tags` — in itself, on whichever page they are tapped,
/// and sends the web's to Safari.
struct NoteStack<Root: View>: View {
    @ViewBuilder var root: () -> Root
    @State private var path: [Route] = []
    @Environment(GraphStore.self) private var store

    var body: some View {
        NavigationStack(path: $path) {
            root().navigationDestination(for: Route.self) { route in
                switch route {
                case .note(let notePath): NoteView(path: notePath)
                case .tag(let name): TagView(name: name)
                case .missing(let title): MissingNoteView(title: title)
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == InlineText.Link.scheme else { return .systemAction }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            switch url.host {
            case "note":
                guard let title = items.first(where: { $0.name == "title" })?.value else { return .discarded }
                path.append(store.resolve(title).map(Route.note) ?? .missing(title))
            case "tag":
                guard let name = items.first(where: { $0.name == "name" })?.value else { return .discarded }
                path.append(.tag(name))
            default:
                return .discarded
            }
            return .handled
        })
    }
}

struct MissingNoteView: View {
    let title: String

    var body: some View {
        ContentUnavailableView(title, systemImage: "doc.questionmark",
                               description: Text("No note has this title yet."))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}
