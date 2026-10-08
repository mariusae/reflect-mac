import UIKit
import UniformTypeIdentifiers

/// Share ▸ Prism: a web page kept as a link note, as the Mac's capture
/// keeps one — its title, address and description, and what was selected
/// on it as a highlight — linked from today; or, chosen, a bullet linking
/// to it at the top of today. A card shows what will be
/// kept, the title editable; Save leaves it for Prism, which makes the
/// note when it next opens.
final class ShareViewController: UIViewController {
    private let card = UIView()
    private let heading = UILabel()
    private let titleField = UITextField()
    private let address = UILabel()
    private let quote = UILabel()
    private let status = UILabel()
    /// Where it goes: a note of its own, or a bullet at the top of today.
    private let destination = UISegmentedControl(items: ["Link Note", "Today"])
    private let save = UIButton(type: .system)
    private let cancel = UIButton(type: .system)
    private var item: ShareQueue.Item?

    private static func color(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                           blue: CGFloat(value & 0xff) / 255, alpha: 1)
        }
    }

    private let paper = color(0xfaf7f2, 0x1c1a18)
    private let ink = color(0x2b2724, 0xece6dc)
    private let secondary = color(0x6f665d, 0xa79e92)
    private let accent = UIColor(red: 0.15, green: 0.36, blue: 0.82, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        card.backgroundColor = paper
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        view.addSubview(card)

        heading.text = "Save to Prism"
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.textColor = secondary
        titleField.font = .systemFont(ofSize: 20, weight: .bold)
        titleField.textColor = ink
        titleField.placeholder = "Title"
        titleField.clearButtonMode = .whileEditing
        titleField.returnKeyType = .done
        titleField.addAction(UIAction { [weak self] _ in self?.titleField.resignFirstResponder() }, for: .editingDidEndOnExit)
        address.font = .systemFont(ofSize: 14)
        address.textColor = accent
        address.lineBreakMode = .byTruncatingMiddle
        quote.font = .italicSystemFont(ofSize: 15)
        quote.textColor = ink
        quote.numberOfLines = 4
        status.font = .systemFont(ofSize: 14)
        status.textColor = secondary
        status.numberOfLines = 0
        status.text = "Reading the page…"

        var saveStyle = UIButton.Configuration.filled()
        saveStyle.title = "Save"
        saveStyle.baseBackgroundColor = accent
        saveStyle.cornerStyle = .capsule
        save.configuration = saveStyle
        save.isEnabled = false
        save.addAction(UIAction { [weak self] _ in self?.keep() }, for: .touchUpInside)
        var cancelStyle = UIButton.Configuration.plain()
        cancelStyle.title = "Cancel"
        cancelStyle.baseForegroundColor = secondary
        cancel.configuration = cancelStyle
        cancel.addAction(UIAction { [weak self] _ in self?.close(cancelled: true) }, for: .touchUpInside)

        destination.selectedSegmentIndex = ShareQueue.lastDestination == "today" ? 1 : 0
        destination.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            ShareQueue.lastDestination = isToday ? "today" : "note"
            describe()
        }, for: .valueChanged)

        let buttons = UIStackView(arrangedSubviews: [cancel, UIView(), save])
        let stack = UIStackView(arrangedSubviews: [heading, titleField, address, quote, destination, status, buttons])
        stack.axis = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(18, after: status)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -60),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            save.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
        ])
        Task { await read() }
    }

    // MARK: What was shared

    private func read() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        var found: ShareQueue.Item?
        for item in items {
            for provider in item.attachments ?? [] {
                // Safari: the page read by GetPageInfo.js.
                if provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier),
                   let dictionary = try? await provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier) as? NSDictionary,
                   let page = dictionary[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any],
                   let url = page["url"] as? String, !url.isEmpty {
                    let selection = (page["selection"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    found = .init(url: url, title: page["title"] as? String ?? "", description: page["description"] as? String ?? "",
                                  highlights: selection.isEmpty ? [] : [selection], shared: Date())
                    break
                }
                // Any other app: an address, its title if the item has one.
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
                   url.scheme?.hasPrefix("http") == true {
                    found = .init(url: url.absoluteString, title: item.attributedContentText?.string ?? "", description: "",
                                  highlights: [], shared: Date())
                    break
                }
                // Text with an address in it.
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
                   let url = Self.firstLink(in: text) {
                    let rest = text.replacingOccurrences(of: url, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    found = .init(url: url, title: rest.count < 200 ? rest : "", description: "", highlights: [], shared: Date())
                    break
                }
            }
            if found != nil { break }
        }
        show(found)
    }

    private static func firstLink(in text: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let match = detector?.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        guard let url = match?.url, url.scheme?.hasPrefix("http") == true else { return nil }
        return url.absoluteString
    }

    private func show(_ found: ShareQueue.Item?) {
        item = found
        guard let found else {
            status.text = "There is no web page here to save."
            titleField.isHidden = true
            address.isHidden = true
            destination.isHidden = true
            quote.isHidden = true
            return
        }
        titleField.text = found.title.trimmingCharacters(in: .whitespacesAndNewlines)
        address.text = found.url
        quote.text = found.highlights.first.map { "“\($0)”" }
        quote.isHidden = found.highlights.isEmpty
        describe()
        save.isEnabled = true
    }

    private var isToday: Bool { destination.selectedSegmentIndex == 1 }

    /// What saving will do, as chosen.
    private func describe() {
        guard let item else { return }
        if isToday {
            status.text = item.highlights.isEmpty
                ? "Added to the top of today, as a link."
                : "Added to the top of today, as a link, this highlight under it."
        } else {
            status.text = item.highlights.isEmpty
                ? "Kept as a link note, linked from today."
                : "Kept as a link note with this highlight, linked from today."
        }
    }

    // MARK: Keeping it

    private func keep() {
        guard var item else { return }
        let typed = titleField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        item.title = typed
        item.destination = isToday ? "today" : "note"
        do {
            try ShareQueue.enqueue(item)
        } catch {
            status.text = "Couldn’t save: \(error.localizedDescription)"
            return
        }
        save.isEnabled = false
        status.text = "Saved. It will be in Prism when you next open it."
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.close(cancelled: false) }
    }

    private func close(cancelled: Bool) {
        if cancelled {
            extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
