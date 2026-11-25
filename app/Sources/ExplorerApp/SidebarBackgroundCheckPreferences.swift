import Combine
import CoreFoundation
import ExplorerCore
import Foundation

enum SidebarBackgroundCheck: String, CaseIterable {
    case protectedLocal
    case cloud
    case network

    var key: String { "nativeExplorer.sidebarBackgroundChecks." + rawValue }

    var title: String {
        switch self {
        case .protectedLocal: return "Unopened Protected Folders"
        case .cloud: return "Cloud Folders"
        case .network: return "Mounted Network Folders"
        }
    }

    var help: String {
        let scope: String
        switch self {
        case .protectedLocal:
            scope = "Visible Favorites such as Desktop, Documents, Downloads, Pictures, Music and Movies may be checked before you open them."
        case .cloud:
            scope = "Checks may request directory listings from your provider. Online-only entries stay deferred."
        case .network:
            scope = "Checks may contact supported shares that are already mounted."
        }
        return scope + " macOS may ask for access. Denying access can also restrict normal browsing until you change it in System Settings. Turning this off cannot dismiss a prompt already displayed."
    }

    func isEnabled(in options: SidebarBackgroundCheckOptions) -> Bool {
        switch self {
        case .protectedLocal: return options.protectedLocal
        case .cloud: return options.cloud
        case .network: return options.network
        }
    }
}

@MainActor
final class SidebarBackgroundCheckPreferences: ObservableObject {
    @Published private(set) var options: SidebarBackgroundCheckOptions
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        func read(_ check: SidebarBackgroundCheck) -> Bool {
            Self.booleanValue(defaults?.object(forKey: check.key)) ?? false
        }
        options = SidebarBackgroundCheckOptions(protectedLocal: read(.protectedLocal),
                                                cloud: read(.cloud), network: read(.network))
    }

    func set(_ check: SidebarBackgroundCheck, enabled: Bool) {
        guard check.isEnabled(in: options) != enabled else { return }
        if let defaults {
            let key = check.key
            // UserDefaults can retain numeric 1 when it compares equal to true.
            // Remove a malformed value before replacing it with a Boolean.
            if let existing = defaults.object(forKey: key), Self.booleanValue(existing) == nil {
                defaults.removeObject(forKey: key)
            }
            defaults.set(enabled, forKey: key)
        }
        options = SidebarBackgroundCheckOptions(
            protectedLocal: check == .protectedLocal ? enabled : options.protectedLocal,
            cloud: check == .cloud ? enabled : options.cloud,
            network: check == .network ? enabled : options.network
        )
    }

    private static func booleanValue(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
