import Darwin
import Foundation

/// An error classification, not a diagnosis of TCC, ACLs, ownership, file flags,
/// or Full Disk Access state. Classification never probes another filesystem path.
public enum FileAccessFailure: Equatable, Sendable {
    case permissionDenied
    case readOnlyVolume

    public static func classify(_ error: Error) -> FileAccessFailure? {
        var result: FileAccessFailure?
        for (cause, native) in causes(error) {
            if let operation = cause as? FileOperationError,
               case .systemFailure(_, let code) = operation {
                result = preferred(result, posix(code))
            }
            if let transfer = cause as? FileTransferError,
               case .cleanupFailed(_, _, let failure) = transfer {
                result = preferred(result, failure)
            }
            if let recovery = cause as? FileRecoveryError,
               case .outcomeUncertain(_, let failure) = recovery {
                result = preferred(result, failure)
            }
            if let replacement = cause as? ReplacementTrashError {
                result = preferred(result, replacement.accessFailure)
            }
            if let replacement = cause as? ReplacementRecoveryError {
                result = preferred(result, replacement.accessFailure)
            }
            if native.domain == NSPOSIXErrorDomain, let code = Int32(exactly: native.code) {
                result = preferred(result, posix(code))
            } else if native.domain == NSCocoaErrorDomain {
                switch native.code {
                case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                    result = preferred(result, .permissionDenied)
                case NSFileWriteVolumeReadOnlyError:
                    result = .readOnlyVolume
                default: break
                }
            }
        }
        return result
    }

    /// A specific read-only cause wins over a wrapper's generic access denial.
    static func preferred(_ lhs: Self?, _ rhs: Self?) -> Self? {
        if lhs == .readOnlyVolume || rhs == .readOnlyVolume { return .readOnlyVolume }
        return lhs ?? rhs
    }

    static func isMissingLocation(_ error: Error) -> Bool {
        // A mixed/native wrapper carrying a real access failure must remain an
        // access failure, rather than being translated into a stale location.
        guard classify(error) == nil else { return false }
        return causes(error).contains { cause, native in
            if let operation = cause as? FileOperationError,
               case .systemFailure(_, let code) = operation, code == ENOENT || code == ENOTDIR { return true }
            return (native.domain == NSPOSIXErrorDomain && [Int(ENOENT), Int(ENOTDIR)].contains(native.code))
                || (native.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(native.code))
        }
    }

    private static func posix(_ code: Int32) -> Self? {
        switch code {
        case EACCES, EPERM: return .permissionDenied
        case EROFS: return .readOnlyVolume
        default: return nil
        }
    }

    private static func causes(_ error: Error) -> [(Error, NSError)] {
        var pending: [Error] = [error]
        var visited: Set<ObjectIdentifier> = []
        var result: [(Error, NSError)] = []
        // Retaining the bridged NSError alongside the Swift value keeps object
        // identities stable even for Swift errors bridged on demand.
        while result.count < 16, let current = pending.popLast() {
            let native = current as NSError
            guard visited.insert(ObjectIdentifier(native)).inserted else { continue }
            result.append((current, native))
            let info = native.userInfo
            if let underlying = info[NSUnderlyingErrorKey] as? Error { pending.append(underlying) }
            if let multiple = info[NSMultipleUnderlyingErrorsKey] as? [Error] {
                pending.append(contentsOf: multiple.prefix(max(0, 16 - pending.count)))
            }
        }
        return result
    }
}
