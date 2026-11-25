import Foundation

enum SpotlightSnapshots {
    static func live<Value: Sendable>(name: String, configure: @escaping (NSMetadataQuery) -> Void,
                                      snapshot: @escaping (NSMetadataQuery, @escaping () -> Bool) -> Value) -> AsyncThrowingStream<Value, Error> {
        let session = SpotlightSession(name: name, configure: configure, snapshot: snapshot)
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { @Sendable _ in session.stop() }
            session.start(continuation)
        }
    }
}

private final class SpotlightSession<Value: Sendable>: @unchecked Sendable {
    private let name: String
    private let configure: (NSMetadataQuery) -> Void
    private let snapshot: (NSMetadataQuery, @escaping () -> Bool) -> Value
    private let queue = OperationQueue()
    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private let lock = NSLock()
    private var cancelled = false

    init(name: String, configure: @escaping (NSMetadataQuery) -> Void,
         snapshot: @escaping (NSMetadataQuery, @escaping () -> Bool) -> Value) {
        self.name = name
        self.configure = configure
        self.snapshot = snapshot
        queue.name = "Maxplorer \(name)"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    func start(_ continuation: AsyncThrowingStream<Value, Error>.Continuation) {
        queue.addOperation { [self] in
            guard !isCancelled else { return }
            query.operationQueue = queue
            configure(query)
            for notification in [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
                observers.append(NotificationCenter.default.addObserver(forName: notification, object: query, queue: nil) {
                    [weak self] _ in
                    guard let self else { return }
                    self.queue.addOperation { [self] in
                        guard !isCancelled, !query.isGathering else { return }
                        query.disableUpdates()
                        let value = snapshot(query, { self.isCancelled })
                        query.enableUpdates()
                        if !isCancelled { continuation.yield(value) }
                    }
                })
            }
            if !query.start() {
                continuation.finish(throwing: NSError(domain: "Maxplorer.Spotlight", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "\(name) is unavailable."]))
            }
        }
    }

    func stop() {
        lock.withLock { cancelled = true }
        queue.addOperation { [self] in
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            if query.isStarted { query.stop() }
        }
    }
}
