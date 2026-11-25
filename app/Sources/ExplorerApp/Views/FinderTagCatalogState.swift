import AppKit
import SwiftUI

/// The configured list can refresh while Spotlight continues reporting live file memberships.
@MainActor
final class FinderTagCatalogState: ObservableObject {
    @Published var refreshRequest = UUID()
    @Published private var catalog: FinderTagCatalog?
    @Published private var indexed: FinderTagsSnapshot?
    @Published private var indexUnavailable = false
    private var refreshGeneration = UUID()

    var isLoading: Bool { catalog == nil && indexed == nil && !indexUnavailable }

    var availabilityMessage: String? {
        if catalog?.isAvailable == false && indexUnavailable {
            return "Finder’s tag list and Spotlight are unavailable."
        }
        if catalog?.isAvailable == false { return "Finder’s configured tag list is unavailable." }
        if indexUnavailable { return "Tags from Spotlight are unavailable." }
        return nil
    }

    func optionNames(including choices: [String] = []) -> [String] {
        FinderTagsSnapshot.tagNames(from: [catalog?.configuredNames ?? [], indexed?.names ?? [], choices])
    }

    func labelIndex(for name: String) -> Int? {
        if let catalog, catalog.isAvailable, catalog.contains(name) {
            return catalog.labelIndex(for: name)
        }
        return indexed?.indexedColorHints[name] ?? catalog?.labelIndex(for: name)
    }

    func refresh() async {
        let generation = UUID()
        refreshGeneration = generation
        let next = await FinderTagCatalog.load()
        guard !Task.isCancelled, refreshGeneration == generation else { return }
        catalog = next
    }

    func observeIndex() async {
        do {
            for try await snapshot in FinderTagsProvider().snapshots(for: .names) {
                guard !Task.isCancelled else { return }
                indexed = snapshot
                indexUnavailable = false
            }
        } catch {
            if !Task.isCancelled { indexUnavailable = true }
        }
    }
}

struct FinderTagMark: View {
    let index: Int?
    @MainActor private static let palette = NSWorkspace.shared.fileLabelColors

    static func description(for index: Int?) -> String {
        switch index {
        case 0: "No Color"
        case 1: "Gray"
        case 2: "Green"
        case 3: "Purple"
        case 4: "Blue"
        case 5: "Yellow"
        case 6: "Red"
        case 7: "Orange"
        default: "Color unavailable"
        }
    }

    var body: some View {
        Group {
            if let index, (1...7).contains(index), Self.palette.indices.contains(index) {
                Circle().fill(Color(nsColor: Self.palette[index]))
            } else if index == 0 {
                Circle().strokeBorder(.secondary, lineWidth: 1.25.pt)
            } else {
                Image(systemName: "tag").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .frame(width: 11.pt, height: 11.pt)
        .accessibilityHidden(true)
    }
}
