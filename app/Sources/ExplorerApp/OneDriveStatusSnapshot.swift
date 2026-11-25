import ExplorerCore
import Foundation

/// Display identity only. Residency and ctime may change without changing policy.
/// Never use this cache key, or a cached policy, to authorize a command.
struct OneDriveStatusKey: Hashable, Sendable {
    let account: String
    let file: String
    let identity: LocalFileIdentity
    let parent: String
    let parentIdentity: LocalFileIdentity
    let version: LocalFileStatusVersion

    init?(_ entry: TransferEntry) {
        guard let identity = entry.item.identity, let version = entry.item.statusVersion else { return nil }
        account = (OneDriveRetentionService.accountRoot(in: entry.source.directoryURL)
            ?? entry.source.directoryURL).absoluteString
        file = entry.item.id
        self.identity = identity
        parent = entry.source.directoryURL.absoluteString
        parentIdentity = entry.source.directoryIdentity
        self.version = version
    }
}

enum OneDriveStatusFreshness: Equatable { case unknown, fresh, stale, unavailable }
enum OneDriveStatusSource: Equatable { case listing, diskHistory, query, operation }

struct OneDriveStatusSnapshot: Equatable {
    var availability: FileAvailability
    var policy: OneDriveRetentionPolicy?
    var freshness: OneDriveStatusFreshness = .unknown
    var failureReason: OneDriveBadgeReadError?
    var repeatedTargetRefusal = false
    var confirmedAt: Date?
    var confirmationElapsed: TimeInterval?
    var staleAfter: TimeInterval?
    var source: OneDriveStatusSource = .listing
    var generation: UInt64

    var observation: OneDriveBadgeObservation? {
        guard let policy, availability != .unknown else { return nil }
        return .init(policy: policy, isDataless: availability == .onlineOnly)
    }

    /// Eligibility to check again is independent of presentation age. Demand may
    /// extend a fresh confirmation's deadline, but can never revive a stale one.
    mutating func reconsiderAge(at time: TimeInterval, visibleCount: Int) {
        guard freshness == .fresh, let confirmed = confirmationElapsed, let deadline = staleAfter else { return }
        if time >= deadline { freshness = .stale; return }
        staleAfter = max(deadline, confirmed + Self.ageLimit(visibleCount: visibleCount))
    }
    static func ageLimit(visibleCount: Int) -> TimeInterval {
        max(1800, 60 * ceil(Double(visibleCount) / 8) + 300)
    }
}

struct OneDriveStatusRequestToken: Hashable {
    let key: OneDriveStatusKey
    let generation: UInt64
    let startSequence: UInt64
}

enum OneDriveStatusRefreshReason { case directory, activation, explicitRefresh }
