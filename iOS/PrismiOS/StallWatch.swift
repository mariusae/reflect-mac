import Foundation
import QuartzCore

/// `-PrismStalls YES`: the main thread watched from another — every time it
/// stays busy past a frame or three, how long, printed — and marks at the
/// phases of starting, from launch. For finding where the app stutters.
enum StallWatch {
    static let enabled = UserDefaults.standard.bool(forKey: "PrismStalls")
    /// The shortest stall told, in seconds: `-PrismStallMs 17` for a frame.
    static let threshold = UserDefaults.standard.object(forKey: "PrismStallMs").map { ($0 as? Double ?? Double("\($0)") ?? 50) / 1000 } ?? 0.05
    private static let start = CACurrentMediaTime()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastBeat = CACurrentMediaTime()
    nonisolated(unsafe) private static var phase = "launch"

    /// A phase begun, its time from launch printed.
    static func mark(_ name: String) {
        guard enabled else { return }
        lock.lock(); phase = name; lock.unlock()
        print(String(format: "PHASE %7.1f ms  %@", (CACurrentMediaTime() - start) * 1000, name))
    }

    static func begin() {
        guard enabled else { return }
        mark("watch")
        // The main thread beats; the watcher reports the gaps.
        Timer.scheduledTimer(withTimeInterval: 0.008, repeats: true) { _ in
            lock.lock(); lastBeat = CACurrentMediaTime(); lock.unlock()
        }
        Thread.detachNewThread {
            var reported = 0.0
            while true {
                usleep(5_000)
                lock.lock()
                let gap = CACurrentMediaTime() - lastBeat
                let current = phase
                let beat = lastBeat
                lock.unlock()
                if gap > threshold, beat != reported {
                    // Report each stall once, when it ends or grows past a second.
                    var end = gap
                    while true {
                        usleep(5_000)
                        lock.lock(); let now = lastBeat; lock.unlock()
                        if now != beat { break }
                        end = CACurrentMediaTime() - beat
                        if end > 5 { break }
                    }
                    reported = beat
                    print(String(format: "STALL %7.1f ms at %7.1f ms (during %@)", end * 1000, (beat - start) * 1000, current))
                }
            }
        }
    }
}
