import AppKit
import ExplorerCore
import SwiftUI

typealias HomeTagSnapshots = (FinderTagScope) -> AsyncThrowingStream<FinderTagsSnapshot, Error>

/// The same folder collection feeds both the Home grid and the sidebar.
@MainActor
struct ExplorerHomeView: View {
    @ObservedObject var store: ExplorerStore
    let page: BrowserPage
    private let tagSnapshots: HomeTagSnapshots
    @StateObject private var keyboard = HomeResultKeyboardFocus()
    @ObservedObject private var pins: PinnedFolderStore
    @ObservedObject private var recent: RecentDocumentStore
    @ObservedObject private var sidebar: SidebarModel

    init(store: ExplorerStore, page: BrowserPage,
         tagSnapshots: @escaping HomeTagSnapshots = { FinderTagsProvider().snapshots(for: $0) }) {
        self.tagSnapshots = tagSnapshots
        self.store = store
        self.page = page
        pins = store.pins
        recent = store.recentDocuments
        sidebar = store.sidebarModel
    }

    var body: some View {
        if page == .thisMac { scrollingPage }
        else { HomeFileDropSurface(store: store, content: scrollingPage) }
    }

    private var scrollingPage: some View {
        ScrollViewReader { reader in
            content.onChange(of: keyboard.request) { _, request in
                if let request, store.homeResultScope == request.scope { reader.scrollTo(request.id) }
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18.pt) {
                switch page {
                case .home, .tag:
                    title("Quick access")
                    if pins.entries.isEmpty {
                        message("No pinned folders")
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180.pt), spacing: 12.pt)], alignment: .leading) {
                            ForEach(pins.entries.filter { store.matchesPageFilter($0.title) }) { pin in
                                item(name: pin.title, url: pin.url, folder: true, symbol: pin.symbol,
                                     identifier: "home-pin", pinKey: pin.id, tile: true)
                            }
                        }
                    }
                    Divider()
                    HStack(spacing: 8.pt) {
                        sectionButton("Recent", symbol: "clock", section: .recent, id: "home-recent")
                        sectionButton("Tags", symbol: "tag", section: .tags, id: "home-tags")
                    }
                    if let scope = store.homeResultScope {
                        if scope.section == .tags {
                            tags(in: scope)
                        } else {
                            recentResults(in: scope)
                        }
                    }
                case .thisMac:
                    title("Devices and drives")
                    let volumes = sidebar.volumes.filter { store.matchesPageFilter($0.title) }
                    if volumes.isEmpty { message("No matching volumes") }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180.pt), spacing: 12.pt)], alignment: .leading) {
                        ForEach(volumes) { volume in
                            item(name: volume.title, url: volume.url, folder: true, symbol: volume.symbol,
                                 identifier: "this-mac-volume", tile: true)
                        }
                    }
                }
            }
            .padding(22.pt)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(page == .thisMac ? "this-mac-page" : "home-page")
    }

    private func title(_ value: String) -> some View {
        Text(value).font(.system(size: 15.pt, weight: .semibold)).accessibilityAddTraits(.isHeader)
    }

    private func message(_ value: String) -> some View {
        Text(value).foregroundStyle(.secondary).font(.system(size: 12.pt))
    }

    private func sectionButton(_ text: String, symbol: String, section: HomeSection, id: String) -> some View {
        let selected = store.activeTab.homeSection == section
        return Button { store.selectHomeSection(section) } label: {
            Label(text, systemImage: symbol)
                .padding(.horizontal, 11.pt).padding(.vertical, 5.pt)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor), in: Capsule())
        }
        .buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    private struct RecentDelivery: Equatable {
        let scope: HomeResultScope
        let rows: [HomeResultRow]?
    }

    private func recentResults(in scope: HomeResultScope) -> some View {
        let rows = recent.entries.filter { store.matchesPageFilter($0.url.lastPathComponent) }
            .map { HomeResultRow(recent: $0) }
        let unsettled = rows.isEmpty && recent.entries.isEmpty
            && (recent.systemStatus == .loading || recent.systemStatus == .unavailable)
        let delivery = RecentDelivery(scope: scope, rows: unsettled ? nil : rows)
        let displayed = delivery.rows ?? (store.activeTab.homeResults.scope == scope ? store.activeTab.homeResults.rows : [])
        return VStack(alignment: .leading, spacing: 3.pt) {
            if displayed.isEmpty && recent.systemStatus == .loading {
                ProgressView("Loading recent files…").controlSize(.small)
            } else if displayed.isEmpty {
                message(scope.filter.isEmpty ? "No recent files" : "No matching recent files")
            }
            if recent.systemStatus == .unavailable { message("Recent activity from other apps is unavailable.") }
            LazyVStack(alignment: .leading, spacing: 3.pt) {
                ForEach(displayed) { row in
                    HomeSelectableResult(store: store, row: row, scope: scope, revision: nil, keyboard: keyboard)
                        .id(row.id)
                }
            }
        }
        .overlay(alignment: .topLeading) { HomeDropBoundary().frame(width: 1, height: 1).allowsHitTesting(false) }
        .onChange(of: delivery, initial: true) { _, next in
            if let rows = next.rows { store.replaceHomeResults(rows, in: next.scope) }
        }
        .task { await recent.observeSystemRecents() }
    }

    private func tags(in scope: HomeResultScope) -> some View {
        FinderTagCollection(store: store, origin: scope, tag: store.activeTab.homeTag, shortcuts: store.tagShortcuts,
                            choose: store.selectHomeTag, snapshots: tagSnapshots, result: { row, revision in
            HomeSelectableResult(store: store, row: row, scope: scope, revision: revision, keyboard: keyboard)
                .id(row.id)
        })
        .id(TagQueryScope(tab: store.activeTabID, page: page, epoch: store.contextMenuLoadGeneration))
    }

    private struct TagQueryScope: Hashable {
        let tab: UUID
        let page: BrowserPage
        let epoch: UUID?
    }

    private func item(name: String, url: URL, folder: Bool, symbol: String, identifier: String,
                      pinKey: String? = nil, tile: Bool = false) -> some View {
        let binding = HomeRowBinding(url: url, tab: store.activeTabID, page: page,
                                     epoch: store.contextMenuLoadGeneration, filter: store.activeTab.homeTagGeneration)
        func stillRepresentsRow() -> Bool {
            store.activeTabID == binding.tab && store.activePage == binding.page
                && store.contextMenuLoadGeneration == binding.epoch && store.activeTab.homeTagGeneration == binding.filter
                && store.matchesPageFilter(name)
        }
        return HomeItemRow(name: name, url: url, folder: folder, symbol: symbol, identifier: identifier,
                           tile: tile, pinned: pins.contains(url)) { action, identity in
            guard stillRepresentsRow() else { return }
            store.performPageAction(action, url: url, folder: folder, pinKey: pinKey,
                                    representedIdentity: identity)
        }
        .id(binding)
    }

    private struct HomeRowBinding: Hashable {
        let url: URL
        let tab: UUID
        let page: BrowserPage
        let epoch: UUID?
        let filter: UUID
    }
}

@MainActor
private final class HomeRowIdentity: ObservableObject {
    @Published var sampled: LocalFileIdentity?
}

@MainActor
private struct HomeItemRow: View {
    let name: String
    let url: URL
    let folder: Bool
    let symbol: String
    let identifier: String
    let tile: Bool
    let pinned: Bool
    let perform: (ExplorerStore.PageItemAction, LocalFileIdentity?) -> Void
    @StateObject private var identityState = HomeRowIdentity()

    var body: some View {
        let identity = identityState.sampled
        let canEditTags = identifier != "this-mac-volume"
        Button { perform(.open, identity) } label: {
            HomeItemLabel(name: name, url: url, folder: folder, symbol: symbol, tile: tile)
        }
        .buttonStyle(ChromeButtonStyle())
        .accessibilityLabel(name).accessibilityHint(url.path).accessibilityIdentifier(identifier)
        .contextMenu {
            Button("Open") { perform(.open, identity) }
            if folder {
                Button("Open in New Tab") { perform(.newTab, identity) }
                Button("Open in New Window") { perform(.newWindow, identity) }
                Button(pinned ? "Unpin from Quick access" : "Pin to Quick access") { perform(.togglePin, identity) }
            }
            if canEditTags {
                Button("Tags…") { perform(.editTags, identity) }.disabled(identity == nil)
            }
            Button("Show in Finder") { perform(.reveal, identity) }
            Button("Copy Pathname") { perform(.copyPath, identity) }
        }
        .task {
            guard canEditTags else { return }
            let value = try? await FinderTagFile.identity(at: url)
            if !Task.isCancelled { identityState.sampled = value }
        }
    }
}

struct HomeItemLabel: View {
    let name: String
    let url: URL
    let folder: Bool
    let symbol: String
    let tile: Bool

    var body: some View {
        HStack(spacing: 10.pt) {
            Image(systemName: symbol)
                .font(.system(size: tile ? 23.pt : 16.pt))
                .foregroundStyle(folder ? Color.accentColor : Color.secondary)
                .frame(width: tile ? 32.pt : 22.pt)
            VStack(alignment: .leading, spacing: 3.pt) {
                Text(name).lineLimit(1).truncationMode(.middle)
                Text(url.path).font(.system(size: 10.pt)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(6.pt).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

@MainActor
private final class FinderTagPickerState: ObservableObject {
    @Published var more = false
    @Published var search = ""
}

@MainActor
private struct FinderTagCollection<ResultRow: View>: View {
    @ObservedObject var store: ExplorerStore
    let origin: HomeResultScope
    let tag: String?
    @ObservedObject var shortcuts: FinderTagShortcuts
    let choose: (String?) -> Void
    let snapshots: HomeTagSnapshots
    @ViewBuilder let result: (HomeResultRow, UUID) -> ResultRow
    @StateObject private var pickerState = FinderTagPickerState()
    @StateObject private var catalog = FinderTagCatalogState()

    var body: some View {
        VStack(alignment: .leading, spacing: 9.pt) {
            TagFilterLayout(spacing: 6.pt) {
                if shortcuts.showsAllTagged {
                    chip("All tagged", value: nil, id: "home-tag-all")
                }
                ForEach(shortcuts.names, id: \.self) { name in
                    chip(name, value: name, id: "home-tag-choice")
                }
                Button {
                    pickerState.search = ""
                    pickerState.more = true
                    catalog.refreshRequest = UUID()
                } label: {
                    Label("More tags", systemImage: "chevron.down").lineLimit(1)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("More tags").accessibilityIdentifier("home-tag-more")
                .popover(isPresented: $pickerState.more, arrowEdge: .bottom) { picker }
            }
            if let tag, !shortcuts.isVisible(tag) {
                Button("Clear filter") { choose(nil) }.accessibilityIdentifier("home-tag-clear-filter")
            }
            let scope = shortcuts.scope(for: tag)
            VStack(alignment: .leading, spacing: 0) {
                if scope == .selected([]) {
                    Text("Choose tags in More tags to see their files here.")
                        .foregroundStyle(.secondary).accessibilityIdentifier("home-tag-empty-selection")
                        .onChange(of: origin, initial: true) { _, next in store.replaceHomeResults([], in: next) }
                } else {
                    FinderTagResults(store: store, origin: origin, scope: scope, catalog: catalog, snapshots: snapshots, result: result)
                        .id(scope)
                }
            }
            .overlay(alignment: .topLeading) { HomeDropBoundary().frame(width: 1, height: 1).allowsHitTesting(false) }
        }
        .task { await catalog.observeIndex() }
        .task(id: catalog.refreshRequest) { await catalog.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            catalog.refreshRequest = UUID()
        }
    }

    private func chip(_ name: String, value: String?, id: String) -> some View {
        let selected = tag == value
        let index = value.flatMap { catalog.labelIndex(for: $0) }
        let hint = value == nil ? "Show every tagged item" : FinderTagMark.description(for: index)
        return Button { choose(value) } label: {
            HStack(spacing: 5.pt) {
                if value != nil {
                    FinderTagMark(index: index).accessibilityHidden(true)
                } else {
                    Image(systemName: selected ? "checkmark" : "square.stack").accessibilityHidden(true)
                }
                Text(name).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 9.pt).padding(.vertical, 4.pt)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor), in: Capsule())
        }
        .buttonStyle(.plain).help(hint).accessibilityLabel(name).accessibilityHint(hint)
        .accessibilityAddTraits(selected ? .isSelected : []).accessibilityIdentifier(id)
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 7.pt) {
            TextField("Search tags", text: $pickerState.search)
                .accessibilityLabel("Search tags").accessibilityIdentifier("home-tag-search")
            if let message = catalog.availabilityMessage { Text(message).foregroundStyle(.secondary) }
            let names = catalog.optionNames(including: shortcuts.names)
            let filtered = pickerState.search.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(pickerState.search) }
            let includeAll = pickerState.search.isEmpty || "All tagged".localizedCaseInsensitiveContains(pickerState.search)
            if filtered.isEmpty {
                if catalog.isLoading {
                    ProgressView("Loading Finder tags…").controlSize(.small)
                } else if pickerState.search.isEmpty || !includeAll {
                    Text("No matching Finder tags").foregroundStyle(.secondary)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2.pt) {
                    if includeAll { pickerOption(nil) }
                    ForEach(filtered, id: \.self) { name in
                        pickerOption(name)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { pickerState.more = false }.accessibilityIdentifier("home-tag-done")
            }
        }
        .padding(10.pt).frame(width: 260.pt, height: 230.pt)
        .onExitCommand { pickerState.more = false }
    }

    private func pickerOption(_ tag: String?) -> some View {
        let label = tag ?? "All tagged"
        let index = tag.flatMap { catalog.labelIndex(for: $0) }
        let hint = tag == nil ? "Show every tagged item" : FinderTagMark.description(for: index)
        let checked = Binding<Bool>(
            get: { tag.map(shortcuts.isVisible) ?? shortcuts.showsAllTagged },
            set: { value in
                if let tag { shortcuts.setVisible(tag, visible: value) }
                else { shortcuts.setShowsAllTagged(value) }
            }
        )
        return Toggle(isOn: checked) {
            HStack(spacing: 6.pt) {
                if tag == nil { Image(systemName: "square.stack").accessibilityHidden(true) }
                else { FinderTagMark(index: index).accessibilityHidden(true) }
                Text(label).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .toggleStyle(.checkbox).padding(.vertical, 2.pt).help(hint)
        .accessibilityLabel(label).accessibilityHint(hint)
        .accessibilityIdentifier(tag == nil ? "home-tag-option-all" : "home-tag-option")
    }
}

@MainActor
private final class FinderTagResultState: ObservableObject {
    @Published var revision = UUID()
    @Published var failure: String?
}

@MainActor
private struct FinderTagResults<ResultRow: View>: View {
    @ObservedObject var store: ExplorerStore
    let origin: HomeResultScope
    let scope: FinderTagScope
    @ObservedObject var catalog: FinderTagCatalogState
    let snapshots: HomeTagSnapshots
    @ViewBuilder let result: (HomeResultRow, UUID) -> ResultRow
    @StateObject private var state = FinderTagResultState()

    var body: some View {
        VStack(alignment: .leading, spacing: 3.pt) {
            if let failure = state.failure {
                Text(failure).foregroundStyle(.secondary)
            }
            if let snapshot = store.homeTagSnapshot, store.activeTab.homeResults.scope == origin {
                if snapshot.hasMoreItems {
                    Text("Showing the first \(FinderTagsSnapshot.previewLimit) tagged items. Some groups and files may be missing. Choose a tag to see all its matches.")
                        .foregroundStyle(.secondary).accessibilityIdentifier("home-tag-limit")
                }
                let groups = Dictionary(grouping: store.activeTab.homeResults.rows) { $0.group ?? "" }
                let names = FinderTagsSnapshot.tagNames(from: Array(scope.selectedNames ?? Set(groups.keys)))
                if names.isEmpty { Text("No matching tagged items").foregroundStyle(.secondary) }
                LazyVStack(alignment: .leading, spacing: 3.pt) {
                    ForEach(names, id: \.self) { name in
                        let rows = groups[name] ?? []
                        Section {
                            ForEach(rows) { row in result(row, state.revision) }
                            if rows.isEmpty { Text("No matching tagged items").foregroundStyle(.secondary) }
                        } header: {
                            let index = catalog.labelIndex(for: name)
                            let color = FinderTagMark.description(for: index)
                            HStack(spacing: 6.pt) {
                                FinderTagMark(index: index).accessibilityHidden(true)
                                Text(name).font(.system(size: 13.pt, weight: .semibold))
                            }
                            .padding(.top, 6.pt).help(color)
                            .accessibilityElement(children: .ignore).accessibilityLabel(name)
                            .accessibilityHint(color).accessibilityAddTraits(.isHeader).accessibilityIdentifier("home-tag-group")
                        }
                    }
                }
            } else if state.failure == nil {
                ProgressView("Loading tagged items…").controlSize(.small)
            }
        }
        .onChange(of: origin, initial: true) { _, next in
            if let retained = store.homeTagSnapshot { store.replaceHomeTagSnapshot(retained, in: next) }
        }
        .task {
            do {
                for try await update in snapshots(scope) {
                    guard !Task.isCancelled else { return }
                    guard let current = store.homeResultScope, current.hasSameCollection(as: origin),
                          current.epoch == origin.epoch else { return }
                    store.replaceHomeTagSnapshot(update, in: current)
                    state.revision = UUID()
                }
            } catch {
                if !Task.isCancelled { state.failure = error.localizedDescription }
            }
        }
    }
}
