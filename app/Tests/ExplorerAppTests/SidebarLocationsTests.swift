import Foundation
import Testing
@testable import ExplorerCore
@testable import ExplorerApp

@MainActor
struct SidebarLocationsTests {
    @Test func onlyLiveMatchingOneDriveDomainsAppearAndDisplayNamesDoNotIdentifyAccounts() throws {
        let external = URL(fileURLWithPath: "/Volumes/External/OneDrive-Company", isDirectory: true)
        let home = URL(fileURLWithPath: "/Users/test/Library/CloudStorage")
        let main = home.appendingPathComponent("OneDrive", isDirectory: true)
        let library = home.appendingPathComponent("OneDrive-SharedLibraries-Company", isDirectory: true)
        func verified(_ url: URL, marker: String?, liveDomain: String?, isRoot: Bool = true) -> SidebarAccount? {
            SidebarAccount.oneDrive(url: url, localizedName: "OneDrive", marker: marker,
                                    liveDomain: liveDomain, isRoot: isRoot)
        }
        let first = try #require(verified(main, marker: "com.microsoft.OneDrive.FileProvider/Account1", liveDomain: "Account1"))
        let second = try #require(verified(external, marker: "com.microsoft.OneDrive-mac.FileProvider/Account2", liveDomain: "Account2"))
        #expect(first.title == second.title && first.id != second.id)
        #expect(second.url == external)
        #expect(verified(main, marker: nil, liveDomain: nil) == nil)
        #expect(verified(main, marker: "com.microsoft.OneDrive.FileProvider/Old", liveDomain: nil) == nil)
        #expect(verified(main, marker: "com.microsoft.OneDrive.FileProvider/Old", liveDomain: "Other") == nil)
        #expect(verified(main, marker: "another.FileProvider/Account1", liveDomain: "Account1") == nil)
        #expect(verified(main, marker: "com.microsoft.OneDrive.FileProvider/Account1", liveDomain: "Account1", isRoot: false) == nil)
        #expect(verified(library, marker: "com.microsoft.OneDrive.FileProvider/Account1", liveDomain: "Account1") == nil)
    }

    @Test func sidebarUsesDistinctLocalizedAccountLabelsAndAvoidsCompactFolderSpellings() throws {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let cloud = home.appendingPathComponent("Library/CloudStorage")
        func account(_ directory: String, localizedName: String, domain: String) throws -> SidebarAccount {
            try #require(SidebarAccount.oneDrive(url: cloud.appendingPathComponent(directory),
                localizedName: localizedName, marker: "com.microsoft.OneDrive.FileProvider/" + domain,
                liveDomain: domain, isRoot: true))
        }
        let personal = try account("OneDrive-Personal", localizedName: "OneDrive – Personal", domain: "OneDrive - 42")
        let work = try account("OneDrive-ExampleOrg", localizedName: "OneDrive-ExampleOrg", domain: "OneDrive - Example Org")
        let catalog = SidebarLocationCatalog()
        let model = SidebarModel(homeURL: home, pins: PinnedFolderStore(homeURL: home), locations: catalog)
        defer { model.cancelLoads() }
        func titles(_ accounts: [SidebarAccount]) -> [String] {
            catalog.update(volumes: [], accounts: accounts)
            return model.roots.filter { $0.key.hasPrefix("account:") }.map(\.title)
        }
        #expect(titles([personal]) == ["OneDrive – Personal"])
        #expect(titles([work]) == ["OneDrive"])
        #expect(titles([work, personal]) == ["OneDrive - Example Org", "OneDrive – Personal"])
    }

    @Test func unmountUpdatesDrivesWhileAnOldAccountLookupIsStillPending() async throws {
        actor Discovery {
            let first = SidebarVolume(id: "1", title: "Backup", url: URL(fileURLWithPath: "/Volumes/Backup"), symbol: "externaldrive")
            var listedVolumes = false
            var pending: CheckedContinuation<[SidebarAccount], Never>?
            func volumes() -> [SidebarVolume] {
                defer { listedVolumes = true }
                return listedVolumes ? [] : [first]
            }
            func accounts(_ volumes: [SidebarVolume]) async -> [SidebarAccount] {
                guard !volumes.isEmpty else { return [] }
                return await withCheckedContinuation { pending = $0 }
            }
            func finish() { pending?.resume(returning: []); pending = nil }
        }
        let source = Discovery()
        let catalog = SidebarLocationCatalog(readVolumes: { await source.volumes() },
                                            readAccounts: { await source.accounts($0) })
        catalog.refresh()
        let start = ContinuousClock.now
        while await source.pending == nil, ContinuousClock.now - start < .seconds(2) {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(catalog.snapshot.volumes.count == 1)
        catalog.refresh()
        let unmount = ContinuousClock.now
        while !catalog.snapshot.volumes.isEmpty, ContinuousClock.now - unmount < .seconds(2) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(catalog.snapshot.volumes.isEmpty)
        await source.finish()
    }

    @Test func mountedVolumesUpdateBothPresentationsAndDisclosureSurvivesPinChanges() throws {
        let drive = SidebarVolume(id: "disk1", title: "Startup", url: URL(fileURLWithPath: "/"), symbol: "internaldrive.fill")
        let alias = SidebarVolume(id: "disk1", title: "Alias", url: URL(fileURLWithPath: "/Volumes/Startup"), symbol: "internaldrive.fill")
        let external = SidebarVolume(id: "disk2", title: "Backup", url: URL(fileURLWithPath: "/Volumes/Backup"), symbol: "externaldrive.fill")
        let pins = PinnedFolderStore()
        let catalog = SidebarLocationCatalog()
        catalog.update(volumes: [drive, alias, external], accounts: [])
        let model = SidebarModel(homeURL: FileManager.default.homeDirectoryForCurrentUser, pins: pins, locations: catalog)
        defer { model.cancelLoads() }
        let mac = try #require(model.roots.last)
        #expect(mac.title == "This Mac" && !mac.expanded)
        model.expand(mac)
        #expect(mac.expanded && model.volumes == [drive, external])
        #expect(mac.children.compactMap(\.url) == model.volumes.map(\.url))
        pins.unpin(FileManager.default.homeDirectoryForCurrentUser)
        #expect(model.roots.last === mac && mac.expanded)
        catalog.update(volumes: [drive], accounts: [])
        #expect(mac.children.compactMap(\.url) == [drive.url])
        #expect(model.volumes == [drive])
        model.collapse(mac)
        #expect(!mac.expanded && mac.children.count == 1)
    }
}
