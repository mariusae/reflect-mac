import CoreServices
import Foundation

/// Tells of the notes that change in a graph — written here, by another
/// app, by a sync — by their graph-relative paths, a moment after they do:
/// every Markdown file under the graph's folder, at any depth, whether
/// saved in place or by replacing it. The repository's own files are left
/// out.
package final class GraphWatcher {
    private var stream: FSEventStreamRef?
    private let root: String
    private let onChange: @MainActor (Set<String>) -> Void

    package init?(root: URL, onChange: @escaping @MainActor (Set<String>) -> Void) {
        // FSEvents reports real paths — /private/tmp, not /tmp — as
        // realpath(3) gives them; Foundation's resolving drops /private.
        self.root = realpath(root.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? root.path
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<GraphWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.changed(list.prefix(count))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [self.root] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags) else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private var pending: Set<String> = []
    private var scheduled = false

    /// Gathers what changed, and tells of it once things have been quiet a
    /// moment — a sync touches many files at once.
    private func changed(_ paths: ArraySlice<String>) {
        let prefix = root + "/"
        for path in paths where path.hasPrefix(prefix) && path.hasSuffix(".md") {
            let relative = String(path.dropFirst(prefix.count))
            guard !relative.hasPrefix(".git/") else { continue }
            pending.insert(relative)
        }
        guard !pending.isEmpty, !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            scheduled = false
            let paths = pending
            pending = []
            MainActor.assumeIsolated { self.onChange(paths) }
        }
    }
}
