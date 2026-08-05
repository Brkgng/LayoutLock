import AppKit
import CoreGraphics

struct DisplayResolver {
    private let screenProvider: () -> [ScreenSnapshot]

    init(screenProvider: @escaping () -> [ScreenSnapshot] = ScreenSnapshot.currentScreens) {
        self.screenProvider = screenProvider
    }

    func captureDisplayState() -> DisplayState {
        let displays = screenProvider()
            .map(\.displayRecord)
            .sorted(by: DisplayRecord.sortComparator)

        return DisplayState(
            displays: displays,
            primaryDisplayID: displays.first(where: { $0.isPrimary })?.id
        )
    }

    func resolveDisplay(
        for windowFrame: CGRect,
        in displayState: DisplayState
    ) -> DisplayRecord? {
        resolveDisplay(for: windowFrame, among: displayState.displays)
    }

    func resolveDisplay(
        for windowFrame: CGRect,
        among displays: [DisplayRecord]
    ) -> DisplayRecord? {
        guard !displays.isEmpty else {
            return nil
        }

        if let intersectingDisplay = displays.max(by: {
            let leftArea = windowFrame.intersectionArea(with: $0.frameRect)
            let rightArea = windowFrame.intersectionArea(with: $1.frameRect)

            if leftArea != rightArea {
                return leftArea < rightArea
            }

            let leftDistance = windowFrame.center.distanceSquared(to: $0.frameRect.center)
            let rightDistance = windowFrame.center.distanceSquared(to: $1.frameRect.center)

            if leftDistance != rightDistance {
                return leftDistance > rightDistance
            }

            return DisplayRecord.sortComparator($0, $1)
        }),
        windowFrame.intersectionArea(with: intersectingDisplay.frameRect) > 0 {
            return intersectingDisplay
        }

        return displays.min(by: {
            let leftDistance = windowFrame.center.distanceSquared(to: $0.frameRect.center)
            let rightDistance = windowFrame.center.distanceSquared(to: $1.frameRect.center)

            if leftDistance != rightDistance {
                return leftDistance < rightDistance
            }

            return DisplayRecord.sortComparator($0, $1)
        })
    }

    func normalizedFrame(
        for windowFrame: CGRect,
        in display: DisplayRecord
    ) -> NormalizedRect {
        NormalizedRect(windowFrame: windowFrame, displayFrame: display.frameRect)
    }

    func restorePlan(
        for window: WindowRecord,
        from sourceDisplayState: DisplayState,
        to currentDisplayState: DisplayState
    ) -> RestoreDisplayPlan {
        guard !currentDisplayState.displays.isEmpty else {
            return RestoreDisplayPlan(
                targetFrame: window.frame.cgRect,
                resolvedDisplayID: nil,
                fallback: DisplayFallbackEvent(
                    savedDisplayID: window.displayID,
                    resolvedDisplayID: nil,
                    reason: DisplayFallbackReason.noDisplaysAvailable
                )
            )
        }

        guard let resolvedDisplay = resolvedRestoreDisplay(
            savedDisplayID: window.displayID,
            sourceDisplayState: sourceDisplayState,
            currentDisplayState: currentDisplayState
        ) else {
            return RestoreDisplayPlan(
                targetFrame: window.frame.cgRect,
                resolvedDisplayID: nil,
                fallback: nil
            )
        }

        let reconstructedFrame = window.normalizedFrame.denormalized(
            in: resolvedDisplay.display.frameRect
        )
        let targetFrame = reconstructedFrame.clamped(to: resolvedDisplay.display.visibleFrameRect)

        return RestoreDisplayPlan(
            targetFrame: targetFrame,
            resolvedDisplayID: resolvedDisplay.display.id,
            fallback: resolvedDisplay.reason.map {
                DisplayFallbackEvent(
                    savedDisplayID: window.displayID,
                    resolvedDisplayID: resolvedDisplay.display.id,
                    reason: $0
                )
            }
        )
    }

    private func resolvedRestoreDisplay(
        savedDisplayID: UInt32?,
        sourceDisplayState: DisplayState,
        currentDisplayState: DisplayState
    ) -> (display: DisplayRecord, reason: String?)? {
        let currentDisplays = currentDisplayState.displays
        let savedDisplay = savedDisplayID.flatMap { id in
            sourceDisplayState.displays.first(where: { $0.id == id })
        }

        if let savedDisplay {
            let hardwareMatches = currentDisplays.filter { $0.hardwareMatches(savedDisplay) }
            if hardwareMatches.count == 1,
               let hardwareMatch = hardwareMatches.first {
                return (
                    hardwareMatch,
                    hardwareMatch.id == savedDisplayID ? nil : DisplayFallbackReason.hardwareMatch
                )
            }

            if let savedDisplayID,
               let exactMatch = currentDisplays.first(where: { $0.id == savedDisplayID }),
               !savedDisplay.hasStableIdentity || exactMatch.identityMatches(savedDisplay) {
                return (exactMatch, nil)
            }
        }

        if let savedDisplay,
           let savedDisplayName = savedDisplay.localizedName.nonEmptyValue,
           let semanticMatch = currentDisplays
            .filter({ $0.localizedName.nonEmptyValue == savedDisplayName })
            .min(by: {
                let leftDistance = $0.frameRect.restoreDisplayDistance(to: savedDisplay.frameRect)
                let rightDistance = $1.frameRect.restoreDisplayDistance(to: savedDisplay.frameRect)

                if leftDistance != rightDistance {
                    return leftDistance < rightDistance
                }

                return DisplayRecord.sortComparator($0, $1)
            }) {
            return (semanticMatch, DisplayFallbackReason.semanticMatch)
        }

        if savedDisplay == nil,
           let savedDisplayID,
           let exactMatch = currentDisplays.first(where: { $0.id == savedDisplayID }) {
            return (exactMatch, nil)
        }

        if let primaryDisplay = currentDisplays.first(where: { $0.id == currentDisplayState.primaryDisplayID }) ??
            currentDisplays.first(where: \.isPrimary) ??
            currentDisplays.sorted(by: DisplayRecord.sortComparator).first {
            return (primaryDisplay, DisplayFallbackReason.primaryDisplay)
        }

        return nil
    }
}

struct RestoreDisplayPlan {
    let targetFrame: CGRect
    let resolvedDisplayID: UInt32?
    let fallback: DisplayFallbackEvent?
}

enum DisplayFallbackReason {
    static let hardwareMatch = "display matched by hardware identifiers"
    static let semanticMatch = "display matched by name and frame"
    static let primaryDisplay = "display fell back to primary display"
    static let noDisplaysAvailable = "no displays available during restore"
}

extension DisplayResolver {
    struct ScreenSnapshot {
        let id: CGDirectDisplayID
        let localizedName: String?
        let frame: CGRect
        let visibleFrame: CGRect
        let backingScaleFactor: Double
        let isPrimary: Bool
        let vendorID: UInt32?
        let productID: UInt32?
        let serialNumber: UInt32?

        var displayRecord: DisplayRecord {
            DisplayRecord(
                id: id,
                localizedName: localizedName,
                frame: CGRectCodable(frame),
                visibleFrame: CGRectCodable(visibleFrame),
                backingScaleFactor: backingScaleFactor,
                isPrimary: isPrimary,
                vendorID: vendorID,
                productID: productID,
                serialNumber: serialNumber
            )
        }

        static func currentScreens() -> [ScreenSnapshot] {
            let primaryDisplayID = CGMainDisplayID()

            let rawScreens: [ScreenSnapshot] = NSScreen.screens.compactMap { screen in
                guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                    return nil
                }

                let displayID = CGDirectDisplayID(screenNumber.uint32Value)

                return ScreenSnapshot(
                    id: displayID,
                    localizedName: screen.localizedName,
                    frame: screen.frame,
                    visibleFrame: screen.visibleFrame,
                    backingScaleFactor: screen.backingScaleFactor,
                    isPrimary: displayID == primaryDisplayID,
                    vendorID: displayValueOrNil(CGDisplayVendorNumber(displayID)),
                    productID: displayValueOrNil(CGDisplayModelNumber(displayID)),
                    serialNumber: displayValueOrNil(CGDisplaySerialNumber(displayID))
                )
            }

            return alignedToAccessibilityCoordinates(
                rawScreens,
                primaryDisplayID: primaryDisplayID
            )
        }

        static func alignedToAccessibilityCoordinates(
            _ screens: [ScreenSnapshot],
            primaryDisplayID: CGDirectDisplayID
        ) -> [ScreenSnapshot] {
            guard let primaryScreen = screens.first(where: { $0.id == primaryDisplayID }) ??
                    screens.first(where: \.isPrimary) else {
                return screens
            }

            return screens.map { screen in
                ScreenSnapshot(
                    id: screen.id,
                    localizedName: screen.localizedName,
                    frame: screen.frame.alignedToAccessibilityCoordinates(
                        primaryFrame: primaryScreen.frame
                    ),
                    visibleFrame: screen.visibleFrame.alignedToAccessibilityCoordinates(
                        primaryFrame: primaryScreen.frame
                    ),
                    backingScaleFactor: screen.backingScaleFactor,
                    isPrimary: screen.isPrimary,
                    vendorID: screen.vendorID,
                    productID: screen.productID,
                    serialNumber: screen.serialNumber
                )
            }
        }

        private static func displayValueOrNil(_ value: UInt32) -> UInt32? {
            value == 0 ? nil : value
        }
    }
}

private extension DisplayRecord {
    static func sortComparator(_ left: DisplayRecord, _ right: DisplayRecord) -> Bool {
        if left.frameRect.minX != right.frameRect.minX {
            return left.frameRect.minX < right.frameRect.minX
        }

        if left.frameRect.minY != right.frameRect.minY {
            return left.frameRect.minY < right.frameRect.minY
        }

        return left.id < right.id
    }

    func hardwareMatches(_ other: DisplayRecord) -> Bool {
        guard hasHardwareIdentity else {
            return false
        }

        return vendorID == other.vendorID &&
            productID == other.productID &&
            serialNumber == other.serialNumber
    }

    var hasStableIdentity: Bool {
        hasHardwareIdentity || localizedName.nonEmptyValue != nil
    }

    private var hasHardwareIdentity: Bool {
        vendorID != nil || productID != nil || serialNumber != nil
    }

    func identityMatches(_ other: DisplayRecord) -> Bool {
        if hardwareMatches(other) {
            return true
        }

        guard let displayName = localizedName.nonEmptyValue else {
            return false
        }

        return displayName == other.localizedName.nonEmptyValue
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    func intersectionArea(with other: CGRect) -> CGFloat {
        let intersection = intersection(other)
        guard !intersection.isNull else {
            return 0
        }

        return intersection.width * intersection.height
    }

    func restoreDisplayDistance(to other: CGRect) -> CGFloat {
        abs(minX - other.minX) +
            abs(minY - other.minY) +
            abs(width - other.width) +
            abs(height - other.height)
    }

    func clamped(to bounds: CGRect) -> CGRect {
        guard !bounds.isNull,
              !bounds.isEmpty,
              bounds.width > 0,
              bounds.height > 0 else {
            return self
        }

        let clampedWidth = min(width, bounds.width)
        let clampedHeight = min(height, bounds.height)
        let clampedX = min(max(minX, bounds.minX), bounds.maxX - clampedWidth)
        let clampedY = min(max(minY, bounds.minY), bounds.maxY - clampedHeight)

        return CGRect(
            x: clampedX,
            y: clampedY,
            width: clampedWidth,
            height: clampedHeight
        )
    }

    func alignedToAccessibilityCoordinates(primaryFrame: CGRect) -> CGRect {
        CGRect(
            x: minX,
            y: primaryFrame.maxY - maxY,
            width: width,
            height: height
        )
    }
}

private extension CGPoint {
    func distanceSquared(to other: CGPoint) -> CGFloat {
        let deltaX = x - other.x
        let deltaY = y - other.y
        return (deltaX * deltaX) + (deltaY * deltaY)
    }
}
