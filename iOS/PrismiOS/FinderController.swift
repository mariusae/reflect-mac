import UIKit
import ReflectCore
import PrismCore

/// Go to a note: typed for by name, or a day by any way of saying it —
/// `friday`, `3 days ago`, `march 5` — whether it has a note yet or not.
final class FinderController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    enum Place {
        case day(Day)
        case note(String)
        /// Every note searched for the words.
        case search(String)
    }

    private struct Item {
        var place: Place
        var title: String
        var detail: String
        var symbol: String
    }

    private let store: PrismStore
    private let field = UISearchBar()
    private let table = UITableView(frame: .zero, style: .plain)
    private var items: [Item] = []
    /// Told what was chosen; the finder is gone by then.
    var onChoose: ((Place) -> Void)?

    init(store: PrismStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Ink.paper
        field.placeholder = "Search notes and days"
        field.searchBarStyle = .minimal
        field.autocapitalizationType = .none
        field.returnKeyType = .go
        field.delegate = self
        field.showsCancelButton = true
        view.addSubview(field)
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.keyboardDismissMode = .onDrag
        table.register(UITableViewCell.self, forCellReuseIdentifier: "place")
        view.addSubview(table)
        find("")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        field.becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top + 8
        field.frame = CGRect(x: 8, y: top, width: view.bounds.width - 16, height: 52)
        table.frame = CGRect(x: 0, y: field.frame.maxY + 4, width: view.bounds.width, height: view.bounds.height - field.frame.maxY - 4)
    }

    // MARK: Finding

    private func find(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespaces)
        var items: [Item] = []
        let today = Day.today
        func dayItem(_ day: Day) -> Item {
            let path = GraphPaths.dailyPath(for: day)
            let named = day == today ? "Today" : day == today.adding(-1) ? "Yesterday" : day == today.adding(1) ? "Tomorrow" : nil
            let exists = store.graph?.exists(path: path) == true
            return Item(place: .day(day), title: NoteBlock.dayTitle(day),
                        detail: [named, exists ? nil : "no note yet"].compactMap { $0 }.joined(separator: " · "), symbol: "calendar")
        }
        if query.isEmpty || "today".hasPrefix(query.lowercased()) { items.append(dayItem(today)) }
        if let day = DayQuery.day(query), !(day == today && !items.isEmpty) { items.append(dayItem(day)) }
        let relative = RelativeDateTimeFormatter()
        for match in store.index?.matches(query, limit: 30) ?? [] {
            items.append(Item(place: .note(match.entry.path), title: match.entry.title,
                              detail: match.alias.map { "as \($0)" } ?? relative.localizedString(for: match.entry.modified, relativeTo: Date()),
                              symbol: match.entry.isTopic ? "number" : "doc.text"))
        }
        // Last, the words looked for in every note.
        if !query.isEmpty {
            items.append(Item(place: .search(query), title: "Search notes for “\(query)”", detail: "", symbol: "text.magnifyingglass"))
        }
        self.items = items
        table.reloadData()
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange text: String) { find(text) }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        if let first = items.first { choose(first.place) }
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) { dismiss(animated: true) }

    private func choose(_ place: Place) {
        field.resignFirstResponder()
        dismiss(animated: true) { [onChoose] in onChoose?(place) }
    }

    // MARK: The list

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "place", for: indexPath)
        let item = items[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = item.title
        content.secondaryText = item.detail.isEmpty ? nil : item.detail
        content.image = UIImage(systemName: item.symbol)
        content.imageProperties.tintColor = Ink.secondary
        content.textProperties.font = Typeface.current.body(17, weight: indexPath.row == 0 ? .semibold : .regular)
        content.textProperties.color = Ink.text
        content.secondaryTextProperties.color = Ink.secondary
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        choose(items[indexPath.row].place)
    }
}
