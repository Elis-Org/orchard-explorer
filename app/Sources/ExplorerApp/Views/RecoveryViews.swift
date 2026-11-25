import Combine
import SwiftUI
import ExplorerCore

/// FR-FILE-005 / EV-0444–0448 / AT-FILE-005. Batch progress and cancellation
/// between native Trash calls are macOS choices beyond the one-file reference.
struct TrashProgressView: View {
    @ObservedObject var store: ExplorerStore

    var body: some View {
        if let progress = store.trashProgress {
            VStack(alignment: .leading, spacing: 16.pt) {
                Label(progress.isCancelling ? "Stopping…" : "Moving items to Trash", systemImage: "trash")
                    .font(.system(size: 13.pt, weight: .bold))
                Text("\(progress.completedItems) of \(progress.totalItems) selected items moved to Trash")
                    .font(.system(size: 11.pt)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("trash-item-count")
                ProgressView().progressViewStyle(.linear)
                    .accessibilityLabel("Current item progress")
                if !progress.currentName.isEmpty {
                    Text(progress.currentName).lineLimit(2).truncationMode(.middle)
                        .accessibilityIdentifier("trash-current-name")
                }
                Divider()
                HStack {
                    if progress.isCancelling {
                        Text("Stopping after the current item…")
                            .font(.system(size: 11.pt)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button(scaled: progress.isCancelling ? "Stopping…" : "Cancel", action: store.cancelTrash)
                        .disabled(progress.isCancelling)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("trash-cancel")
                }
            }
            .padding(24.pt)
            .frame(width: 460.pt)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("trash-progress")
        }
    }
}

/// NATIVE-P18A / MAC-078: Compress to ▸ progress. The archive is built in staging
/// and published only on success; Cancel stops the tool and publishes nothing.
struct ArchiveProgressView: View {
    @ObservedObject var store: ExplorerStore

    var body: some View {
        if let progress = store.archiveProgress {
            VStack(alignment: .leading, spacing: 16.pt) {
                Label(progress.isCancelling ? "Stopping…" : "Compressing to \(progress.format.title)",
                      systemImage: "archivebox")
                    .font(.system(size: 13.pt, weight: .bold))
                Text(progress.itemCount == 1 ? "“\(progress.firstName)”" : "\(progress.itemCount) items")
                    .font(.system(size: 11.pt)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    .accessibilityIdentifier("archive-items")
                ProgressView().progressViewStyle(.linear).accessibilityLabel("Compression progress")
                Divider()
                HStack {
                    Spacer(minLength: 0)
                    Button(scaled: progress.isCancelling ? "Stopping…" : "Cancel", action: store.cancelArchive)
                        .disabled(progress.isCancelling)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("archive-cancel")
                }
            }
            .padding(24.pt)
            .frame(width: 460.pt)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("archive-progress")
        }
    }
}

/// FR-FILE-007 / EV-0449 screenshot + EV-0450 UIA, EV-0453 / AT-FILE-007.
/// This session receipt list is an explicit macOS adaptation. The reference
/// establishes Restore without a collision; editable Restore as is native policy.
struct RecentlyTrashedView: View {
    @ObservedObject var store: ExplorerStore
    @ObservedObject private var history: RecoveryHistory
    @StateObject private var draft = RecoveryDraft()
    @FocusState private var nameIsFocused: Bool

    init(store: ExplorerStore) {
        self.store = store
        _history = ObservedObject(wrappedValue: store.recoveryHistory)
    }

    private var selectedReceipt: TrashReceipt? {
        history.entries.first { $0.id == draft.selectedID }
    }

    private var canRestore: Bool {
        guard let selectedID = draft.selectedID, !draft.proposedName.isEmpty else { return false }
        return !store.isPerformingOperation && store.canRestore(selectedID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16.pt) {
            Label("Recently Trashed", systemImage: "trash").font(.system(size: 13.pt, weight: .bold))
            Text("Items moved to Trash by \(AppIdentity.name) during this app session.")
                .font(.system(size: 11.pt)).foregroundStyle(.secondary)
            if history.entries.isEmpty {
                Text("No items are available to restore from this app session.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160.pt)
                    .accessibilityIdentifier("recovery-empty")
            } else {
                List(selection: $draft.selectedID) {
                    ForEach(history.entries) { receipt in
                        VStack(alignment: .leading, spacing: 3.pt) {
                            HStack {
                                Label(receipt.original.name,
                                      systemImage: receipt.original.isDirectory ? "folder" : "doc")
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                if history.claimedIDs.contains(receipt.id) {
                                    Text("Restoring…").font(.system(size: 10.pt)).foregroundStyle(.secondary)
                                }
                            }
                            Text(receipt.originalContext.directoryURL.path)
                                .font(.system(size: 10.pt)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .help(receipt.originalContext.directoryURL.path)
                            Text(receipt.trashedAt, format: .dateTime.year().month().day().hour().minute())
                                .font(.system(size: 10.pt)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3.pt)
                        .tag(receipt.id)
                    }
                }
                .frame(height: 210.pt)
                .disabled(store.isPerformingOperation)
                .accessibilityLabel("Items trashed during this app session")
                .accessibilityIdentifier("recovery-list")
            }

            if let receipt = selectedReceipt {
                VStack(alignment: .leading, spacing: 8.pt) {
                    HStack(spacing: 10.pt) {
                        Text("Restore as")
                        TextField("Name", text: $draft.proposedName)
                            .textFieldStyle(.roundedBorder)
                            .focused($nameIsFocused)
                            .disabled(store.isPerformingOperation)
                            .onSubmit(restoreSelected)
                            .accessibilityLabel("Restore as")
                            .accessibilityIdentifier("recovery-name")
                    }
                    Text("To: \(receipt.originalContext.directoryURL.path)")
                        .font(.system(size: 11.pt)).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        .accessibilityIdentifier("recovery-destination")
                    Text("Trash location: \(receipt.trashed.url.path)")
                        .font(.system(size: 10.pt)).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        .help(receipt.trashed.url.path)
                        .accessibilityIdentifier("recovery-trash-location")
                }
            }
            if let error = store.recoveryError {
                Label {
                    Text(error).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.system(size: 11.pt)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("recovery-error")
            }
            if let issue = store.recoveryAccessIssue {
                Button(scaled: "Access Help…") { store.showAccessHelp(issue) }
                    .disabled(store.isPerformingOperation)
            }
            Divider()
            HStack {
                if store.isPerformingOperation {
                    ProgressView().controlSize(.small)
                    Text("Restoring…").font(.system(size: 11.pt)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(scaled: "Done", action: store.dismissRecovery)
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.isPerformingOperation)
                    .accessibilityIdentifier("recovery-done")
                Button(scaled: "Restore", action: restoreSelected)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRestore)
                    .accessibilityIdentifier("recovery-restore")
            }
        }
        .padding(24.pt)
        .frame(width: 540.pt)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recently-trashed")
        .onAppear { selectAvailableReceipt() }
        .onChange(of: draft.selectedID) { _, _ in
            draft.proposedName = selectedReceipt?.original.name ?? ""
        }
        .onChange(of: history.entries.map(\.id)) { _, _ in selectAvailableReceipt() }
        .onChange(of: store.recoveryError) { _, error in
            if error != nil && !store.isPerformingOperation { nameIsFocused = true }
        }
    }

    private func selectAvailableReceipt() {
        guard selectedReceipt == nil else { return }
        draft.selectedID = history.entries.first?.id
        draft.proposedName = selectedReceipt?.original.name ?? ""
    }

    private func restoreSelected() {
        guard let selectedID = draft.selectedID, canRestore else { return }
        store.restore(selectedID, as: draft.proposedName)
    }
}

@MainActor
private final class RecoveryDraft: ObservableObject {
    @Published var selectedID: UUID?
    @Published var proposedName = ""
}
