import SwiftUI
import ExplorerCore

/// Native presentation for UI-FILE-004, FR-FILE-012/020 / EV-0409–0417 /
/// AT-UIFILE-004, AT-FILE-012/020. Measured bytes and selected-item counts are
/// shown separately; the captured Windows percentage/ETA are not inferred.
struct TransferProgressView: View {
    @ObservedObject var store: ExplorerStore

    var body: some View {
        Group {
            if let transfer = store.transfer {
                VStack(alignment: .leading, spacing: 16.pt) {
                    HStack(alignment: .top, spacing: 12.pt) {
                        Image(systemName: transferSymbol(transfer))
                            .font(.system(size: 27.pt))
                            .foregroundStyle(transfer.isPaused ? .orange : .blue)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5.pt) {
                            Text(title(transfer)).font(.system(size: 13.pt, weight: .bold))
                            Text("\(transfer.completedItems) of \(transfer.totalItems) selected items completed")
                                .font(.system(size: 11.pt)).foregroundStyle(.secondary)
                                .accessibilityIdentifier("transfer-item-count")
                            if transfer.skippedItems > 0 {
                                Text("\(transfer.skippedItems) skipped").font(.system(size: 11.pt)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 7.pt) {
                        if transfer.isPreparing && transfer.sourceURLs.isEmpty {
                            Text("Reading source locations…").font(.system(size: 11.pt))
                                .foregroundStyle(.secondary).accessibilityIdentifier("transfer-source")
                        } else if let source = transfer.sourceURLs.first, transfer.sourceURLs.count == 1 {
                            location("From", url: source, identifier: "transfer-source")
                        } else {
                            Text("From \(transfer.sourceURLs.count) locations")
                                .font(.system(size: 11.pt)).accessibilityIdentifier("transfer-source")
                                .help(transfer.sourceURLs.map(\.path).joined(separator: "\n"))
                        }
                        location("To", url: transfer.destinationURL, identifier: "transfer-destination")
                    }

                    if let name = transfer.conflictName {
                        conflict(name: name, transfer: transfer)
                    } else {
                        progress(transfer)
                        Divider()
                        details(transfer)
                        HStack {
                            if transfer.isCancelling {
                                Text("Stopping at a safe point…").font(.system(size: 11.pt)).foregroundStyle(.secondary)
                            } else if transfer.isFinishingItem {
                                Text(transfer.phase == .removingOriginals
                                     ? "The copy is complete; removing originals can’t be paused or cancelled."
                                     : "This item is committed; finishing it can’t be paused or cancelled.")
                                    .font(.system(size: 11.pt)).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("transfer-removal-note")
                            }
                            Spacer(minLength: 0)
                            Button(scaled: transfer.isPaused ? "Resume" : "Pause") {
                                if transfer.isPaused { store.resumeTransfer() } else { store.pauseTransfer() }
                            }
                            .disabled(!transfer.isPaused && !transfer.canPause)
                            .accessibilityIdentifier("transfer-pause-resume")
                            Button(scaled: transfer.isCancelling ? "Cancelling…" : "Cancel", action: store.cancelTransfer)
                                .disabled(!(transfer.canCancel || transfer.isPreparing || transfer.isCounting))
                                .keyboardShortcut(.cancelAction)
                                .accessibilityIdentifier("transfer-cancel")
                        }
                    }
                }
                .padding(24.pt)
                .frame(width: transfer.conflictName == nil ? 460.pt : 560.pt)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("File transfer")
                .accessibilityIdentifier("transfer-progress")
            }
        }
    }

    private func location(_ label: String, url: URL, identifier: String) -> some View {
        HStack(alignment: .top, spacing: 10.pt) {
            Text(label).foregroundStyle(.secondary).frame(width: 34.pt, alignment: .leading)
            Text(url.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(url.path)
                .accessibilityIdentifier(identifier)
        }
        .font(.system(size: 11.pt))
    }

    private func progress(_ transfer: TransferSession) -> some View {
        VStack(alignment: .leading, spacing: 9.pt) {
            if transfer.isPaused && !transfer.isCancelling {
                Label(transfer.isFinishingItem ? "Pausing after the current item" : "Paused", systemImage: "pause.circle")
                    .font(.system(size: 11.pt)).foregroundStyle(.orange)
            }
            if let fraction = transfer.fraction, !transfer.isCounting {
                // MAC-069: shown only with completed counts.
                ProgressView(value: fraction).progressViewStyle(.linear)
                    .accessibilityLabel("Transfer progress")
                    .accessibilityValue("\(Int((fraction * 100).rounded(.down))) percent")
                    .accessibilityIdentifier("transfer-progress-bar")
                Text("\(Int((fraction * 100).rounded(.down)))% complete")
                    .font(.system(size: 11.pt)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("transfer-percent")
            } else if !transfer.isPaused {
                ProgressView().progressViewStyle(.linear)
                    .accessibilityLabel(transfer.isCounting ? "Counting items" : "Current item progress")
                    .accessibilityIdentifier("transfer-indeterminate-progress")
            }
            if !transfer.currentName.isEmpty {
                Text(transfer.currentName).lineLimit(2).truncationMode(.middle)
                    .accessibilityIdentifier("transfer-current-name")
            }
            if transfer.kind == .copy {
                Text("\(transfer.bytesCopied.formatted()) bytes copied for the current item")
                    .font(.system(size: 11.pt)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("transfer-current-bytes")
            }
        }
    }

    /// FR-FILE-020 / EV-0413 native subset: measured counts and estimates only
    /// (MAC-069); no graph, and unknown values are labelled as unknown.
    private func details(_ transfer: TransferSession) -> some View {
        DisclosureGroup("More details") {
            // Re-evaluated every second so a stalled transfer stops showing old estimates.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let now = ProcessInfo.processInfo.systemUptime
                Grid(alignment: .leading, horizontalSpacing: 12.pt, verticalSpacing: 5.pt) {
                    detailRow("Status", phaseText(transfer), identifier: "transfer-detail-phase")
                    detailRow("Items", itemsText(transfer), identifier: "transfer-detail-items")
                    detailRow("Data", bytesText(transfer), identifier: "transfer-detail-bytes")
                    detailRow("Speed", speedText(transfer, now: now), identifier: "transfer-detail-speed")
                    detailRow("Time remaining", timeText(transfer, now: now), identifier: "transfer-detail-time")
                }
                .font(.system(size: 11.pt))
                .padding(.top, 6.pt)
            }
        }
        .font(.system(size: 11.pt))
        .accessibilityIdentifier("transfer-details")
    }

    private func detailRow(_ label: String, _ value: String, identifier: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).accessibilityIdentifier(identifier)
        }
    }

    private func phaseText(_ transfer: TransferSession) -> String {
        if transfer.isCounting { return "Counting items…" }
        if transfer.isPaused && transfer.isFinishingItem { return "Finishing the current item; will pause before the next" }
        if transfer.isPaused { return "Paused" }
        if transfer.phase == .removingOriginals { return "Removing originals after a verified copy" }
        if transfer.phase == .finalizing { return "Finishing the current item" }
        return transfer.kind == .copy ? "Copying" : "Moving"
    }

    private func itemsText(_ transfer: TransferSession) -> String {
        guard let totals = transfer.totals else {
            return "\(transfer.doneEntries.formatted()) processed (total \(transfer.totalsChanged ? "changed while copying" : "not yet known"))"
        }
        let done = min(transfer.doneEntries, totals.items)
        return "\(done.formatted()) of \(totals.items.formatted()) (\((transfer.remainingEntries ?? 0).formatted()) remaining)"
    }

    private func bytesText(_ transfer: TransferSession) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        guard let totals = transfer.totals else {
            return "\(formatter.string(fromByteCount: transfer.doneBytes)) (total \(transfer.totalsChanged ? "changed while copying" : "not yet known"))"
        }
        return "\(formatter.string(fromByteCount: min(transfer.doneBytes, totals.bytes))) of \(formatter.string(fromByteCount: totals.bytes)) (\(formatter.string(fromByteCount: transfer.remainingBytes ?? 0)) remaining)"
    }

    private func speedText(_ transfer: TransferSession, now: TimeInterval) -> String {
        if transfer.isPaused { return "Paused" }
        guard let speed = transfer.rate.bytesPerSecond(at: now) else { return "Measuring…" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(speed)))/s"
    }

    private func timeText(_ transfer: TransferSession, now: TimeInterval) -> String {
        if transfer.totals == nil { return "Unknown" }
        guard let seconds = transfer.secondsRemaining(at: now) else {
            return transfer.isPaused ? "Paused" : "Calculating…"
        }
        return Self.remaining(seconds)
    }

    static func remaining(_ seconds: Double) -> String {
        if seconds < 60 { return "About \(max(1, Int(seconds.rounded()))) seconds" }
        if seconds < 3_600 {
            let minutes = Int((seconds / 60).rounded())
            return minutes == 1 ? "About 1 minute" : "About \(minutes) minutes"
        }
        let hours = Int((seconds / 3_600).rounded())
        return hours == 1 ? "About 1 hour" : "About \(hours) hours"
    }

    /// FR-FILE-009/017, UI-FILE-002/003 / EV-0256–0259 / AT-FILE-009,
    /// AT-UIFILE-002/003 native subset (MAC-070/071): both versions compared by
    /// metadata only; Replace, Skip, Keep Both and Cancel with no default button.
    private func conflict(name: String, transfer: TransferSession) -> some View {
        let info = transfer.conflict
        return VStack(alignment: .leading, spacing: 12.pt) {
            Divider()
            Label("An item with this name already exists", systemImage: "exclamationmark.triangle")
                .font(.system(size: 13.pt, weight: .bold))
            Text(name).font(.system(size: 13.pt)).lineLimit(3).textSelection(.enabled)
                .accessibilityIdentifier("transfer-conflict-name")
            if info?.changedSinceCompared == true {
                Label("The existing item changed after it was compared. Nothing was replaced; review the current details.",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11.pt)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("transfer-conflict-changed")
            }
            if let info {
                comparison(info)
            }
            Text("Matching size and date don’t prove the contents are identical. Keep Both adds the incoming item with a different name.")
                .font(.system(size: 11.pt)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = info?.replaceUnavailableReason {
                Text("Replace is unavailable: \(reason)")
                    .font(.system(size: 11.pt)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("transfer-conflict-replace-reason")
            }
            HStack {
                if transfer.isCancelling {
                    Text("Cancelling…").font(.system(size: 11.pt)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                // Replace is never the default button: Return does nothing (MAC-070).
                Button(scaled: "Replace") { store.resolveTransferConflict(.replace) }
                    .disabled(info?.canReplace != true)
                    .help(info?.replaceUnavailableReason ?? (info?.archiveTarget == nil
                        ? "Move the existing item to the Trash and put the incoming item in its place."
                        : "Replace the existing ZIP member permanently after verification."))
                    .accessibilityIdentifier("transfer-conflict-replace")
                Button(scaled: "Skip") { store.resolveTransferConflict(.skip) }
                    .accessibilityIdentifier("transfer-conflict-skip")
                Button(scaled: "Keep Both") { store.resolveTransferConflict(.keepBoth) }
                    .accessibilityIdentifier("transfer-conflict-keep-both")
                Button(scaled: "Cancel") { store.resolveTransferConflict(.cancel) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("transfer-conflict-cancel")
            }
            .disabled(transfer.isCancelling)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transfer-conflict")
    }

    private func comparison(_ info: TransferConflictInfo) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12.pt, verticalSpacing: 5.pt) {
            GridRow {
                Text("")
                Text("Item being transferred").font(.system(size: 11.pt, weight: .semibold))
                Text("Existing item").font(.system(size: 11.pt, weight: .semibold))
            }
            GridRow {
                Text("Location").foregroundStyle(.secondary)
                Text(info.incomingLocation.path).lineLimit(2).truncationMode(.middle)
                    .help(info.incomingLocation.path)
                    .accessibilityIdentifier("transfer-conflict-incoming-location")
                Text(info.destinationLocation.path).lineLimit(2).truncationMode(.middle)
                    .help(info.destinationLocation.path)
                    .accessibilityIdentifier("transfer-conflict-existing-location")
            }
            GridRow {
                Text("Kind").foregroundStyle(.secondary)
                Text(incomingKind(info.incoming)).accessibilityIdentifier("transfer-conflict-incoming-kind")
                Text(info.existingKind ?? "Unavailable").accessibilityIdentifier("transfer-conflict-existing-kind")
            }
            GridRow {
                Text("Size").foregroundStyle(.secondary)
                Text(sizeText(info.incoming.isDirectory && !info.incoming.isSymbolicLink ? nil : info.incoming.size))
                    .accessibilityIdentifier("transfer-conflict-incoming-size")
                Text(info.hasComparedEntry ? sizeText(info.existingSize) : "Unavailable").accessibilityIdentifier("transfer-conflict-existing-size")
            }
            GridRow {
                Text("Modified").foregroundStyle(.secondary)
                Text(dateText(info.incoming.modifiedAt)).accessibilityIdentifier("transfer-conflict-incoming-modified")
                Text(info.hasComparedEntry ? dateText(info.existingModified) : "Unavailable").accessibilityIdentifier("transfer-conflict-existing-modified")
            }
        }
        .font(.system(size: 11.pt))
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transfer-conflict-comparison")
    }

    private func existingValue(_ info: TransferConflictInfo, _ value: (ConflictEntry) -> String) -> String {
        guard let existing = info.existing else { return info.inspectionError == nil ? "Unavailable" : "Couldn’t be read" }
        return value(existing)
    }

    private func incomingKind(_ item: FileItem) -> String {
        if item.isSymbolicLink { return "Symbolic link" }
        return item.isDirectory ? "Folder" : (item.kind.isEmpty ? "File" : item.kind)
    }

    private func sizeText(_ size: Int64?) -> String {
        guard let size else { return "—" }
        return size == 1 ? "1 byte" : "\(size.formatted()) bytes"
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    private func title(_ transfer: TransferSession) -> String {
        if transfer.isCancelling { return "Cancelling transfer…" }
        if transfer.isPreparing { return "Preparing transfer…" }
        if transfer.isCounting { return "Counting items…" }
        if transfer.conflictName != nil { return "Choose how to continue" }
        if transfer.isPaused && transfer.isFinishingItem { return "Finishing current item…" }
        if transfer.isPaused { return "Transfer paused" }
        if let label = transfer.operationLabel { return label }
        switch transfer.kind {
        case .copy: return "Copying items"
        case .move: return "Moving items"
        }
    }

    private func transferSymbol(_ transfer: TransferSession) -> String {
        if transfer.conflictName != nil { return "doc.on.doc" }
        switch transfer.kind {
        case .copy: return "doc.on.doc"
        case .move: return "folder.badge.arrow.forward"
        }
    }
}
