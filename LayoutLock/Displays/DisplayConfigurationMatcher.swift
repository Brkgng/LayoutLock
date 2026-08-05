import Foundation

struct DisplayConfigurationMatch: Equatable {
    let snapshotID: UUID
    let snapshotName: String
    let reason: DisplayConfigurationMatchReason
}

enum DisplayConfigurationMatchReason: Equatable {
    case hardwareIdentity
    case nameSizeScale
}

struct DisplayConfigurationMatcher {
    func matches(
        among snapshots: [Snapshot],
        currentDisplayState: DisplayState
    ) -> [DisplayConfigurationMatch] {
        snapshots.compactMap {
            match(snapshot: $0, currentDisplayState: currentDisplayState)
        }
    }

    func uniqueMatch(
        among snapshots: [Snapshot],
        currentDisplayState: DisplayState
    ) -> DisplayConfigurationMatch? {
        let matches = matches(
            among: snapshots,
            currentDisplayState: currentDisplayState
        )

        guard matches.count == 1 else {
            return nil
        }

        return matches[0]
    }

    func match(
        snapshot: Snapshot,
        currentDisplayState: DisplayState
    ) -> DisplayConfigurationMatch? {
        let savedDisplays = snapshot.sourceDisplayState.displays
        let currentDisplays = currentDisplayState.displays

        guard savedDisplays.count == currentDisplays.count,
              !savedDisplays.isEmpty else {
            return nil
        }

        guard let reason = matchReason(
            savedDisplays: savedDisplays,
            currentDisplays: currentDisplays
        ) else {
            return nil
        }

        return DisplayConfigurationMatch(
            snapshotID: snapshot.id,
            snapshotName: snapshot.name,
            reason: reason
        )
    }

    private func matchReason(
        savedDisplays: [DisplayRecord],
        currentDisplays: [DisplayRecord]
    ) -> DisplayConfigurationMatchReason? {
        if oneToOneMatch(
            savedDisplays: savedDisplays,
            currentDisplays: currentDisplays,
            key: \.hardwareConfigurationKey
        ) {
            return .hardwareIdentity
        }

        if oneToOneMatch(
            savedDisplays: savedDisplays,
            currentDisplays: currentDisplays,
            key: \.nameSizeScaleConfigurationKey
        ) {
            return .nameSizeScale
        }

        return nil
    }

    private func oneToOneMatch<Key: Hashable>(
        savedDisplays: [DisplayRecord],
        currentDisplays: [DisplayRecord],
        key: (DisplayRecord) -> Key?
    ) -> Bool {
        let savedKeys = savedDisplays.compactMap(key)
        let currentKeys = currentDisplays.compactMap(key)

        guard savedKeys.count == savedDisplays.count,
              currentKeys.count == currentDisplays.count,
              Set(savedKeys).count == savedDisplays.count,
              Set(currentKeys).count == currentDisplays.count else {
            return false
        }

        return Set(savedKeys) == Set(currentKeys)
    }
}

private struct DisplayHardwareConfigurationKey: Hashable {
    let vendorID: UInt32?
    let productID: UInt32?
    let serialNumber: UInt32?
}

private struct DisplayNameSizeScaleConfigurationKey: Hashable {
    let localizedName: String
    let width: Double
    let height: Double
    let backingScaleFactor: Double
}

private extension DisplayRecord {
    var hardwareConfigurationKey: DisplayHardwareConfigurationKey? {
        guard let vendorID,
              let productID,
              let serialNumber else {
            return nil
        }

        return DisplayHardwareConfigurationKey(
            vendorID: vendorID,
            productID: productID,
            serialNumber: serialNumber
        )
    }

    var nameSizeScaleConfigurationKey: DisplayNameSizeScaleConfigurationKey? {
        guard let name = localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }

        return DisplayNameSizeScaleConfigurationKey(
            localizedName: name,
            width: frame.width,
            height: frame.height,
            backingScaleFactor: backingScaleFactor
        )
    }
}
