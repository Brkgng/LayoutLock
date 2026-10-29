import AppKit
import SwiftUI
import XCTest
@testable import LayoutLock

final class DashboardPresentationModelsTests: XCTestCase {
    func testLaunchModeUsesLoginItemArgumentOnlyForBackgroundLaunches() {
        XCTAssertEqual(AppLaunchMode(arguments: ["LayoutLock"]), .foreground)
        XCTAssertEqual(
            AppLaunchMode(arguments: ["LayoutLock", AppLaunchMode.loginItemArgument]),
            .loginItem
        )
    }

    func testForegroundLaunchAllowsAutomaticOnboarding() {
        var startCount = 0

        let didStart = AutomaticOnboardingPresentationPolicy.startIfAllowed(
            for: .foreground
        ) {
            startCount += 1
            return true
        }

        XCTAssertTrue(didStart)
        XCTAssertEqual(startCount, 1)
    }

    func testLoginItemLaunchLeavesOnboardingAvailableForExplicitPresentation() {
        var startCount = 0
        func startOnboarding() -> Bool {
            startCount += 1
            return true
        }

        let didStartAutomatically = AutomaticOnboardingPresentationPolicy.startIfAllowed(
            for: .loginItem,
            start: startOnboarding
        )

        XCTAssertFalse(didStartAutomatically)
        XCTAssertEqual(startCount, 0)
        XCTAssertTrue(startOnboarding())
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testExternalLaunchSuppressesAutomaticOnboarding() {
        let presentationState = AppLaunchPresentationState()
        presentationState.suppressInitialPresentation()
        var startCount = 0

        let didStart = AutomaticOnboardingPresentationPolicy.startIfAllowed(
            for: .foreground,
            presentationState: presentationState
        ) {
            startCount += 1
            return true
        }

        XCTAssertFalse(didStart)
        XCTAssertEqual(startCount, 0)
    }

    func testReopenPolicyUsesExistingDashboardBeforeNormalWindowReopening() {
        XCTAssertFalse(
            DashboardReopenPolicy.shouldAllowNormalReopen(focusedExistingWindow: true)
        )
        XCTAssertTrue(
            DashboardReopenPolicy.shouldAllowNormalReopen(focusedExistingWindow: false)
        )
    }

    @MainActor
    func testForegroundLaunchPresentsInitialDashboardExactlyOnce() {
        let window = NSWindow()
        var activationCount = 0
        var shownWindows: [NSWindow] = []
        var hiddenWindows: [NSWindow] = []
        let coordinator = DashboardWindowPresentationCoordinator(
            launchMode: .foreground,
            actions: .init(
                activateApplication: { activationCount += 1 },
                showWindow: { shownWindows.append($0) },
                hideWindow: { hiddenWindows.append($0) }
            )
        )

        coordinator.presentInitialWindow(window)
        coordinator.presentInitialWindow(window)

        XCTAssertEqual(activationCount, 1)
        XCTAssertEqual(shownWindows, [window])
        XCTAssertTrue(hiddenWindows.isEmpty)
        XCTAssertTrue(coordinator.hasPresentedInitialWindow)
    }

    @MainActor
    func testLoginItemLaunchSuppressesInitialDashboardExactlyOnce() {
        let window = NSWindow()
        var activationCount = 0
        var shownWindows: [NSWindow] = []
        var hiddenWindows: [NSWindow] = []
        let coordinator = DashboardWindowPresentationCoordinator(
            launchMode: .loginItem,
            actions: .init(
                activateApplication: { activationCount += 1 },
                showWindow: { shownWindows.append($0) },
                hideWindow: { hiddenWindows.append($0) }
            )
        )

        coordinator.presentInitialWindow(window)
        coordinator.presentInitialWindow(window)

        XCTAssertEqual(activationCount, 0)
        XCTAssertTrue(shownWindows.isEmpty)
        XCTAssertEqual(hiddenWindows, [window])
        XCTAssertTrue(coordinator.hasPresentedInitialWindow)
    }

    @MainActor
    func testExternalLaunchSuppressesInitialDashboardWithoutActivation() {
        let window = NSWindow()
        let presentationState = AppLaunchPresentationState()
        presentationState.suppressInitialPresentation()
        var activationCount = 0
        var shownWindows: [NSWindow] = []
        var hiddenWindows: [NSWindow] = []
        let coordinator = DashboardWindowPresentationCoordinator(
            launchMode: .foreground,
            presentationState: presentationState,
            actions: .init(
                activateApplication: { activationCount += 1 },
                showWindow: { shownWindows.append($0) },
                hideWindow: { hiddenWindows.append($0) }
            )
        )

        coordinator.presentInitialWindow(window)

        XCTAssertEqual(activationCount, 0)
        XCTAssertTrue(shownWindows.isEmpty)
        XCTAssertEqual(hiddenWindows, [window])
    }

    @MainActor
    func testDashboardWindowSupportConfiguresWindowIdentityAndAutosaveName() {
        let frameAutosaveName = "LayoutLockDashboardTests.\(UUID().uuidString)"
        NSWindow.removeFrame(usingName: frameAutosaveName)
        defer {
            NSWindow.removeFrame(usingName: frameAutosaveName)
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )

        DashboardWindowSupport.configure(window, frameAutosaveName: frameAutosaveName)

        XCTAssertEqual(window.identifier, DashboardWindowSupport.identifier)
        XCTAssertEqual(window.frameAutosaveName, frameAutosaveName)
    }

    @MainActor
    func testDashboardWindowSupportSavesFrameWithAutosaveName() {
        let frameAutosaveName = "LayoutLockDashboardTests.\(UUID().uuidString)"
        let frameAutosaveKey = "NSWindow Frame \(frameAutosaveName)"
        NSWindow.removeFrame(usingName: frameAutosaveName)
        defer {
            NSWindow.removeFrame(usingName: frameAutosaveName)
        }

        let window = NSWindow(
            contentRect: NSRect(x: 20, y: 30, width: 320, height: 240),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )

        DashboardWindowSupport.saveFrame(window, frameAutosaveName: frameAutosaveName)

        XCTAssertNotNil(UserDefaults.standard.string(forKey: frameAutosaveKey))
    }

    func testDashboardSnapshotNameRequestTrimsSubmittedName() {
        let request = DashboardSnapshotNameRequest(defaultName: "Layout - Default")

        XCTAssertEqual(request.submissionName(for: "  Focus  "), "Focus")
    }

    func testDashboardSnapshotNameRequestUsesDefaultForBlankName() {
        let request = DashboardSnapshotNameRequest(defaultName: "Layout - Default")

        XCTAssertEqual(request.submissionName(for: "  \n "), "Layout - Default")
    }

    func testOpeningTargetPresentationDescribesOnlyEffectiveTargets() throws {
        let appOnlyWindow = makeWindow(
            bundleIdentifier: "com.example.editor",
            windowTitle: "Notes"
        )
        let automaticBrowserTarget = WindowOpenTarget(
            kind: .webURL,
            url: try XCTUnwrap(URL(string: "https://youtube.com/watch")),
            title: "YouTube"
        )
        let browserWindow = makeWindow(
            bundleIdentifier: "org.mozilla.firefoxdeveloperedition",
            windowTitle: "YouTube"
        ).withOpeningConfiguration(
            WindowOpeningConfiguration(
                automaticallyCapturedTargets: [automaticBrowserTarget]
            )
        )
        let manualBrowserWindow = browserWindow.withOpeningConfiguration(
            WindowOpeningConfiguration(
                manualTargets: [
                    WindowOpenTarget(
                        kind: .webURL,
                        url: try XCTUnwrap(URL(string: "https://example.com/"))
                    )
                ]
            )
        )
        let projectWindow = appOnlyWindow.withOpeningConfiguration(
            WindowOpeningConfiguration(
                manualTargets: [
                    WindowOpenTarget(
                        kind: .file,
                        url: URL(fileURLWithPath: "/tmp/LayoutLock.xcodeproj")
                    )
                ]
            )
        )
        let manuallyClearedWindow = appOnlyWindow.withOpeningConfiguration(
            WindowOpeningConfiguration(
                automaticallyCapturedTargets: [
                    WindowOpenTarget(
                        kind: .folder,
                        url: URL(fileURLWithPath: "/tmp/Notes")
                    )
                ],
                manualTargets: []
            )
        )

        XCTAssertNil(DashboardSnapshotPresentation.openingTargetDescription(for: appOnlyWindow))
        XCTAssertEqual(
            DashboardSnapshotPresentation.primaryWindowDescription(
                for: appOnlyWindow,
                applicationName: "Editor"
            ),
            appOnlyWindow.windowTitle
        )
        XCTAssertNil(
            DashboardSnapshotPresentation.openingTargetDescription(
                for: manuallyClearedWindow
            )
        )
        XCTAssertNil(
            DashboardSnapshotPresentation.primaryWindowDescription(
                for: manuallyClearedWindow,
                applicationName: "Editor"
            )
        )
        XCTAssertEqual(
            DashboardSnapshotPresentation.openingTargetDescription(for: browserWindow),
            "YouTube"
        )
        XCTAssertEqual(
            DashboardSnapshotPresentation.openingTargetDescription(for: manualBrowserWindow),
            "example.com"
        )
        XCTAssertEqual(
            DashboardSnapshotPresentation.openingTargetDescription(for: projectWindow),
            "LayoutLock"
        )
        XCTAssertEqual(
            DashboardSnapshotPresentation.openingTargetDescriptions(for: projectWindow),
            ["LayoutLock"]
        )
        XCTAssertEqual(
            DashboardSnapshotPresentation.primaryWindowDescription(
                for: projectWindow,
                applicationName: "Editor"
            ),
            "LayoutLock"
        )
        XCTAssertNil(
            DashboardSnapshotPresentation.openingTargetDescription(
                for: makeWindow(
                    bundleIdentifier: "com.openai.chat",
                    windowTitle: "ChatGPT"
                )
            )
        )
        XCTAssertNil(
            DashboardSnapshotPresentation.windowTitleDescription(
                for: makeWindow(
                    bundleIdentifier: "com.example.untitled",
                    windowTitle: "   "
                ),
                applicationName: "Example"
            )
        )
        XCTAssertNil(
            DashboardSnapshotPresentation.windowTitleDescription(
                for: makeWindow(
                    bundleIdentifier: "com.whatsapp",
                    windowTitle: " WhatsApp "
                ),
                applicationName: "WhatsApp"
            )
        )
        XCTAssertNil(
            DashboardSnapshotPresentation.windowTitleDescription(
                for: makeWindow(
                    bundleIdentifier: "com.toggl.track",
                    windowTitle: "Untitled"
                ),
                applicationName: "Toggl Track"
            )
        )
        XCTAssertEqual(
            DashboardSnapshotPresentation.windowTitleDescription(
                for: appOnlyWindow,
                applicationName: "Editor"
            ),
            "Notes"
        )
    }

    func testOpeningTargetPresentationShowsEveryTargetAndMissingLocalTarget() throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Missing.xcodeproj")
        let window = makeWindow(
            bundleIdentifier: "com.example.editor"
        ).withOpeningConfiguration(
            WindowOpeningConfiguration(
                manualTargets: [
                    WindowOpenTarget(kind: .file, url: missingURL),
                    WindowOpenTarget(
                        kind: .webURL,
                        url: try XCTUnwrap(URL(string: "https://example.com/"))
                    )
                ]
            )
        )

        XCTAssertEqual(
            DashboardSnapshotPresentation.openingTargetDescriptions(for: window),
            ["Missing", "example.com"]
        )
        XCTAssertTrue(DashboardSnapshotPresentation.hasMissingOpeningTarget(for: window))
    }

    func testOpeningTargetCapabilitiesAllowOnlyURLsForRecognizedBrowsers() {
        let browserBundleIdentifiers = [
            "com.apple.Safari",
            "com.brave.Browser",
            "com.google.Chrome",
            "com.kagi.kagimacOS",
            "com.microsoft.edgemac",
            "com.operasoftware.Opera",
            "com.vivaldi.Vivaldi",
            "company.thebrowser.Browser",
            "org.mozilla.firefoxdeveloperedition",
            "org.mozilla.nightly"
        ]

        for bundleIdentifier in browserBundleIdentifiers {
            let capabilities = DashboardOpeningTargetCapabilities.resolve(
                for: makeWindow(bundleIdentifier: bundleIdentifier)
            )

            XCTAssertEqual(capabilities.supportedKinds, [.webURL])
            XCTAssertEqual(capabilities.localTargetSelection, .none)
            XCTAssertTrue(capabilities.supportsWebURLs)
            XCTAssertTrue(capabilities.showsEditor)
        }
    }

    func testOpeningTargetCapabilitiesMatchSupportedLocalApps() {
        let expectedKindsByBundleIdentifier: [String: Set<WindowOpenTargetKind>] = [
            "com.apple.dt.Xcode": [.file, .folder],
            "com.google.antigravity-ide": [.file, .folder],
            "com.microsoft.VSCode": [.file, .folder],
            "com.microsoft.VSCodeInsiders": [.file, .folder],
            "com.mitchellh.ghostty": [.folder],
            "com.apple.Preview": [.file],
            "com.apple.TextEdit": [.file]
        ]

        for (bundleIdentifier, expectedKinds) in expectedKindsByBundleIdentifier {
            let capabilities = DashboardOpeningTargetCapabilities.resolve(
                for: makeWindow(bundleIdentifier: bundleIdentifier)
            )

            XCTAssertEqual(capabilities.supportedKinds, expectedKinds)
            XCTAssertFalse(capabilities.supportsWebURLs)
            XCTAssertTrue(capabilities.showsEditor)
        }
    }

    func testOpeningTargetCapabilitiesKeepKnownAppOnlyWindowsUneditable() {
        let appOnlyBundleIdentifiers = [
            "com.openai.chat",
            "com.openai.codex",
            "com.toggl.daneel",
            "net.whatsapp.WhatsApp"
        ]

        for bundleIdentifier in appOnlyBundleIdentifiers {
            let capabilities = DashboardOpeningTargetCapabilities.resolve(
                for: makeWindow(bundleIdentifier: bundleIdentifier)
            )

            XCTAssertTrue(capabilities.supportedKinds.isEmpty)
            XCTAssertFalse(capabilities.showsEditor)
        }
    }

    func testOpeningTargetCapabilitiesAllowFilesAndFoldersForUnknownAppsWithoutTargets() {
        let capabilities = DashboardOpeningTargetCapabilities.resolve(
            for: makeWindow(bundleIdentifier: "com.example.unknown")
        )

        XCTAssertEqual(capabilities.supportedKinds, [.file, .folder])
        XCTAssertEqual(capabilities.localTargetSelection, .filesAndFolders)
        XCTAssertFalse(capabilities.supportsWebURLs)
        XCTAssertFalse(capabilities.hasExistingTargets)
        XCTAssertTrue(capabilities.showsEditor)
    }

    func testOpeningTargetCapabilitiesPreserveAutomaticAndManualKindsForUnknownApps() throws {
        let fileTarget = WindowOpenTarget(
            kind: .file,
            url: URL(fileURLWithPath: "/tmp/Document.txt")
        )
        let webTarget = WindowOpenTarget(
            kind: .webURL,
            url: try XCTUnwrap(URL(string: "https://example.com/"))
        )
        let automaticWindow = makeWindow(
            bundleIdentifier: "com.example.document"
        ).withOpeningConfiguration(
            WindowOpeningConfiguration(
                automaticallyCapturedTargets: [fileTarget, webTarget]
            )
        )
        let manualOnlyWindow = makeWindow(
            bundleIdentifier: "com.example.manual"
        ).withOpeningConfiguration(
            WindowOpeningConfiguration(manualTargets: [fileTarget, webTarget])
        )

        let automaticCapabilities = DashboardOpeningTargetCapabilities.resolve(
            for: automaticWindow
        )
        let manualCapabilities = DashboardOpeningTargetCapabilities.resolve(
            for: manualOnlyWindow
        )

        XCTAssertEqual(automaticCapabilities.supportedKinds, [.file, .folder, .webURL])
        XCTAssertEqual(automaticCapabilities.localTargetSelection, .filesAndFolders)
        XCTAssertTrue(automaticCapabilities.supportsWebURLs)
        XCTAssertTrue(automaticCapabilities.hasExistingTargets)
        XCTAssertTrue(automaticCapabilities.showsEditor)
        XCTAssertEqual(manualCapabilities.supportedKinds, [.file, .folder, .webURL])
        XCTAssertEqual(manualCapabilities.localTargetSelection, .filesAndFolders)
        XCTAssertTrue(manualCapabilities.supportsWebURLs)
        XCTAssertTrue(manualCapabilities.hasExistingTargets)
        XCTAssertTrue(manualCapabilities.showsEditor)
    }

    func testLocalTargetSelectionConfiguresLabelsValidationAndPickerKinds() {
        XCTAssertEqual(DashboardLocalTargetSelection.files.sectionTitle, "Add File")
        XCTAssertEqual(DashboardLocalTargetSelection.files.expectedKind, .file)
        XCTAssertTrue(DashboardLocalTargetSelection.files.canChooseFiles)
        XCTAssertFalse(DashboardLocalTargetSelection.files.canChooseDirectories)

        XCTAssertEqual(DashboardLocalTargetSelection.folders.sectionTitle, "Add Folder")
        XCTAssertEqual(DashboardLocalTargetSelection.folders.expectedKind, .folder)
        XCTAssertFalse(DashboardLocalTargetSelection.folders.canChooseFiles)
        XCTAssertTrue(DashboardLocalTargetSelection.folders.canChooseDirectories)

        XCTAssertEqual(DashboardLocalTargetSelection.filesAndFolders.sectionTitle, "Add Path")
        XCTAssertNil(DashboardLocalTargetSelection.filesAndFolders.expectedKind)
        XCTAssertTrue(DashboardLocalTargetSelection.filesAndFolders.canChooseFiles)
        XCTAssertTrue(DashboardLocalTargetSelection.filesAndFolders.canChooseDirectories)
    }

    func testPathSuggestionsExpandTildeAndSupportNestedAbsoluteAndRootPaths() async throws {
        let homeURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeURL) }

        let nestedDirectoryURL = homeURL.appendingPathComponent("Space Folder", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nestedDirectoryURL,
            withIntermediateDirectories: false
        )
        let unicodeFileURL = nestedDirectoryURL.appendingPathComponent("Résumé.txt")
        try Data().write(to: unicodeFileURL)

        let provider = DashboardPathSuggestionProvider(homeDirectoryURL: homeURL)
        let emptySuggestions = await provider.suggestions(
            for: "",
            selection: .folders
        )
        let relativeSuggestions = await provider.suggestions(
            for: "space",
            selection: .folders
        )
        let tildeSuggestions = await provider.suggestions(
            for: "~/Space Folder/Ré",
            selection: .files
        )
        let absoluteSuggestions = await provider.suggestions(
            for: nestedDirectoryURL.path + "/Ré",
            selection: .files
        )
        let rootProvider = DashboardPathSuggestionProvider(
            homeDirectoryURL: homeURL,
            directoryContents: { _ in [nestedDirectoryURL] }
        )
        let rootSuggestions = await rootProvider.suggestions(
            for: "/",
            selection: .folders
        )

        XCTAssertEqual(emptySuggestions.map(\.displayPath), ["~/Space Folder/"])
        XCTAssertEqual(relativeSuggestions.map(\.displayPath), ["~/Space Folder/"])
        XCTAssertEqual(tildeSuggestions.map(\.displayPath), ["~/Space Folder/Résumé.txt"])
        XCTAssertEqual(
            absoluteSuggestions.map(\.displayPath),
            [nestedDirectoryURL.path + "/Résumé.txt"]
        )
        XCTAssertEqual(rootSuggestions.map(\.displayPath), ["/Space Folder/"])
    }

    func testPathSuggestionsFilterSortAndLimitImmediateChildren() async throws {
        let homeURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeURL) }

        for name in ["Item 10", "Item 2", "Item 1"] {
            try FileManager.default.createDirectory(
                at: homeURL.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: false
            )
        }

        let provider = DashboardPathSuggestionProvider(
            homeDirectoryURL: homeURL,
            maximumSuggestionCount: 2
        )
        let suggestions = await provider.suggestions(
            for: "~/item",
            selection: .folders
        )

        XCTAssertEqual(suggestions.map(\.name), ["Item 1", "Item 2"])
        XCTAssertEqual(suggestions.map(\.displayPath), ["~/Item 1/", "~/Item 2/"])
    }

    func testPathSuggestionsRespectFileAndFolderCapabilities() async throws {
        let homeURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeURL) }

        let folderURL = homeURL.appendingPathComponent("Folder", isDirectory: true)
        let fileURL = homeURL.appendingPathComponent("File.txt")
        try FileManager.default.createDirectory(
            at: folderURL,
            withIntermediateDirectories: false
        )
        try Data().write(to: fileURL)

        let provider = DashboardPathSuggestionProvider(homeDirectoryURL: homeURL)
        let fileSuggestions = await provider.suggestions(for: "~/", selection: .files)
        let folderSuggestions = await provider.suggestions(for: "~/", selection: .folders)
        let mixedSuggestions = await provider.suggestions(
            for: "~/",
            selection: .filesAndFolders
        )

        XCTAssertEqual(Set(fileSuggestions.map(\.kind)), [.file, .folder])
        XCTAssertEqual(
            fileSuggestions.first(where: { $0.kind == .folder })?.isSelectable,
            false
        )
        XCTAssertEqual(
            fileSuggestions.first(where: { $0.kind == .file })?.isSelectable,
            true
        )
        XCTAssertEqual(folderSuggestions.map(\.kind), [.folder])
        XCTAssertTrue(folderSuggestions.allSatisfy(\.isSelectable))
        XCTAssertEqual(Set(mixedSuggestions.map(\.kind)), [.file, .folder])
        XCTAssertTrue(mixedSuggestions.allSatisfy(\.isSelectable))
    }

    func testPathSuggestionsRevealHiddenEntriesOnlyForDotPrefix() async throws {
        let homeURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeURL) }

        let hiddenURL = homeURL.appendingPathComponent(".Secret", isDirectory: true)
        let visibleURL = homeURL.appendingPathComponent("Visible", isDirectory: true)
        try FileManager.default.createDirectory(
            at: hiddenURL,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: visibleURL,
            withIntermediateDirectories: false
        )

        let provider = DashboardPathSuggestionProvider(homeDirectoryURL: homeURL)
        let regularSuggestions = await provider.suggestions(for: "~/", selection: .folders)
        let hiddenSuggestions = await provider.suggestions(for: "~/.", selection: .folders)

        XCTAssertEqual(regularSuggestions.map(\.name), ["Visible"])
        XCTAssertEqual(hiddenSuggestions.map(\.name), [".Secret"])
    }

    func testPathSuggestionsReturnEmptyForInvalidMissingAndUnreadableDirectories() async {
        let homeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let provider = DashboardPathSuggestionProvider(homeDirectoryURL: homeURL)
        let unreadableProvider = DashboardPathSuggestionProvider(
            homeDirectoryURL: homeURL,
            directoryContents: { _ in
                throw CocoaError(.fileReadNoPermission)
            }
        )

        let emptySuggestions = await provider.suggestions(for: "", selection: .folders)
        let relativeSuggestions = await provider.suggestions(
            for: "relative/path",
            selection: .folders
        )
        let malformedTildeSuggestions = await provider.suggestions(
            for: "~other/path",
            selection: .folders
        )
        let missingSuggestions = await provider.suggestions(
            for: "~/Missing/",
            selection: .folders
        )
        let unreadableSuggestions = await unreadableProvider.suggestions(
            for: "~/",
            selection: .folders
        )

        XCTAssertTrue(emptySuggestions.isEmpty)
        XCTAssertTrue(relativeSuggestions.isEmpty)
        XCTAssertTrue(malformedTildeSuggestions.isEmpty)
        XCTAssertTrue(missingSuggestions.isEmpty)
        XCTAssertTrue(unreadableSuggestions.isEmpty)
    }

    func testPathSuggestionNavigationMovesAndClampsHighlightedIndex() {
        XCTAssertEqual(
            DashboardPathSuggestionNavigation.movedIndex(
                from: nil,
                offset: 1,
                suggestionCount: 3
            ),
            0
        )
        XCTAssertEqual(
            DashboardPathSuggestionNavigation.movedIndex(
                from: nil,
                offset: -1,
                suggestionCount: 3
            ),
            2
        )
        XCTAssertEqual(
            DashboardPathSuggestionNavigation.movedIndex(
                from: 1,
                offset: 1,
                suggestionCount: 3
            ),
            2
        )
        XCTAssertEqual(
            DashboardPathSuggestionNavigation.movedIndex(
                from: 0,
                offset: -1,
                suggestionCount: 3
            ),
            0
        )
        XCTAssertNil(
            DashboardPathSuggestionNavigation.movedIndex(
                from: 0,
                offset: 1,
                suggestionCount: 0
            )
        )
    }

    func testRelativeDateFormatterReturnsJustNowForMatchingAndRecentDates() {
        let now = Date(timeIntervalSince1970: 1_000)

        for offset: TimeInterval in [0, -30, 30] {
            XCTAssertEqual(
                DashboardRelativeDateFormatter.string(from: now.addingTimeInterval(offset), relativeTo: now),
                "just now",
                "Offset: \(offset)"
            )
        }
    }

    func testRelativeDateFormatterUsesSystemFormatterForOlderDate() {
        let now = Date(timeIntervalSince1970: 1_000)
        let updatedAt = now.addingTimeInterval(-120)
        let formatter = RelativeDateTimeFormatter()

        XCTAssertEqual(
            DashboardRelativeDateFormatter.string(from: updatedAt, relativeTo: now),
            formatter.localizedString(for: updatedAt, relativeTo: now)
        )
    }

    func testDashboardCommandAvailabilityDisablesSelectedLayoutActionsWithoutSelection() {
        let availability = DashboardCommandAvailability(
            isSnapshotActionDisabled: false,
            isAccessibilityAuthorized: true,
            hasSelectedLayout: false,
            selectedLayoutHasHotkey: false
        )

        XCTAssertTrue(availability.canCreateLayout)
        XCTAssertFalse(availability.canRestoreLayout)
        XCTAssertFalse(availability.canUpdateLayout)
        XCTAssertFalse(availability.canRenameLayout)
        XCTAssertFalse(availability.canAssignHotkey)
        XCTAssertFalse(availability.canClearHotkey)
        XCTAssertFalse(availability.canDeleteLayout)
        XCTAssertEqual(availability.hotkeyCommandTitle, "Set Hotkey")
    }

    func testDashboardCommandAvailabilityDisablesAllActionsWhenSnapshotActionsAreDisabled() {
        let availability = DashboardCommandAvailability(
            isSnapshotActionDisabled: true,
            isAccessibilityAuthorized: true,
            hasSelectedLayout: true,
            selectedLayoutHasHotkey: true
        )

        XCTAssertFalse(availability.canCreateLayout)
        XCTAssertFalse(availability.canRestoreLayout)
        XCTAssertFalse(availability.canUpdateLayout)
        XCTAssertFalse(availability.canRenameLayout)
        XCTAssertFalse(availability.canAssignHotkey)
        XCTAssertFalse(availability.canClearHotkey)
        XCTAssertFalse(availability.canDeleteLayout)
        XCTAssertEqual(availability.hotkeyCommandTitle, "Change Hotkey")
    }

    func testDashboardCommandAvailabilityEnablesClearHotkeyOnlyWhenSelectedLayoutHasHotkey() {
        let withoutHotkey = DashboardCommandAvailability(
            isSnapshotActionDisabled: false,
            isAccessibilityAuthorized: true,
            hasSelectedLayout: true,
            selectedLayoutHasHotkey: false
        )
        let withHotkey = DashboardCommandAvailability(
            isSnapshotActionDisabled: false,
            isAccessibilityAuthorized: true,
            hasSelectedLayout: true,
            selectedLayoutHasHotkey: true
        )

        XCTAssertTrue(withoutHotkey.canAssignHotkey)
        XCTAssertTrue(withoutHotkey.canUpdateLayout)
        XCTAssertFalse(withoutHotkey.canClearHotkey)
        XCTAssertEqual(withoutHotkey.hotkeyCommandTitle, "Set Hotkey")
        XCTAssertTrue(withHotkey.canClearHotkey)
        XCTAssertEqual(withHotkey.hotkeyCommandTitle, "Change Hotkey")
    }

    func testDashboardCommandAvailabilityDisablesPrivilegedActionsWithoutAuthorization() {
        let availability = DashboardCommandAvailability(
            isSnapshotActionDisabled: false,
            isAccessibilityAuthorized: false,
            hasSelectedLayout: true,
            selectedLayoutHasHotkey: true
        )

        XCTAssertFalse(availability.canCreateLayout)
        XCTAssertFalse(availability.canRestoreLayout)
        XCTAssertFalse(availability.canUpdateLayout)
        XCTAssertTrue(availability.canRenameLayout)
        XCTAssertTrue(availability.canAssignHotkey)
        XCTAssertTrue(availability.canClearHotkey)
        XCTAssertTrue(availability.canDeleteLayout)
        XCTAssertEqual(availability.hotkeyCommandTitle, "Change Hotkey")
    }

    func testDashboardDetailContentPrefersExplicitPermissionEducationWithoutLayouts() {
        XCTAssertEqual(
            DashboardDetailContentPreference.resolve(
                showsPermissionEducation: true,
                isAccessibilityAuthorized: true,
                hasSavedLayouts: false,
                hasSelectedLayout: false
            ),
            .permissionEducation
        )
    }

    func testDashboardDetailContentPrefersExplicitPermissionEducationWithSelection() {
        XCTAssertEqual(
            DashboardDetailContentPreference.resolve(
                showsPermissionEducation: true,
                isAccessibilityAuthorized: true,
                hasSavedLayouts: true,
                hasSelectedLayout: true
            ),
            .permissionEducation
        )
    }

    func testDashboardDetailContentUsesPermissionEducationWhenUnauthorizedWithoutLayouts() {
        XCTAssertEqual(
            DashboardDetailContentPreference.resolve(
                showsPermissionEducation: false,
                isAccessibilityAuthorized: false,
                hasSavedLayouts: false,
                hasSelectedLayout: false
            ),
            .permissionEducation
        )
    }

    func testDashboardDetailContentUsesEmptyStateWhenAuthorizedWithoutLayouts() {
        XCTAssertEqual(
            DashboardDetailContentPreference.resolve(
                showsPermissionEducation: false,
                isAccessibilityAuthorized: true,
                hasSavedLayouts: false,
                hasSelectedLayout: false
            ),
            .emptyState
        )
    }

    func testDashboardDetailContentUsesSelectedLayoutWhenUnauthorizedWithExistingLayout() {
        XCTAssertEqual(
            DashboardDetailContentPreference.resolve(
                showsPermissionEducation: false,
                isAccessibilityAuthorized: false,
                hasSavedLayouts: true,
                hasSelectedLayout: true
            ),
            .selectedLayout
        )
    }

    func testDashboardDetailContentUsesSelectedLayoutWhenAuthorized() {
        XCTAssertEqual(
            DashboardDetailContentPreference.resolve(
                showsPermissionEducation: false,
                isAccessibilityAuthorized: true,
                hasSavedLayouts: true,
                hasSelectedLayout: true
            ),
            .selectedLayout
        )
    }

    func testDashboardDetailContentUsesEmptyStateWhenExistingLayoutIsNotSelected() {
        XCTAssertEqual(
            DashboardDetailContentPreference.resolve(
                showsPermissionEducation: false,
                isAccessibilityAuthorized: false,
                hasSavedLayouts: true,
                hasSelectedLayout: false
            ),
            .emptyState
        )
    }

    func testSidebarSearchShowsSearchFieldOnlyAtMinimumLayoutCount() {
        XCTAssertFalse(DashboardSidebarSearch.showsSearchField(layoutCount: 4))
        XCTAssertTrue(DashboardSidebarSearch.showsSearchField(layoutCount: 5))
        XCTAssertTrue(DashboardSidebarSearch.showsSearchField(layoutCount: 12))
    }

    func testSidebarSearchFiltersSummariesCaseAndDiacriticInsensitivelyPreservingOrder() {
        let summaries = [
            makeSummary(name: "Writing"),
            makeSummary(name: "Recording"),
            makeSummary(name: "Résumé")
        ]

        let filtered = DashboardSidebarSearch.filteredSummaries(summaries, query: "RE")

        XCTAssertEqual(filtered.map(\.name), ["Recording", "Résumé"])
    }

    func testSidebarSearchReturnsAllSummariesForBlankQuery() {
        let summaries = [
            makeSummary(name: "Writing"),
            makeSummary(name: "Recording")
        ]

        XCTAssertEqual(
            DashboardSidebarSearch.filteredSummaries(summaries, query: "  ").map(\.name),
            ["Writing", "Recording"]
        )
    }

    func testSidebarSearchReturnsNoSummariesForUnmatchedQuery() {
        let summaries = [
            makeSummary(name: "Writing"),
            makeSummary(name: "Recording")
        ]

        XCTAssertTrue(
            DashboardSidebarSearch.filteredSummaries(summaries, query: "zzz").isEmpty
        )
    }

    func testSidebarSearchReplacementSelectionPrefersFirstVisibleMatch() {
        let alpha = makeSummary(name: "Alpha")
        let morningWork = makeSummary(name: "Work Morning")
        let beta = makeSummary(name: "Beta")
        let eveningWork = makeSummary(name: "Work Evening")
        let gamma = makeSummary(name: "Gamma")

        XCTAssertEqual(
            DashboardSidebarSearch.replacementSelectionID(
                in: [alpha, morningWork, beta, eveningWork, gamma],
                query: "work"
            ),
            morningWork.id
        )
    }

    func testSidebarSearchReplacementSelectionFallsBackToFirstLayoutWithoutVisibleMatch() {
        let alpha = makeSummary(name: "Alpha")
        let beta = makeSummary(name: "Beta")
        let summaries = [
            alpha,
            beta,
            makeSummary(name: "Gamma"),
            makeSummary(name: "Delta"),
            makeSummary(name: "Epsilon")
        ]

        XCTAssertEqual(
            DashboardSidebarSearch.replacementSelectionID(in: summaries, query: "zzz"),
            alpha.id
        )
    }

    func testSidebarSearchReplacementSelectionIgnoresQueryBelowMinimumLayoutCount() {
        let alpha = makeSummary(name: "Alpha")
        let summaries = [
            alpha,
            makeSummary(name: "Beta"),
            makeSummary(name: "Gamma"),
            makeSummary(name: "Delta")
        ]

        XCTAssertEqual(
            DashboardSidebarSearch.replacementSelectionID(in: summaries, query: "beta"),
            alpha.id
        )
    }

    func testWindowListTitlesOnlyAppearForRepeatedAppsAcrossWholeLayout() {
        let first = makeWindow(bundleIdentifier: "com.example.editor", windowTitle: "First", displayID: 1)
        let second = makeWindow(bundleIdentifier: "com.example.editor", windowTitle: "Second", displayID: 2)
        let unassigned = makeWindow(bundleIdentifier: "com.example.editor", windowTitle: "Third", displayID: nil)
        let single = makeWindow(bundleIdentifier: "com.example.browser", windowTitle: "Only window", displayID: 1)
        let snapshot = makeSnapshot(windows: [first, second, unassigned, single])

        XCTAssertEqual(DashboardSnapshotPresentation.windowListTitles(for: snapshot), [
            first.id: "First", second.id: "Second", unassigned.id: "Third"
        ])
    }

    func testWindowListTitlesTrimSavedTitlesAndOmitMissingTitles() {
        let titled = makeWindow(bundleIdentifier: "com.example.editor", windowTitle: "  Project — zsh  ")
        let blank = makeWindow(bundleIdentifier: "com.example.editor", windowTitle: " \n ")
        let missing = makeWindow(bundleIdentifier: "com.example.editor", windowTitle: nil)

        XCTAssertEqual(DashboardSnapshotPresentation.windowListTitles(for: makeSnapshot(windows: [titled, blank, missing])),
            [titled.id: "Project — zsh"])
    }

    func testWindowListUsesSavedResourceNamesInsteadOfAdditionalWindowTitles() {
        let projects = ["FirstProject", "MySecondProject"].map { name in
            makeWindow(bundleIdentifier: "com.example.editor", windowTitle: "\(name) - Editor")
                .withOpeningConfiguration(WindowOpeningConfiguration(automaticallyCapturedTargets: [
                    WindowOpenTarget(kind: .file, url: URL(fileURLWithPath: "/Projects/\(name).uproject"))
                ]))
        }
        let appOnly = makeWindow(bundleIdentifier: "com.example.editor", windowTitle: "No saved resource")

        XCTAssertEqual(DashboardSnapshotPresentation.windowListTitles(for: makeSnapshot(windows: projects + [appOnly])),
            [appOnly.id: "No saved resource"])
        XCTAssertEqual(projects.map { DashboardSnapshotPresentation.openingTargetDescriptions(for: $0) },
            [["FirstProject"], ["MySecondProject"]])
    }

    func testWindowListTitlesDisappearWhenOnlyOneAppWindowRemains() {
        let first = makeWindow(bundleIdentifier: "com.example.editor", windowTitle: "First")
        let second = makeWindow(bundleIdentifier: "com.example.editor", windowTitle: "Second")
        XCTAssertEqual(DashboardSnapshotPresentation.windowListTitles(for: makeSnapshot(windows: [first, second])).count, 2)
        XCTAssertTrue(DashboardSnapshotPresentation.windowListTitles(for: makeSnapshot(windows: [first])).isEmpty)
        XCTAssertTrue(DashboardSnapshotPresentation.windowListTitles(for: makeSnapshot(windows: [])).isEmpty)
    }

    @MainActor
    func testRepeatedAppWindowTitlePreviewRenders() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projects = try ["FirstProject", "MySecondProject"].map { name in
            let file = directory.appendingPathComponent("\(name).uproject")
            try Data("{}".utf8).write(to: file)
            return makeWindow(bundleIdentifier: "com.epicgames.UnrealEditor", windowTitle: "\(name) - Unreal Editor")
                .withOpeningConfiguration(WindowOpeningConfiguration(automaticallyCapturedTargets: [
                    WindowOpenTarget(kind: .file, url: file)
                ]))
        }
        let snapshot = makeSnapshot(displays: [makeDisplay(id: 1, name: "Built-in Display", x: 0)], windows: [
            makeWindow(bundleIdentifier: "com.apple.Terminal", windowTitle: "LayoutLock — zsh", zOrderHint: 0),
            makeWindow(bundleIdentifier: "com.apple.Terminal", windowTitle: "ZapPDF — zsh", zOrderHint: 1),
            makeWindow(bundleIdentifier: "com.apple.Safari", windowTitle: "Documentation", zOrderHint: 2)
        ] + projects)
        for scheme in [ColorScheme.light, .dark] {
            let preview = DashboardSnapshotPreviewView(
                snapshot: snapshot, appIdentityResolver: .shared,
                removeWindow: { _ in }, editOpeningTargets: { _ in }, reorderWindows: { _, _ in true }
            )
            .frame(width: 560)
            .padding(20)
            .background(scheme == .dark ? Color.black : Color.white)
            .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: preview)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 600),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                uniformTypeIdentifier: "public.png")
            attachment.name = "Repeated app window titles — \(scheme == .dark ? "dark" : "light")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testDisplayPreviewModelsGroupWindowsByDisplayID() {
        let snapshot = makeSnapshot(windows: [
            makeWindow(bundleIdentifier: "com.example.editor", displayID: 1),
            makeWindow(bundleIdentifier: "com.example.browser", displayID: 2),
            makeWindow(bundleIdentifier: "com.example.missing", displayID: 99)
        ])

        let models = DashboardSnapshotPresentation.displayPreviewModels(for: snapshot)

        XCTAssertEqual(models.map(\.id), [1, 2])
        XCTAssertEqual(models[0].windows.map(\.bundleIdentifier), ["com.example.editor"])
        XCTAssertEqual(models[1].windows.map(\.bundleIdentifier), ["com.example.browser"])
    }

    func testDisplayPreviewModelsOmitDisplaysWithoutWindows() {
        let snapshot = makeSnapshot(windows: [
            makeWindow(bundleIdentifier: "com.example.editor", displayID: 1)
        ])

        let models = DashboardSnapshotPresentation.displayPreviewModels(for: snapshot)

        XCTAssertEqual(models.map(\.id), [1])
        XCTAssertEqual(models.first?.windows.map(\.bundleIdentifier), ["com.example.editor"])
    }

    func testDisplayPreviewEmptyMessageReportsNoSavedDisplays() {
        let snapshot = makeSnapshot(displays: [], windows: [
            makeWindow(bundleIdentifier: "com.example.editor", displayID: nil)
        ])

        XCTAssertEqual(
            DashboardSnapshotPresentation.displayPreviewEmptyMessage(for: snapshot),
            "No displays were saved in this layout."
        )
    }

    func testDisplayPreviewEmptyMessageReportsNoAssignedWindows() {
        let snapshot = makeSnapshot(windows: [
            makeWindow(bundleIdentifier: "com.example.nil", displayID: nil),
            makeWindow(bundleIdentifier: "com.example.unknown", displayID: 99)
        ])

        XCTAssertEqual(
            DashboardSnapshotPresentation.displayPreviewEmptyMessage(for: snapshot),
            "No saved windows are assigned to saved displays."
        )
    }

    func testDisplayPreviewEmptyMessageIsNilWhenDisplayPreviewExists() {
        let snapshot = makeSnapshot(windows: [
            makeWindow(bundleIdentifier: "com.example.editor", displayID: 1)
        ])

        XCTAssertNil(DashboardSnapshotPresentation.displayPreviewEmptyMessage(for: snapshot))
    }

    func testUnassignedWindowsIncludeMissingAndUnknownDisplayIDs() {
        let nilDisplayWindow = makeWindow(bundleIdentifier: "com.example.nil", displayID: nil)
        let unknownDisplayWindow = makeWindow(bundleIdentifier: "com.example.unknown", displayID: 42)
        let assignedWindow = makeWindow(bundleIdentifier: "com.example.assigned", displayID: 1)
        let snapshot = makeSnapshot(windows: [
            nilDisplayWindow,
            unknownDisplayWindow,
            assignedWindow
        ])

        let unassignedWindows = DashboardSnapshotPresentation.unassignedWindows(in: snapshot)

        XCTAssertEqual(
            unassignedWindows.map(\.bundleIdentifier),
            ["com.example.nil", "com.example.unknown"]
        )
    }

    func testAppSummariesGroupAndSortByWindowCountThenName() {
        let snapshot = makeSnapshot(windows: [
            makeWindow(bundleIdentifier: "com.example.beta", windowTitle: "Beta 1"),
            makeWindow(bundleIdentifier: "com.example.alpha", windowTitle: "Alpha"),
            makeWindow(bundleIdentifier: "com.example.beta", windowTitle: "Beta 2"),
            makeWindow(bundleIdentifier: "com.example.gamma", windowTitle: "Gamma")
        ])

        let summaries = DashboardSnapshotPresentation.appSummaries(
            for: snapshot,
            identityResolver: identity
        )

        XCTAssertEqual(summaries.map(\.bundleIdentifier), [
            "com.example.beta",
            "com.example.alpha",
            "com.example.gamma"
        ])
        XCTAssertEqual(summaries.map(\.windowCount), [2, 1, 1])
    }

    func testAppSummariesExposeOnlyNonEmptyWindowTitles() {
        let snapshot = makeSnapshot(windows: [
            makeWindow(bundleIdentifier: "com.example.editor", windowTitle: "Notes"),
            makeWindow(bundleIdentifier: "com.example.editor", windowTitle: "  "),
            makeWindow(bundleIdentifier: "com.example.editor", windowTitle: nil)
        ])

        let summary = DashboardSnapshotPresentation.appSummaries(
            for: snapshot,
            identityResolver: identity
        ).first

        XCTAssertEqual(summary?.visibleWindowTitles, ["Notes"])
    }

    func testInactiveAppSummariesOmitRunningAppsAndPreserveSummaryOrder() {
        let snapshot = makeSnapshot(windows: [
            makeWindow(bundleIdentifier: "com.example.beta", windowTitle: "Beta 1"),
            makeWindow(bundleIdentifier: "com.example.alpha", windowTitle: "Alpha"),
            makeWindow(bundleIdentifier: "com.example.beta", windowTitle: "Beta 2"),
            makeWindow(bundleIdentifier: "com.example.gamma", windowTitle: "Gamma")
        ])

        let summaries = DashboardSnapshotPresentation.inactiveAppSummaries(
            for: snapshot,
            runningBundleIdentifiers: ["com.example.beta"],
            identityResolver: identity
        )

        XCTAssertEqual(summaries.map(\.id), [
            "com.example.alpha",
            "com.example.gamma"
        ])
        XCTAssertEqual(summaries.map(\.windowCount), [1, 1])
    }

    func testInactiveAppsDistinguishMissingAppsAndReflectAvailabilityChanges() throws {
        let bundle = "com.example.editor"
        let snapshot = makeSnapshot(windows: [makeWindow(bundleIdentifier: bundle)])
        let missing = try XCTUnwrap(DashboardSnapshotPresentation.inactiveAppSummaries(
            for: snapshot, runningBundleIdentifiers: [], unavailableBundleIdentifiers: [bundle],
            identityResolver: identity).first)
        XCTAssertFalse(missing.isAvailable)
        XCTAssertEqual(missing.statusText, "App Not Found")

        let installed = try XCTUnwrap(DashboardSnapshotPresentation.inactiveAppSummaries(
            for: snapshot, runningBundleIdentifiers: [], identityResolver: identity).first)
        XCTAssertTrue(installed.isAvailable)
        XCTAssertEqual(installed.statusText, "Not Running")
        XCTAssertTrue(DashboardSnapshotPresentation.inactiveAppSummaries(
            for: snapshot, runningBundleIdentifiers: [bundle], unavailableBundleIdentifiers: [bundle],
            identityResolver: identity).isEmpty)
    }

    @MainActor
    func testInactiveAppAvailabilityUsesCapturedInstallationAndRefreshesAfterSavedPathChanges() throws {
        let directory = try TestTemporaryDirectory()
        let bundle = TestFixtures.bundleIdentifier
        let captured = try makeApplicationBundle(in: directory.url, named: "Captured.app")
        let missing = directory.url.appendingPathComponent("Missing.app")
        let oldSnapshot = makeSnapshot(windows: [makeWindowRecord(bundleIdentifier: bundle,
            applicationBundleURL: missing)])
        let updatedSnapshot = makeSnapshot(windows: [makeWindowRecord(bundleIdentifier: bundle,
            applicationBundleURL: missing), makeWindowRecord(bundleIdentifier: bundle,
            applicationBundleURL: captured)])

        XCTAssertEqual(DashboardInactiveAppsView.unavailableApplications(in: oldSnapshot,
            runningBundleIdentifiers: [], registeredApplicationURL: { _ in nil }), [bundle])
        XCTAssertTrue(DashboardInactiveAppsView.unavailableApplications(in: updatedSnapshot,
            runningBundleIdentifiers: [], registeredApplicationURL: { _ in nil }).isEmpty)
        try FileManager.default.removeItem(at: captured)
        XCTAssertEqual(DashboardInactiveAppsView.unavailableApplications(in: updatedSnapshot,
            runningBundleIdentifiers: [], registeredApplicationURL: { _ in nil }), [bundle])
        XCTAssertTrue(DashboardInactiveAppsView.unavailableApplications(in: updatedSnapshot,
            runningBundleIdentifiers: [bundle], registeredApplicationURL: { _ in nil }).isEmpty)
        let registered = try makeApplicationBundle(in: directory.url, named: "Registered.app")
        XCTAssertTrue(DashboardInactiveAppsView.unavailableApplications(in: updatedSnapshot,
            runningBundleIdentifiers: [], registeredApplicationURL: { _ in registered }).isEmpty)
    }

    func testWindowRemovalConfirmationUsesWindowTitleWhenAvailable() {
        let confirmation = DashboardWindowRemovalConfirmation(
            snapshotID: UUID(),
            snapshotName: "Writing",
            appIdentity: identity(for: "com.example.editor"),
            windowID: UUID(),
            windowTitle: "  Draft.md  ",
            isLastWindowOnDisplay: false
        )

        XCTAssertEqual(confirmation.appName, "Editor")
        XCTAssertEqual(confirmation.windowDisplayTitle, "Draft.md")
        XCTAssertEqual(
            confirmation.message,
            "Remove this saved window from \"Writing\"? This cannot be undone."
        )
    }

    func testWindowRemovalConfirmationFallsBackForUntitledWindowAndIncludesPreviewNote() {
        let confirmation = DashboardWindowRemovalConfirmation(
            snapshotID: UUID(),
            snapshotName: "Daily Setup",
            appIdentity: identity(for: "com.example.editor"),
            windowID: UUID(),
            windowTitle: "  ",
            isLastWindowOnDisplay: true
        )

        XCTAssertEqual(confirmation.windowDisplayTitle, "Untitled window")
        XCTAssertEqual(
            confirmation.message,
            "Remove this saved window from \"Daily Setup\"? This cannot be undone. This is the last saved window on this display, so the display will no longer appear in the layout preview."
        )
    }

    func testWindowPreviewGroupsKeepNonOverlappingWindowsSeparate() {
        let windows = [
            makeWindow(
                bundleIdentifier: "com.example.left",
                frame: CGRectCodable(x: 0, y: 0, width: 100, height: 100)
            ),
            makeWindow(
                bundleIdentifier: "com.example.right",
                frame: CGRectCodable(x: 130, y: 0, width: 100, height: 100)
            )
        ]

        let groups = DashboardSnapshotPresentation.windowPreviewGroups(
            for: windows,
            displayID: 1,
            displayFrame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )

        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.allSatisfy { $0.overlapCount == 0 })
    }

    func testWindowPreviewGroupsStackHeavilyOverlappingWindows() {
        let backWindow = makeWindow(
            bundleIdentifier: "com.example.back",
            frame: CGRectCodable(x: 0, y: 0, width: 100, height: 100),
            zOrderHint: 2
        )
        let frontWindow = makeWindow(
            bundleIdentifier: "com.example.front",
            frame: CGRectCodable(x: 10, y: 10, width: 100, height: 100),
            zOrderHint: 1
        )

        let groups = DashboardSnapshotPresentation.windowPreviewGroups(
            for: [backWindow, frontWindow],
            displayID: 1,
            displayFrame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.overlapCount, 1)
        XCTAssertEqual(groups.first?.frontmostWindow.bundleIdentifier, "com.example.front")
    }

    func testWindowPreviewGroupsIgnoreSmallIntersections() {
        let windows = [
            makeWindow(
                bundleIdentifier: "com.example.first",
                frame: CGRectCodable(x: 0, y: 0, width: 100, height: 100)
            ),
            makeWindow(
                bundleIdentifier: "com.example.second",
                frame: CGRectCodable(x: 90, y: 0, width: 100, height: 100)
            )
        ]

        let groups = DashboardSnapshotPresentation.windowPreviewGroups(
            for: windows,
            displayID: 1,
            displayFrame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )

        XCTAssertEqual(groups.count, 2)
    }

    func testWindowPreviewGroupsUseStableIDFallbackWithoutZOrderHint() throws {
        let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let firstWindow = makeWindow(
            id: firstID,
            bundleIdentifier: "com.example.first",
            frame: CGRectCodable(x: 0, y: 0, width: 100, height: 100)
        )
        let secondWindow = makeWindow(
            id: secondID,
            bundleIdentifier: "com.example.second",
            frame: CGRectCodable(x: 5, y: 5, width: 100, height: 100)
        )

        let group = DashboardSnapshotPresentation.windowPreviewGroups(
            for: [secondWindow, firstWindow],
            displayID: 1,
            displayFrame: CGRect(x: 0, y: 0, width: 400, height: 300)
        ).first

        XCTAssertEqual(group?.frontmostWindow.id, firstID)
    }

    func testWindowPreviewGroupsKeepNormalizedNonOverlappingWindowsSeparateWhenAbsoluteFramesOverlap() {
        let displayFrame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let windows = [
            makeWindow(
                bundleIdentifier: "com.example.left",
                frame: CGRectCodable(x: 0, y: 0, width: 100, height: 100),
                normalizedFrame: NormalizedRect(xRatio: 0, yRatio: 0, widthRatio: 0.25, heightRatio: 1.0 / 3.0)
            ),
            makeWindow(
                bundleIdentifier: "com.example.right",
                frame: CGRectCodable(x: 0, y: 0, width: 100, height: 100),
                normalizedFrame: NormalizedRect(xRatio: 0.5, yRatio: 0, widthRatio: 0.25, heightRatio: 1.0 / 3.0)
            )
        ]

        let groups = DashboardSnapshotPresentation.windowPreviewGroups(
            for: windows,
            displayID: 1,
            displayFrame: displayFrame
        )

        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.allSatisfy { $0.overlapCount == 0 })
    }

    func testWindowPreviewGroupsStackNormalizedOverlappingWindowsWhenAbsoluteFramesAreSeparate() {
        let displayFrame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let backWindow = makeWindow(
            bundleIdentifier: "com.example.back",
            frame: CGRectCodable(x: 0, y: 0, width: 100, height: 100),
            normalizedFrame: NormalizedRect(xRatio: 0, yRatio: 0, widthRatio: 0.25, heightRatio: 1.0 / 3.0),
            zOrderHint: 2
        )
        let frontWindow = makeWindow(
            bundleIdentifier: "com.example.front",
            frame: CGRectCodable(x: 300, y: 0, width: 100, height: 100),
            normalizedFrame: NormalizedRect(xRatio: 0.025, yRatio: 0.025, widthRatio: 0.25, heightRatio: 1.0 / 3.0),
            zOrderHint: 1
        )

        let groups = DashboardSnapshotPresentation.windowPreviewGroups(
            for: [backWindow, frontWindow],
            displayID: 1,
            displayFrame: displayFrame
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.overlapCount, 1)
        XCTAssertEqual(groups.first?.frontmostWindow.bundleIdentifier, "com.example.front")
    }

    func testDisplayPreviewLayoutPlacesDisplayFrameOriginAtSurfaceTop() {
        let displayFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let layout = DashboardDisplayPreviewLayout(
            displayFrame: displayFrame,
            size: CGSize(width: 300, height: 200)
        )

        let scaledWindowFrame = layout.scaledFrame(
            for: CGRect(x: 14, y: displayFrame.minY, width: 600, height: 420)
        )

        XCTAssertEqual(scaledWindowFrame.minY, layout.scaledDisplayFrame.minY, accuracy: 0.001)
    }

    func testDisplayPreviewLayoutMapsFullDisplayWindowInsideSurface() {
        let displayFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let layout = DashboardDisplayPreviewLayout(
            displayFrame: displayFrame,
            size: CGSize(width: 361, height: 174)
        )

        let scaledWindowFrame = layout.scaledFrame(for: displayFrame)

        XCTAssertEqual(scaledWindowFrame.minX, layout.scaledDisplayFrame.minX, accuracy: 0.001)
        XCTAssertEqual(scaledWindowFrame.minY, layout.scaledDisplayFrame.minY, accuracy: 0.001)
        XCTAssertEqual(scaledWindowFrame.maxX, layout.scaledDisplayFrame.maxX, accuracy: 0.001)
        XCTAssertEqual(scaledWindowFrame.maxY, layout.scaledDisplayFrame.maxY, accuracy: 0.001)
    }

    func testDisplayPreviewUsesFullDisplayFrameWhenVisibleFrameIsOffset() {
        let display = makeDisplay(
            id: 1,
            name: "Offset Dock",
            x: 0,
            frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 80, y: 25, width: 2480, height: 1415)
        )
        let window = makeWindow(
            bundleIdentifier: "com.example.editor",
            normalizedFrame: NormalizedRect(xRatio: 0, yRatio: 0, widthRatio: 1, heightRatio: 1)
        )
        let layout = DashboardDisplayPreviewLayout(
            displayFrame: display.frameRect,
            size: CGSize(width: 361, height: 174)
        )

        let previewFrame = DashboardSnapshotPresentation.previewFrame(for: window, in: display)
        let scaledWindowFrame = layout.scaledFrame(for: previewFrame)

        XCTAssertEqual(previewFrame, display.frameRect)
        XCTAssertEqual(scaledWindowFrame.minX, layout.scaledDisplayFrame.minX, accuracy: 0.001)
        XCTAssertEqual(scaledWindowFrame.minY, layout.scaledDisplayFrame.minY, accuracy: 0.001)
        XCTAssertEqual(scaledWindowFrame.maxX, layout.scaledDisplayFrame.maxX, accuracy: 0.001)
        XCTAssertEqual(scaledWindowFrame.maxY, layout.scaledDisplayFrame.maxY, accuracy: 0.001)
    }

    func testDisplayPreviewUsesNormalizedFrameInsteadOfSavedAbsoluteFrame() {
        let display = makeDisplay(
            id: 1,
            name: "Main",
            x: 0,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        let window = makeWindow(
            bundleIdentifier: "com.example.editor",
            frame: CGRectCodable(x: -500, y: -500, width: 4000, height: 3000),
            normalizedFrame: NormalizedRect(xRatio: 0.25, yRatio: 0.2, widthRatio: 0.5, heightRatio: 0.4)
        )

        let previewFrame = DashboardSnapshotPresentation.previewFrame(for: window, in: display)

        XCTAssertEqual(previewFrame, CGRect(x: 250, y: 160, width: 500, height: 320))
        XCTAssertNotEqual(previewFrame, window.frame.cgRect)
    }

    func testWindowsForDisplayListUsesZOrderHint() {
        let backWindow = makeWindow(bundleIdentifier: "com.example.back", zOrderHint: 4)
        let frontWindow = makeWindow(bundleIdentifier: "com.example.front", zOrderHint: 1)

        let orderedWindows = DashboardSnapshotPresentation.windowsForDisplayList([
            backWindow,
            frontWindow
        ])

        XCTAssertEqual(orderedWindows.map(\.bundleIdentifier), [
            "com.example.front",
            "com.example.back"
        ])
    }

    private func identity(for bundleIdentifier: String) -> DashboardAppIdentity {
        let names = [
            "com.example.alpha": "Alpha",
            "com.example.beta": "Beta",
            "com.example.gamma": "Gamma",
            "com.example.editor": "Editor"
        ]

        return DashboardAppIdentity(
            bundleIdentifier: bundleIdentifier,
            name: names[bundleIdentifier] ?? bundleIdentifier,
            icon: NSImage(),
            accentColor: .accentColor
        )
    }

    private func makeSummary(name: String) -> SnapshotSummary {
        SnapshotSummary(
            snapshot: Snapshot(
                name: name,
                sourceDisplayState: DisplayState(displays: [], primaryDisplayID: nil),
                windows: [makeWindow(bundleIdentifier: "com.example.editor")]
            )
        )
    }

    private func makeSnapshot(
        displays: [DisplayRecord]? = nil,
        windows: [WindowRecord]
    ) -> Snapshot {
        Snapshot(
            name: "Dashboard",
            sourceDisplayState: DisplayState(
                displays: displays ?? [
                    makeDisplay(id: 1, name: "Main", x: 0),
                    makeDisplay(id: 2, name: "Side", x: 1440)
                ],
                primaryDisplayID: 1
            ),
            windows: windows
        )
    }

    private func makeDisplay(
        id: UInt32,
        name: String,
        x: Double,
        frame: CGRect? = nil,
        visibleFrame: CGRect? = nil
    ) -> DisplayRecord {
        let displayFrame = frame ?? CGRect(x: x, y: 0, width: 1440, height: 900)
        let defaultVisibleFrame = frame == nil
            ? CGRect(x: x, y: 0, width: 1440, height: 860)
            : displayFrame

        return DisplayRecord(
            id: id,
            localizedName: name,
            frame: CGRectCodable(displayFrame),
            visibleFrame: CGRectCodable(visibleFrame ?? defaultVisibleFrame),
            backingScaleFactor: 2,
            isPrimary: id == 1,
            vendorID: nil,
            productID: nil,
            serialNumber: nil
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let URL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: URL,
            withIntermediateDirectories: false
        )
        return URL
    }

    private func makeWindow(
        id: UUID = UUID(),
        bundleIdentifier: String,
        windowTitle: String? = "Window",
        displayID: UInt32? = 1,
        frame: CGRectCodable = CGRectCodable(x: 20, y: 20, width: 400, height: 260),
        normalizedFrame: NormalizedRect? = nil,
        zOrderHint: Int? = nil
    ) -> WindowRecord {
        let previewDisplayFrame = CGRect(x: 0, y: 0, width: 400, height: 300)

        return WindowRecord(
            id: id,
            bundleIdentifier: bundleIdentifier,
            pidAtCapture: 1,
            windowTitle: windowTitle,
            role: "AXWindow",
            subrole: nil,
            frame: frame,
            displayID: displayID,
            normalizedFrame: normalizedFrame ?? NormalizedRect(
                windowFrame: frame.cgRect,
                displayFrame: previewDisplayFrame
            ),
            zOrderHint: zOrderHint,
            isMinimized: false,
            isFullscreen: false,
            isVisible: true,
            captureSignature: WindowSignature(
                bundleIdentifier: bundleIdentifier,
                owningPid: 1,
                windowTitle: windowTitle,
                role: "AXWindow",
                subrole: nil,
                capturedFrame: frame,
                cgWindowID: nil
            )
        )
    }
}
