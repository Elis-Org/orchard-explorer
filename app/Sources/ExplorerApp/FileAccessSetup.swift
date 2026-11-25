import AppKit
import Combine
import ExplorerCore
import SwiftUI

/// Native access guidance context, independent of browser navigation and drafts.
/// Reference macOS adaptation: permissions, privacy, ACLs and read-only mounts
/// can independently deny an action; Full Disk Access is optional user setup.
struct FileAccessContext: Equatable {
    var failure: FileAccessFailure?
    var locations: [URL]
    var action: String

    init(failure: FileAccessFailure? = nil, locations: [URL], action: String) {
        self.failure = failure
        self.locations = locations
        self.action = action
    }
}

enum FileAccessCheckOutcome: Equatable {
    case readable(visibleItemCount: Int)
    case failed(failure: FileAccessFailure?, message: String)
}

struct FileAccessCheckResult: Identifiable, Equatable {
    let location: URL
    let outcome: FileAccessCheckOutcome
    let checkedAt: Date
    var id: String { location.absoluteString }

    init(location: URL, outcome: FileAccessCheckOutcome, checkedAt: Date = Date()) {
        self.location = location
        self.outcome = outcome
        self.checkedAt = checkedAt
    }

    var summary: String {
        switch outcome {
        case .readable(let count): return "Folder listing succeeded: \(count) visible entries."
        case .failed(let failure, _):
            switch failure {
            case .permissionDenied: return "Read check was denied for this folder."
            case .readOnlyVolume: return "This volume is read-only."
            case nil: return "The folder could not be read."
            }
        }
    }
}

/// Explicit folder listing checks only. No startup, activation, protected-path,
/// write-access, or global Full Disk Access probe is performed by this model.
@MainActor
final class FileAccessSetupModel: ObservableObject {
    @Published private(set) var context: FileAccessContext?
    @Published private(set) var checkingURL: URL?
    @Published private(set) var results: [FileAccessCheckResult] = []
    @Published private(set) var settingsMessage: String?
    let bundleURL: URL
    private let loader: any DirectoryListing
    private var checkTask: Task<Void, Never>?
    private var generation = UUID()

    init(context: FileAccessContext? = nil, loader: any DirectoryListing = LocalDirectoryLoader(),
         bundleURL: URL = Bundle.main.bundleURL) {
        self.context = context
        self.loader = loader
        self.bundleURL = bundleURL
    }

    deinit { checkTask?.cancel() }

    func updateContext(_ value: FileAccessContext?) {
        guard context != value else { return }
        cancelChecks()
        context = value
        results = []
    }

    func checkFolder(_ url: URL) {
        cancelChecks()
        guard url.isFileURL else {
            record(FileAccessCheckResult(location: url,
                outcome: .failed(failure: nil, message: "Choose a local folder URL to check.")))
            return
        }
        let location = url.standardizedFileURL
        let request = generation
        checkingURL = location
        let loader = self.loader
        checkTask = Task { [weak self] in
            do {
                let snapshot = try await loader.snapshot(of: location, showHidden: false)
                guard !Task.isCancelled, let self, self.generation == request else { return }
                self.checkingURL = nil
                self.checkTask = nil
                self.record(FileAccessCheckResult(location: location,
                    outcome: .readable(visibleItemCount: snapshot.items.count)))
            } catch {
                guard !Task.isCancelled, let self, self.generation == request else { return }
                self.checkingURL = nil
                self.checkTask = nil
                guard !(error is CancellationError) else { return }
                self.record(FileAccessCheckResult(location: location,
                    outcome: .failed(failure: FileAccessFailure.classify(error), message: error.localizedDescription)))
            }
        }
    }

    func cancelChecks() {
        generation = UUID()
        checkTask?.cancel()
        checkTask = nil
        checkingURL = nil
    }

    func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
    }

    func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!
        settingsMessage = NSWorkspace.shared.open(url) ? nil
            : "System Settings could not be opened. Open it manually, then choose Privacy & Security → Full Disk Access."
    }

    private func record(_ result: FileAccessCheckResult) {
        results = Array(([result] + results.filter { $0.id != result.id }).prefix(10))
    }
}

/// A separate utility window leaves browser history, drafts and recovery sheets
/// intact. It can receive keyboard focus, but never becomes the main browser window.
@MainActor
final class FileAccessWindowController: NSWindowController, NSWindowDelegate {
    let model: FileAccessSetupModel
    private var chooser: NSOpenPanel?

    convenience init() {
        self.init(model: FileAccessSetupModel())
    }

    init(model: FileAccessSetupModel) {
        self.model = model
        let panel = ExplorerUtilityPanel(contentRect: NSRect(x: 0, y: 0, width: 560.pt, height: 640.pt),
                                    styleMask: [.titled, .closable, .utilityWindow],
                                    backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "File Access"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        installContent()
        panel.center()
    }

    /// MAC-074: rebuild at the current interface scale (launch and View ▸ Interface Size).
    func installContent() {
        guard let panel = window else { return }
        panel.setContentSize(ExplorerScale.fittingContentSize(NSSize(width: 560.pt, height: 640.pt), on: panel.screen))
        let hosting = NSHostingView(rootView: FileAccessSetupView(model: model,
            chooseFolder: { [weak self] in self?.chooseFolder() },
            close: { [weak self] in self?.close() }).font(.system(size: 12.pt)).controlSize(ExplorerScale.controlSize))
        hosting.sizingOptions = []
        panel.contentView = hosting
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(context: FileAccessContext? = nil) {
        model.updateContext(context)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    override func close() {
        cancelPendingUI()
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        cancelPendingUI()
    }

    private func chooseFolder() {
        guard window != nil, chooser == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Folder to Check"
        panel.message = "Check whether \(AppIdentity.name) can list this folder. This does not change the browser's location."
        panel.prompt = "Check Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        chooser = panel
        // Use a standalone native chooser; parent closure still invalidates its reply.
        panel.begin { [weak self, weak panel] response in
            guard let self, let panel, self.chooser === panel else { return }
            self.chooser = nil
            guard let window = self.window, window.isVisible else { return }
            window.makeKeyAndOrderFront(nil)
            guard response == .OK, let url = panel.url else { return }
            self.model.checkFolder(url)
        }
    }

    private func cancelPendingUI() {
        let panel = chooser
        chooser = nil
        panel?.cancel(nil)
        model.cancelChecks()
    }
}
