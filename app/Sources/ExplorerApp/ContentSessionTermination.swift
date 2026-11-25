import Combine
import ExplorerCore

/// Async termination policy is separate from NSApplication's reply API so a
/// failed durable receipt cannot be mistaken for successful shutdown.
@MainActor
final class ContentSessionTermination {
    enum State { case idle, finishing, finished }
    private(set) var state: State = .idle
    var onFailure: ((String) -> Void)?
    private let shutdown: @Sendable () async throws -> Void
    private var task: Task<Bool, Never>?
    init(shutdown: @escaping @Sendable () async throws -> Void = {
        _ = try await ContentLeaseRegistry.shared.shutdown()
    }) { self.shutdown = shutdown }

    func finish() async -> Bool {
        if state == .finished { return true }
        if let task { return await task.value }
        state = .finishing
        let shutdown = self.shutdown
        let pending = Task { [weak self] in
            do {
                try await shutdown()
                self?.state = .finished; self?.task = nil
                return true
            } catch {
                self?.state = .idle; self?.task = nil
                self?.onFailure?(error.localizedDescription)
                return false
            }
        }
        task = pending
        return await pending.value
    }
}
