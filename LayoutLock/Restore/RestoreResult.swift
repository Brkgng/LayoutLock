import Foundation

enum RestoreProgress: Sendable {
    case discovering
    case recoveringWindows
    case opening
    case waiting
    case positioning
    case stacking

    var message: String {
        switch self {
        case .discovering:
            return "Finding saved windows…"
        case .recoveringWindows:
            return "Bringing windows to the current desktop…"
        case .opening:
            return "Opening apps and saved resources…"
        case .waiting:
            return "Waiting for apps and windows…"
        case .positioning:
            return "Positioning windows…"
        case .stacking:
            return "Restoring window order…"
        }
    }
}

struct RestoreResult {
    let restoredWindows: Int
    let skippedItems: [RestoreSkip]
    let downgradedItems: [RestoreDowngrade]
    let displayFallbacks: [DisplayFallbackEvent]
    let requestedTargetCount: Int
    let targetIssues: [RestoreTargetIssue]
    let windowDiagnostics: [RestoreWindowDiagnostic]
    let discoveryDiagnostics: [WindowDiscoveryDiagnostic]

    init(
        restoredWindows: Int,
        skippedItems: [RestoreSkip],
        downgradedItems: [RestoreDowngrade],
        displayFallbacks: [DisplayFallbackEvent],
        requestedTargetCount: Int = 0,
        targetIssues: [RestoreTargetIssue] = [],
        windowDiagnostics: [RestoreWindowDiagnostic] = [],
        discoveryDiagnostics: [WindowDiscoveryDiagnostic] = []
    ) {
        self.restoredWindows = restoredWindows
        self.skippedItems = skippedItems
        self.downgradedItems = downgradedItems
        self.displayFallbacks = displayFallbacks
        self.requestedTargetCount = requestedTargetCount
        self.targetIssues = targetIssues
        self.windowDiagnostics = windowDiagnostics
        self.discoveryDiagnostics = discoveryDiagnostics
    }
}

struct RestoreWindowDiagnostic {
    let windowID: UUID
    let bundleIdentifier: String
    let matchStrategy: RestoreWindowMatchStrategy?
    let candidateCount: Int
    let filteredCandidateCount: Int
    let readinessTimedOut: Bool
    let geometryAttempted: Bool
    let geometryAttemptCount: Int
    let expectedFrame: CGRect?
    let finalObservedFrame: CGRect?
    let displayOutcome: RestoreDisplayOutcome?
    let result: String
    let reason: String?
}

enum RestoreTargetIssueReason: String {
    case missingTarget
    case targetKindMismatch
    case unsupportedURL
    case applicationUnavailable
    case openRequestFailed
    case openingNotConfirmed
    case unsupportedTarget

    var userFacingDescription: String {
        switch self {
        case .missingTarget:
            return "Saved file or folder no longer exists."
        case .targetKindMismatch:
            return "Saved file or folder type has changed."
        case .unsupportedURL:
            return "Only HTTP and HTTPS URLs can be opened."
        case .applicationUnavailable:
            return "Saved application is unavailable."
        case .openRequestFailed:
            return "Saved resource could not be opened."
        case .openingNotConfirmed:
            return "The file or folder could not be confirmed in the restored window."
        case .unsupportedTarget:
            return "This file or folder cannot be reopened automatically."
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
    let windowID: UUID?
    let bundleIdentifier: String
    let windowTitle: String?
    let reason: String

    init(
        id: UUID = UUID(),
        windowID: UUID? = nil,
        bundleIdentifier: String,
        windowTitle: String? = nil,
        reason: String
    ) {
        self.id = id
        self.windowID = windowID
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
    let windowID: UUID?
    let bundleIdentifier: String?
    let outcome: RestoreDisplayOutcome
    let savedDisplayID: UInt32?
    let resolvedDisplayID: UInt32?
    let savedDisplayName: String?
    let resolvedDisplayName: String?
    let reason: String

    init(
        id: UUID = UUID(),
        windowID: UUID? = nil,
        bundleIdentifier: String? = nil,
        outcome: RestoreDisplayOutcome = .primaryFallback,
        savedDisplayID: UInt32?,
        resolvedDisplayID: UInt32?,
        savedDisplayName: String? = nil,
        resolvedDisplayName: String? = nil,
        reason: String
    ) {
        self.id = id
        self.windowID = windowID
        self.bundleIdentifier = bundleIdentifier
        self.outcome = outcome
        self.savedDisplayID = savedDisplayID
        self.resolvedDisplayID = resolvedDisplayID
        self.savedDisplayName = savedDisplayName
        self.resolvedDisplayName = resolvedDisplayName
        self.reason = reason
    }
}
