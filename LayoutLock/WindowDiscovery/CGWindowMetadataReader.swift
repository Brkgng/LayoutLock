import CoreGraphics
import Foundation

struct CGWindowMetadata {
    let windowID: CGWindowID
    let processIdentifier: pid_t
    let ownerName: String?
    let layer: Int
    let bounds: CGRect
    let title: String?
    let isOnScreen: Bool
    let zOrderHint: Int?
}

struct CGWindowMetadataReader {
    typealias WindowListProvider = (CGWindowListOption) -> [[String: Any]]?

    private let windowListProvider: WindowListProvider

    init(
        windowListProvider: @escaping WindowListProvider = {
            CGWindowListCopyWindowInfo($0, kCGNullWindowID) as? [[String: Any]]
        }
    ) {
        self.windowListProvider = windowListProvider
    }

    func readWindowMetadata(
        processIdentifiers: Set<pid_t>
    ) -> [pid_t: [CGWindowMetadata]] {
        guard !processIdentifiers.isEmpty,
              let rawWindowList = windowListProvider(.optionAll) else {
            return [:]
        }

        let onscreenZOrder = onscreenZOrderByWindowID()
        var windowsByProcessIdentifier: [pid_t: [CGWindowMetadata]] = [:]

        for rawWindow in rawWindowList {
            guard let metadata = metadata(
                from: rawWindow,
                onscreenZOrder: onscreenZOrder
            ),
            processIdentifiers.contains(metadata.processIdentifier) else {
                continue
            }

            windowsByProcessIdentifier[metadata.processIdentifier, default: []].append(metadata)
        }

        return windowsByProcessIdentifier
    }

    private func onscreenZOrderByWindowID() -> [CGWindowID: Int] {
        guard let rawWindowList = windowListProvider(.optionOnScreenOnly) else {
            return [:]
        }

        return rawWindowList.enumerated().reduce(into: [:]) { orderByWindowID, item in
            guard let windowNumber = item.element[kCGWindowNumber as String] as? NSNumber else {
                return
            }

            orderByWindowID[CGWindowID(windowNumber.uint32Value)] = item.offset
        }
    }

    private func metadata(
        from rawWindow: [String: Any],
        onscreenZOrder: [CGWindowID: Int]
    ) -> CGWindowMetadata? {
        guard let windowNumber = rawWindow[kCGWindowNumber as String] as? NSNumber,
              let ownerPID = rawWindow[kCGWindowOwnerPID as String] as? NSNumber,
              let boundsValue = rawWindow[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsValue as CFDictionary),
              bounds.isFinite else {
            return nil
        }

        let windowID = CGWindowID(windowNumber.uint32Value)
        let layerNumber = rawWindow[kCGWindowLayer as String] as? NSNumber
        let onScreenNumber = rawWindow[kCGWindowIsOnscreen as String] as? NSNumber
        let isOnScreen = onScreenNumber?.boolValue ?? false

        return CGWindowMetadata(
            windowID: windowID,
            processIdentifier: pid_t(ownerPID.int32Value),
            ownerName: rawWindow[kCGWindowOwnerName as String] as? String,
            layer: layerNumber?.intValue ?? 0,
            bounds: bounds,
            title: rawWindow[kCGWindowName as String] as? String,
            isOnScreen: isOnScreen,
            zOrderHint: isOnScreen ? onscreenZOrder[windowID] : nil
        )
    }
}

private extension CGRect {
    var isFinite: Bool {
        origin.x.isFinite &&
        origin.y.isFinite &&
        size.width.isFinite &&
        size.height.isFinite &&
        !isNull &&
        !isInfinite
    }
}
