import AppKit
import ExplorerCore
import Foundation

/// NATIVE-P13 / FR-DROP-001–004 / AT-DROP-001–004.
/// In-memory authority for one pointer drag; never uses the general clipboard.
@MainActor
final class FileDragSource: NSObject, NSDraggingSource {
    let token = UUID()
    let entries: [TransferEntry]
    fileprivate weak var owner: AnyObject?
    private var sessionOwner: AnyObject?
    private(set) var hasActiveSession = false
    private(set) var hasIssuedWriter = false
    private weak var coordinator: FileDragCoordinator?

    fileprivate init(entries: [TransferEntry], owner: AnyObject, coordinator: FileDragCoordinator) {
        self.entries = entries
        self.owner = owner
        self.coordinator = coordinator
    }

    var isValid: Bool { coordinator?.isLive(self) == true }

    func pasteboardWriter(itemID: String) -> NSPasteboardWriting? {
        guard coordinator?.isLive(self) == true,
              let entry = entries.first(where: { $0.item.id == itemID }) else { return nil }
        let item = NSPasteboardItem()
        guard item.setString(entry.item.url.absoluteString, forType: .fileURL),
              item.setString(token.uuidString, forType: FileDragCoordinator.tokenType) else { return nil }
        hasIssuedWriter = true
        return item
    }

    func finish() { coordinator?.finishSource(self) }

    /// Authority follows the physical AppKit session, including spring-loaded
    /// navigation that dismantles the source presentation.
    func startSession() {
        guard coordinator?.isLive(self) == true, let owner else { return }
        sessionOwner = owner
        hasActiveSession = true
    }

    func finishIfInactive() {
        if !hasActiveSession { finish() }
    }

    fileprivate func releaseSessionOwner() {
        hasActiveSession = false
        sessionOwner = nil
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        guard coordinator?.isLive(self) == true else { return [] }
        return context == .withinApplication ? [.copy, .move] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        // The receiving store owns all writes. Session completion only releases authority.
        finish()
    }
}

struct FileDropHover {
    // Only tabs spring-load. Folder destinations remain highlighted in place.
    let id: String
    let action: @MainActor () -> Void
}

@MainActor
final class FileDragCoordinator {
    static let shared = FileDragCoordinator()
    static let registeredTypes: [NSPasteboard.PasteboardType] = [.fileURL]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    fileprivate static let tokenType = NSPasteboard.PasteboardType("com.native-explorer.file-drag-token")

    fileprivate struct Sequence: Equatable {
        let number: Int
        let pasteboard: ObjectIdentifier
    }

    fileprivate let importer: any FileTransferImporting
    fileprivate let preparer: any FileDropPreparing
    fileprivate let tabHoverDelay: TimeInterval
    fileprivate let modifierFlags: @MainActor () -> NSEvent.ModifierFlags
    private var sources: [UUID: FileDragSource] = [:]
    // The desktop has one pointer-drag session. Retain its claim after view teardown.
    private var acceptedSequence: Sequence?

    init(importer: any FileTransferImporting = LocalFileTransferImporter(),
         preparer: any FileDropPreparing = LocalFileDropPreparer(),
         tabHoverDelay: TimeInterval = 0.7,
         modifierFlags: @escaping @MainActor () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }) {
        self.importer = importer
        self.preparer = preparer
        self.tabHoverDelay = tabHoverDelay
        self.modifierFlags = modifierFlags
    }

    func beginSource(entries: [TransferEntry], owner: AnyObject) -> FileDragSource? {
        guard !entries.isEmpty, entries.count <= 1_024,
              Set(entries.map { $0.item.id }).count == entries.count,
              entries.allSatisfy({ $0.item.identity != nil && $0.item.url.isFileURL }),
              entries.reduce(0, { $0 + $1.item.url.absoluteString.utf8.count }) <= 1_048_576 else { return nil }
        // A view cannot leave old source authority live when starting another gesture.
        let previous = sources.values.filter { $0.owner === owner }
        for source in previous { finishSource(source) }
        let source = FileDragSource(entries: entries, owner: owner, coordinator: self)
        sources[source.token] = source
        return source
    }

    func makeDestination(store: ExplorerStore) -> FileDragDestination {
        FileDragDestination(store: store, coordinator: self)
    }

    fileprivate func isLive(_ source: FileDragSource) -> Bool {
        source.owner != nil && sources[source.token] === source
    }

    fileprivate func finishSource(_ source: FileDragSource) {
        if sources[source.token] === source { sources.removeValue(forKey: source.token) }
        source.releaseSessionOwner()
    }

    fileprivate func source(token: UUID, actualSource: AnyObject?) -> FileDragSource? {
        guard let source = sources[token], isLive(source), let actualSource,
              actualSource === source || actualSource === source.owner else { return nil }
        return source
    }

    fileprivate func isClaimed(_ sequence: Sequence) -> Bool { acceptedSequence == sequence }

    fileprivate func claim(_ sequence: Sequence) -> Bool {
        guard !isClaimed(sequence) else { return false }
        acceptedSequence = sequence
        return true
    }
}

/// Each receiving view owns one controller. Late reads and timers can therefore
/// never replace another view's destination or submit a write after it has exited.
@MainActor
final class FileDragDestination {
    private struct Key: Equatable {
        let sequence: FileDragCoordinator.Sequence
        let changeCount: Int
        let urlBytes: [Data]
        let sourceToken: UUID?
        let target: FileDropTarget
        let allowedOperations: UInt
        let kind: TransferKind
        let modifiers: UInt
    }

    private struct Input {
        let parser: TransferClipboard
        let snapshot: ExternalClipboardSnapshot
        let source: FileDragSource?
    }

    private struct Attempt {
        let id: UUID
        let key: Key
        let input: Input
    }

    private weak var store: ExplorerStore?
    private let coordinator: FileDragCoordinator
    private var attempt: Attempt?
    private enum Ready {
        case folder(PreparedFileDrop)
        case choose([TransferEntry])
    }
    private var prepared: Ready?
    private var preparationTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var hover: FileDropHover?
    private(set) var refusalReason: String?
    private(set) var isPreparing = false
    var draggingSequenceNumber: Int? { attempt?.key.sequence.number }

    fileprivate init(store: ExplorerStore, coordinator: FileDragCoordinator) {
        self.store = store
        self.coordinator = coordinator
    }

    deinit {
        preparationTask?.cancel()
        hoverTask?.cancel()
    }

    func update(_ info: NSDraggingInfo, binding: FileDropBinding?,
                hover: FileDropHover? = nil) -> NSDragOperation {
        update(info, target: binding.map(FileDropTarget.folder), hover: hover)
    }

    func update(_ info: NSDraggingInfo, target: FileDropTarget?,
                hover: FileDropHover? = nil) -> NSDragOperation {
        do {
            let candidate = try capture(info, target: target)
            if attempt?.key != candidate.key {
                invalidate()
                attempt = candidate
                self.hover = hover
                beginPreparation(candidate)
            } else {
                updateHover(hover)
            }
            guard prepared != nil else {
                return []
            }
            armHover()
            return operation(for: candidate.key.kind)
        } catch {
            invalidate()
            refusalReason = error.localizedDescription
            return []
        }
    }

    func accept(_ info: NSDraggingInfo, binding: FileDropBinding?) -> Bool {
        accept(info, target: binding.map(FileDropTarget.folder))
    }

    func accept(_ info: NSDraggingInfo, target: FileDropTarget?) -> Bool {
        // Capture again without launching work. A release while preparation is pending
        // or after modifiers/target/pasteboard changed is a refused drop.
        guard let candidate = try? capture(info, target: target),
              let attempt, attempt.key == candidate.key, let prepared,
              isCurrent(attempt), coordinator.claim(attempt.key.sequence) else {
            invalidate()
            return false
        }
        let store = self.store
        let key = attempt.key
        invalidate()
        guard let store else { return false }
        let accepted: Bool
        switch (prepared, key.target) {
        case (.folder(let ready), .folder(let binding)):
            accepted = store.acceptPreparedFileDrop(ready, binding: binding)
        case (.choose(let entries), .choose(let origin)):
            // Source and native pasteboard are no longer needed once this sequence is claimed.
            let preparer = coordinator.preparer, kind = key.kind
            let mask = NSDragOperation(rawValue: key.allowedOperations)
            guard mask.contains(operation(for: kind)) else { return false }
            accepted = store.chooseHomeDestination(for: origin) { [weak store] context in
                guard let store, let context, store.isHomeOperationPageCurrent(origin) else { return }
                let binding = store.homeFileDropBinding(.chosen(origin), context: context)
                Task { @MainActor [weak store] in
                    do {
                        let ready = try await preparer.prepare(entries: entries, destinationURL: context.directoryURL,
                            expectedDestinationIdentity: context.directoryIdentity, expectedEntryIdentity: nil, kind: kind)
                        guard let store, store.isCurrentFileDropBinding(binding) else { return }
                        _ = store.acceptPreparedFileDrop(ready, binding: binding)
                    } catch {
                        store?.reportHomeDropError(error, origin: origin)
                    }
                }
            }
        default: return false
        }
        if accepted {
            // Acceptance happens after pointer release. The receiver now owns
            // the captured payload; an omitted native source-ended callback
            // must not retain its old presentation or authorize a later drag.
            candidate.input.source?.finish()
        }
        return accepted
    }

    func invalidate() {
        preparationTask?.cancel()
        hoverTask?.cancel()
        preparationTask = nil
        hoverTask = nil
        hover = nil
        prepared = nil
        attempt = nil
        isPreparing = false
        refusalReason = nil
    }

    private func capture(_ info: NSDraggingInfo, target: FileDropTarget?) throws -> Attempt {
        guard let target, store?.isCurrentFileDropTarget(target) == true else {
            throw FileOperationError.staleParent
        }
        let board = info.draggingPasteboard
        let sequence = FileDragCoordinator.Sequence(number: info.draggingSequenceNumber,
                                                     pasteboard: ObjectIdentifier(board))
        guard !coordinator.isClaimed(sequence) else {
            throw FileOperationError.unsupported("This drag has already been submitted.")
        }
        let pasteboardItems = board.pasteboardItems ?? []
        if case .choose = target {
            let promises = Set(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
            guard pasteboardItems.allSatisfy({ promises.isDisjoint(with: $0.types) }) else {
                throw FileOperationError.unsupported("Choose a destination for existing files. File promises are unsupported.")
            }
        }
        let parser = TransferClipboard(pasteboard: board)
        let snapshot = try parser.externalSnapshot()
        let tokens = pasteboardItems.compactMap { $0.string(forType: FileDragCoordinator.tokenType) }
        let source: FileDragSource?
        if pasteboardItems.contains(where: { $0.types.contains(FileDragCoordinator.tokenType) }) {
            guard tokens.count == pasteboardItems.count, Set(tokens).count == 1,
                  let spelling = tokens.first, let token = UUID(uuidString: spelling),
                  let live = coordinator.source(token: token, actualSource: info.draggingSource as AnyObject?),
                  live.entries.count == snapshot.urlStrings.count,
                  Set(live.entries.map { Data($0.item.url.absoluteString.utf8) })
                    == Set(snapshot.urlStrings.map { Data($0.utf8) }) else {
                throw FileOperationError.unsupported("The file drag source is no longer valid.")
            }
            source = live
        } else {
            source = nil
        }
        guard parser.stillMatches(snapshot) else { throw ExternalClipboardError.changed }
        let modifiers = coordinator.modifierFlags().intersection([.option, .command, .control, .shift])
        // MAC-068: Explorer drags move within a volume and copy to another volume
        // by default; Option forces Copy and Command forces Move. External drags copy.
        let kind: TransferKind
        if let source, !modifiers.contains(.option) {
            switch target {
            case .choose:
                // Until a folder is chosen only explicit Command offers a move.
                kind = modifiers.contains(.command) ? .move : .copy
            case .folder(let binding):
                guard let device = (binding.expectedEntryIdentity ?? binding.expectedDestinationIdentity
                    ?? binding.tabDirectoryIdentity)?.device else { throw FileOperationError.staleParent }
                let sameVolume = source.entries.allSatisfy {
                    $0.item.identity?.device == device && $0.source.directoryIdentity.device == device
                }
                kind = sameVolume || modifiers.contains(.command) ? .move : .copy
            }
        } else {
            kind = .copy
        }
        guard info.draggingSourceOperationMask.contains(operation(for: kind)) else {
            throw FileOperationError.unsupported("The source does not allow this file transfer operation.")
        }
        let key = Key(sequence: sequence, changeCount: snapshot.changeCount,
                      urlBytes: snapshot.urlStrings.map { Data($0.utf8) }, sourceToken: source?.token,
                      target: target, allowedOperations: info.draggingSourceOperationMask.rawValue, kind: kind, modifiers: modifiers.rawValue)
        return Attempt(id: UUID(), key: key, input: Input(parser: parser, snapshot: snapshot, source: source))
    }

    private func beginPreparation(_ attempt: Attempt) {
        isPreparing = true
        let importer = coordinator.importer
        let preparer = coordinator.preparer
        preparationTask = Task { [weak self] in
            do {
                let entries: [TransferEntry]
                if let source = attempt.input.source { entries = source.entries }
                else { entries = try await importer.capture(urlStrings: attempt.input.snapshot.urlStrings) }
                try Task.checkCancellation()
                if case .choose(let origin) = attempt.key.target {
                    if origin.selectedUniqueCount > 0 {
                        guard let store = self?.store else { return }
                        let selection = try await store.verifiedHomeDestinationEntries(for: origin)
                        guard ExplorerStore.homeDestination(for: selection) == .chooseFolder else {
                            throw FileOperationError.staleParent
                        }
                    }
                    try Task.checkCancellation()
                    guard let self, self.attempt?.id == attempt.id, self.isCurrent(attempt) else { return }
                    self.prepared = .choose(entries)
                    self.isPreparing = false
                    self.preparationTask = nil
                    return
                }
                guard case .folder(let binding) = attempt.key.target else { return }
                if let receiver = binding.homeReceiver {
                    guard let store = self?.store else { return }
                    let verified: FileOperationContext
                    switch receiver {
                    case .folder(let scope, let row, let membership):
                        verified = try await store.verifiedHomeFolder(for: row, in: scope, membership: membership)
                    case .selection(let origin):
                        let selection = try await store.verifiedHomeDestinationEntries(for: origin)
                        guard case .folder(let context) = ExplorerStore.homeDestination(for: selection) else {
                            throw FileOperationError.staleParent
                        }
                        verified = context
                    case .chosen: throw FileOperationError.staleParent
                    }
                    guard verified.directoryURL == binding.destinationURL,
                          verified.directoryIdentity == binding.expectedDestinationIdentity else {
                        throw FileOperationError.staleParent
                    }
                }
                let result = try await preparer.prepare(entries: entries,
                    destinationURL: binding.destinationURL,
                    expectedDestinationIdentity: binding.expectedDestinationIdentity,
                    expectedEntryIdentity: binding.expectedEntryIdentity,
                    kind: attempt.key.kind)
                try Task.checkCancellation()
                guard let self, self.attempt?.id == attempt.id else { return }
                guard self.isCurrent(attempt) else { self.invalidate(); return }
                // MAC-068: a default Move predicted from the target entry (e.g. a link
                // to a folder on another volume) must not become a cross-volume move.
                if result.kind == .move, attempt.key.modifiers & NSEvent.ModifierFlags.command.rawValue == 0,
                   result.entries.contains(where: { $0.item.identity?.device != result.destination.directoryIdentity.device }) {
                    self.preparationTask = nil
                    self.isPreparing = false
                    self.refusalReason = "This folder is on another volume. Hold Command to move or Option to copy."
                    return
                }
                self.preparationTask = nil
                self.isPreparing = false
                self.prepared = .folder(result)
                self.armHover()
            } catch {
                guard let self, self.attempt?.id == attempt.id else { return }
                self.preparationTask = nil
                self.isPreparing = false
                self.refusalReason = error.localizedDescription
            }
        }
    }

    private func isCurrent(_ attempt: Attempt) -> Bool {
        guard !coordinator.isClaimed(attempt.key.sequence),
              store?.isCurrentFileDropTarget(attempt.key.target) == true,
              attempt.input.parser.stillMatches(attempt.input.snapshot),
              coordinator.modifierFlags().intersection([.option, .command, .control, .shift]).rawValue
                == attempt.key.modifiers else { return false }
        return attempt.input.source.map { coordinator.isLive($0) } ?? true
    }

    private func updateHover(_ next: FileDropHover?) {
        if hover?.id != next?.id {
            hoverTask?.cancel()
            hoverTask = nil
        }
        hover = next
    }

    private func armHover() {
        guard hoverTask == nil, prepared != nil, let hover, let attempt else { return }
        let delay = coordinator.tabHoverDelay
        let duration = UInt64(max(0, min(delay, 60)) * 1_000_000_000)
        hoverTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: duration) }
            catch { return }
            guard let self, self.attempt?.id == attempt.id, self.prepared != nil,
                  self.hover?.id == hover.id,
                  self.isCurrent(attempt) else { return }
            let action = self.hover?.action
            // Tab activation invalidates the receiving location. It never accepts a drop.
            self.invalidate()
            action?()
        }
    }

    private func operation(for kind: TransferKind) -> NSDragOperation { kind == .copy ? .copy : .move }
}
