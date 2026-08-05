import CoreGraphics
import Foundation

struct Snapshot: Codable, Identifiable {
    static let currentSchemaVersion = 3

    let id: UUID
    var name: String
    let createdAt: Date
    var updatedAt: Date
    let schemaVersion: Int
    let sourceDisplayState: DisplayState
    let windows: [WindowRecord]
    var hotkey: HotkeyBinding?

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        schemaVersion: Int = Snapshot.currentSchemaVersion,
        sourceDisplayState: DisplayState,
        windows: [WindowRecord],
        hotkey: HotkeyBinding? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
        self.sourceDisplayState = sourceDisplayState
        self.windows = windows
        self.hotkey = hotkey
    }
}

enum WindowOpenTargetKind: String, Codable, Hashable {
    case file
    case folder
    case webURL
}

struct WindowOpenTarget: Codable, Hashable, Identifiable {
    let id: UUID
    let kind: WindowOpenTargetKind
    let url: URL
    let title: String?

    init(
        id: UUID = UUID(),
        kind: WindowOpenTargetKind,
        url: URL,
        title: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.url = url
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue
    }

    var displayName: String {
        switch kind {
        case .file, .folder:
            return url.lastPathComponent.nonEmptyValue ?? url.path
        case .webURL:
            return url.absoluteString
        }
    }

    var compactDisplayName: String {
        switch kind {
        case .file:
            let name = url.deletingPathExtension().lastPathComponent
            return name.nonEmptyValue ?? displayName
        case .folder:
            return displayName
        case .webURL:
            if let title {
                return title
            }
            let host = url.host?.removingPrefix("www.")
            return host?.nonEmptyValue ?? displayName
        }
    }

    func isMissing(fileManager: FileManager = .default) -> Bool {
        guard kind != .webURL else {
            return false
        }

        return !fileManager.fileExists(atPath: url.path)
    }
}

struct WindowOpeningConfiguration: Codable, Hashable {
    let automaticallyCapturedTargets: [WindowOpenTarget]
    let manualTargets: [WindowOpenTarget]?

    init(
        automaticallyCapturedTargets: [WindowOpenTarget] = [],
        manualTargets: [WindowOpenTarget]? = nil
    ) {
        self.automaticallyCapturedTargets = automaticallyCapturedTargets
        self.manualTargets = manualTargets
    }

    var effectiveTargets: [WindowOpenTarget] {
        manualTargets ?? automaticallyCapturedTargets
    }

    var isManual: Bool {
        manualTargets != nil
    }

    func replacingManualTargets(_ targets: [WindowOpenTarget]) -> WindowOpeningConfiguration {
        WindowOpeningConfiguration(
            automaticallyCapturedTargets: automaticallyCapturedTargets,
            manualTargets: targets
        )
    }
}

enum WindowOpenTargetValidationError: LocalizedError, Equatable {
    case emptyPath
    case pathDoesNotExist
    case expectedFile
    case expectedFolder
    case invalidWebURL(String)

    var errorDescription: String? {
        switch self {
        case .emptyPath:
            return "Enter a file or folder path."
        case .pathDoesNotExist:
            return "The file or folder does not exist."
        case .expectedFile:
            return "Choose a file, not a folder."
        case .expectedFolder:
            return "Choose a folder, not a file."
        case let .invalidWebURL(value):
            return "\"\(value)\" is not a valid HTTP or HTTPS URL."
        }
    }
}

struct WindowOpenTargetValidator {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func localTarget(
        path: String,
        expectedKind: WindowOpenTargetKind? = nil
    ) throws -> WindowOpenTarget {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw WindowOpenTargetValidationError.emptyPath
        }

        let expandedPath = NSString(string: trimmedPath).expandingTildeInPath
        let url: URL
        if let fileURL = URL(string: expandedPath), fileURL.isFileURL {
            url = fileURL.standardizedFileURL
        } else {
            url = URL(fileURLWithPath: expandedPath).standardizedFileURL
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw WindowOpenTargetValidationError.pathDoesNotExist
        }

        let resolvedKind: WindowOpenTargetKind = isDirectory.boolValue ? .folder : .file
        if expectedKind == .file, resolvedKind != .file {
            throw WindowOpenTargetValidationError.expectedFile
        }
        if expectedKind == .folder, resolvedKind != .folder {
            throw WindowOpenTargetValidationError.expectedFolder
        }

        return WindowOpenTarget(kind: resolvedKind, url: url)
    }

    func existingLocalTarget(url: URL) -> WindowOpenTarget? {
        let standardizedURL = url.standardizedFileURL
        guard standardizedURL.isFileURL else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: standardizedURL.path,
            isDirectory: &isDirectory
        ) else {
            return nil
        }

        return WindowOpenTarget(
            kind: isDirectory.boolValue ? .folder : .file,
            url: standardizedURL
        )
    }

    func webTarget(url: URL) -> WindowOpenTarget? {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ),
        let scheme = components.scheme?.lowercased(),
        ["http", "https"].contains(scheme),
        components.host?.nonEmptyValue != nil,
        let standardizedURL = components.url else {
            return nil
        }

        return WindowOpenTarget(kind: .webURL, url: standardizedURL)
    }

    func webTargets(from input: String) throws -> [WindowOpenTarget] {
        let values = input
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return try values.map { value in
            let normalizedValue = value.contains("://")
                ? value
                : "https://\(value)"
            guard let url = URL(string: normalizedValue),
                  let target = webTarget(url: url) else {
                throw WindowOpenTargetValidationError.invalidWebURL(value)
            }

            return target
        }
    }
}

struct WindowRecord: Codable, Identifiable {
    let id: UUID
    let bundleIdentifier: String
    let pidAtCapture: Int32
    let windowTitle: String?
    let role: String
    let subrole: String?
    let frame: CGRectCodable
    let displayID: UInt32?
    let normalizedFrame: NormalizedRect
    let zOrderHint: Int?
    let isMinimized: Bool
    let isFullscreen: Bool
    let isVisible: Bool
    let captureSignature: WindowSignature
    let openingConfiguration: WindowOpeningConfiguration

    init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        pidAtCapture: Int32,
        windowTitle: String?,
        role: String,
        subrole: String?,
        frame: CGRectCodable,
        displayID: UInt32?,
        normalizedFrame: NormalizedRect,
        zOrderHint: Int?,
        isMinimized: Bool,
        isFullscreen: Bool,
        isVisible: Bool,
        captureSignature: WindowSignature,
        openingConfiguration: WindowOpeningConfiguration = WindowOpeningConfiguration()
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.pidAtCapture = pidAtCapture
        self.windowTitle = windowTitle
        self.role = role
        self.subrole = subrole
        self.frame = frame
        self.displayID = displayID
        self.normalizedFrame = normalizedFrame
        self.zOrderHint = zOrderHint
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.isVisible = isVisible
        self.captureSignature = captureSignature
        self.openingConfiguration = openingConfiguration
    }
}

extension WindowRecord {
    func withZOrderHint(_ zOrderHint: Int?) -> WindowRecord {
        WindowRecord(
            id: id,
            bundleIdentifier: bundleIdentifier,
            pidAtCapture: pidAtCapture,
            windowTitle: windowTitle,
            role: role,
            subrole: subrole,
            frame: frame,
            displayID: displayID,
            normalizedFrame: normalizedFrame,
            zOrderHint: zOrderHint,
            isMinimized: isMinimized,
            isFullscreen: isFullscreen,
            isVisible: isVisible,
            captureSignature: captureSignature,
            openingConfiguration: openingConfiguration
        )
    }

    func withOpeningConfiguration(_ openingConfiguration: WindowOpeningConfiguration) -> WindowRecord {
        WindowRecord(
            id: id,
            bundleIdentifier: bundleIdentifier,
            pidAtCapture: pidAtCapture,
            windowTitle: windowTitle,
            role: role,
            subrole: subrole,
            frame: frame,
            displayID: displayID,
            normalizedFrame: normalizedFrame,
            zOrderHint: zOrderHint,
            isMinimized: isMinimized,
            isFullscreen: isFullscreen,
            isVisible: isVisible,
            captureSignature: captureSignature,
            openingConfiguration: openingConfiguration
        )
    }

    func preservingIdentityAndManualTargets(from previousWindow: WindowRecord) -> WindowRecord {
        WindowRecord(
            id: previousWindow.id,
            bundleIdentifier: bundleIdentifier,
            pidAtCapture: pidAtCapture,
            windowTitle: windowTitle,
            role: role,
            subrole: subrole,
            frame: frame,
            displayID: displayID,
            normalizedFrame: normalizedFrame,
            zOrderHint: zOrderHint,
            isMinimized: isMinimized,
            isFullscreen: isFullscreen,
            isVisible: isVisible,
            captureSignature: captureSignature,
            openingConfiguration: WindowOpeningConfiguration(
                automaticallyCapturedTargets: openingConfiguration.automaticallyCapturedTargets,
                manualTargets: previousWindow.openingConfiguration.manualTargets
            )
        )
    }
}

struct WindowSignature: Codable, Hashable {
    let bundleIdentifier: String
    let owningPid: Int32?
    let windowTitle: String?
    let role: String
    let subrole: String?
    let capturedFrame: CGRectCodable
    let cgWindowID: UInt32?

    init(
        bundleIdentifier: String,
        owningPid: Int32?,
        windowTitle: String?,
        role: String,
        subrole: String?,
        capturedFrame: CGRectCodable,
        cgWindowID: UInt32?
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.owningPid = owningPid
        self.windowTitle = windowTitle
        self.role = role
        self.subrole = subrole
        self.capturedFrame = capturedFrame
        self.cgWindowID = cgWindowID
    }

    init(application: DiscoveredApplication, window: DiscoveredWindow) {
        self.init(
            bundleIdentifier: application.bundleIdentifier,
            owningPid: application.pid,
            windowTitle: window.title,
            role: window.role,
            subrole: window.subrole,
            capturedFrame: CGRectCodable(window.frame),
            cgWindowID: window.cgWindowID
        )
    }
}

struct DisplayState: Codable, Hashable {
    let displays: [DisplayRecord]
    let primaryDisplayID: UInt32?
    let virtualDesktopBounds: CGRectCodable

    init(
        displays: [DisplayRecord],
        primaryDisplayID: UInt32?,
        virtualDesktopBounds: CGRectCodable? = nil
    ) {
        self.displays = displays
        self.primaryDisplayID = primaryDisplayID
        self.virtualDesktopBounds = virtualDesktopBounds ?? CGRectCodable(
            displays.map(\.frameRect).unionBounds()
        )
    }

    var virtualDesktopBoundsRect: CGRect {
        virtualDesktopBounds.cgRect
    }
}

struct DisplayRecord: Codable, Identifiable, Hashable {
    let id: UInt32
    let localizedName: String?
    let frame: CGRectCodable
    let visibleFrame: CGRectCodable
    let backingScaleFactor: Double
    let isPrimary: Bool
    let vendorID: UInt32?
    let productID: UInt32?
    let serialNumber: UInt32?

    var frameRect: CGRect {
        frame.cgRect
    }

    var visibleFrameRect: CGRect {
        visibleFrame.cgRect
    }
}

struct NormalizedRect: Codable, Hashable {
    let xRatio: Double
    let yRatio: Double
    let widthRatio: Double
    let heightRatio: Double

    init(
        xRatio: Double,
        yRatio: Double,
        widthRatio: Double,
        heightRatio: Double
    ) {
        self.xRatio = xRatio
        self.yRatio = yRatio
        self.widthRatio = widthRatio
        self.heightRatio = heightRatio
    }

    init(windowFrame: CGRect, displayFrame: CGRect) {
        guard displayFrame.width > 0, displayFrame.height > 0 else {
            self.init(xRatio: 0, yRatio: 0, widthRatio: 0, heightRatio: 0)
            return
        }

        self.init(
            xRatio: (windowFrame.minX - displayFrame.minX) / displayFrame.width,
            yRatio: (windowFrame.minY - displayFrame.minY) / displayFrame.height,
            widthRatio: windowFrame.width / displayFrame.width,
            heightRatio: windowFrame.height / displayFrame.height
        )
    }

    func denormalized(in displayFrame: CGRect) -> CGRect {
        CGRect(
            x: displayFrame.minX + (xRatio * displayFrame.width),
            y: displayFrame.minY + (yRatio * displayFrame.height),
            width: widthRatio * displayFrame.width,
            height: heightRatio * displayFrame.height
        )
    }
}

struct HotkeyBinding: Codable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32
    let displayString: String
}

private extension Array where Element == CGRect {
    func unionBounds() -> CGRect {
        reduce(into: CGRect.null) { partialResult, rect in
            partialResult = partialResult.union(rect)
        }.nullCoalescedToZero
    }
}

private extension CGRect {
    var nullCoalescedToZero: CGRect {
        isNull ? .zero : self
    }
}
