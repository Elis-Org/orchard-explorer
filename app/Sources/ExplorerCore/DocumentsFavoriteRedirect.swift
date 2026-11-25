import Darwin
import Foundation

/// A verified directory-link route for the built-in Documents favorite only.
/// This proves directory identity/spelling, not provider ownership or command authority.
public struct DocumentsFavoriteRedirect: Sendable {
    public let destinationURL: URL
    public let directoryIdentity: LocalFileIdentity
    private let homeURL: URL
    private let physicalHome: URL
    private let cloudURL: URL
    private let accountURL: URL
    private let physicalTarget: URL
    private let homeIdentity: LocalFileIdentity
    private let cloudIdentity: LocalFileIdentity
    private let accountIdentity: LocalFileIdentity
    private let linkIdentity: LocalFileIdentity

    public static func resolve(homeURL: URL) async throws -> Self? {
        try await BlockingIO.run(on: .read) { cancellation in
            try cancellation.checkCancellation()
            let candidate: Self?
            do { candidate = try HydrationMaterializationPolicy().disabled { _ in
                let home = try FileSystemPath.resolvingExisting(homeURL)
                guard try home.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == true else { return nil }
                let source = homeURL.appendingPathComponent("Documents")
                guard let link = try identity(at: source, type: mode_t(S_IFLNK)) else { return nil }
                let target = try FileSystemPath.resolvingExisting(source)
                guard target.lastPathComponent == "Documents" else { return nil }
                let account = target.deletingLastPathComponent()
                let cloud = home.appendingPathComponent("Library/CloudStorage")
                guard account.deletingLastPathComponent().path.utf8.elementsEqual(cloud.path.utf8) else { return nil }
                let destination = homeURL.standardizedFileURL.appendingPathComponent("Library/CloudStorage")
                    .appendingPathComponent(account.lastPathComponent).appendingPathComponent("Documents", isDirectory: true)
                guard OneDriveRetentionService.isBadgeLocation(destination, homeURL: homeURL),
                      try FileSystemPath.packageStatus(at: target) == false,
                      try target.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == true,
                      let homeID = try identity(at: home, type: mode_t(S_IFDIR)),
                      let cloudID = try identity(at: cloud, type: mode_t(S_IFDIR)),
                      let accountID = try identity(at: account, type: mode_t(S_IFDIR)),
                      let targetID = try identity(at: target, type: mode_t(S_IFDIR)) else { return nil }
                return Self(destinationURL: destination, directoryIdentity: targetID, homeURL: homeURL,
                    physicalHome: home, cloudURL: cloud, accountURL: account, physicalTarget: target,
                    homeIdentity: homeID, cloudIdentity: cloudID, accountIdentity: accountID, linkIdentity: link)
            } } catch {
                // Optional classification must not prevent the ordinary loader
                // from handling unsupported metadata or an inaccessible path.
                try cancellation.checkCancellation()
                return nil
            }
            try cancellation.checkCancellation()
            guard let candidate else { return nil }
            return try HydrationMaterializationPolicy().disabled { _ in
                try candidate.validateRoute()
                try cancellation.checkCancellation()
                return candidate
            }
        }
    }

    /// The caller loads destinationURL with its ordinary DirectoryListing, then
    /// verifies both the original favorite route and that exact snapshot before commit.
    public func validate(_ snapshot: DirectorySnapshot) async throws {
        try await BlockingIO.run(on: .read) { cancellation in
            try cancellation.checkCancellation()
            try HydrationMaterializationPolicy().disabled { _ in
                guard snapshot.archiveRevision == nil, snapshot.directoryIdentity == directoryIdentity,
                      snapshot.items.allSatisfy({
                          $0.url.deletingLastPathComponent().standardizedFileURL.path.utf8
                              .elementsEqual(destinationURL.standardizedFileURL.path.utf8)
                      }) else { throw Self.changed }
                try validateRoute()
                try cancellation.checkCancellation()
            }
        }
    }

    private func validateRoute() throws {
        let source = homeURL.appendingPathComponent("Documents")
        guard OneDriveRetentionService.isBadgeLocation(destinationURL, homeURL: homeURL),
              try FileSystemPath.resolvingExisting(homeURL).path.utf8.elementsEqual(physicalHome.path.utf8),
              try Self.identity(at: physicalHome, type: mode_t(S_IFDIR)) == homeIdentity,
              try Self.identity(at: cloudURL, type: mode_t(S_IFDIR)) == cloudIdentity,
              try Self.identity(at: accountURL, type: mode_t(S_IFDIR)) == accountIdentity,
              try Self.identity(at: source, type: mode_t(S_IFLNK)) == linkIdentity,
              try FileSystemPath.resolvingExisting(source).path.utf8.elementsEqual(physicalTarget.path.utf8),
              try FileSystemPath.resolvingExisting(destinationURL).path.utf8.elementsEqual(physicalTarget.path.utf8),
              try Self.identity(at: physicalTarget, type: mode_t(S_IFDIR)) == directoryIdentity,
              try FileSystemPath.packageStatus(at: physicalTarget) == false,
              try Self.identity(at: source, type: mode_t(S_IFLNK)) == linkIdentity else { throw Self.changed }
    }

    private static func identity(at url: URL, type: mode_t) throws -> LocalFileIdentity? {
        var path = url.path
        while path.count > 1 && path.last == "/" { path.removeLast() }
        var value = stat()
        guard lstat(path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard value.st_mode & mode_t(S_IFMT) == type else { return nil }
        return LocalFileIdentity.fromStat(value)
    }

    private static var changed: CocoaError {
        CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Documents changed while it was being opened. Try again."])
    }
}
