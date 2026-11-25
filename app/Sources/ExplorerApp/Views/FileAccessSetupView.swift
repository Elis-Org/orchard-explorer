import SwiftUI
import ExplorerCore

/// Native access setup, not a Windows permission-dialog reproduction. Reference:
/// macOS adaptations, permissions/sandbox/entitlements/bookmarks policy.
struct FileAccessSetupView: View {
    @ObservedObject var model: FileAccessSetupModel
    let chooseFolder: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16.pt) {
            Label("File Access", systemImage: "lock.shield").font(.system(size: 17.pt))
            ScrollView {
                VStack(alignment: .leading, spacing: 18.pt) {
                    Text("Ordinary browsing works without Full Disk Access. You can enable it for broader access to protected folders.")
                        .font(.system(size: 11.pt)).foregroundStyle(.secondary)
                    if let context = model.context { contextSection(context) }
                    appSection
                    settingsSection
                    Divider()
                    checksSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4.pt)
            }
            Divider()
            HStack {
                Spacer()
                Button(scaled: "Done", action: close)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("file-access-done")
            }
        }
        .padding(24.pt)
        // The controller sizes the panel (capped to the screen); content scrolls (review 8ab56c03 #7).
        .frame(minWidth: 0, idealWidth: 560.pt, maxWidth: .infinity, minHeight: 0, idealHeight: 640.pt, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("file-access-setup")
    }

    private func contextSection(_ context: FileAccessContext) -> some View {
        VStack(alignment: .leading, spacing: 6.pt) {
            Text(context.action).font(.system(size: 13.pt, weight: .bold))
            switch context.failure {
            case .permissionDenied:
                Text("macOS denied access for this action. Privacy settings or file permissions may be involved.")
                    .font(.system(size: 11.pt))
            case .readOnlyVolume:
                Text("The volume is read-only. Full Disk Access will not make it writable.")
                    .font(.system(size: 11.pt))
            case nil:
                Text("Use a folder check below to inspect read access for this location.")
                    .font(.system(size: 11.pt))
            }
        }
        .padding(12.pt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8.pt))
        .accessibilityIdentifier("file-access-context")
    }

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 8.pt) {
            Text("This app").font(.system(size: 13.pt, weight: .bold))
            Text(model.bundleURL.path)
                .font(.system(size: 11.pt)).textSelection(.enabled)
                .lineLimit(3).truncationMode(.middle).help(model.bundleURL.path)
                .accessibilityIdentifier("file-access-app-path")
            Button(scaled: "Reveal App", action: model.revealApp)
                .accessibilityIdentifier("file-access-reveal-app")
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10.pt) {
            Text("Optional protected-folder access").font(.system(size: 13.pt, weight: .bold))
            Text("In System Settings → Privacy & Security → Full Disk Access, add the app shown above and turn on its switch.")
                .font(.system(size: 11.pt)).textSelection(.enabled)
            Button(scaled: "Open Full Disk Access in Settings", action: model.openFullDiskAccessSettings)
                .accessibilityIdentifier("file-access-open-settings")
            if let message = model.settingsMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.pt)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("file-access-settings-error")
            }
            Text("Full Disk Access does not override file permissions or make read-only volumes writable.")
                .font(.system(size: 10.pt)).foregroundStyle(.secondary)
            Text("If macOS asks you to quit and reopen \(AppIdentity.name), finish ongoing operations first. Rebuilding or moving this development app may require adding it again.")
                .font(.system(size: 10.pt)).foregroundStyle(.secondary)
        }
    }

    private var checksSection: some View {
        VStack(alignment: .leading, spacing: 12.pt) {
            Text("Check a folder").font(.system(size: 13.pt, weight: .bold))
            Text("A check lists one folder at the recorded time. Access can change. Choosing a folder can itself affect access, so this result may differ from opening the same path directly. It does not test file contents, writing, or Full Disk Access for other locations.")
                .font(.system(size: 11.pt)).foregroundStyle(.secondary)
                .accessibilityIdentifier("file-access-check-scope")
            Button(scaled: "Choose Folder to Check…", action: chooseFolder)
                .disabled(model.checkingURL != nil)
                .accessibilityIdentifier("file-access-choose-folder")
            if let context = model.context {
                ForEach(Array(context.locations.enumerated()), id: \.offset) { index, location in
                    HStack(alignment: .top, spacing: 10.pt) {
                        path(location)
                        Spacer(minLength: 0)
                        Button(scaled: "Check") { model.checkFolder(location) }
                            .disabled(model.checkingURL != nil)
                            .accessibilityLabel("Check read access to \(location.path)")
                            .accessibilityIdentifier("file-access-check-location-\(index)")
                    }
                }
            }
            if let location = model.checkingURL {
                VStack(alignment: .leading, spacing: 8.pt) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Checking folder listing…").font(.system(size: 11.pt))
                        Spacer(minLength: 0)
                        Button(scaled: "Cancel Check", action: model.cancelChecks)
                            .accessibilityIdentifier("file-access-cancel-check")
                    }
                    path(location)
                }
                .accessibilityIdentifier("file-access-check-progress")
            }
            ForEach(model.results) { result in
                checkResult(result)
            }
        }
    }

    private func checkResult(_ result: FileAccessCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 6.pt) {
            path(result.location)
            HStack(spacing: 4.pt) {
                Text("Checked")
                Text(result.checkedAt, format: .dateTime.year().month().day().hour().minute().second())
            }
            .font(.system(size: 10.pt)).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("file-access-check-time")
            switch result.outcome {
            case .readable:
                Label(result.summary, systemImage: "checkmark.circle")
                    .font(.system(size: 11.pt)).foregroundStyle(.green)
            case .failed(_, let message):
                Label(result.summary, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.pt)).foregroundStyle(.orange)
                Text(message).font(.system(size: 10.pt)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(12.pt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8.pt))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("file-access-check-result")
    }

    private func path(_ url: URL) -> some View {
        Text(url.isFileURL ? url.path : url.absoluteString)
            .font(.system(size: 10.pt)).lineLimit(3).truncationMode(.middle)
            .textSelection(.enabled).help(url.isFileURL ? url.path : url.absoluteString)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
