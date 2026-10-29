import AppKit
import ApplicationServices
import CoreGraphics

private let axFullScreenAttribute = "AXFullScreen" as CFString
private let axDialogRole = "AXDialog"
private let approximateFrameTolerance: CGFloat = 8
private let transientWindowRoles: Set<String> = [
    kAXSheetRole as String,
    "AXPopover",
    kAXMenuRole as String
]
private let transientWindowSubroles: Set<String> = [
    "AXSystemDialog",
    kAXFloatingWindowSubrole as String
]

struct DiscoveredApplication {
    let bundleIdentifier: String
    let pid: pid_t
    let localizedName: String?
    let windows: [DiscoveredWindow]
}

struct DiscoveredWindow {
    let axElement: AXUIElement
    let browserScriptingIdentifier: String?
    let documentURL: URL?
    let documentURLs: [URL]
    let documentTitles: [String]
    let capturedOpeningTargets: [WindowOpenTarget]
    let title: String?
    let role: String
    let subrole: String?
    let frame: CGRect
    let isMinimized: Bool
    let isFullscreen: Bool
    let isMain: Bool
    let isVisible: Bool
    // Only a direct AX identity confirmed against the owning process's CG metadata.
    let cgWindowID: CGWindowID?
    let ownerName: String?
    let cgLayer: Int?
    let zOrderHint: Int?
    let isOnScreen: Bool?
    let isModal: Bool?

    init(
        axElement: AXUIElement,
        browserScriptingIdentifier: String? = nil,
        documentURL: URL? = nil,
        documentURLs: [URL] = [],
        documentTitles: [String] = [],
        capturedOpeningTargets: [WindowOpenTarget] = [],
        title: String?,
        role: String,
        subrole: String?,
        frame: CGRect,
        isMinimized: Bool,
        isFullscreen: Bool,
        isMain: Bool,
        isVisible: Bool,
        cgWindowID: CGWindowID?,
        ownerName: String?,
        cgLayer: Int?,
        zOrderHint: Int?,
        isOnScreen: Bool?,
        isModal: Bool? = nil
    ) {
        var resolvedDocumentURLs = documentURLs
        if let documentURL, !resolvedDocumentURLs.contains(documentURL) {
            resolvedDocumentURLs.insert(documentURL, at: 0)
        }

        self.axElement = axElement
        self.browserScriptingIdentifier = browserScriptingIdentifier
        self.documentURL = documentURL ?? resolvedDocumentURLs.first
        self.documentURLs = resolvedDocumentURLs
        self.documentTitles = documentTitles
        self.capturedOpeningTargets = capturedOpeningTargets
        self.title = title
        self.role = role
        self.subrole = subrole
        self.frame = frame
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.isMain = isMain
        self.isVisible = isVisible
        self.cgWindowID = cgWindowID
        self.ownerName = ownerName
        self.cgLayer = cgLayer
        self.zOrderHint = zOrderHint
        self.isOnScreen = isOnScreen
        self.isModal = isModal
    }
}

struct UnexposedApplicationWindows {
    let bundleIdentifier: String
    let pid: pid_t
    let windows: [CGWindowMetadata]
    var documentURLs: [URL] = []
}

struct WindowDiscoveryResult {
    let applications: [DiscoveredApplication]
    let diagnostics: [WindowDiscoveryDiagnostic]
    var unexposedApplications: [UnexposedApplicationWindows] = []
}

struct WindowDiscoveryDiagnostic: Equatable {
    enum Kind: String { case windowRejected, applicationEnumeration }

    let bundleIdentifier: String?
    let processIdentifier: Int32?
    let reason: String
    var kind: Kind = .windowRejected
}

struct RunningApplicationSnapshot {
    let bundleIdentifier: String?
    let processIdentifier: pid_t
    let localizedName: String?
    let isTerminated: Bool
    let activationPolicy: NSApplication.ActivationPolicy

    init(
        bundleIdentifier: String?,
        processIdentifier: pid_t,
        localizedName: String?,
        isTerminated: Bool = false,
        activationPolicy: NSApplication.ActivationPolicy = .regular
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.localizedName = localizedName
        self.isTerminated = isTerminated
        self.activationPolicy = activationPolicy
    }

    init(application: NSRunningApplication) {
        self.init(
            bundleIdentifier: application.bundleIdentifier,
            processIdentifier: application.processIdentifier,
            localizedName: application.localizedName,
            isTerminated: application.isTerminated,
            activationPolicy: application.activationPolicy
        )
    }
}

enum WindowDiscoveryError: Error {
    case accessibilityPermissionDenied
}

extension WindowDiscoveryError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            return "Accessibility access is required to capture layouts."
        }
    }
}

struct WindowDiscoveryEngine {
    private let trustChecker: AccessibilityTrustChecker
    private let attributeReader: AXAttributeReader
    private let runningApplicationsProvider: () -> [RunningApplicationSnapshot]
    private let appElementProvider: (pid_t) -> AXUIElement
    private let cgWindowMetadataProvider: (Set<pid_t>) -> [pid_t: [CGWindowMetadata]]
    private let windowIDProvider: (AXUIElement) -> CGWindowID?
    private let applicationDocumentURLResolver: ApplicationWindowDocumentURLResolver
    private let unityProjectURLProvider: (pid_t, URL?) -> URL?
    private let unrealProjectURLProvider: (pid_t, URL?) -> URL?
    private let currentProcessIdentifier: pid_t

    init(
        workspace: NSWorkspace = .shared,
        trustChecker: AccessibilityTrustChecker = AccessibilityTrustChecker(),
        attributeReader: AXAttributeReader = AXAttributeReader(),
        cgWindowMetadataReader: CGWindowMetadataReader = CGWindowMetadataReader(),
        applicationDocumentURLResolver: ApplicationWindowDocumentURLResolver =
            ApplicationWindowDocumentURLResolver(),
        currentProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        runningApplicationsProvider: (() -> [RunningApplicationSnapshot])? = nil,
        appElementProvider: @escaping (pid_t) -> AXUIElement = AXUIElementCreateApplication,
        cgWindowMetadataProvider: ((Set<pid_t>) -> [pid_t: [CGWindowMetadata]])? = nil,
        windowIDProvider: @escaping (AXUIElement) -> CGWindowID? = AXAttributeReader.windowID,
        unityProjectURLProvider: @escaping (pid_t, URL?) -> URL? = {
            UnityProjectResolver().resolve(processIdentifier: $0, documentURL: $1)
        },
        unrealProjectURLProvider: @escaping (pid_t, URL?) -> URL? = {
            UnrealProjectResolver().resolve(processIdentifier: $0, documentURL: $1)
        }
    ) {
        self.trustChecker = trustChecker
        self.attributeReader = attributeReader
        self.runningApplicationsProvider = runningApplicationsProvider ?? {
            workspace.runningApplications.map(RunningApplicationSnapshot.init)
        }
        self.appElementProvider = appElementProvider
        self.applicationDocumentURLResolver = applicationDocumentURLResolver
        self.cgWindowMetadataProvider = cgWindowMetadataProvider ?? {
            cgWindowMetadataReader.readWindowMetadata(processIdentifiers: $0)
        }
        self.currentProcessIdentifier = currentProcessIdentifier
        self.unityProjectURLProvider = unityProjectURLProvider
        self.unrealProjectURLProvider = unrealProjectURLProvider
        self.windowIDProvider = windowIDProvider
    }

    func discoverRunningWindows() throws -> [DiscoveredApplication] {
        try discoverRunningWindowsWithDiagnostics().applications
    }

    func discoverRunningWindowsWithDiagnostics() throws -> WindowDiscoveryResult {
        try discoverRunningWindowsWithDiagnostics(
            runningApplications: runningApplicationsProvider()
        )
    }

    func discoverRunningWindowsWithDiagnostics(
        bundleIdentifiers: Set<String>?,
        processIdentifier: pid_t? = nil
    ) throws -> WindowDiscoveryResult {
        try discoverRunningWindowsWithDiagnostics(
            runningApplications: runningApplicationsProvider().filter { application in
                (bundleIdentifiers.map { $0.contains(application.bundleIdentifier ?? "") } ?? true) &&
                    (processIdentifier == nil || application.processIdentifier == processIdentifier)
            }
        )
    }

    func discoverRunningWindowsWithDiagnostics(
        runningApplications: [RunningApplicationSnapshot]
    ) throws -> WindowDiscoveryResult {
        guard trustChecker.isTrusted() else {
            throw WindowDiscoveryError.accessibilityPermissionDenied
        }

        let candidateApplications = self.candidateApplications(runningApplications)
        let processIdentifiers = Set(candidateApplications.map(\.processIdentifier))
        let cgWindowMetadataByProcessIdentifier = cgWindowMetadataProvider(processIdentifiers)
        let preparedDocumentURLResolver = applicationDocumentURLResolver.preparing(
            bundleIdentifiers: Set(candidateApplications.compactMap(\.bundleIdentifier))
        )

        var diagnostics: [WindowDiscoveryDiagnostic] = []
        var unexposedCGWindows = cgWindowMetadataByProcessIdentifier
        let applications = candidateApplications.compactMap { application in
            discoveredApplication(
                from: application,
                cgWindowMetadata: cgWindowMetadataByProcessIdentifier[application.processIdentifier] ?? [],
                applicationDocumentURLResolver: preparedDocumentURLResolver,
                diagnostics: &diagnostics,
                unexposedCGWindows: &unexposedCGWindows[application.processIdentifier, default: []]
            )
        }

        let unexposedApplications = candidateApplications.compactMap { application -> UnexposedApplicationWindows? in
            guard let bundleIdentifier = application.bundleIdentifier else { return nil }
            let exposed = applications.first { $0.pid == application.processIdentifier }?.windows ?? []
            // Without AX identities, a CG record could describe an already captured window.
            guard !exposed.contains(where: { $0.cgWindowID == nil }) else { return nil }
            let remaining = unexposedCGWindows[application.processIdentifier] ?? []
            guard exposed.isEmpty || !remaining.isEmpty else { return nil }
            var project = UnityProjectResolver.isUnity(bundleIdentifier: bundleIdentifier) &&
                remaining.contains(where: { $0.layer == 0 && $0.bounds.width > 0 && $0.bounds.height > 0 })
                ? unityProjectURLProvider(application.processIdentifier, nil) : nil
            if UnrealProjectResolver.isUnreal(bundleIdentifier: bundleIdentifier) {
                // A starting Editor may have its project argument before it has any windows.
                project = unrealProjectURLProvider(application.processIdentifier, nil)
            }
            return UnexposedApplicationWindows(
                bundleIdentifier: bundleIdentifier,
                pid: application.processIdentifier,
                windows: remaining,
                documentURLs: project.map { [$0] } ?? []
            )
        }
        return WindowDiscoveryResult(applications: applications, diagnostics: diagnostics, unexposedApplications: unexposedApplications)
    }

    private func candidateApplications(
        _ runningApplications: [RunningApplicationSnapshot]
    ) -> [RunningApplicationSnapshot] {
        runningApplications.filter { application in
            guard application.bundleIdentifier != nil,
                  !application.isTerminated,
                  application.activationPolicy != .prohibited,
                  application.processIdentifier != currentProcessIdentifier else {
                return false
            }

            return true
        }
    }

    private func discoveredApplication(
        from application: RunningApplicationSnapshot,
        cgWindowMetadata: [CGWindowMetadata],
        applicationDocumentURLResolver: ApplicationWindowDocumentURLResolver,
        diagnostics: inout [WindowDiscoveryDiagnostic],
        unexposedCGWindows: inout [CGWindowMetadata]
    ) -> DiscoveredApplication? {
        guard let bundleIdentifier = application.bundleIdentifier else {
            return nil
        }

        let appElement = appElementProvider(application.processIdentifier)
        _ = attributeReader.string(
            from: appElement,
            attribute: kAXRoleAttribute as CFString
        )
        let appIsHidden = attributeReader.bool(
            from: appElement,
            attribute: kAXHiddenAttribute as CFString
        ) ?? false
        let windows = discoveredWindows(
            in: appElement,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: application.processIdentifier,
            appIsHidden: appIsHidden,
            cgWindowMetadata: cgWindowMetadata,
            applicationDocumentURLResolver: applicationDocumentURLResolver,
            diagnostics: &diagnostics,
            unexposedCGWindows: &unexposedCGWindows
        )

        guard !windows.isEmpty else {
            return nil
        }

        return DiscoveredApplication(
            bundleIdentifier: bundleIdentifier,
            pid: application.processIdentifier,
            localizedName: application.localizedName,
            windows: windows
        )
    }

    private func discoveredWindows(
        in appElement: AXUIElement,
        bundleIdentifier: String,
        processIdentifier: pid_t,
        appIsHidden: Bool,
        cgWindowMetadata: [CGWindowMetadata],
        applicationDocumentURLResolver: ApplicationWindowDocumentURLResolver,
        diagnostics: inout [WindowDiscoveryDiagnostic],
        unexposedCGWindows: inout [CGWindowMetadata]
    ) -> [DiscoveredWindow] {
        let windowRead = attributeReader.windows(from: appElement)
        var windows = windowRead.elements
        if windows.isEmpty {
            diagnostics.append(WindowDiscoveryDiagnostic(
                bundleIdentifier: bundleIdentifier,
                processIdentifier: Int32(processIdentifier),
                reason: windowRead.error == .success
                    ? "AXWindows returned no windows"
                    : "AXWindows failed (\(windowRead.error.rawValue))",
                kind: .applicationEnumeration
            ))
        }

        // Some apps omit off-Space windows from AXWindows while exposing their main/focused handle.
        for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            guard let window = attributeReader.element(from: appElement, attribute: attribute as CFString),
                !windows.contains(where: { CFEqual($0, window) }),
                let windowID = windowIDProvider(window),
                cgWindowMetadata.contains(where: {
                    $0.windowID == windowID && $0.processIdentifier == processIdentifier
                }),
                !windows.contains(where: { windowIDProvider($0) == windowID }) else { continue }
            windows.append(window)
        }

        var remainingCGWindowMetadata = cgWindowMetadata
        var discoveredWindows: [DiscoveredWindow] = []

        for window in windows {
            let resolvedWindowID = windowIDProvider(window)
            let identifiedMetadata = cgWindowMetadata.first {
                $0.windowID != 0 && $0.windowID == resolvedWindowID && $0.processIdentifier == processIdentifier
            }
            // AX-observed windows must not re-enter through CG fallback after rejection.
            if let identifiedMetadata {
                unexposedCGWindows.removeAll { $0.windowID == identifiedMetadata.windowID }
            } else {
                // An unresolved AX identity makes this owner's remaining CG records ambiguous.
                unexposedCGWindows.removeAll()
            }
            guard let axWindowSnapshot = axWindowSnapshot(
                from: window,
                bundleIdentifier: bundleIdentifier,
                processIdentifier: processIdentifier,
                appIsHidden: appIsHidden,
                applicationDocumentURLResolver: applicationDocumentURLResolver
            ) else {
                diagnostics.append(
                    WindowDiscoveryDiagnostic(
                        bundleIdentifier: bundleIdentifier,
                        processIdentifier: Int32(processIdentifier),
                        reason: WindowDiscoveryDiagnosticReason.missingOrInvalidFrame
                    )
                )
                continue
            }

            // Geometry can supply presentation hints, but never an identity for Space operations.
            let cgWindowMatch = identifiedMetadata ?? bestCGWindowMatch(
                for: axWindowSnapshot,
                candidates: remainingCGWindowMetadata
            )?.metadata

            if let cgWindowMatch {
                remainingCGWindowMetadata.removeAll { $0.windowID == cgWindowMatch.windowID }
            }

            if let rejectionReason = unmanageableWindowRejectionReason(
                role: axWindowSnapshot.role,
                subrole: axWindowSnapshot.subrole,
                cgWindowMetadata: cgWindowMatch
            ) {
                diagnostics.append(
                    WindowDiscoveryDiagnostic(
                        bundleIdentifier: bundleIdentifier,
                        processIdentifier: Int32(processIdentifier),
                        reason: rejectionReason
                    )
                )
                continue
            }

            discoveredWindows.append(discoveredWindow(
                axElement: window,
                from: axWindowSnapshot,
                cgWindowMetadata: cgWindowMatch,
                confirmedWindowID: identifiedMetadata?.windowID
            ))
        }

        return discoveredWindows
    }

    private func axWindowSnapshot(
        from window: AXUIElement,
        bundleIdentifier: String,
        processIdentifier: pid_t,
        appIsHidden: Bool,
        applicationDocumentURLResolver: ApplicationWindowDocumentURLResolver
    ) -> AXWindowSnapshot? {
        guard let position = attributeReader.point(
            from: window,
            attribute: kAXPositionAttribute as CFString
        ),
        let size = attributeReader.size(
            from: window,
            attribute: kAXSizeAttribute as CFString
        ) else {
            return nil
        }

        let frame = CGRect(origin: position, size: size)
        guard frame.isValidDiscoveredWindowFrame else {
            return nil
        }

        let isHidden = attributeReader.bool(
            from: window,
            attribute: kAXHiddenAttribute as CFString
        ) ?? appIsHidden
        let documentMetadata = WindowDocumentMetadataFinder(
            attributeReader: attributeReader,
            urlResolver: WindowDocumentURLResolver()
        ).resolve(in: window)
        let title = attributeReader.string(
            from: window,
            attribute: kAXTitleAttribute as CFString
        )
        let applicationDocumentURL = applicationDocumentURLResolver.resolve(
            bundleIdentifier: bundleIdentifier,
            windowTitle: title
        )
        var documentURLs = applicationDocumentURL.map { [$0] } ?? documentMetadata.urls
        if UnityProjectResolver.isUnity(bundleIdentifier: bundleIdentifier),
            let project = unityProjectURLProvider(processIdentifier, documentURLs.first),
            !documentURLs.contains(project) {
            documentURLs.append(project)
        }
        if UnrealProjectResolver.isUnreal(bundleIdentifier: bundleIdentifier),
            let project = unrealProjectURLProvider(processIdentifier, documentURLs.first),
            !documentURLs.contains(project) {
            documentURLs.append(project)
        }

        return AXWindowSnapshot(
            documentURL: documentURLs.first,
            documentURLs: documentURLs,
            documentTitles: documentMetadata.titles,
            title: title,
            role: attributeReader.string(
                from: window,
                attribute: kAXRoleAttribute as CFString
            ) ?? kAXWindowRole as String,
            subrole: attributeReader.string(
                from: window,
                attribute: kAXSubroleAttribute as CFString
            ),
            frame: frame,
            isMinimized: attributeReader.bool(
                from: window,
                attribute: kAXMinimizedAttribute as CFString
            ) ?? false,
            isFullscreen: attributeReader.bool(
                from: window,
                attribute: axFullScreenAttribute
            ) ?? false,
            isMain: attributeReader.bool(
                from: window,
                attribute: kAXMainAttribute as CFString
            ) ?? false,
            isHidden: isHidden,
            isModal: attributeReader.bool(from: window, attribute: kAXModalAttribute as CFString)
        )
    }

    private func bestCGWindowMatch(
        for axWindow: AXWindowSnapshot,
        candidates: [CGWindowMetadata]
    ) -> (index: Int, metadata: CGWindowMetadata)? {
        var bestMatch: (
            rank: Int,
            visibilityRank: Int,
            distance: CGFloat,
            index: Int,
            metadata: CGWindowMetadata
        )?

        for (index, candidate) in candidates.enumerated() {
            let titleMatches = axWindow.title.exactMatches(candidate.title)
            let frameMatches = axWindow.frame.approximatelyMatches(candidate.bounds)

            // If geometry is not plausibly close, prefer no CG match over borrowing unrelated metadata.
            let rank: Int
            if titleMatches && frameMatches {
                rank = 0
            } else if frameMatches {
                rank = 1
            } else {
                continue
            }

            let distance = axWindow.frame.matchDistance(to: candidate.bounds)
            let visibilityRank = candidate.isOnScreen ? 0 : 1

            guard bestMatch == nil ||
                    rank < bestMatch!.rank ||
                    (rank == bestMatch!.rank && visibilityRank < bestMatch!.visibilityRank) ||
                    (
                        rank == bestMatch!.rank &&
                        visibilityRank == bestMatch!.visibilityRank &&
                        distance < bestMatch!.distance
                    ) else {
                continue
            }

            bestMatch = (rank, visibilityRank, distance, index, candidate)
        }

        guard let bestMatch else {
            return nil
        }

        return (bestMatch.index, bestMatch.metadata)
    }

    private func discoveredWindow(
        axElement: AXUIElement,
        from axWindow: AXWindowSnapshot,
        cgWindowMetadata: CGWindowMetadata?,
        confirmedWindowID: CGWindowID?
    ) -> DiscoveredWindow {
        let isVisible = cgWindowMetadata?.isOnScreen ?? !axWindow.isHidden

        return DiscoveredWindow(
            axElement: axElement,
            documentURL: axWindow.documentURL,
            documentURLs: axWindow.documentURLs,
            documentTitles: axWindow.documentTitles,
            title: axWindow.title,
            role: axWindow.role,
            subrole: axWindow.subrole,
            frame: axWindow.frame,
            isMinimized: axWindow.isMinimized,
            isFullscreen: axWindow.isFullscreen,
            isMain: axWindow.isMain,
            isVisible: isVisible,
            cgWindowID: confirmedWindowID,
            ownerName: cgWindowMetadata?.ownerName,
            cgLayer: cgWindowMetadata?.layer,
            zOrderHint: cgWindowMetadata?.zOrderHint,
            isOnScreen: cgWindowMetadata?.isOnScreen,
            isModal: axWindow.isModal
        )
    }

    private func unmanageableWindowRejectionReason(
        role: String,
        subrole: String?,
        cgWindowMetadata: CGWindowMetadata?
    ) -> String? {
        if let cgWindowMetadata, cgWindowMetadata.layer != 0 {
            return WindowDiscoveryDiagnosticReason.nonzeroCGWindowLayer
        }

        if transientWindowRoles.contains(role) {
            return WindowDiscoveryDiagnosticReason.transientRole
        }

        if let subrole, transientWindowSubroles.contains(subrole) {
            return WindowDiscoveryDiagnosticReason.transientSubrole
        }

        if role == axDialogRole {
            return cgWindowMetadata?.layer == 0 ? nil : WindowDiscoveryDiagnosticReason.unmanageableDialog
        }

        return nil
    }
}

enum WindowDiscoveryDiagnosticReason {
    static let missingOrInvalidFrame = "missing or invalid frame"
    static let nonzeroCGWindowLayer = "nonzero CoreGraphics window layer"
    static let transientRole = "transient role"
    static let transientSubrole = "transient subrole"
    static let unmanageableDialog = "unmanageable dialog"
}

private struct AXWindowSnapshot {
    let documentURL: URL?
    let documentURLs: [URL]
    let documentTitles: [String]
    let title: String?
    let role: String
    let subrole: String?
    let frame: CGRect
    let isMinimized: Bool
    let isFullscreen: Bool
    let isMain: Bool
    let isHidden: Bool
    let isModal: Bool?
}

struct WindowDocumentURLResolver {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func resolve(_ value: String?) -> URL? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        if let webURL = URL(string: value),
           let components = URLComponents(
               url: webURL,
               resolvingAgainstBaseURL: false
           ),
           let scheme = components.scheme?.lowercased(),
           ["http", "https"].contains(scheme),
           components.host?.nonEmptyValue != nil {
            return components.url
        }

        let expandedValue = NSString(string: value).expandingTildeInPath
        let url: URL
        if let parsedURL = URL(string: expandedValue), parsedURL.isFileURL {
            url = parsedURL.standardizedFileURL
        } else if expandedValue.hasPrefix("/") {
            url = URL(fileURLWithPath: expandedValue).standardizedFileURL
        } else {
            return nil
        }

        guard fileManager.fileExists(atPath: url.path),
              fileManager.isReadableFile(atPath: url.path) else {
            return nil
        }

        return url
    }

    func resolveLocalPathReference(in value: String) -> URL? {
        if let directURL = resolve(value), directURL.isFileURL {
            return directURL
        }

        for marker in [":~/", ":/"] {
            guard let markerRange = value.range(of: marker, options: .backwards) else {
                continue
            }

            let pathStart = value.index(after: markerRange.lowerBound)
            if let url = resolve(String(value[pathStart...])), url.isFileURL {
                return url
            }
        }

        return nil
    }
}

struct ApplicationWindowDocumentURLResolver {
    private let fileManager: FileManager
    private let workspaceStorageDirectoryProvider: (String) -> URL?
    private let indexedWorkspaceFolders: [String: [URL]]?

    init(
        fileManager: FileManager = .default,
        workspaceStorageDirectoryProvider: ((String) -> URL?)? = nil,
        indexedWorkspaceFolders: [String: [URL]]? = nil
    ) {
        self.fileManager = fileManager
        self.indexedWorkspaceFolders = indexedWorkspaceFolders
        self.workspaceStorageDirectoryProvider = workspaceStorageDirectoryProvider ?? {
            guard let applicationSupportName = Self.applicationSupportName(
                bundleIdentifier: $0
            ) else {
                return nil
            }

            return fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
                .appendingPathComponent(applicationSupportName, isDirectory: true)
                .appendingPathComponent("User/workspaceStorage", isDirectory: true)
        }
    }

    func preparing(bundleIdentifiers: Set<String>) -> Self {
        var foldersByBundleIdentifier: [String: [URL]] = [:]
        for bundleIdentifier in bundleIdentifiers
            where Self.applicationSupportName(bundleIdentifier: bundleIdentifier) != nil {
            foldersByBundleIdentifier[bundleIdentifier] = workspaceFolders(
                bundleIdentifier: bundleIdentifier
            )
        }

        return Self(
            fileManager: fileManager,
            workspaceStorageDirectoryProvider: workspaceStorageDirectoryProvider,
            indexedWorkspaceFolders: foldersByBundleIdentifier
        )
    }

    static func applicationSupportName(bundleIdentifier: String) -> String? {
        switch bundleIdentifier {
        case "com.microsoft.VSCode":
            return "Code"
        case "com.microsoft.VSCodeInsiders":
            return "Code - Insiders"
        case "com.google.antigravity-ide":
            return "Antigravity IDE"
        default:
            return nil
        }
    }

    func resolve(bundleIdentifier: String, windowTitle: String?) -> URL? {
        guard let windowTitle = windowTitle?.nonEmptyValue else {
            return nil
        }

        let titleComponents = [" — ", " - "].flatMap { separator in
            windowTitle
                .components(separatedBy: separator)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        let workspaceFolders = if let indexedWorkspaceFolders {
            indexedWorkspaceFolders[bundleIdentifier] ?? []
        } else {
            workspaceFolders(bundleIdentifier: bundleIdentifier)
        }
        let matches = workspaceFolders.filter { folderURL in
            titleComponents.contains {
                $0.caseInsensitiveCompare(folderURL.lastPathComponent) == .orderedSame
            }
        }

        let uniqueMatches = Dictionary(
            matches.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard uniqueMatches.count == 1 else {
            return nil
        }

        return uniqueMatches.values.first
    }

    private func workspaceFolders(bundleIdentifier: String) -> [URL] {
        guard let storageDirectory = workspaceStorageDirectoryProvider(bundleIdentifier),
              let entries = try? fileManager.contentsOfDirectory(
                  at: storageDirectory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return entries.compactMap { entry in
            let metadataURL = entry.appendingPathComponent("workspace.json")
            guard let data = try? Data(contentsOf: metadataURL),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let folderValue = object["folder"] as? String,
                  let folderURL = URL(string: folderValue)?.standardizedFileURL,
                  folderURL.isFileURL,
                  isExistingDirectory(folderURL) else {
                return nil
            }

            return folderURL
        }
    }

    private func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) &&
            isDirectory.boolValue
    }
}

struct WindowDocumentMetadata {
    let urls: [URL]
    let titles: [String]
}

struct WindowDocumentMetadataFinder {
    let attributeReader: AXAttributeReader
    let urlResolver: WindowDocumentURLResolver
    var maximumDepth = 12
    var maximumElementCount = 2_048

    func resolve(in window: AXUIElement) -> WindowDocumentMetadata {
        var urls: [URL] = []
        var titles: [String] = []
        var queue = [(element: window, depth: 0, isTab: false)]
        var index = 0

        while index < queue.count, index < maximumElementCount {
            let candidate = queue[index]
            index += 1

            let role = attributeReader.string(
                from: candidate.element,
                attribute: kAXRoleAttribute as CFString
            )

            if candidate.isTab,
               let title = attributeReader.string(
                from: candidate.element,
                attribute: kAXTitleAttribute as CFString
               )?.nonEmptyValue,
               !titles.contains(title) {
                titles.append(title)
            }

            let attributes: [CFString] = candidate.depth == 0 || role == "AXWebArea"
                ? [
                    kAXDocumentAttribute as CFString,
                    kAXURLAttribute as CFString
                ]
                : [kAXDocumentAttribute as CFString]
            for attribute in attributes {
                let value = attributeReader.urlString(
                    from: candidate.element,
                    attribute: attribute
                )
                if let url = urlResolver.resolve(value), !urls.contains(url) {
                    urls.append(url)
                }
            }

            if role == "AXWebArea" {
                continue
            }

            guard candidate.depth < maximumDepth,
                  let children = attributeReader.elementArray(
                      from: candidate.element,
                      attribute: kAXChildrenAttribute as CFString
                  ) else {
                continue
            }

            queue.append(contentsOf: children.map {
                (
                    element: $0,
                    depth: candidate.depth + 1,
                    isTab: role == "AXTabGroup"
                )
            })
        }

        return WindowDocumentMetadata(urls: urls, titles: titles)
    }
}

private extension CGRect {
    var isValidDiscoveredWindowFrame: Bool {
        !isNull &&
        !isInfinite &&
        !isEmpty &&
        origin.x.isFinite &&
        origin.y.isFinite &&
        size.width.isFinite &&
        size.height.isFinite &&
        size.width > 0 &&
        size.height > 0
    }

    func approximatelyMatches(_ other: CGRect) -> Bool {
        abs(minX - other.minX) <= approximateFrameTolerance &&
        abs(minY - other.minY) <= approximateFrameTolerance &&
        abs(width - other.width) <= approximateFrameTolerance &&
        abs(height - other.height) <= approximateFrameTolerance
    }

    func matchDistance(to other: CGRect) -> CGFloat {
        abs(minX - other.minX) +
        abs(minY - other.minY) +
        abs(width - other.width) +
        abs(height - other.height)
    }
}

private extension Optional where Wrapped == String {
    func exactMatches(_ other: String?) -> Bool {
        guard let left = self?.nonEmptyValue,
              let right = other?.nonEmptyValue else {
            return false
        }

        return left == right
    }
}
