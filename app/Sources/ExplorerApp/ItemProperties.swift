import AppKit
import Combine
import ExplorerCore
import SwiftUI

/// FR-PREVIEW-002 / EV-0277–0279 / AT-PREVIEW-002. Properties captures a
/// selected entry; subsequent browser selection changes never retarget it.
@MainActor
final class ItemPropertiesModel: ObservableObject {
    @Published private(set) var item: FileItem?
    @Published private(set) var metadata: FileMetadata?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var accessIssue: FileAccessContext?
    var onShowAccessHelp: ((FileAccessContext) -> Void)?
    private let reader: any FileMetadataReading
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(reader: any FileMetadataReading = LocalFileMetadataReader()) {
        self.reader = reader
    }

    deinit { task?.cancel() }

    func show(_ item: FileItem) {
        group = []
        self.item = item
        refresh()
    }

    /// NATIVE-P18A: several selected items show one read-only summary built from
    /// their listed metadata (no folder scanning, no extra reads).
    @Published private(set) var group: [FileItem] = []

    func show(items: [FileItem]) {
        guard items.count > 1 else { if let item = items.first { show(item) }; return }
        dismiss()
        group = items
    }

    var groupSummary: (count: String, type: String, location: String, size: String, note: String?)? {
        guard group.count > 1 else { return nil }
        let kinds = Set(group.map(\.kind))
        let parents = Set(group.map { $0.url.deletingLastPathComponent().standardizedFileURL.path })
        let files = group.filter { !$0.isDirectory && !$0.isSymbolicLink }
        let bytes = files.compactMap(\.size).reduce(Int64(0)) { sum, size in
            let result = sum.addingReportingOverflow(size)
            return result.overflow ? Int64.max : result.partialValue
        }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " (\(bytes.formatted()) bytes)"
        let note: String? = files.count < group.count ? "Folder and link contents are not counted." : nil
        return ("\(group.count) items",
                kinds.count == 1 ? "All of type \(kinds.first!.isEmpty ? "Unavailable" : kinds.first!)" : "Multiple types",
                parents.count == 1 ? parents.first! : "Multiple folders",
                size, note)
    }

    func refresh() {
        guard let item else { return }
        task?.cancel()
        generation = UUID()
        let request = generation
        metadata = nil
        errorMessage = nil
        accessIssue = nil
        isLoading = true
        let reader = self.reader
        task = Task { [weak self] in
            do {
                let result = try await reader.metadata(for: item)
                guard !Task.isCancelled, let self, self.generation == request else { return }
                self.metadata = result
                self.isLoading = false
                self.task = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == request else { return }
                self.errorMessage = error.localizedDescription
                if let failure = FileAccessFailure.classify(error) {
                    self.accessIssue = FileAccessContext(failure: failure,
                        locations: [item.url.deletingLastPathComponent()], action: "Read properties")
                }
                self.isLoading = false
                self.task = nil
            }
        }
    }

    func dismiss() {
        generation = UUID()
        task?.cancel()
        task = nil
        item = nil
        group = []
        metadata = nil
        errorMessage = nil
        accessIssue = nil
        isLoading = false
    }

    func showAccessHelp() {
        guard let accessIssue else { return }
        onShowAccessHelp?(accessIssue)
    }
}

/// Separate key-capable panel; menu commands must not reach the browser behind it.
@MainActor
final class ItemPropertiesWindowController: NSWindowController, NSWindowDelegate {
    let model: ItemPropertiesModel

    convenience init() { self.init(model: ItemPropertiesModel()) }

    init(model: ItemPropertiesModel) {
        self.model = model
        let panel = ExplorerUtilityPanel(contentRect: NSRect(x: 0, y: 0, width: 420.pt, height: 560.pt),
            styleMask: [.titled, .closable, .utilityWindow, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Properties"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        installContent()
        panel.center()
    }

    /// MAC-074: rebuild at the current interface scale (launch and View ▸ Interface Size).
    func installContent() {
        guard let panel = window else { return }
        panel.minSize = ExplorerScale.fittingContentSize(NSSize(width: 380.pt, height: 480.pt), on: panel.screen)
        panel.setContentSize(ExplorerScale.fittingContentSize(NSSize(width: 420.pt, height: 560.pt), on: panel.screen))
        let hosting = NSHostingView(rootView: ItemPropertiesView(model: model,
            close: { [weak self] in self?.close() }).font(.system(size: 12.pt)).controlSize(ExplorerScale.controlSize))
        hosting.sizingOptions = []
        panel.contentView = hosting
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ item: FileItem) {
        model.show(item)
        window?.title = "\(item.name) Properties"
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func show(items: [FileItem]) {
        guard items.count > 1 else { if let item = items.first { show(item) }; return }
        model.show(items: items)
        window?.title = "\(items.count) items Properties"
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    override func close() {
        model.dismiss()
        super.close()
    }

    func windowWillClose(_ notification: Notification) { model.dismiss() }
}
