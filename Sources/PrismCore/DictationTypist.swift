import Foundation

/// What is heard, typed out rather than put down at once: each word comes
/// in a few letters at a time, quickly, so the eye can follow where the
/// words are going. Heard again differently, the letters no longer heard
/// go at once, and the rest is typed from there.
@MainActor
public final class DictationTypist {
    /// What is written so far.
    public private(set) var shown = ""
    private var target = ""
    private var timer: Timer?
    private let write: (String) -> Void

    /// `write`: what is to stand written now — called as each few letters come.
    public init(write: @escaping (String) -> Void) {
        self.write = write
    }

    /// What has been heard so far, to type out.
    public func type(_ text: String) {
        target = text
        guard timer == nil, shown != target else { return }
        let timer = Timer(timeInterval: 1.0 / 45, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        step()
    }

    /// The rest written at once: when listening stops.
    public func flush(_ text: String? = nil) {
        if let text { target = text }
        stop()
        guard shown != target else { return }
        shown = target
        write(shown)
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func step() {
        let same = zip(shown, target).prefix { $0 == $1 }.count
        let left = target.count - same
        guard left > 0 || shown.count != same else { return stop() }
        // A fifth of what is left each time, so a long phrase catches up.
        shown = String(target.prefix(same + max(1, left / 5)))
        write(shown)
        if shown == target { stop() }
    }
}
