import AppKit
import UniformTypeIdentifiers

struct ApplicationPickerSelection: Equatable {
    let applicationURL: URL
    let scope: ApplicationPickerScope
}

enum ApplicationPickerScope: Equatable {
    case once
    case file
    case fileType(UTType)

    var contentType: UTType? {
        if case .fileType(let type) = self { return type }
        return nil
    }
}

enum ApplicationPickerMode: Equatable { case recommended, all }

struct ApplicationPickerPolicy {
    private let recommendedPaths: Set<String>

    init(recommendedApplications: [URL]) {
        recommendedPaths = Set(recommendedApplications.filter(\.isFileURL).map { Self.resolved($0).path })
    }

    func allowsApplication(_ url: URL, in mode: ApplicationPickerMode) -> Bool {
        url.isFileURL && (mode == .all || recommendedPaths.contains(Self.resolved(url).path))
    }

    fileprivate static func resolved(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}

@MainActor
final class ApplicationPicker: NSObject, NSOpenSavePanelDelegate {
    let panel = NSOpenPanel()
    private let filter = NSPopUpButton(frame: .zero, pullsDown: false)
    private let once = NSButton(radioButtonWithTitle: "Open once", target: nil, action: nil)
    private let file = NSButton(radioButtonWithTitle: "Always open this file with this app", target: nil, action: nil)
    private let fileType = NSButton(radioButtonWithTitle: "Always use this app for this file type", target: nil, action: nil)
    private let eligibleType: UTType?
    private let policy: ApplicationPickerPolicy

    init(recommendedApplications: [URL], allowsDefaultAssociation: Bool, eligibleType: UTType?,
         filenameExtension: String = "") {
        self.eligibleType = allowsDefaultAssociation ? eligibleType : nil
        policy = ApplicationPickerPolicy(recommendedApplications: recommendedApplications)
        super.init()
        filter.addItems(withTitles: ["Recommended Applications", "All Applications"])
        filter.selectItem(at: 0)
        filter.setAccessibilityLabel("Enable")
        filter.target = self
        filter.action = #selector(changeFilter)
        once.state = .on
        file.isEnabled = allowsDefaultAssociation
        fileType.isEnabled = self.eligibleType != nil
        for (button, identifier) in [(once, "open-with-once"), (file, "open-with-file"), (fileType, "open-with-file-type")] {
            button.target = self
            button.action = #selector(changeScope(_:))
            button.setAccessibilityIdentifier(identifier)
        }
        let scopes = NSStackView(views: [once, file, fileType])
        scopes.orientation = .vertical
        scopes.alignment = .leading
        scopes.setAccessibilityElement(true)
        scopes.setAccessibilityRole(.radioGroup)
        scopes.setAccessibilityLabel("Open With scope")
        scopes.setAccessibilityIdentifier("open-with-scope")
        let help: String
        if let type = self.eligibleType {
            let extensions = (type.tags[.filenameExtension] ?? []).sorted().map { ".\($0)" }.joined(separator: ", ")
            help = "Changes the macOS default for this file type (\(extensions)) for your user account. Individual file defaults still apply."
        } else if !allowsDefaultAssociation {
            help = "Default changes are unavailable for symbolic links or files that could not be verified."
        } else if filenameExtension.isEmpty {
            help = "A file type default is unavailable without a verified filename extension."
        } else {
            help = "macOS could not verify a registered type for .\(filenameExtension)."
        }
        let note = NSTextField(wrappingLabelWithString: help)
        note.preferredMaxLayoutWidth = 320
        fileType.setAccessibilityHelp(help)

        let row = NSStackView(views: [NSTextField(labelWithString: "Enable:"), filter])
        row.alignment = .centerY
        let accessory = NSStackView(views: [row, scopes, note])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        accessory.frame.size = accessory.fittingSize
        panel.title = "Choose Application"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        panel.delegate = self
    }

    func choose(prompt: String) -> ApplicationPickerSelection? {
        panel.message = prompt
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return selection(for: url)
    }

    func selection(for url: URL) -> ApplicationPickerSelection? {
        guard let application = validatedApplication(at: url) else { return nil }
        let scope: ApplicationPickerScope
        if fileType.isEnabled, fileType.state == .on, let eligibleType {
            scope = .fileType(eligibleType)
        } else if file.isEnabled, file.state == .on {
            scope = .file
        } else {
            scope = .once
        }
        return ApplicationPickerSelection(applicationURL: application, scope: scope)
    }

    @objc private func changeScope(_ sender: NSButton) {
        guard sender.isEnabled else { return }
        for button in [once, file, fileType] {
            button.state = button === sender ? .on : .off
        }
    }

    @objc private func changeFilter() { panel.validateVisibleColumns() }

    private var mode: ApplicationPickerMode { filter.indexOfSelectedItem == 1 ? .all : .recommended }

    func validatedApplication(at url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let resolved = ApplicationPickerPolicy.resolved(url)
        guard let values = try? resolved.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey]),
              values.isDirectory == true, values.contentType?.conforms(to: .applicationBundle) == true,
              policy.allowsApplication(resolved, in: mode) else { return nil }
        return resolved
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let resolved = ApplicationPickerPolicy.resolved(url)
        guard let values = try? resolved.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isPackageKey]) else { return false }
        if values.contentType?.conforms(to: .applicationBundle) == true {
            return values.isDirectory == true && policy.allowsApplication(resolved, in: mode)
        }
        return values.isDirectory == true && values.isPackage != true
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard validatedApplication(at: url) != nil else {
            throw NSError(domain: "Explorer.ApplicationPicker", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Choose an application enabled by the current filter."])
        }
    }
}
