import UIKit

/// The card file: every column at once, small, two to a row — the one left
/// from marked — tapped to go to it, its × to close it, + for another.
final class OverviewController: UIViewController {
    private let cards: [(image: UIImage, title: String)]
    private let current: Int
    private let scroll = UIScrollView()
    private var cardViews: [UIView] = []
    var onPick: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onAdd: ((SheetKind) -> Void)?

    init(cards: [(UIImage, String)], current: Int) {
        self.cards = cards.map { (image: $0.0, title: $0.1) }
        self.current = current
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Ink.shelf
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)
        for (i, card) in cards.enumerated() {
            let holder = UIView()
            let image = UIImageView(image: card.image)
            image.contentMode = .scaleAspectFill
            image.clipsToBounds = true
            image.layer.cornerRadius = 14
            image.layer.borderWidth = i == current ? 2.5 : 0.5
            image.layer.borderColor = (i == current ? Ink.accent : Ink.rule).cgColor
            image.isUserInteractionEnabled = true
            image.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
            image.tag = i
            holder.addSubview(image)
            let label = UILabel()
            label.text = card.title
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = Ink.text
            label.textAlignment = .center
            holder.addSubview(label)
            if cards.count > 1 {
                let close = UIButton(type: .system)
                close.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22)), for: .normal)
                close.tintColor = Ink.secondary
                close.accessibilityLabel = "Close Column"
                close.tag = i
                close.addTarget(self, action: #selector(closed(_:)), for: .touchUpInside)
                holder.addSubview(close)
            }
            scroll.addSubview(holder)
            cardViews.append(holder)
        }
        let add = UIButton(type: .system)
        add.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
        add.tintColor = Ink.text
        add.accessibilityLabel = "New Column"
        add.showsMenuAsPrimaryAction = true
        add.menu = UIMenu(title: "New Column", children: [
            ("Days", "calendar", SheetKind.timeline), ("Inbox", "tray", .inbox), ("Tasks", "checklist", .tasks), ("Search", "magnifyingglass", .search("")),
        ].map { title, symbol, kind in
            UIAction(title: title, image: UIImage(systemName: symbol)) { [weak self] _ in
                self?.dismiss(animated: true) { self?.onAdd?(kind) }
            }
        })
        navigationItemButton(add, at: .right)
        let done = UIButton(type: .system)
        done.setTitle("Done", for: .normal)
        done.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        done.tintColor = Ink.text
        done.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        navigationItemButton(done, at: .left)
    }

    private enum Side { case left, right }
    private var barButtons: [(UIView, Side)] = []

    private func navigationItemButton(_ button: UIView, at side: Side) {
        view.addSubview(button)
        barButtons.append((button, side))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets
        for (button, side) in barButtons {
            let size = CGSize(width: max(44, button.intrinsicContentSize.width), height: 44)
            button.frame = CGRect(x: side == .left ? 16 : view.bounds.width - 16 - size.width, y: safe.top + 4, width: size.width, height: size.height)
        }
        scroll.frame = CGRect(x: 0, y: safe.top + 52, width: view.bounds.width, height: view.bounds.height - safe.top - 52)
        let gap: CGFloat = 20
        let width = floor((view.bounds.width - 3 * gap) / 2)
        let aspect = view.bounds.height / max(view.bounds.width, 1)
        let height = round(width * aspect)
        for (i, holder) in cardViews.enumerated() {
            let x = gap + CGFloat(i % 2) * (width + gap)
            let y = gap / 2 + CGFloat(i / 2) * (height + 44)
            holder.frame = CGRect(x: x, y: y, width: width, height: height + 30)
            holder.subviews[0].frame = CGRect(x: 0, y: 0, width: width, height: height)
            holder.subviews[1].frame = CGRect(x: 0, y: height + 6, width: width, height: 20)
            if holder.subviews.count > 2 { holder.subviews[2].frame = CGRect(x: width - 34, y: -8, width: 42, height: 42) }
        }
        let rows = CGFloat((cardViews.count + 1) / 2)
        scroll.contentSize = CGSize(width: view.bounds.width, height: rows * (height + 44) + gap)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let page = gesture.view?.tag else { return }
        onPick?(page)
        dismiss(animated: true)
    }

    @objc private func closed(_ sender: UIButton) {
        let page = sender.tag
        dismiss(animated: true) { [weak self] in self?.onClose?(page) }
    }
}
