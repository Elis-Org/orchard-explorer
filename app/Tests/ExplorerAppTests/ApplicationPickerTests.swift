import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ExplorerApp

@Suite(.serialized)
@MainActor
struct ApplicationPickerTests {
    @Test func scopeChoicesDefaultToOpenOnce() throws {
        let app = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("open-with-scope-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let application = try makeApplication("Editor", in: folder)
        let picker = ApplicationPicker(recommendedApplications: [application], allowsDefaultAssociation: true, eligibleType: .plainText)
        let accessory = try #require(picker.panel.accessoryView)
        let buttons = descendantButtons(in: accessory)
        let titles = [
            "Open once",
            "Always open this file with this app",
            "Always use this app for this file type"
        ]
        let choices = buttons.filter { titles.contains($0.title) }
        #expect(choices.map(\.title) == titles)
        #expect(choices.filter { $0.state == .on }.map(\.title) == ["Open once"])
        let once = try #require(choices.first)
        let group = try #require(once.superview)
        #expect(group.accessibilityRole() == .radioGroup)
        #expect(group.accessibilityLabel()?.isEmpty == false)
        let scopes: [ApplicationPickerScope] = [.once, .file, .fileType(.plainText)]
        let identifiers = ["open-with-once", "open-with-file", "open-with-file-type"]
        #expect(choices.map { $0.accessibilityIdentifier() } == identifiers)
        for (choice, scope) in zip(choices, scopes) {
            let action = try #require(choice.action)
            #expect(app.sendAction(action, to: choice.target, from: choice))
            #expect(choices.filter { $0.state == .on }.map(\.title) == [choice.title])
            #expect(picker.selection(for: application)?.scope == scope)
        }
        let typeChoice = try #require(choices.last)
        let help = try #require(typeChoice.accessibilityHelp())
        #expect(help.contains(".txt") && help.contains(".text") && help.contains("user account"))
        let fresh = ApplicationPicker(recommendedApplications: [], allowsDefaultAssociation: true, eligibleType: .plainText)
        let freshAccessory = try #require(fresh.panel.accessoryView)
        let freshChoices = descendantButtons(in: freshAccessory).filter { titles.contains($0.title) }
        #expect(freshChoices.filter { $0.state == .on }.map(\.title) == ["Open once"])
    }

    private func descendantButtons(in view: NSView) -> [NSButton] {
        if let button = view as? NSButton { return [button] }
        return view.subviews.flatMap { descendantButtons(in: $0) }
    }

    @Test func modeActionRechecksEligibleBundlesAndLeavesFoldersNavigable() throws {
        let app = NSApplication.shared
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("open-with-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: folder) }
        let recommended = try makeApplication("Recommended", in: folder)
        let other = try makeApplication("Other", in: folder)
        let linked = folder.appendingPathComponent("Linked.app")
        try fm.createSymbolicLink(at: linked, withDestinationURL: recommended)
        let document = folder.appendingPathComponent("Document.txt")
        try Data("Synthetic".utf8).write(to: document)

        let picker = ApplicationPicker(recommendedApplications: [recommended], allowsDefaultAssociation: true, eligibleType: .plainText)
        let panel = picker.panel
        let accessory = try #require(panel.accessoryView as? NSStackView)
        let row = try #require(accessory.arrangedSubviews.first as? NSStackView)
        let mode = try #require(row.arrangedSubviews.compactMap { $0 as? NSPopUpButton }.first)
        #expect(panel.delegate === picker && panel.isAccessoryViewDisclosed)
        #expect(mode.itemTitles == ["Recommended Applications", "All Applications"] && mode.indexOfSelectedItem == 0)
        #expect(picker.panel(panel, shouldEnable: folder))
        #expect(picker.panel(panel, shouldEnable: recommended))
        #expect(picker.panel(panel, shouldEnable: linked))
        #expect(!picker.panel(panel, shouldEnable: other))
        #expect(!picker.panel(panel, shouldEnable: document))
        try picker.panel(panel, validate: linked)
        #expect(picker.validatedApplication(at: linked) == recommended.resolvingSymlinksInPath().standardizedFileURL)
        #expect(throws: NSError.self) { try picker.panel(panel, validate: other) }

        let action = try #require(mode.action)
        mode.selectItem(at: 1)
        #expect(app.sendAction(action, to: mode.target, from: mode))
        #expect(picker.panel(panel, shouldEnable: folder))
        #expect(picker.panel(panel, shouldEnable: other))
        try picker.panel(panel, validate: other)
        #expect(throws: NSError.self) { try picker.panel(panel, validate: folder) }
        #expect(throws: NSError.self) { try picker.panel(panel, validate: document) }

        mode.selectItem(at: 0)
        #expect(app.sendAction(action, to: mode.target, from: mode))
        #expect(!picker.panel(panel, shouldEnable: other))
        #expect(picker.validatedApplication(at: other) == nil)
        #expect(throws: NSError.self) { try picker.panel(panel, validate: other) }

        let empty = ApplicationPicker(recommendedApplications: [], allowsDefaultAssociation: false, eligibleType: nil)
        let emptyPanel = empty.panel
        let emptyAccessory = try #require(emptyPanel.accessoryView as? NSStackView)
        let unavailable = descendantButtons(in: emptyAccessory)
        let perFile = try #require(unavailable.first { $0.title == "Always open this file with this app" })
        let perType = try #require(unavailable.first { $0.title == "Always use this app for this file type" })
        for choice in [perFile, perType] {
            #expect(choice.state == .off && !choice.isEnabled)
        }
        #expect(empty.panel(emptyPanel, shouldEnable: folder))
        #expect(!empty.panel(emptyPanel, shouldEnable: recommended))
        #expect(throws: NSError.self) { try empty.panel(emptyPanel, validate: recommended) }

        let unknownType = ApplicationPicker(recommendedApplications: [recommended], allowsDefaultAssociation: true,
                                            eligibleType: nil, filenameExtension: "xyz")
        let unknownAccessory = try #require(unknownType.panel.accessoryView)
        let unknownScope = try #require(descendantButtons(in: unknownAccessory).first {
            $0.title == "Always use this app for this file type"
        })
        #expect(!unknownScope.isEnabled && unknownScope.accessibilityHelp()?.contains(".xyz") == true)
        unknownScope.state = .on
        #expect(unknownType.selection(for: recommended)?.scope == .once)
    }

    @Test func onlyExactDeclaredTypesWithMatchingFilenameTagsCanBeAssigned() {
        #expect(LocalApplicationRouter.classifyOpenWithType(.plainText, filenameExtension: "TXT") == .plainText)
        #expect(LocalApplicationRouter.classifyOpenWithType(.plainText, filenameExtension: "text") == .plainText)
        #expect(LocalApplicationRouter.classifyOpenWithType(.png, filenameExtension: "png") == .png)
        #expect(LocalApplicationRouter.classifyOpenWithType(.data, filenameExtension: "txt") == nil)
        #expect(LocalApplicationRouter.classifyOpenWithType(.png, filenameExtension: "txt") == nil)
        #expect(LocalApplicationRouter.classifyOpenWithType(.plainText, filenameExtension: "") == nil)
        let extensionName = "maxplorer-" + UUID().uuidString
        let unknown = UTType(filenameExtension: extensionName)
        #expect(unknown?.isDynamic == true)
        #expect(LocalApplicationRouter.classifyOpenWithType(unknown, filenameExtension: extensionName) == nil)
    }

    @Test func defaultAssociationRejectsNonphysicalURLs() async throws {
        let router = LocalApplicationRouter()
        let remote = try #require(URL(string: "https://example.invalid/app"))
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID())")
        do {
            try await router.setDefaultApplication(at: remote, forType: .plainText)
            Issue.record("A nonphysical application reached the type setter")
        } catch let error as CocoaError {
            #expect(error.code == .fileReadUnsupportedScheme)
        }
        for (application, file) in [(remote, local), (local, remote)] {
            do {
                try await router.setDefaultApplication(at: application, forFile: file)
                Issue.record("A nonphysical association reached the workspace setter")
            } catch let error as CocoaError {
                #expect(error.code == .fileReadUnsupportedScheme)
            }
        }
    }

    private func makeApplication(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.maxplorer.picker.\(name)", "CFBundlePackageType": "APPL"]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        return url
    }
}
