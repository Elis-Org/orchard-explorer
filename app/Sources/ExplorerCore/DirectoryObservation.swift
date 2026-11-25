import CoreServices
import Darwin
import Foundation

/// Advisory refresh hints, never a replacement for an authoritative directory read.
public enum DirectoryChange: Equatable, Sendable {
    /// Direct child names observed in the native stream. They prioritize metadata reads only.
    case children(Set<String>)
    case changed
    /// Re-resolve/rebind the location before reading: its route changed or events were coalesced/lost.
    case rootChanged

    /// Preserve rebinds, and fall back to the authoritative listing when detail grows too large.
    func merging(_ other: Self) -> Self {
        switch (self, other) {
        case (.rootChanged, _), (_, .rootChanged): return .rootChanged
        case (.changed, _), (_, .changed): return .changed
        case let (.children(first), .children(second)):
            let names = first.union(second)
            return names.count <= 64 ? .children(names) : .changed
        }
    }
}

public protocol DirectoryObserving: Sendable {
    /// The native watcher is running when this function returns, before the first snapshot starts.
    func events(for url: URL) throws -> AsyncThrowingStream<DirectoryChange, Error>
}

/// Native local-directory observation. Uses FileEvents, UseCFTypes and WatchRoot;
/// no contents are read and no recursive filesystem scan or polling timer is created.
public struct LocalDirectoryObserver: DirectoryObserving {
    private let onStop: (@Sendable () -> Void)?
    public init() { onStop = nil }

    // Tests can verify actual native lifetime termination without exposing native handles.
    init(onStop: @escaping @Sendable () -> Void) { self.onStop = onStop }

    public func events(for url: URL) throws -> AsyncThrowingStream<DirectoryChange, Error> {
        let scope = try DirectoryWatchScope(url: url)
        let (source, continuation) = AsyncThrowingStream<DirectoryChange, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let native = try NativeDirectoryStream(scope: scope, continuation: continuation, onStop: onStop)
        let iterator = DirectoryEventIterator(source)
        // The returned sequence owns the native lifetime, but the native callback only
        // owns the inner continuation. There is no continuation -> owner -> continuation
        // retain cycle; dropping an unconsumed sequence also releases the native stream.
        return AsyncThrowingStream(unfolding: {
            try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                return try await iterator.next()
            }, onCancel: { native.stop() })
        })
    }
}

private actor DirectoryEventIterator {
    private var iterator: AsyncThrowingStream<DirectoryChange, Error>.Iterator
    init(_ stream: AsyncThrowingStream<DirectoryChange, Error>) { iterator = stream.makeAsyncIterator() }
    func next() async throws -> DirectoryChange? {
        var current = iterator
        let result = try await current.next()
        iterator = current
        return result
    }
}

/// Scope matching is separate from native ownership so path filtering can be tested
/// without inventing timing or provider guarantees. Paths remain lexical presentation paths.
struct DirectoryWatchScope: Sendable {
    let logicalURL: URL
    let roots: Set<String>
    let routeLinks: Set<String>
    let watchedPaths: [String]

    init(url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              !url.path.contains("\0") else { throw CocoaError(.fileReadUnsupportedScheme) }
        logicalURL = URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
        let resolved: URL
        do { resolved = try FileSystemPath.resolvingExisting(logicalURL) }
        catch {
            guard Self.isMissing(error) else { throw error }
            resolved = logicalURL
        }
        // Foundation may collapse /private/var to /var only while an entry
        // exists. Capture its physical spelling now, including missing suffixes,
        // so callbacks remain comparable after any watched ancestry disappears.
        roots = Set([logicalURL.path, logicalURL.resolvingSymlinksInPath().path,
                     resolved.path, Self.physicalPath(logicalURL)])
        // A preexisting regular file is never a directory-observation destination.
        do {
            let values = try resolved.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: logicalURL.path,
                    NSLocalizedDescriptionKey: "This location is not a folder."])
            }
        } catch {
            guard Self.isMissing(error) else { throw error }
            // A missing leaf can recover through its nearest existing parent. This
            // does not claim that enumeration of the requested location succeeded.
        }

        var candidates = [logicalURL, resolved, logicalURL.deletingLastPathComponent(), resolved.deletingLastPathComponent()]
        // The generic parent-recovery candidates above must obey the same bounded
        // root-link policy as the ancestor-link candidates below. Ordinary folders
        // and browsing / itself retain their existing parent recovery behavior.
        if logicalURL.deletingLastPathComponent().path == "/",
           (try? logicalURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            candidates.removeAll { $0.path == "/" }
        }
        var links: Set<String> = []
        var componentURL = URL(fileURLWithPath: "/", isDirectory: true)
        for component in logicalURL.pathComponents.dropFirst() {
            componentURL.appendPathComponent(component)
            if (try? componentURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                // Resolve the parent, not the final link: replacing an ancestor link
                // must trigger rebinding even while its former target still exists.
                let parent = componentURL.deletingLastPathComponent().resolvingSymlinksInPath()
                links.insert(parent.appendingPathComponent(componentURL.lastPathComponent).path)
                // Preserve the link entry itself; only its parent is resolved.
                links.insert(URL(fileURLWithPath: Self.physicalPath(parent), isDirectory: true)
                    .appendingPathComponent(componentURL.lastPathComponent).path)
                // FSEvents WatchRoot follows the old target and does not reliably
                // report an ancestor-link replacement. Watch that link's parent too.
                // Do not turn root-level system aliases (/var, /tmp) into a broad
                // whole-volume FSEvents subscription. Privileged retargeting of
                // those root-level aliases requires an explicit user refresh.
                if parent.path != "/" { candidates.append(parent) }
            }
        }
        routeLinks = links
        var nativePaths: Set<String> = []
        for candidate in candidates {
            nativePaths.insert(try Self.nearestExistingDirectory(candidate).path)
        }
        watchedPaths = nativePaths.sorted()
    }

    func change(for path: String, flags: FSEventStreamEventFlags) -> DirectoryChange? {
        let unconditional = UInt32(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagUnmount)
        if flags & unconditional != 0 { return .rootChanged }
        if flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { return nil }
        // Native paths are compared with captured spellings, without consulting
        // the event entry or its parents after deletion or link replacement.
        let normalized = URL(fileURLWithPath: path, isDirectory: false).path
        let structural = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
            | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagMount)
        if routeLinks.contains(normalized) { return .rootChanged }
        if roots.contains(normalized) { return flags & structural == 0 ? .changed : .rootChanged }
        let child = URL(fileURLWithPath: normalized, isDirectory: false)
        if roots.contains(child.deletingLastPathComponent().path) {
            // FSEvents need not deliver both names of a rename in one batch.
            if flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 { return .changed }
            return .children([child.lastPathComponent])
        }
        if flags & structural != 0, roots.contains(where: { Self.isAncestor(normalized, of: $0) }) { return .rootChanged }
        // Ignore unrelated siblings and deeper descendants. A direct child-directory
        // metadata event remains relevant because its displayed modification time changed.
        return nil
    }

    private static func isAncestor(_ path: String, of descendant: String) -> Bool {
        path == "/" ? descendant != "/" : descendant.hasPrefix(path + "/")
    }
    private static func physicalPath(_ url: URL) -> String {
        var candidate = url
        var missingComponents: [String] = []
        while true {
            if let physical = candidate.withUnsafeFileSystemRepresentation({ Darwin.realpath($0!, nil) }) {
                defer { Darwin.free(physical) }
                return missingComponents.reversed().reduce(String(cString: physical)) {
                    $0 == "/" ? $0 + $1 : $0 + "/" + $1
                }
            }
            guard candidate.path != "/" else { return url.path }
            missingComponents.append(candidate.lastPathComponent)
            candidate.deleteLastPathComponent()
        }
    }
    private static func nearestExistingDirectory(_ url: URL) throws -> URL {
        var candidate = url.standardizedFileURL
        while true {
            do {
                let values = try FileSystemPath.resolvingExisting(candidate)
                    .resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey])
                if values.isDirectory == true {
                    guard values.volumeIsLocal == true else {
                        throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSFilePathErrorKey: candidate.path,
                            NSLocalizedDescriptionKey: "Filesystem observation requires a local volume."])
                    }
                    return candidate
                }
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: candidate.path])
            } catch {
                guard isMissing(error), candidate.path != "/" else { throw error }
                candidate.deleteLastPathComponent()
            }
        }
    }
    private static func isMissing(_ error: Error) -> Bool {
        FileAccessFailure.isMissingLocation(error)
    }
}

private final class DirectoryEventSink: @unchecked Sendable {
    let scope: DirectoryWatchScope
    let continuation: AsyncThrowingStream<DirectoryChange, Error>.Continuation
    init(scope: DirectoryWatchScope, continuation: AsyncThrowingStream<DirectoryChange, Error>.Continuation) {
        self.scope = scope
        self.continuation = continuation
    }
    func receive(paths: [String], flags: UnsafePointer<FSEventStreamEventFlags>, count: Int) {
        var hint: DirectoryChange? = count == paths.count ? nil : .changed
        for index in 0..<min(count, paths.count) {
            guard let change = scope.change(for: paths[index], flags: flags[index]) else { continue }
            hint = hint?.merging(change) ?? change
            if hint == .rootChanged { break }
        }
        guard let hint else { return }
        // This stream has one serialized producer. If a pending hint was displaced,
        // queue the union. A consumer racing this second yield may see an extra hint.
        if case let .dropped(previous) = continuation.yield(hint) {
            let combined = previous.merging(hint)
            if combined != hint { continuation.yield(combined) }
        }
    }
}

/// All native stream access is serialized; stop detaches the handle once under a lock.
/// The FSEvents context retains only DirectoryEventSink, which has no owner back-reference.
private final class NativeDirectoryStream: @unchecked Sendable {
    private let queue = DispatchQueue(label: "nativeExplorer.directory-events", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let lock = NSLock()
    private let sink: DirectoryEventSink
    private let onStop: (@Sendable () -> Void)?
    private var stream: FSEventStreamRef?

    init(scope: DirectoryWatchScope, continuation: AsyncThrowingStream<DirectoryChange, Error>.Continuation,
         onStop: (@Sendable () -> Void)?) throws {
        sink = DirectoryEventSink(scope: scope, continuation: continuation)
        self.onStop = onStop
        queue.setSpecific(key: queueKey, value: 1)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<DirectoryEventSink>.fromOpaque(pointer).retain()
                return pointer
            }, release: { pointer in
                if let pointer { Unmanaged<DirectoryEventSink>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let sink = Unmanaged<DirectoryEventSink>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            sink.receive(paths: paths, flags: flags, count: count)
        }, &context, scope.watchedPaths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15, flags) else {
            continuation.finish()
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Couldn’t create filesystem observation."])
        }
        let started = queue.sync {
            FSEventStreamSetDispatchQueue(created, queue)
            return FSEventStreamStart(created)
        }
        guard started else {
            queue.sync { FSEventStreamInvalidate(created); FSEventStreamRelease(created) }
            continuation.finish()
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Couldn’t start filesystem observation."])
        }
        stream = created
    }

    func stop() {
        lock.lock()
        let stopping = stream
        stream = nil
        lock.unlock()
        guard let stopping else { return }
        sink.continuation.finish()
        let cleanup = {
            FSEventStreamStop(stopping)
            FSEventStreamInvalidate(stopping)
            FSEventStreamRelease(stopping)
            self.onStop?()
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil { cleanup() }
        else { queue.sync(execute: cleanup) }
    }
    deinit { stop() }
}
