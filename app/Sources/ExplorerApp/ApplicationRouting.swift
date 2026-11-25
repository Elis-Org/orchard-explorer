import AppKit
import ExplorerCore
import UniformTypeIdentifiers

struct ApplicationChoice: Identifiable, Equatable {
    let url: URL
    let name: String
    let isDefault: Bool
    var id: URL { url }
}
@MainActor protocol ApplicationRouting: AnyObject {
    func applications(toOpen url: URL) -> [ApplicationChoice]
    func open(_ urls: [URL], withApplicationAt application: URL) async throws
    func openInTerminal(_ folder: URL) async throws
    func revealInFinder(_ urls: [URL])
    func eligibleOpenWithType(for file: URL) -> UTType?
    func chooseApplication(for document: URL, title: String, allowsDefaultAssociation: Bool, eligibleType: UTType?) -> ApplicationPickerSelection?
    func setDefaultApplication(at application: URL, forFile file: URL) async throws
    func setDefaultApplication(at application: URL, forType type: UTType) async throws
    func icon(forApplicationAt url: URL) -> NSImage
    /// Opens each URL with its default application; returns the URLs that failed.
    func openWithDefaultApplications(_ urls: [URL]) -> [URL]
}

@MainActor final class OpenWithTypeReservations {
    static let shared = OpenWithTypeReservations()
    private var pending: Set<String> = []

    func acquire(_ type: UTType) -> Bool { pending.insert(type.identifier).inserted }
    func release(_ type: UTType) { pending.remove(type.identifier) }
}

@MainActor final class LocalApplicationRouter: ApplicationRouting {
    init() {}
    private func isPhysical(_ url: URL) -> Bool { BrowsingLocation(url: url)?.physicalURL != nil }
    func applications(toOpen url: URL) -> [ApplicationChoice] {
        guard isPhysical(url) else { return [] }
        let workspace = NSWorkspace.shared
        let preferred = workspace.urlForApplication(toOpen: url)?.standardizedFileURL
        var seen = Set<URL>()
        let urls = (preferred.map { [$0] } ?? []) + workspace.urlsForApplications(toOpen: url)
        return urls.compactMap { candidate -> ApplicationChoice? in
            let candidate = candidate.standardizedFileURL
            guard seen.insert(candidate).inserted else { return nil }
            let name = FileManager.default.displayName(atPath: candidate.path)
            return ApplicationChoice(url: candidate, name: name, isDefault: candidate == preferred)
        }.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.url.path < $1.url.path : comparison == .orderedAscending
        }
    }
    func open(_ urls: [URL], withApplicationAt application: URL) async throws {
        guard !urls.isEmpty, urls.allSatisfy(isPhysical), isPhysical(application) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
    func openInTerminal(_ folder: URL) async throws {
        guard isPhysical(folder) else { throw CocoaError(.fileReadUnsupportedScheme) }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw NSError(domain: "Explorer.ApplicationRouting", code: 1, userInfo: [NSLocalizedDescriptionKey: "Terminal.app could not be found."])
        }
        try await open([folder], withApplicationAt: terminal)
    }
    func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty, urls.allSatisfy(isPhysical) else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
    func eligibleOpenWithType(for file: URL) -> UTType? {
        guard isPhysical(file) else { return nil }
        let fresh = URL(fileURLWithPath: file.path, isDirectory: false)
        guard let metadata = try? fresh.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentTypeKey]),
              metadata.isRegularFile == true, metadata.isSymbolicLink == false else { return nil }
        return Self.classifyOpenWithType(metadata.contentType, filenameExtension: fresh.pathExtension)
    }

    nonisolated static func classifyOpenWithType(_ contentType: UTType?, filenameExtension: String) -> UTType? {
        let suffix = filenameExtension.lowercased()
        guard !suffix.isEmpty, let contentType, contentType.isDeclared, !contentType.isDynamic,
              UTType(filenameExtension: suffix) == contentType,
              contentType.tags[.filenameExtension]?.contains(where: { $0.lowercased() == suffix }) == true else { return nil }
        return contentType
    }

    func chooseApplication(for document: URL, title: String, allowsDefaultAssociation: Bool, eligibleType: UTType?) -> ApplicationPickerSelection? {
        guard isPhysical(document) else { return nil }
        let picker = ApplicationPicker(recommendedApplications: applications(toOpen: document).map(\.url),
                                       allowsDefaultAssociation: allowsDefaultAssociation, eligibleType: eligibleType,
                                       filenameExtension: document.pathExtension.lowercased())
        return picker.choose(prompt: title)
    }
    func setDefaultApplication(at application: URL, forFile file: URL) async throws {
        guard isPhysical(application), isPhysical(file) else { throw CocoaError(.fileReadUnsupportedScheme) }
        try await NSWorkspace.shared.setDefaultApplication(at: application, toOpenFileAt: file)
    }
    func setDefaultApplication(at application: URL, forType type: UTType) async throws {
        guard isPhysical(application) else { throw CocoaError(.fileReadUnsupportedScheme) }
        try await NSWorkspace.shared.setDefaultApplication(at: application, toOpen: type)
    }
    func icon(forApplicationAt url: URL) -> NSImage {
        guard isPhysical(url) else { return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage() }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
    func openWithDefaultApplications(_ urls: [URL]) -> [URL] {
        urls.filter { !isPhysical($0) || !NSWorkspace.shared.open($0) }
    }
}
