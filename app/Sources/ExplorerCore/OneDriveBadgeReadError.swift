import FileProvider
import Foundation

/// Failures of a read-only keep-policy query. Only errors with evidence of a
/// wider scope should delay work on other items.
public enum OneDriveBadgeReadError: Error, Equatable, Sendable {
    case busy, staleTarget, itemUnavailable, itemRejected, incompatibleResponse
    case accountUnavailable, installationUntrusted, timedOut

    static func classify(_ error: Error) -> Self {
        if let typed = error as? Self { return typed }
        if let retention = error as? OneDriveRetentionError {
            switch retention {
            case .busy: return .busy
            case .staleTarget: return .staleTarget
            case .untrustedApplication: return .installationUntrusted
            case .timedOut: return .timedOut
            case .providerRejected, .unsupportedTarget: return .itemRejected
            default: return .itemUnavailable
            }
        }
        if let file = error as? FileOperationError,
           file == .staleParent || file == .staleSource { return .staleTarget }
        if FileAccessFailure.isMissingLocation(error) { return .staleTarget }
        let ns = error as NSError
        if ns.domain == NSFileProviderErrorDomain,
           ns.code == NSFileProviderError.Code.notAuthenticated.rawValue
            || ns.code == NSFileProviderError.Code.serverUnreachable.rawValue { return .accountUnavailable }
        return .itemUnavailable
    }
}
