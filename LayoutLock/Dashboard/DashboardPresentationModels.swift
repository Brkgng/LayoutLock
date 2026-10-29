import Foundation

struct DashboardDisplayPreviewModel: Identifiable {
    let display: DisplayRecord
    let windows: [WindowRecord]

    var id: UInt32 {
        display.id
    }
}

struct DashboardWindowPreviewGroup: Identifiable {
    let displayID: UInt32
    let windows: [WindowRecord]
    let displayFrame: CGRect

    var id: UUID {
        frontmostWindow.id
    }

    var frontmostWindow: WindowRecord {
        windows[0]
    }

    var overlapCount: Int {
        max(windows.count - 1, 0)
    }
}

struct DashboardAppSummary: Identifiable {
    let identity: DashboardAppIdentity
    let windows: [WindowRecord]

    var id: String {
        identity.bundleIdentifier
    }

    var bundleIdentifier: String {
        identity.bundleIdentifier
    }

    var name: String {
        identity.name
    }

    var windowCount: Int {
        windows.count
    }

    var visibleWindowTitles: [String] {
        windows.compactMap { window in
            let title = window.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            return title?.isEmpty == false ? title : nil
        }
    }
}

struct DashboardInactiveAppSummary: Identifiable {
    let appSummary: DashboardAppSummary
    let isAvailable: Bool

    var statusText: String {
        isAvailable ? "Not Running" : "App Not Found"
    }

    var id: String {
        appSummary.id
    }

    var identity: DashboardAppIdentity {
        appSummary.identity
    }

    var name: String {
        appSummary.name
    }

    var windowCount: Int {
        appSummary.windowCount
    }
}

struct DashboardWindowRemovalConfirmation {
    let snapshotID: UUID
    let snapshotName: String
    let appIdentity: DashboardAppIdentity
    let windowID: UUID
    let windowTitle: String?
    let isLastWindowOnDisplay: Bool

    var appName: String {
        appIdentity.name
    }

    var windowDisplayTitle: String {
        windowTitle.nonEmptyValue ?? "Untitled window"
    }

    var message: String {
        let previewNote = isLastWindowOnDisplay
            ? " This is the last saved window on this display, so the display will no longer appear in the layout preview."
            : ""
        return "Remove this saved window from \"\(snapshotName)\"? This cannot be undone.\(previewNote)"
    }
}

enum DashboardSidebarSearch {
    static let minimumLayoutCount = 5

    static func showsSearchField(layoutCount: Int) -> Bool {
        layoutCount >= minimumLayoutCount
    }

    static func filteredSummaries(
        _ summaries: [SnapshotSummary],
        query: String
    ) -> [SnapshotSummary] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return summaries
        }

        return summaries.filter {
            $0.name.range(
                of: trimmedQuery,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }

    static func replacementSelectionID(
        in summaries: [SnapshotSummary],
        query: String
    ) -> UUID? {
        let visibleSummaries = showsSearchField(layoutCount: summaries.count)
            ? filteredSummaries(summaries, query: query)
            : summaries

        return (visibleSummaries.first ?? summaries.first)?.id
    }
}

enum DashboardSnapshotPresentation {
    static let windowOverlapThreshold = 0.35

    static func windowListTitles(for snapshot: Snapshot) -> [UUID: String] {
        let windowsByApp = Dictionary(grouping: snapshot.windows, by: \.bundleIdentifier)
        var titles: [UUID: String] = [:]
        for windows in windowsByApp.values where windows.count > 1 {
            for window in windows where window.openingConfiguration.effectiveTargets.isEmpty {
                titles[window.id] = window.windowTitle?.nonEmptyValue
            }
        }
        return titles
    }

    static func displayPreviewModels(for snapshot: Snapshot) -> [DashboardDisplayPreviewModel] {
        let windowsByDisplayID = Dictionary(grouping: assignedWindows(in: snapshot)) { window in
            window.displayID ?? 0
        }

        return snapshot.sourceDisplayState.displays.compactMap { display in
            guard let windows = windowsByDisplayID[display.id],
                  !windows.isEmpty else {
                return nil
            }

            return DashboardDisplayPreviewModel(
                display: display,
                windows: windows
            )
        }
    }

    static func displayPreviewEmptyMessage(for snapshot: Snapshot) -> String? {
        if snapshot.sourceDisplayState.displays.isEmpty {
            return "No displays were saved in this layout."
        }

        if displayPreviewModels(for: snapshot).isEmpty {
            return "No saved windows are assigned to saved displays."
        }

        return nil
    }

    static func unassignedWindows(in snapshot: Snapshot) -> [WindowRecord] {
        let displayIDs = Set(snapshot.sourceDisplayState.displays.map(\.id))
        return snapshot.windows.filter { window in
            guard let displayID = window.displayID else {
                return true
            }

            return !displayIDs.contains(displayID)
        }
    }

    static func appSummaries(
        for snapshot: Snapshot,
        identityResolver: (String) -> DashboardAppIdentity
    ) -> [DashboardAppSummary] {
        Dictionary(grouping: snapshot.windows, by: \.bundleIdentifier)
            .map { bundleIdentifier, windows in
                DashboardAppSummary(
                    identity: identityResolver(bundleIdentifier),
                    windows: sortedWindows(windows)
                )
            }
            .sorted { lhs, rhs in
                if lhs.windowCount != rhs.windowCount {
                    return lhs.windowCount > rhs.windowCount
                }

                let nameComparison = lhs.name.localizedStandardCompare(rhs.name)
                if nameComparison != .orderedSame {
                    return nameComparison == .orderedAscending
                }

                return lhs.bundleIdentifier < rhs.bundleIdentifier
            }
    }

    static func inactiveAppSummaries(
        for snapshot: Snapshot,
        runningBundleIdentifiers: Set<String>,
        unavailableBundleIdentifiers: Set<String> = [],
        identityResolver: (String) -> DashboardAppIdentity
    ) -> [DashboardInactiveAppSummary] {
        appSummaries(for: snapshot, identityResolver: identityResolver)
            .filter { !runningBundleIdentifiers.contains($0.bundleIdentifier) }
            .map { DashboardInactiveAppSummary(appSummary: $0,
                isAvailable: !unavailableBundleIdentifiers.contains($0.bundleIdentifier)) }
    }

    static func windowPreviewGroups(
        for windows: [WindowRecord],
        displayID: UInt32,
        displayFrame: CGRect,
        overlapThreshold: Double = windowOverlapThreshold
    ) -> [DashboardWindowPreviewGroup] {
        var groups: [[WindowRecord]] = []

        for window in sortedWindows(windows) {
            if let groupIndex = groups.firstIndex(where: { group in
                group.contains { groupedWindow in
                    windowsOverlap(
                        previewFrame(for: window, in: displayFrame),
                        previewFrame(for: groupedWindow, in: displayFrame),
                        threshold: overlapThreshold
                    )
                }
            }) {
                groups[groupIndex].append(window)
            } else {
                groups.append([window])
            }
        }

        return groups.map { group in
            DashboardWindowPreviewGroup(
                displayID: displayID,
                windows: group,
                displayFrame: displayFrame
            )
        }
    }

    static func previewFrame(for window: WindowRecord, in display: DisplayRecord) -> CGRect {
        window.normalizedFrame.denormalized(in: display.frameRect)
    }

    private static func previewFrame(for window: WindowRecord, in displayFrame: CGRect) -> CGRect {
        window.normalizedFrame.denormalized(in: displayFrame)
    }

    static func windowsForDisplayList(_ windows: [WindowRecord]) -> [WindowRecord] {
        sortedWindows(windows)
    }

    static func openingTargetDescription(for window: WindowRecord) -> String? {
        openingTargetDescriptions(for: window).first
    }

    static func primaryWindowDescription(
        for window: WindowRecord,
        applicationName: String
    ) -> String? {
        if let openingTargetDescription = openingTargetDescription(for: window) {
            return openingTargetDescription
        }

        guard window.openingConfiguration.manualTargets?.isEmpty != true else {
            return nil
        }

        return windowTitleDescription(for: window, applicationName: applicationName)
    }

    static func windowTitleDescription(
        for window: WindowRecord,
        applicationName: String
    ) -> String? {
        guard let title = window.windowTitle?.nonEmptyValue else {
            return nil
        }

        let redundantTitles = [applicationName, "Untitled", "Untitled Window"]
        guard !redundantTitles.contains(where: {
            $0.caseInsensitiveCompare(title) == .orderedSame
        }) else {
            return nil
        }

        return title
    }

    static func openingTargetDescriptions(for window: WindowRecord) -> [String] {
        window.openingConfiguration.effectiveTargets.map { target in
            target.compactDisplayName
        }
    }

    static func hasMissingOpeningTarget(
        for window: WindowRecord,
        fileManager: FileManager = .default
    ) -> Bool {
        window.openingConfiguration.effectiveTargets.contains {
            $0.isMissing(fileManager: fileManager)
        }
    }

    private static func assignedWindows(in snapshot: Snapshot) -> [WindowRecord] {
        let displayIDs = Set(snapshot.sourceDisplayState.displays.map(\.id))
        return snapshot.windows.filter { window in
            guard let displayID = window.displayID else {
                return false
            }

            return displayIDs.contains(displayID)
        }
    }

    private static func sortedWindows(_ windows: [WindowRecord]) -> [WindowRecord] {
        windows.sorted { lhs, rhs in
            switch (lhs.zOrderHint, rhs.zOrderHint) {
            case let (lhsHint?, rhsHint?) where lhsHint != rhsHint:
                return lhsHint < rhsHint
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }

    private static func windowsOverlap(
        _ lhs: CGRect,
        _ rhs: CGRect,
        threshold: Double
    ) -> Bool {
        guard lhs.width > 0, lhs.height > 0, rhs.width > 0, rhs.height > 0 else {
            return false
        }

        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else {
            return false
        }

        let intersectionArea = intersection.width * intersection.height
        let lhsArea = lhs.width * lhs.height
        let rhsArea = rhs.width * rhs.height
        let smallerWindowArea = min(lhsArea, rhsArea)

        guard smallerWindowArea > 0 else {
            return false
        }

        return (intersectionArea / smallerWindowArea) >= threshold
    }
}

enum DashboardLocalTargetSelection: Equatable, Hashable, Sendable {
    case none
    case files
    case folders
    case filesAndFolders

    var sectionTitle: String {
        switch self {
        case .none:
            return ""
        case .files:
            return "Add File"
        case .folders:
            return "Add Folder"
        case .filesAndFolders:
            return "Add Path"
        }
    }

    var addButtonTitle: String {
        sectionTitle
    }

    var chooseButtonTitle: String {
        switch self {
        case .none:
            return ""
        case .files:
            return "Choose File…"
        case .folders:
            return "Choose Folder…"
        case .filesAndFolders:
            return "Choose Path…"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .none:
            return ""
        case .files:
            return "File path"
        case .folders:
            return "Folder path"
        case .filesAndFolders:
            return "File or folder path"
        }
    }

    var expectedKind: WindowOpenTargetKind? {
        switch self {
        case .none, .filesAndFolders:
            return nil
        case .files:
            return .file
        case .folders:
            return .folder
        }
    }

    var canChooseFiles: Bool {
        self == .files || self == .filesAndFolders
    }

    var canChooseDirectories: Bool {
        self == .folders || self == .filesAndFolders
    }

    func includes(_ kind: WindowOpenTargetKind) -> Bool {
        switch (self, kind) {
        case (.files, .file),
             (.folders, .folder),
             (.filesAndFolders, .file),
             (.filesAndFolders, .folder):
            return true
        default:
            return false
        }
    }
}

struct DashboardPathSuggestion: Equatable, Identifiable, Sendable {
    let url: URL
    let kind: WindowOpenTargetKind
    let displayPath: String
    let isSelectable: Bool

    var id: URL {
        url
    }

    var name: String {
        url.lastPathComponent
    }
}

enum DashboardPathSuggestionNavigation {
    static func movedIndex(
        from currentIndex: Int?,
        offset: Int,
        suggestionCount: Int
    ) -> Int? {
        guard suggestionCount > 0 else {
            return nil
        }

        let currentIndex = currentIndex ?? (offset > 0 ? -1 : suggestionCount)
        return min(max(currentIndex + offset, 0), suggestionCount - 1)
    }
}

actor DashboardPathSuggestionProvider {
    typealias DirectoryContents = @Sendable (URL) throws -> [URL]

    private let homeDirectoryURL: URL
    private let directoryContents: DirectoryContents
    private let maximumSuggestionCount: Int

    init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        maximumSuggestionCount: Int = 8
    ) {
        self.homeDirectoryURL = homeDirectoryURL.standardizedFileURL
        self.maximumSuggestionCount = maximumSuggestionCount
        directoryContents = { directoryURL in
            try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        }
    }

    init(
        homeDirectoryURL: URL,
        maximumSuggestionCount: Int = 8,
        directoryContents: @escaping DirectoryContents
    ) {
        self.homeDirectoryURL = homeDirectoryURL.standardizedFileURL
        self.maximumSuggestionCount = maximumSuggestionCount
        self.directoryContents = directoryContents
    }

    func suggestions(
        for input: String,
        selection: DashboardLocalTargetSelection
    ) -> [DashboardPathSuggestion] {
        guard selection != .none,
              let query = DashboardPathSuggestionQuery(
                  input: input,
                  homeDirectoryURL: homeDirectoryURL
              ),
              let entries = try? directoryContents(query.directoryURL) else {
            return []
        }

        let includesHiddenEntries = query.fragment.hasPrefix(".")
        return entries.compactMap { entryURL in
            let name = entryURL.lastPathComponent
            guard !name.isEmpty,
                  includesHiddenEntries || !name.hasPrefix("."),
                  query.fragment.isEmpty || name.range(
                      of: query.fragment,
                      options: [.anchored, .caseInsensitive, .diacriticInsensitive]
                  ) != nil,
                  let isDirectory = try? entryURL.resourceValues(
                      forKeys: [.isDirectoryKey]
                  ).isDirectory else {
                return nil
            }

            let kind: WindowOpenTargetKind = isDirectory ? .folder : .file
            if kind == .file, selection == .folders {
                return nil
            }

            return DashboardPathSuggestion(
                url: entryURL.standardizedFileURL,
                kind: kind,
                displayPath: query.displayPrefix
                    + name
                    + (isDirectory ? "/" : ""),
                isSelectable: selection.includes(kind)
            )
        }
        .sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            if comparison == .orderedSame {
                return $0.url.path < $1.url.path
            }
            return comparison == .orderedAscending
        }
        .prefix(maximumSuggestionCount)
        .map { $0 }
    }
}

private struct DashboardPathSuggestionQuery {
    let directoryURL: URL
    let displayPrefix: String
    let fragment: String

    init?(input: String, homeDirectoryURL: URL) {
        let typedValue = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = typedValue.isEmpty
            ? "~/"
            : typedValue.hasPrefix("~") || typedValue.hasPrefix("/")
            ? typedValue
            : "~/" + typedValue

        if value == "~" {
            directoryURL = homeDirectoryURL
            displayPrefix = "~/"
            fragment = ""
            return
        }

        guard value.hasPrefix("~/") || value.hasPrefix("/") else {
            return nil
        }

        if value.hasSuffix("/") {
            guard let resolvedDirectoryURL = Self.resolve(
                displayPath: value,
                homeDirectoryURL: homeDirectoryURL
            ) else {
                return nil
            }

            directoryURL = resolvedDirectoryURL
            displayPrefix = value
            fragment = ""
            return
        }

        guard let separatorIndex = value.lastIndex(of: "/") else {
            return nil
        }

        let prefixEndIndex = value.index(after: separatorIndex)
        let prefix = String(value[..<prefixEndIndex])
        guard let resolvedDirectoryURL = Self.resolve(
            displayPath: prefix,
            homeDirectoryURL: homeDirectoryURL
        ) else {
            return nil
        }

        directoryURL = resolvedDirectoryURL
        displayPrefix = prefix
        fragment = String(value[prefixEndIndex...])
    }

    private static func resolve(
        displayPath: String,
        homeDirectoryURL: URL
    ) -> URL? {
        if displayPath.hasPrefix("~/") {
            return URL(
                fileURLWithPath: homeDirectoryURL.path + displayPath.dropFirst(),
                isDirectory: true
            ).standardizedFileURL
        }

        guard displayPath.hasPrefix("/") else {
            return nil
        }

        return URL(
            fileURLWithPath: displayPath,
            isDirectory: true
        ).standardizedFileURL
    }
}

struct DashboardOpeningTargetCapabilities: Equatable {
    let supportedKinds: Set<WindowOpenTargetKind>
    let hasExistingTargets: Bool

    var supportsWebURLs: Bool {
        supportedKinds.contains(.webURL)
    }

    var localTargetSelection: DashboardLocalTargetSelection {
        switch (
            supportedKinds.contains(.file),
            supportedKinds.contains(.folder)
        ) {
        case (true, true):
            return .filesAndFolders
        case (true, false):
            return .files
        case (false, true):
            return .folders
        case (false, false):
            return .none
        }
    }

    var showsEditor: Bool {
        !supportedKinds.isEmpty || hasExistingTargets
    }

    static func resolve(for window: WindowRecord) -> DashboardOpeningTargetCapabilities {
        let bundleIdentifier = window.bundleIdentifier
        let supportedKinds: Set<WindowOpenTargetKind>

        if appOnlyBundleIdentifiers.contains(bundleIdentifier) {
            supportedKinds = []
        } else if browserBundleIdentifierPrefixes.contains(where: {
            bundleIdentifier.hasPrefix($0)
        }) {
            supportedKinds = [.webURL]
        } else if fileAndFolderBundleIdentifiers.contains(bundleIdentifier) {
            supportedKinds = [.file, .folder]
        } else if folderBundleIdentifiers.contains(bundleIdentifier) {
            supportedKinds = [.folder]
        } else if fileBundleIdentifiers.contains(bundleIdentifier) {
            supportedKinds = [.file]
        } else {
            let configuration = window.openingConfiguration
            supportedKinds = Set<WindowOpenTargetKind>([.file, .folder])
                .union(configuration.automaticallyCapturedTargets.map(\.kind))
                .union((configuration.manualTargets ?? []).map(\.kind))
        }

        return DashboardOpeningTargetCapabilities(
            supportedKinds: supportedKinds,
            hasExistingTargets: !window.openingConfiguration.effectiveTargets.isEmpty
        )
    }

    private static let browserBundleIdentifierPrefixes = [
        "com.apple.Safari",
        "com.brave.Browser",
        "com.google.Chrome",
        "com.kagi.kagimacOS",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "org.mozilla.nightly"
    ]

    private static let fileAndFolderBundleIdentifiers: Set<String> = [
        "com.apple.dt.Xcode",
        "com.google.antigravity-ide",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders"
    ]

    private static let folderBundleIdentifiers: Set<String> = [
        "com.mitchellh.ghostty"
    ]

    private static let fileBundleIdentifiers: Set<String> = [
        "com.apple.Preview",
        "com.apple.TextEdit"
    ]

    private static let appOnlyBundleIdentifiers: Set<String> = [
        "com.openai.chat",
        "com.openai.codex",
        "com.toggl.daneel",
        "net.whatsapp.WhatsApp"
    ]
}
