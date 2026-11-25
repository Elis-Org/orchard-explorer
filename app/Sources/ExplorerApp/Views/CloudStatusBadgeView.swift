import AppKit
import ExplorerCore

/// The small badge primarily describes the contents of this visible file. Keep
/// policy, including its age or verification failure, is independently accessible.
enum CloudStatusPresentation: Equatable {
    enum Keep: Equatable {
        case unchecked
        case confirmed(OneDriveRetentionPolicy)
        case lastKnown(OneDriveRetentionPolicy)
        case targetChanged(previous: OneDriveRetentionPolicy?, repeated: Bool)
        case unavailable(lastKnown: OneDriveRetentionPolicy?, reason: OneDriveBadgeReadError?)
    }
    case onlineOnly, availableLocally, downloading
    case oneDrive(FileAvailability, Keep)

    /// Search enumeration skips expensive cloud membership metadata. A lexical
    /// OneDrive candidate still gets a visible, guarded read. A path alone (or
    /// a rejected read) has no artwork to show on a same-named unmanaged root.
    static func forItem(_ item: FileItem, isDownloading: Bool = false,
                        snapshot: OneDriveStatusSnapshot? = nil) -> Self? {
        let evidence = item.availability != .unknown || snapshot?.policy != nil
            || snapshot.map { $0.availability != .unknown } == true
        return Self(availability: item.availability, isDownloading: isDownloading,
                    oneDriveCandidate: evidence && OneDriveRetentionService.isBadgeCandidate(item),
                    snapshot: snapshot)
    }

    init?(availability: FileAvailability, isDownloading: Bool = false,
          oneDriveCandidate: Bool = false, observation: OneDriveBadgeObservation? = nil,
          snapshot: OneDriveStatusSnapshot? = nil) {
        if isDownloading { self = .downloading; return }
        guard oneDriveCandidate else {
            switch availability {
            case .unknown: return nil
            case .onlineOnly: self = .onlineOnly
            case .availableLocally: self = .availableLocally
            }
            return
        }
        if let snapshot {
            let keep: Keep
            if snapshot.failureReason == .staleTarget {
                keep = .targetChanged(previous: snapshot.policy, repeated: snapshot.repeatedTargetRefusal)
            } else if snapshot.freshness == .unavailable {
                keep = .unavailable(lastKnown: snapshot.policy, reason: snapshot.failureReason)
            } else if let policy = snapshot.policy {
                keep = snapshot.freshness == .fresh ? .confirmed(policy) : .lastKnown(policy)
            } else { keep = .unchecked }
            self = .oneDrive(snapshot.availability, keep)
        } else if let observation {
            self = .oneDrive(observation.isDataless ? .onlineOnly : .availableLocally, .confirmed(observation.policy))
        } else { self = .oneDrive(availability, .unchecked) }
    }

    func help(checkedAt: Date?) -> String {
        guard let checkedAt else { return label }
        return label + "\nKeep status checked "
            + DateFormatter.localizedString(from: checkedAt, dateStyle: .medium, timeStyle: .medium)
    }

    var label: String {
        switch self {
        case .onlineOnly: return "Online-only"
        case .availableLocally: return "Available locally"
        case .downloading: return "Downloading"
        case let .oneDrive(availability, keep):
            let residency: String
            switch availability {
            case .availableLocally: residency = "Available locally."
            case .onlineOnly: residency = "Visible contents online-only."
            case .unknown: residency = "Local availability unknown."
            }
            switch keep {
            case .unchecked: return residency + " Keep status not yet checked."
            case .confirmed(.pinned):
                return (availability == .availableLocally ? "Always keep on this device. " : "Always keep enabled. ") + residency
            case .confirmed: return residency + " Always keep is off."
            case .lastKnown(let policy):
                return residency + (policy == .pinned ? " Last known: Always keep enabled." : "") + " Keep status needs checking."
            case let .targetChanged(previous, repeated):
                return residency + (previous == .pinned ? " Last known: Always keep enabled." : "")
                    + (repeated ? " Keep status verification unavailable. The file changed again during verification."
                                : " Keep status needs checking. The file changed during verification.")
            case let .unavailable(lastKnown, reason):
                let message = residency + (lastKnown == .pinned ? " Last known: Always keep enabled." : "")
                    + " Keep status verification unavailable."
                guard let reason else { return message }
                return message + " " + reason.badgeDescription
            }
        }
    }
}

private extension OneDriveBadgeReadError {
    var badgeDescription: String {
        switch self {
        case .busy: return "OneDrive is busy."
        case .staleTarget: return "The file changed during verification."
        case .itemUnavailable: return "The file could not be inspected."
        case .itemRejected: return "OneDrive could not verify this file."
        case .incompatibleResponse: return "OneDrive returned an unrecognized response."
        case .accountUnavailable: return "The OneDrive account is unavailable."
        case .installationUntrusted: return "The OneDrive installation could not be verified."
        case .timedOut: return "OneDrive did not respond in time."
        }
    }
}

/// Noninteractive: selection, renaming and drag handling remain with the row.
final class CloudStatusBadgeView: NSView {
    private let legacyLocalImage = NSImageView()
    private let progress = NSProgressIndicator()
    private(set) var presentation: CloudStatusPresentation?

    init() {
        super.init(frame: .zero)
        legacyLocalImage.imageScaling = .scaleProportionallyUpOrDown
        legacyLocalImage.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        legacyLocalImage.contentTintColor = .systemGreen
        legacyLocalImage.setAccessibilityElement(false)
        legacyLocalImage.unregisterDraggedTypes()
        addSubview(legacyLocalImage)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isIndeterminate = true
        progress.isDisplayedWhenStopped = false
        progress.setAccessibilityElement(false)
        addSubview(progress)
        setAccessibilityElement(false)
        configure(nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        legacyLocalImage.frame = bounds
        progress.frame = bounds
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    func configure(_ value: CloudStatusPresentation?) {
        presentation = value
        isHidden = value == nil
        toolTip = value?.label
        legacyLocalImage.isHidden = value != .availableLocally
        progress.isHidden = value != .downloading
        if value == .downloading { progress.startAnimation(nil) }
        else { progress.stopAnimation(nil) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let presentation, presentation != .availableLocally,
              presentation != .downloading else { return }
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.translateBy(x: bounds.midX - side / 2, y: bounds.midY - side / 2)
        context.scaleBy(x: side / 16, y: side / 16)
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // Confirmed OneDrive tick/disk pairs exceed 3:1 contrast in both appearances.
        // Unrelated local availability retains its original system symbol above.
        let green = dark ? NSColor(srgbRed: 0.04, green: 0.43, blue: 0.20, alpha: 1)
            : NSColor(srgbRed: 0.02, green: 0.44, blue: 0.19, alpha: 1)
        let pale = dark ? NSColor(srgbRed: 0.88, green: 0.96, blue: 0.90, alpha: 1)
            : NSColor(srgbRed: 0.96, green: 0.99, blue: 0.96, alpha: 1)
        // Keep the visible residency underneath a compact pin qualifier. Only a
        // current, resident pin gets the filled disk. The clock means last known.
        let availability: FileAvailability
        var currentPin = false, previousPin = false
        switch presentation {
        case .onlineOnly: availability = .onlineOnly
        case let .oneDrive(value, keep):
            availability = value
            switch keep {
            case .confirmed(.pinned): currentPin = true
            case .lastKnown(.pinned), .targetChanged(previous: .pinned, repeated: _),
                 .unavailable(lastKnown: .pinned, reason: _): previousPin = true
            default: break
            }
        case .availableLocally, .downloading: return
        }
        let hasQualifier = previousPin || (currentPin && availability != .availableLocally)
        NSGraphicsContext.saveGraphicsState()
        if hasQualifier {
            context.translateBy(x: 0, y: 4)
            context.scaleBy(x: 0.78, y: 0.78)
        }
        switch availability {
        case .onlineOnly:
            let cloud = NSBezierPath()
            cloud.move(to: NSPoint(x: 4, y: 4))
            cloud.curve(to: NSPoint(x: 3.5, y: 10), controlPoint1: NSPoint(x: 0, y: 4), controlPoint2: NSPoint(x: 0, y: 9.5))
            cloud.curve(to: NSPoint(x: 11.5, y: 10), controlPoint1: NSPoint(x: 4, y: 15), controlPoint2: NSPoint(x: 10.5, y: 15))
            cloud.curve(to: NSPoint(x: 12, y: 4), controlPoint1: NSPoint(x: 16, y: 11), controlPoint2: NSPoint(x: 16, y: 4))
            cloud.close()
            (dark ? NSColor(srgbRed: 0.32, green: 0.67, blue: 1, alpha: 1)
                : NSColor(srgbRed: 0.02, green: 0.35, blue: 0.78, alpha: 1)).setStroke()
            cloud.lineWidth = 1.5; cloud.stroke()
        case .availableLocally:
            let disk = NSBezierPath(ovalIn: NSRect(x: 1.1, y: 1.1, width: 13.8, height: 13.8))
            pale.setFill(); disk.fill()
            if currentPin {
                green.setFill()
                NSBezierPath(ovalIn: NSRect(x: 1.8, y: 1.8, width: 12.4, height: 12.4)).fill()
            } else {
                green.setStroke(); disk.lineWidth = 1.35; disk.stroke()
            }
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: 4.4, y: 7.8))
            tick.line(to: NSPoint(x: 7, y: 5.2))
            tick.line(to: NSPoint(x: 11.8, y: 10.7))
            tick.lineWidth = 1.65; tick.lineCapStyle = .round; tick.lineJoinStyle = .round
            (currentPin ? NSColor.white : green).setStroke(); tick.stroke()
        case .unknown:
            if currentPin {
                drawPin(in: NSRect(x: 2, y: 1, width: 12, height: 14))
            } else {
                drawQuestion(in: NSRect(x: 4, y: 2, width: 8, height: 12))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if previousPin {
            let clock = NSBezierPath(ovalIn: NSRect(x: 9, y: 0.75, width: 6.1, height: 6.1))
            NSColor.controlBackgroundColor.setFill(); clock.fill()
            NSColor.labelColor.setStroke(); clock.lineWidth = 1; clock.stroke()
            let hands = NSBezierPath()
            hands.move(to: NSPoint(x: 12, y: 5.6))
            hands.line(to: NSPoint(x: 12, y: 3.7))
            hands.line(to: NSPoint(x: 13.7, y: 3))
            hands.lineWidth = 0.95; hands.stroke()
        } else if currentPin && availability == .unknown {
            let backing = NSBezierPath(ovalIn: NSRect(x: 7.8, y: 0.6, width: 7.7, height: 7.7))
            NSColor.controlBackgroundColor.setFill(); backing.fill()
            NSColor.labelColor.setStroke(); backing.lineWidth = 1; backing.stroke()
            drawQuestion(in: NSRect(x: 9.8, y: 1.7, width: 3.8, height: 5.6))
        } else if hasQualifier {
            drawPin(in: NSRect(x: 9, y: 0.4, width: 6.5, height: 7.8))
        }
    }

    private func drawQuestion(in rect: NSRect) {
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        let mark = NSBezierPath()
        mark.move(to: point(0.08, 0.72))
        mark.curve(to: point(0.87, 0.72), controlPoint1: point(0.08, 1.06), controlPoint2: point(0.93, 1.06))
        mark.curve(to: point(0.47, 0.31), controlPoint1: point(0.85, 0.52), controlPoint2: point(0.47, 0.56))
        mark.lineWidth = max(0.95, rect.width * 0.21); mark.lineCapStyle = .round
        NSColor.labelColor.setStroke(); mark.stroke()
        let dot = max(1.0, rect.width * 0.26)
        NSColor.labelColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + rect.width * 0.47 - dot / 2, y: rect.minY, width: dot, height: dot)).fill()
    }

    private func drawPin(in rect: NSRect) {
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        let pin = NSBezierPath()
        pin.move(to: point(0.13, 0.96)); pin.line(to: point(0.87, 0.96))
        pin.line(to: point(0.75, 0.79)); pin.line(to: point(0.75, 0.56))
        pin.line(to: point(1, 0.38)); pin.line(to: point(0.57, 0.38))
        pin.line(to: point(0.50, 0)); pin.line(to: point(0.43, 0.38))
        pin.line(to: point(0, 0.38)); pin.line(to: point(0.25, 0.56))
        pin.line(to: point(0.25, 0.79)); pin.close()
        NSColor.labelColor.setFill(); pin.fill()
    }
}

final class CloudStatusCellView: NSTableCellView {
    let badge = CloudStatusBadgeView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(badge)
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        badge.frame = NSRect(x: 9.pt, y: max(0, (bounds.height - 16.pt) / 2), width: 16.pt, height: 16.pt)
    }
    func configure(_ status: CloudStatusPresentation?, checkedAt: Date? = nil) {
        let changed = badge.presentation != status
        if changed { badge.configure(status) }
        let help = status?.help(checkedAt: checkedAt)
        badge.toolTip = help
        toolTip = help
        let label = status?.label ?? ""
        if accessibilityLabel() != label { setAccessibilityLabel(label) }
        let valueChanged = accessibilityValue() as? String != label
        if valueChanged { setAccessibilityValue(label) }
        setAccessibilityHelp(help)
        setAccessibilityIdentifier("cloud-status")
        if valueChanged { NSAccessibility.post(element: self, notification: .valueChanged) }
    }
}
