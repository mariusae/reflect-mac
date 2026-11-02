import PhoneUI
import ReflectCore
import UIKit

/// Under a note, on the phone: the notes related to it without a link in
/// its text — its frontmatter `related:`, and the notes naming it in theirs —
/// a pill each, opened with a tap, unrelated from the menu a long press
/// shows; + relates another, chosen as Go to chooses.
final class RelatedSheetBlock: UIView, SheetBlock {
    var onHeightChange: (() -> Void)?
    var onCaretMove: (() -> Void)?
    var editors: [OutlineEditor] { [] }
    var isLive: Bool { true }
    func goLive() {}
    func save() {}
    func notesChanged(_ paths: Set<String>) {}

    let related: [RelatedNote]
    var onOpen: ((RelatedNote) -> Void)?
    var onUnrelate: ((RelatedNote) -> Void)?
    var onAdd: (() -> Void)?

    private let label = UILabel()
    private var pills: [UIButton] = []
    private let add: UIButton
    private let metrics: PhoneMetrics
    private let gap: CGFloat = 8

    init(_ related: [RelatedNote], metrics: PhoneMetrics) {
        self.related = related
        self.metrics = metrics
        var plus = UIButton.Configuration.plain()
        plus.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: round(metrics.size * 0.8), weight: .semibold))
        plus.baseForegroundColor = Ink.secondary
        add = UIButton(configuration: plus)
        super.init(frame: .zero)
        label.text = (related.isEmpty ? "Related" : "Related · \(related.count)").uppercased()
        label.textColor = Ink.secondary
        label.font = metrics.face.heading(round(metrics.size * 0.68), weight: .semibold)
        addSubview(label)
        for note in related {
            var look = UIButton.Configuration.filled()
            look.cornerStyle = .capsule
            look.baseBackgroundColor = Ink.codeBack
            look.baseForegroundColor = note.path == nil ? Ink.secondary : Ink.text
            look.image = UIImage(systemName: note.isOwn ? "link" : "arrow.turn.down.left",
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: round(metrics.size * 0.62), weight: .semibold))
            look.imagePadding = 5
            look.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            look.attributedTitle = AttributedString(note.name, attributes: AttributeContainer([
                .font: metrics.face.body(round(metrics.size * 0.88), italic: note.path == nil),
            ]))
            look.titleLineBreakMode = .byTruncatingTail
            let pill = UIButton(configuration: look, primaryAction: UIAction { [weak self] _ in self?.onOpen?(note) })
            pill.menu = UIMenu(children: [UIAction(title: "Unrelate", image: UIImage(systemName: "minus.circle"), attributes: .destructive) { [weak self] _ in
                self?.onUnrelate?(note)
            }])
            pill.accessibilityHint = note.isOwn ? "Related here" : "\(note.name) relates itself to this note"
            addSubview(pill)
            pills.append(pill)
        }
        add.addAction(UIAction { [weak self] _ in self?.onAdd?() }, for: .primaryActionTriggered)
        add.accessibilityLabel = "Relate to Another Note"
        addSubview(add)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var labelHeight: CGFloat { ceil(label.font.lineHeight) }

    /// Each pill's frame, and + last, wrapping as words do.
    private func frames(width: CGFloat) -> [CGRect] {
        let left = NoteBlock.side
        let room = max(60, width - 2 * left)
        var x = left
        var y: CGFloat = 22 + labelHeight + 8
        var frames: [CGRect] = []
        for button in pills + [add] {
            var size = button.sizeThatFits(CGSize(width: room, height: .greatestFiniteMagnitude))
            size.width = min(size.width, room)
            if x > left, x + size.width > left + room {
                x = left
                y += size.height + gap
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + gap
        }
        return frames
    }

    func height(width: CGFloat) -> CGFloat { (frames(width: width).last?.maxY ?? 22) + 4 }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = CGRect(x: NoteBlock.side, y: 22, width: bounds.width - 2 * NoteBlock.side, height: labelHeight)
        for (button, frame) in zip(pills + [add], frames(width: bounds.width)) { button.frame = frame }
    }
}

extension PrismStore {
    /// The name a relation writes for a note: its title, a day's date.
    private func relationName(_ path: String) -> String {
        index?.entry(path)?.title ?? GraphPaths.day(fromDailyPath: path)?.description
            ?? (path as NSString).deletingPathExtension.components(separatedBy: "/").last ?? path
    }

    /// Every name a note answers to: for unrelating it, however it was named.
    private func names(_ path: String) -> [String] {
        guard let entry = index?.entry(path) else { return [relationName(path)] }
        return [entry.title] + entry.aliases + (entry.day.map { [$0.description] } ?? [])
    }

    /// Two notes related, written in the first's frontmatter `related:`.
    func relate(_ path: String, to other: String) {
        guard other != path, index?.related(to: path).contains(where: { $0.path == other }) != true else { return }
        change(path, undoName: "Relate") { Related.adding(relationName(other), to: $0) }
    }

    /// Two notes related no longer: taken out of whichever's frontmatter names the other.
    func unrelate(_ path: String, from other: RelatedNote) {
        if other.isOwn {
            change(path, undoName: "Unrelate") { Related.removing([other.name] + (other.path.map(names) ?? []), from: $0) }
        } else if let otherPath = other.path {
            change(otherPath, undoName: "Unrelate") { Related.removing(names(path), from: $0) }
        }
    }
}
