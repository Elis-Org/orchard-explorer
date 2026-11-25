# How Orchard Explorer is organized

Orchard Explorer is a Swift package with two production targets. `ExplorerCore` owns filesystem access and data models. The `ExplorerApp` executable combines SwiftUI window content with AppKit controls for the file list, keyboard focus, menus and macOS application integration. SwiftPM builds the executable as `Explorer`; the build script packages it as `Orchard Explorer.app`. [Package definition](../app/Package.swift)

## Source map

| Area | Start here | What it owns |
| --- | --- | --- |
| Navigation and tabs | [ExplorerStore.swift](../app/Sources/ExplorerApp/ExplorerStore.swift), [BrowsingDirectoryListing.swift](../app/Sources/ExplorerCore/BrowsingDirectoryListing.swift) | Load the active location, route physical and ZIP listings, and coordinate selection with navigation. |
| Application and windows | [ExplorerApplication.swift](../app/Sources/ExplorerApp/ExplorerApplication.swift) | Own AppKit lifecycle, windows, application menus and external open/reveal requests. |
| Sidebar and addresses | [SidebarModel.swift](../app/Sources/ExplorerApp/SidebarModel.swift), [DocumentsFavoriteRedirect.swift](../app/Sources/ExplorerCore/DocumentsFavoriteRedirect.swift) | Manage sidebar locations and resolve the built-in Documents favorite when it points to verified OneDrive storage. |
| File commands | [FileCommandEligibility.swift](../app/Sources/ExplorerApp/FileCommandEligibility.swift), [ItemOperationCoordinator.swift](../app/Sources/ExplorerApp/ItemOperationCoordinator.swift) | Decide which actions are available for the selection and coordinate their execution and feedback. |
| Local transfers and recovery | [FileOperations.swift](../app/Sources/ExplorerCore/FileOperations.swift), [FileRecovery.swift](../app/Sources/ExplorerCore/FileRecovery.swift), [TransferSession.swift](../app/Sources/ExplorerApp/TransferSession.swift) | Validate source and destination identities, execute local operations, handle conflicts and retain recovery receipts. |
| ZIP contents | [ZIPDirectoryListing.swift](../app/Sources/ExplorerCore/ZIPDirectoryListing.swift), [ArchiveOperations.swift](../app/Sources/ExplorerCore/ArchiveOperations.swift) | Enumerate archive members, verify archive revisions and stage changes to a writable ZIP. ZIPFoundation is pinned in [Package.resolved](../app/Package.resolved). |
| Filename search | [FilenameSearch.swift](../app/Sources/ExplorerCore/FilenameSearch.swift), [SearchSession.swift](../app/Sources/ExplorerApp/SearchSession.swift) | Traverse within bounded scope, apply filename and metadata filters, and report results and incomplete coverage to the active search. |
| Preview and cloud files | [ItemPreview.swift](../app/Sources/ExplorerApp/ItemPreview.swift), [PhysicalFileHydration.swift](../app/Sources/ExplorerCore/PhysicalFileHydration.swift), [OneDriveRetention.swift](../app/Sources/ExplorerCore/OneDriveRetention.swift) | Coordinate content reads and explicit downloads. For OneDrive, pin policy and whether bytes are local are separate observations. A successful unpin can precede removal of the local copy. |

## Runtime boundaries

Each window's store owns its tabs, selection and pending UI work. Asynchronous results must still belong to the captured tab, location and intent before they change the display. Cancelling a task does not prove that a blocking filesystem or provider call has stopped. [BlockingIO.swift](../app/Sources/ExplorerCore/BlockingIO.swift) keeps that work off the UI actor and bounds its worker lanes.

Command availability uses captured row metadata. Core operations revalidate physical identities and routes before acting; a row URL alone does not authorize a write. ZIP members have archive locations and revision checks instead of physical-entry authority.

Preview and materialized ZIP content use content leases. A preview detaches its renderer before releasing the lease. [ContentLeaseRegistry.swift](../app/Sources/ExplorerCore/ContentLeaseRegistry.swift) accounts for owned temporary ZIP content; clipboard exports and external-open copies can be retained when another consumer may still need them or cleanup is unsafe. Downloading a physical cloud file does not pin it or turn its borrowed content into a temporary file to delete.

[OneDriveBadgeCache.swift](../app/Sources/ExplorerApp/OneDriveBadgeCache.swift) shares bounded read-only policy queries across visible rows. Retention commands invalidate earlier observations. A fresh result can confirm a deferred Free Up Space notice only while the original selected version and notice still belong to that request; a new selection or command supersedes it.

## Tests and validation

Swift tests are split between [core behavior](../app/Tests/ExplorerCoreTests) and [application interactions](../app/Tests/ExplorerAppTests). Use [Contributing](../CONTRIBUTING.md) for build and test commands. Component tests and on-screen behavior need their own evidence, particularly for Finder, OneDrive and accessibility integration.
