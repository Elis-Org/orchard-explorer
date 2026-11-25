import AppKit
import Combine
import CoreFoundation
import ExplorerCore
import Foundation
import Testing
@testable import ExplorerApp

@Suite @MainActor struct SidebarBackgroundSettingsTests {
    // This interface gate checks selector availability. Menu behavior is covered separately.
    @Test func exposesNativeToggleAction() {
        _ = NSApplication.shared
        let delegate = ExplorerAppDelegate()
        #expect(delegate.responds(to: NSSelectorFromString("toggleSidebarBackgroundCheck:")))
    }

    @Test func nativeViewMenuDispatchesIndependentSettingsWithoutAWindow() throws {
        let app = NSApplication.shared
        let preferences = SidebarBackgroundCheckPreferences()
        let delegate = ExplorerAppDelegate(sidebarBackgroundCheckPreferences: preferences)
        let viewMenu = NSMenu(title: "View")
        delegate.populateViewMenu(viewMenu)
        let settings = try #require(viewMenu.item(withTitle: "Background Folder Checks")?.submenu)
        #expect(settings.items.map(\.title) == ["Unopened Protected Folders", "Cloud Folders", "Mounted Network Folders"])
        for item in settings.items {
            #expect(item.target === delegate && item.view == nil && item.keyEquivalent.isEmpty)
            #expect(item.toolTip?.contains("System Settings") == true)
            #expect(item.toolTip?.contains("already displayed") == true)
            #expect(delegate.validateMenuItem(item))
        }
        #expect(settings.items.map(\.state) == [.off, .off, .off])

        for (index, item) in settings.items.enumerated() {
            let action = try #require(item.action)
            #expect(app.sendAction(action, to: item.target, from: item))
            #expect(item.state == .on)
            #expect(settings.items.enumerated().allSatisfy { offset, current in
                delegate.validateMenuItem(current) && current.state == (offset <= index ? .on : .off)
            })
        }
        #expect(preferences.options == .init(protectedLocal: true, cloud: true, network: true))
        let cloud = try #require(settings.item(withTitle: "Cloud Folders"))
        #expect(app.sendAction(try #require(cloud.action), to: cloud.target, from: cloud))
        #expect(settings.items.map(\.state) == [.on, .off, .on])
        #expect(preferences.options == .init(protectedLocal: true, network: true))
    }

    @Test func persistsOnlyChangedTypedPreference() throws {
        let suite = "SidebarBackgroundSettings-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let protectedKey = "nativeExplorer.sidebarBackgroundChecks.protectedLocal"
        let cloudKey = "nativeExplorer.sidebarBackgroundChecks.cloud"
        let networkKey = "nativeExplorer.sidebarBackgroundChecks.network"
        let data = Data([7])

        #expect(SidebarBackgroundCheckPreferences(defaults: defaults).options == .init())
        defaults.set(1, forKey: protectedKey)
        defaults.set("YES", forKey: cloudKey)
        defaults.set(data, forKey: networkKey)
        defaults.set("preserve", forKey: "unrelated")
        let preferences = SidebarBackgroundCheckPreferences(defaults: defaults)
        #expect(preferences.options == .init())

        var publications: [SidebarBackgroundCheckOptions] = []
        let subscription = preferences.$options.dropFirst().sink { publications.append($0) }
        defer { subscription.cancel() }
        preferences.set(.cloud, enabled: true)
        preferences.set(.cloud, enabled: true)
        #expect(preferences.options == .init(cloud: true))
        #expect(publications == [.init(cloud: true)])
        let domain = try #require(defaults.persistentDomain(forName: suite))
        let cloud = domain[cloudKey] as? NSNumber
        #expect(cloud.map { CFGetTypeID($0) } == CFBooleanGetTypeID())
        let malformed = try #require(domain[protectedKey] as? NSNumber)
        #expect(CFGetTypeID(malformed) == CFNumberGetTypeID() && malformed.intValue == 1)
        #expect(domain[networkKey] as? Data == data)
        #expect(domain["unrelated"] as? String == "preserve")
        #expect(domain.count == 4)

        let reopened = try #require(UserDefaults(suiteName: suite))
        #expect(SidebarBackgroundCheckPreferences(defaults: reopened).options == .init(cloud: true))

        preferences.set(.protectedLocal, enabled: true)
        let repairedDomain = try #require(defaults.persistentDomain(forName: suite))
        let repaired = try #require(repairedDomain[protectedKey] as? NSNumber)
        #expect(CFGetTypeID(repaired) == CFBooleanGetTypeID() && repaired.boolValue)
        #expect(repairedDomain[networkKey] as? Data == data)
        #expect(repairedDomain["unrelated"] as? String == "preserve")
        #expect(repairedDomain.count == 4)

        preferences.set(.network, enabled: true)
        #expect(SidebarBackgroundCheckPreferences(defaults: reopened).options ==
                .init(protectedLocal: true, cloud: true, network: true))
        preferences.set(.protectedLocal, enabled: false)
        preferences.set(.cloud, enabled: false)
        preferences.set(.network, enabled: false)
        #expect(SidebarBackgroundCheckPreferences(defaults: reopened).options == .init())
        for key in [protectedKey, cloudKey, networkKey] {
            let persisted = try #require(reopened.object(forKey: key) as? NSNumber)
            #expect(CFGetTypeID(persisted) == CFBooleanGetTypeID() && !persisted.boolValue)
        }
    }
}
