import CoreGraphics
import Foundation

struct BrowserWindowTargetEnricher {
    struct Result {
        let discoveryResult: WindowDiscoveryResult
        let issues: [BrowserCaptureIssue]
    }

    private let frameTolerance: CGFloat
    private let allowsOrderFallback: Bool

    init(
        frameTolerance: CGFloat = 12,
        allowsOrderFallback: Bool = true
    ) {
        self.frameTolerance = frameTolerance
        self.allowsOrderFallback = allowsOrderFallback
    }

    func enrich(
        _ discoveryResult: WindowDiscoveryResult,
        with captureResult: BrowserTabCaptureResult
    ) -> Result {
        var issues = captureResult.issues
        let applications = discoveryResult.applications.map { application in
            guard let browser = BrowserAutomationBrowser.allCases.first(
                where: { $0.bundleIdentifier == application.bundleIdentifier }
            ) else {
                return application
            }

            let capturedWindows = captureResult.windows
                .filter { $0.browser == browser }
                .sorted { $0.frontToBackIndex < $1.frontToBackIndex }
            guard !capturedWindows.isEmpty else {
                return application
            }

            let matchResult = match(
                discoveredWindows: application.windows,
                capturedWindows: capturedWindows
            )
            if matchResult.isAmbiguous {
                issues.append(
                    BrowserCaptureIssue(browser: browser, reason: .ambiguousWindowMatch)
                )
            }

            let windows = application.windows.enumerated().map { index, window in
                guard let capturedIndex = matchResult.capturedIndexByDiscoveredIndex[index] else {
                    return window
                }
                let capturedWindow = capturedWindows[capturedIndex]
                return window.addingBrowserEvidence(capturedWindow)
            }

            return DiscoveredApplication(
                bundleIdentifier: application.bundleIdentifier,
                pid: application.pid,
                localizedName: application.localizedName,
                windows: windows
            )
        }

        return Result(
            discoveryResult: WindowDiscoveryResult(
                applications: applications,
                diagnostics: discoveryResult.diagnostics
            ),
            issues: issues.uniqued()
        )
    }

    private func match(
        discoveredWindows: [DiscoveredWindow],
        capturedWindows: [CapturedBrowserWindow]
    ) -> MatchResult {
        var unmatchedDiscoveredIndices = Set(discoveredWindows.indices)
        var unmatchedCapturedIndices = Set(capturedWindows.indices)
        var capturedIndexByDiscoveredIndex: [Int: Int] = [:]
        var isAmbiguous = false
        var foundAmbiguousCandidate = false

        for capturedIndex in capturedWindows.indices {
            let capturedWindow = capturedWindows[capturedIndex]
            let frameCandidates = unmatchedDiscoveredIndices.filter {
                discoveredWindows[$0].frame.isApproximatelyEqual(
                    to: capturedWindow.frame,
                    tolerance: frameTolerance
                )
            }
            let titleCandidates = frameCandidates.filter {
                normalizedTitle(discoveredWindows[$0].title) ==
                    normalizedTitle(capturedWindow.title)
            }
            let candidates = titleCandidates.isEmpty ? frameCandidates : titleCandidates

            if candidates.count == 1, let discoveredIndex = candidates.first {
                capturedIndexByDiscoveredIndex[discoveredIndex] = capturedIndex
                unmatchedDiscoveredIndices.remove(discoveredIndex)
                unmatchedCapturedIndices.remove(capturedIndex)
            } else if candidates.count > 1 {
                isAmbiguous = true
                foundAmbiguousCandidate = true
            }
        }

        if allowsOrderFallback,
           !foundAmbiguousCandidate,
           !unmatchedCapturedIndices.isEmpty,
           unmatchedCapturedIndices.count == unmatchedDiscoveredIndices.count {
            let discoveredByOrder = unmatchedDiscoveredIndices.sorted {
                discoveredOrder(for: discoveredWindows[$0], fallback: $0) <
                    discoveredOrder(for: discoveredWindows[$1], fallback: $1)
            }
            let capturedByOrder = unmatchedCapturedIndices.sorted {
                capturedWindows[$0].frontToBackIndex < capturedWindows[$1].frontToBackIndex
            }

            for (discoveredIndex, capturedIndex) in zip(discoveredByOrder, capturedByOrder) {
                capturedIndexByDiscoveredIndex[discoveredIndex] = capturedIndex
            }
            unmatchedCapturedIndices.removeAll()
        }

        if !unmatchedCapturedIndices.isEmpty {
            isAmbiguous = true
        }

        return MatchResult(
            capturedIndexByDiscoveredIndex: capturedIndexByDiscoveredIndex,
            isAmbiguous: isAmbiguous
        )
    }

    private func discoveredOrder(
        for window: DiscoveredWindow,
        fallback: Int
    ) -> Int {
        window.zOrderHint ?? fallback
    }

    private func normalizedTitle(_ title: String?) -> String? {
        title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nonEmptyValue
    }

    private struct MatchResult {
        let capturedIndexByDiscoveredIndex: [Int: Int]
        let isAmbiguous: Bool
    }
}

private extension DiscoveredWindow {
    func addingBrowserEvidence(_ capturedWindow: CapturedBrowserWindow) -> DiscoveredWindow {
        let validator = WindowOpenTargetValidator()
        let retainedDocumentURLs = documentURLs.filter {
            validator.webTarget(url: $0) == nil
        }
        let targets = capturedWindow.tabs.compactMap { tab -> WindowOpenTarget? in
            guard let target = validator.webTarget(url: tab.URL) else {
                return nil
            }
            return WindowOpenTarget(
                id: target.id,
                kind: target.kind,
                url: target.url,
                title: tab.title
            )
        }
        return DiscoveredWindow(
            axElement: axElement,
            browserScriptingIdentifier: capturedWindow.scriptingIdentifier,
            documentURL: retainedDocumentURLs.first,
            documentURLs: retainedDocumentURLs,
            documentTitles: documentTitles,
            capturedOpeningTargets: targets,
            title: title,
            role: role,
            subrole: subrole,
            frame: frame,
            isMinimized: isMinimized,
            isFullscreen: isFullscreen,
            isMain: isMain,
            isVisible: isVisible,
            cgWindowID: cgWindowID,
            ownerName: ownerName,
            cgLayer: cgLayer,
            zOrderHint: zOrderHint,
            isOnScreen: isOnScreen
        )
    }
}

private extension CGRect {
    func isApproximatelyEqual(to other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance &&
            abs(minY - other.minY) <= tolerance &&
            abs(width - other.width) <= tolerance &&
            abs(height - other.height) <= tolerance
    }
}

private extension Array where Element == BrowserCaptureIssue {
    func uniqued() -> [BrowserCaptureIssue] {
        var seen: Set<String> = []
        return filter {
            seen.insert("\($0.browser.rawValue):\($0.reason.rawValue)").inserted
        }
    }
}
