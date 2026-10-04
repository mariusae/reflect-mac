import UIKit
import ReflectCore

/// A note two devices wrote at once, shown in place of its editor: what
/// happened, each side of each conflict in its own shade — this device's
/// in the accent, the other's in grey — and buttons that keep one side of
/// every conflict, or both. The markers never reach the editor.
final class ConflictView: UIView {
    private let stack = UIStackView()
    private let resolve: (ConflictMarkers.Resolution) -> Void

    init(source: String, metrics: PhoneMetrics, resolve: @escaping (ConflictMarkers.Resolution) -> Void) {
        self.resolve = resolve
        super.init(frame: .zero)
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let labels = ConflictMarkers.labels(source)
        let manySided = ConflictMarkers.blockCount(source) > 1
        // Git's own labels read best as they are; a device's name says which it keeps.
        let named = labels.map { $0.ours != ConflictMarkers.ourLabel } ?? false
        stack.addArrangedSubview(notice(metrics: metrics, buttons: [
            (named ? "Keep “\(labels!.ours)”" : "Keep This Device’s", Self.ours, .ours),
            (manySided ? "Keep the Other Versions" : named ? "Keep “\(labels!.theirs)”" : "Keep the Other Device’s", Self.theirs, .theirs),
            (manySided ? "Keep All" : "Keep Both", Ink.text, .both),
        ]))
        for (i, segment) in ConflictMarkers.segments(source).enumerated() {
            switch segment {
            case .text(let text):
                let trimmed = (i == 0 ? Self.droppingFrontmatter(text) : text).trimmingCharacters(in: .newlines)
                guard !trimmed.isEmpty else { continue }
                stack.addArrangedSubview(Self.text(trimmed, metrics: metrics, color: Ink.text))
            case .conflict(let ours, let theirs):
                stack.addArrangedSubview(side(ours, title: named ? ours.label : "This device", tint: Self.ours, metrics: metrics))
                stack.addArrangedSubview(side(theirs, title: named ? theirs.label : "Other device", tint: Self.theirs, metrics: metrics))
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The note's text without the frontmatter it opens with: the note's
    /// settings, not what was written.
    private static func droppingFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex)
        else { return text }
        return String(text[end.upperBound...])
    }

    private static let ours = Ink.accent
    private static let theirs = UIColor.systemGray

    func height(width: CGFloat) -> CGFloat {
        ceil(systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                     withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height)
    }

    // MARK: Parts

    private static func text(_ text: String, metrics: PhoneMetrics, color: UIColor, size: CGFloat? = nil, weight: UIFont.Weight = .regular) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.text = text
        label.textColor = color
        label.font = metrics.face.body(size ?? metrics.size, weight: weight)
        return label
    }

    private func notice(metrics: PhoneMetrics, buttons: [(String, UIColor, ConflictMarkers.Resolution)]) -> UIView {
        let card = UIView()
        card.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.1)
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        let inner = UIStackView()
        inner.axis = .vertical
        inner.spacing = 8
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])
        let small = round(metrics.size * 0.87)
        let title = Self.text("This note was edited on two devices at once.", metrics: metrics, color: Ink.text, size: small, weight: .semibold)
        inner.addArrangedSubview(title)
        inner.addArrangedSubview(Self.text("Both versions are below. Choose what to keep — every version stays in the history.",
                                           metrics: metrics, color: Ink.secondary, size: small))
        inner.setCustomSpacing(12, after: inner.arrangedSubviews.last!)
        for (title, tint, keep) in buttons {
            var configuration = UIButton.Configuration.filled()
            configuration.title = title
            configuration.baseBackgroundColor = tint.withAlphaComponent(0.14)
            configuration.baseForegroundColor = tint == Ink.text ? Ink.text : tint
            configuration.cornerStyle = .medium
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
                return attributes
            }
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                self?.resolve(keep)
            })
            inner.addArrangedSubview(button)
        }
        return card
    }

    /// One side of a conflict: its name, and what it says, in its shade.
    private func side(_ side: ConflictMarkers.Side, title: String, tint: UIColor, metrics: PhoneMetrics) -> UIView {
        let box = UIView()
        box.backgroundColor = tint.withAlphaComponent(0.08)
        box.layer.cornerRadius = 10
        let bar = UIView()
        bar.backgroundColor = tint
        bar.layer.cornerRadius = 1.5
        bar.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(bar)
        let inner = UIStackView(arrangedSubviews: [
            Self.text(title.uppercased(), metrics: metrics, color: tint, size: round(metrics.size * 0.68), weight: .semibold),
            Self.text(side.text.isEmpty ? "(nothing)" : side.text, metrics: metrics, color: side.text.isEmpty ? Ink.faint : Ink.text),
        ])
        inner.axis = .vertical
        inner.spacing = 4
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            bar.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            bar.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
            bar.widthAnchor.constraint(equalToConstant: 3),
            inner.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 10),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            inner.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
        ])
        return box
    }
}
