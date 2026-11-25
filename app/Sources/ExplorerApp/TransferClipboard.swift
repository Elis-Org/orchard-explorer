import AppKit
import Combine
import ExplorerCore
import Foundation

/// In-process authority captured from an enumerated selection. Pasteboard bytes never
/// reconstruct this value; the shared application instance supplies it to its windows.
struct TransferClipboardPayload: Sendable {
    let id: UUID
    let entries: [TransferEntry]
    let kind: TransferKind
    let logicalEntries: [ItemOperationEntry]
    let leases: [any MaterializedContentLease]

    init(id: UUID, entries: [TransferEntry], kind: TransferKind,
         logicalEntries: [ItemOperationEntry]? = nil, leases: [any MaterializedContentLease] = []) {
        self.id = id; self.entries = entries; self.kind = kind
        self.logicalEntries = logicalEntries ?? entries.map(ItemOperationEntry.init)
        self.leases = leases
    }

    var items: [FileItem] { entries.map(\.item) }
    var hasArchiveOrigin: Bool { logicalEntries.contains { if case .archive = $0.context { return true }; return false } }
}

/// Public URL strings are candidates only; the background importer resolves file
/// references and samples filesystem identity. Constructing Swift URL can resolve a
/// reference, so snapshots retain the exact public spelling until background work.
struct ExternalClipboardSnapshot: Sendable {
    let id: UUID
    let changeCount: Int
    let urlStrings: [String]
}

enum ExternalClipboardError: LocalizedError, Equatable {
    case unsupported(String)
    case changed
    case moveAlreadyClaimed

    var errorDescription: String? {
        switch self {
        case .unsupported(let reason): return reason
        case .changed: return "The clipboard changed. Copy the files again and retry."
        case .moveAlreadyClaimed:
            return "Move Here has already used this clipboard selection. Copy the files again to move them."
        }
    }
}

/// Refusal reasons only. Pasteboard markers never grant transfer authority.
enum ArchivePasteRefusal: Equatable {
    case archiveOrigin
    case unverifiedPrivateToken
    case managedExport

    var message: String {
        switch self {
        case .archiveOrigin:
            return "Direct ZIP-to-ZIP transfers aren't available. Copy the contents to an ordinary folder first."
        case .unverifiedPrivateToken:
            return "Copy the files again before adding them to a ZIP. Maxplorer can’t verify this clipboard selection."
        case .managedExport:
            return "Direct ZIP-to-ZIP transfers aren't available, including exported ZIP clipboard files."
        }
    }
}

/// Native policy supporting FR-FILE-003/004, EV-0252/0255, AT-FILE-003/004,
/// and NATIVE-P12. All checks here inspect pasteboard bytes, never the filesystem.
@MainActor
final class TransferClipboard: ObservableObject {
    @Published private(set) var version = 0

    private struct Captured {
        let payload: TransferClipboardPayload
        let token: String
        let changeCount: Int
    }
    private static let tokenType = NSPasteboard.PasteboardType("com.native-explorer.internal-transfer-token")
    private static let archiveOriginType = NSPasteboard.PasteboardType("com.native-explorer.archive-export-origin")
    private static let promiseTypes = Set(NSFilePromiseReceiver.readableDraggedTypes.map {
        NSPasteboard.PasteboardType($0)
    })
    private static let maximumItems = 1_024
    private static let maximumURLBytes = 1_048_576
    let pasteboard: NSPasteboard
    private var captured: Captured?
    private var cachedCandidate: (changeCount: Int, value: Bool)?
    // Candidate queries may run during rendering; only explicit refresh/mutations
    // publish. Keep this independent so a query cannot swallow an activation update.
    private var lastAnnouncedChangeCount: Int
    // One shared clipboard serves all app windows. A failed/cancelled preparation does
    // not release this generation; only a clipboard replacement permits another move.
    private var claimedMove: ExternalClipboardSnapshot?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        lastAnnouncedChangeCount = pasteboard.changeCount
    }

    var payload: TransferClipboardPayload? {
        guard let captured, stillOwns(captured) else { return nil }
        return captured.payload
    }

    /// Eligibility and action-time checks use the same precedence. The prepared
    /// payload supplements current markers after import; it never replaces them.
    /// Managed-path inspection is caller supplied and performs no filesystem I/O.
    func archivePasteRefusal(for prepared: TransferClipboardPayload? = nil,
                             isManagedURL: (URL) -> Bool) -> ArchivePasteRefusal? {
        let owned = payload
        let effective = prepared ?? owned
        let types = pasteboard.pasteboardItems?.flatMap(\.types) ?? []
        if types.contains(Self.archiveOriginType) || effective?.hasArchiveOrigin == true { return .archiveOrigin }
        if types.contains(Self.tokenType), owned == nil { return .unverifiedPrivateToken }
        if effective?.entries.contains(where: { isManagedURL($0.item.url) }) == true { return .managedExport }
        return nil
    }

    private func retireCapture() {
        let leases = captured?.payload.leases ?? []
        captured = nil
        if !leases.isEmpty { Task { for lease in leases { _ = await lease.release() } } }
    }

    /// Cache format inspection per generation; rendering reads no URL data and does
    /// not publish. Action-time payload/snapshot checks still verify current authority.
    /// Invalid file candidates stay enabled so the action can explain its refusal.
    var hasTransferCandidate: Bool {
        let count = pasteboard.changeCount
        if let cachedCandidate, cachedCandidate.changeCount == count { return cachedCandidate.value }
        let candidate = pasteboard.pasteboardItems?.contains { item in
            let types = item.types
            return types.contains(.fileURL) || !Self.promiseTypes.isDisjoint(with: types)
        } ?? false
        guard pasteboard.changeCount == count else { return false }
        cachedCandidate = (count, candidate)
        return candidate
    }

    func externalSnapshot() throws -> ExternalClipboardSnapshot {
        let count = pasteboard.changeCount
        let urlStrings = try externalURLStrings(expectedChangeCount: count)
        return ExternalClipboardSnapshot(id: UUID(), changeCount: count, urlStrings: urlStrings)
    }

    /// Compare content as well as generation: a provider may change data for an
    /// existing type without incrementing changeCount. Never accepts a filtered subset.
    func stillMatches(_ snapshot: ExternalClipboardSnapshot) -> Bool {
        guard let current = try? externalURLStrings(expectedChangeCount: snapshot.changeCount),
              current.count == snapshot.urlStrings.count else { return false }
        return zip(current, snapshot.urlStrings).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }

    /// Reserve synchronously before async filesystem preparation starts. Re-snapshotting
    /// the same generation cannot make a failed or cancelled Move Here reusable.
    func claimMove(_ snapshot: ExternalClipboardSnapshot) throws {
        guard stillMatches(snapshot) else { throw ExternalClipboardError.changed }
        guard claimedMove?.changeCount != snapshot.changeCount else {
            throw ExternalClipboardError.moveAlreadyClaimed
        }
        claimedMove = snapshot
        publishChange()
    }

    /// Completion from an older operation cannot clear newer clipboard contents.
    @discardableResult
    func consumeExternalMove(_ snapshot: ExternalClipboardSnapshot) -> Bool {
        guard claimedMove?.id == snapshot.id, stillMatches(snapshot) else { return false }
        retireCapture()
        pasteboard.clearContents()
        publishChange()
        return true
    }

    func capture(items: [FileItem], source: FileOperationContext, kind: TransferKind) {
        capture(entries: items.map { TransferEntry(source: source, item: $0) }, kind: kind)
    }

    /// NATIVE-P14 / MAC-065: search results may come from several parents. Each
    /// entry must be an exact child of its own sampled source context.
    func capture(entries: [TransferEntry], kind: TransferKind) {
        guard !entries.isEmpty, Set(entries.map(\.item.id)).count == entries.count,
              entries.allSatisfy({ entry in
                  let item = entry.item
                  return Self.isCanonicalLocalURLString(entry.source.directoryURL.absoluteString, allowRoot: true)
                      && item.identity != nil && Self.isCanonicalLocalURLString(item.url.absoluteString)
                      && item.url.deletingLastPathComponent().standardizedFileURL.path.utf8
                          .elementsEqual(entry.source.directoryURL.path.utf8)
                      // Foundation can normalize URL spelling; preserve the sampled name
                      // and accept canonical Unicode equivalence, as the rename service does.
                      && item.name == item.url.lastPathComponent
                      && !item.name.isEmpty && item.name != "." && item.name != ".."
                      && !item.name.contains("/") && !item.name.contains("\0")
              }) else { return }

        let items = entries.map(\.item)
        let payload = TransferClipboardPayload(id: UUID(), entries: entries, kind: kind)
        let token = UUID().uuidString
        retireCapture()
        pasteboard.clearContents()
        if pasteboard.writeObjects(items.map { $0.url as NSURL }) {
            // The legacy type APIs add data to the first URL item, not another file entry.
            pasteboard.addTypes([Self.tokenType], owner: nil)
            if pasteboard.setString(token, forType: Self.tokenType) {
                let candidate = Captured(payload: payload, token: token, changeCount: pasteboard.changeCount)
                if stillOwns(candidate) { captured = candidate }
            }
        }
        publishChange()
    }

    /// Complete all materialization before this synchronous publication. The
    /// caller owns leases on refusal; successful capture transfers ownership.
    @discardableResult
    func captureArchive(entries: [ItemOperationEntry], leases: [any MaterializedContentLease],
                        kind: TransferKind, expectedChangeCount: Int) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount, !entries.isEmpty,
              entries.count <= Self.maximumItems, entries.count == leases.count,
              Set(entries.map(\.item.id)).count == entries.count,
              entries.allSatisfy({ $0.archiveTarget != nil }),
              zip(entries, leases).allSatisfy({ entry, lease in
                  entry.acceptsContent(lease, for: .clipboardExport)
                      && entry.item.url.absoluteString == lease.sourceURL.absoluteString
                      && entry.item.archiveRevision == lease.archiveRevision
                      && lease.physicalEntry.item.url == lease.fileURL
                      && Self.isCanonicalLocalURLString(lease.fileURL.absoluteString)
                      && lease.physicalEntry.item.identity != nil
              }) else { return false }
        let payload = TransferClipboardPayload(id: UUID(), entries: leases.map(\.physicalEntry), kind: kind,
            logicalEntries: entries, leases: leases)
        let token = UUID().uuidString
        retireCapture()
        pasteboard.clearContents()
        guard pasteboard.writeObjects(leases.map { $0.fileURL as NSURL }) else { publishChange(); return false }
        pasteboard.addTypes([Self.tokenType, Self.archiveOriginType], owner: nil)
        guard pasteboard.setString(token, forType: Self.tokenType),
              pasteboard.setString("archive-export", forType: Self.archiveOriginType) else { publishChange(); return false }
        let candidate = Captured(payload: payload, token: token, changeCount: pasteboard.changeCount)
        guard stillOwns(candidate) else { publishChange(); return false }
        captured = candidate
        publishChange()
        return true
    }

    /// The store consumes a move intent before starting its batch; copy intents remain
    /// reusable until replaced. A late completion cannot consume a newer capture.
    func consume(_ id: UUID) {
        guard let captured, captured.payload.id == id else { return }
        guard stillOwns(captured) else { refresh(); return }
        retireCapture()
        pasteboard.clearContents()
        publishChange()
    }

    /// Called on application activation/menu validation, never polls or persists content.
    func refresh() {
        let lostCapture = captured.map { !stillOwns($0) } ?? false
        if lostCapture { retireCapture() }
        guard lostCapture || pasteboard.changeCount != lastAnnouncedChangeCount else { return }
        publishChange()
    }

    func retireOwnedExports() { retireCapture() }

    private func publishChange() {
        lastAnnouncedChangeCount = pasteboard.changeCount
        version &+= 1
    }

    private func stillOwns(_ captured: Captured) -> Bool {
        pasteboard.changeCount == captured.changeCount
            && pasteboard.string(forType: Self.tokenType) == captured.token
            && pasteboard.changeCount == captured.changeCount
    }

    private func externalURLStrings(expectedChangeCount: Int) throws -> [String] {
        guard pasteboard.changeCount == expectedChangeCount else { throw ExternalClipboardError.changed }
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            throw ExternalClipboardError.unsupported("The clipboard contains no local files.")
        }
        guard items.count <= Self.maximumItems else {
            throw ExternalClipboardError.unsupported("Paste supports at most 1,024 files at a time.")
        }
        var urlStrings: [String] = []
        var byteCount = 0
        for item in items {
            // Read every item explicitly: readObjects(fileURLsOnly:) could silently drop
            // unsupported companions, turning a mixed selection into a partial transfer.
            guard item.types.contains(.fileURL), let data = item.data(forType: .fileURL),
                  data.count <= Self.maximumURLBytes - byteCount,
                  let spelling = String(data: data, encoding: .utf8),
                  Self.isCanonicalLocalURLString(spelling) else {
                throw ExternalClipboardError.unsupported(
                    "Paste requires only local file URLs, within 1 MiB of URL data. Remote files, file promises and mixed clipboard selections are unsupported.")
            }
            byteCount += data.count
            urlStrings.append(spelling)
        }
        guard pasteboard.changeCount == expectedChangeCount else { throw ExternalClipboardError.changed }
        return urlStrings
    }

    private static func isCanonicalLocalURLString(_ spelling: String, allowRoot: Bool = false) -> Bool {
        // URL.path can resolve file-reference URLs, while its legacy spelling can
        // truncate NUL. Decode components from the string without consulting disk.
        guard let components = URLComponents(string: spelling, encodingInvalidCharacters: false),
              let path = components.percentEncodedPath.removingPercentEncoding,
              components.scheme?.lowercased() == "file",
              components.host == nil || components.host == "" || components.host == "localhost",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil, !path.contains("\0"),
              components.percentEncodedPath.range(of: "%2f", options: .caseInsensitive) == nil,
              path.hasPrefix("/"), allowRoot || path != "/" else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        for (index, part) in parts.enumerated() where index > 0 {
            guard part != ".", part != "..",
                  !part.isEmpty || index == parts.count - 1 else { return false }
        }
        return true
    }
}
