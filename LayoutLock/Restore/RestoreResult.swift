import Foundation

struct RestoreResult {
    let restoredWindows: Int
    let skippedItems: [RestoreSkip]
    let downgradedItems: [RestoreDowngrade]
    let displayFallbacks: [DisplayFallbackEvent]
    let requestedTargetCount: Int
    let targetIssues: [RestoreTargetIssue]

    init(
        restoredWindows: Int,
        skippedItems: [RestoreSkip],
        downgradedItems: [RestoreDowngrade],
        displayFallbacks: [DisplayFallbackEvent],
        requestedTargetCount: Int = 0,
        targetIssues: [RestoreTargetIssue] = []
    ) {
        self.restoredWindows = restoredWindows
        self.skippedItems = skippedItems
        self.downgradedItems = downgradedItems
        self.displayFallbacks = displayFallbacks
        self.requestedTargetCount = requestedTargetCount
        self.targetIssues = targetIssues
    }
}

enum RestoreTargetIssueReason: String {
    case missingTarget
    case targetKindMismatch
    case unsupportedURL
    case applicationUnavailable
    case openRequestFailed

    var userFacingDescription: String {
        switch self {
        case .missingTarget:
            return "Target no longer exists."
        case .targetKindMismatch:
            return "Target type has changed."
        case .unsupportedURL:
            return "Only HTTP and HTTPS URLs can be opened."
        case .applicationUnavailable:
            return "Saved application is unavailable."
        case .openRequestFailed:
            return "Target could not be opened."
        }
    }
}

struct RestoreTargetIssue: Identifiable {
    let id: UUID
    let windowID: UUID
    let bundleIdentifier: String
    let windowTitle: String?
    let target: WindowOpenTarget
    let reason: RestoreTargetIssueReason

    init(
        id: UUID = UUID(),
        windowID: UUID,
        bundleIdentifier: String,
        windowTitle: String?,
        target: WindowOpenTarget,
        reason: RestoreTargetIssueReason
    ) {
        self.id = id
        self.windowID = windowID
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.target = target
        self.reason = reason
    }
}

struct RestoreSkip: Identifiable {
    let id: UUID
    let bundleIdentifier: String
    let windowTitle: String?
    let reason: String

    init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        windowTitle: String? = nil,
        reason: String
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.reason = reason
    }
}

struct RestoreDowngrade: Identifiable {
    let id: UUID
    let bundleIdentifier: String
    let windowTitle: String?
    let reason: String

    init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        windowTitle: String? = nil,
        reason: String
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.reason = reason
    }
}

struct DisplayFallbackEvent: Identifiable {
    let id: UUID
    let savedDisplayID: UInt32?
    let resolvedDisplayID: UInt32?
    let reason: String

    init(
        id: UUID = UUID(),
        savedDisplayID: UInt32?,
        resolvedDisplayID: UInt32?,
        reason: String
    ) {
        self.id = id
        self.savedDisplayID = savedDisplayID
        self.resolvedDisplayID = resolvedDisplayID
        self.reason = reason
    }
}
