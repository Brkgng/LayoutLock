import AppKit
import Combine
import SwiftUI

@MainActor
final class AppUpdateWindowController: NSWindowController, NSWindowDelegate,
    AppUpdateWindowPresenting
{
    static let shared = AppUpdateWindowController()

    private var model: AppUpdatePresentationModel?
    private var actionHandler: ((AppUpdateAction) -> Void)?
    private var phaseObservation: AnyCancellable?
    private var isClosingProgrammatically = false

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    func configure(
        model: AppUpdatePresentationModel,
        actionHandler: @escaping (AppUpdateAction) -> Void
    ) {
        self.model = model
        self.actionHandler = actionHandler

        phaseObservation = model.$phase.sink { [weak self] phase in
            self?.window?.standardWindowButton(.closeButton)?.isEnabled =
                phase.allowsWindowClose
        }
    }

    func show(activatingApplication: Bool) {
        guard let model, let actionHandler else {
            return
        }

        if window == nil {
            window = makeWindow(model: model, actionHandler: actionHandler)
        }

        if activatingApplication {
            NSApp.activate(ignoringOtherApps: true)
        }

        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    override func close() {
        isClosingProgrammatically = true
        super.close()
        isClosingProgrammatically = false
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        guard !isClosingProgrammatically, let phase = model?.phase else {
            return true
        }

        guard let closeAction = phase.closeAction else {
            NSSound.beep()
            return false
        }

        actionHandler?(closeAction)

        return false
    }

    private func makeWindow(
        model: AppUpdatePresentationModel,
        actionHandler: @escaping (AppUpdateAction) -> Void
    ) -> NSWindow {
        let hostingController = NSHostingController(
            rootView: AppUpdateView(model: model, actionHandler: actionHandler)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "LayoutLock Update"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 680, height: 520))
        window.contentMinSize = NSSize(width: 580, height: 420)
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.closeButton)?.isEnabled =
            model.phase.allowsWindowClose
        return window
    }
}

struct AppUpdateView: View {
    @ObservedObject var model: AppUpdatePresentationModel
    let actionHandler: (AppUpdateAction) -> Void
    @FocusState private var focusedAction: AppUpdateAction?

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .checking:
                statusView(
                    symbol: "arrow.triangle.2.circlepath.circle",
                    title: "Checking for Updates",
                    message: "Looking for the latest version of LayoutLock."
                ) {
                    actionButton("Cancel", action: .cancel, isCancelAction: true)
                }
            case let .available(details):
                updateView(details: details) {
                    availableFooter(details)
                }
            case let .downloading(details, progress):
                updateView(details: details) {
                    downloadingFooter(progress)
                }
            case let .extracting(details, progress):
                updateView(details: details) {
                    extractingFooter(progress)
                }
            case let .ready(details):
                updateView(details: details) {
                    readyFooter()
                }
            case let .installing(details, applicationTerminated):
                updateView(details: details) {
                    installingFooter(applicationTerminated: applicationTerminated)
                }
            case let .upToDate(message):
                statusView(
                    symbol: "checkmark.circle",
                    title: "LayoutLock Is Up to Date",
                    message: message
                ) {
                    actionButton("Close", action: .acknowledge, isCancelAction: true)
                }
            case let .unavailable(title, message):
                statusView(
                    symbol: "exclamationmark.circle",
                    title: title,
                    message: message
                ) {
                    actionButton("Close", action: .acknowledge, isCancelAction: true)
                }
            case let .error(title, message):
                statusView(
                    symbol: "exclamationmark.triangle",
                    title: title,
                    message: message
                ) {
                    HStack {
                        actionButton("Close", action: .acknowledge, isCancelAction: true)
                        actionButton("Retry", action: .retry, isDefaultAction: true)
                    }
                }
            case let .installed(relaunched):
                statusView(
                    symbol: "checkmark.seal",
                    title: "Update Installed",
                    message: relaunched
                        ? "LayoutLock was updated and relaunched successfully."
                        : "LayoutLock was updated successfully."
                ) {
                    actionButton("Close", action: .acknowledge, isCancelAction: true)
                }
            }
        }
        .frame(minWidth: 580, minHeight: 420)
        .tint(.accentColor)
        .defaultFocus($focusedAction, model.phase.preferredFocusAction)
        .onChange(of: model.phase.preferredFocusAction) { _, action in
            focusedAction = action
        }
        .onExitCommand(perform: handleExitCommand)
    }

    private func updateView<Footer: View>(
        details: AppUpdateDetails,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        VStack(spacing: 0) {
            updateHeader(details)
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 20)

            releaseNotesCard(details)
                .padding(.horizontal, 28)

            Spacer(minLength: 18)

            Divider()

            footer()
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
    }

    private func updateHeader(_ details: AppUpdateDetails) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 30))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Text(headerTitle)
                    .font(.title2.bold())

                HStack(spacing: 8) {
                    Text(details.currentVersion)
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.semibold))
                        .accessibilityLabel("to")
                    Text(details.displayVersion)
                        .foregroundStyle(.tint)
                }
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Current version \(details.currentVersion), new version \(details.displayVersion)"
                )
            }

            Spacer()
        }
    }

    private func releaseNotesCard(_ details: AppUpdateDetails) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("v\(details.displayVersion)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.tint)

                if let releaseDate = details.formattedReleaseDate {
                    Text(releaseDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Divider()

            ScrollView {
                releaseNotesText(details)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
            .defaultScrollAnchor(.top)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Release notes for version \(details.displayVersion)")
    }

    @ViewBuilder
    private func releaseNotesText(_ details: AppUpdateDetails) -> some View {
        switch details.releaseNotesFormat {
        case .markdown:
            AppUpdateMarkdownView(markdown: details.releaseNotes)
                .textSelection(.enabled)
                .environment(\.openURL, safeOpenURLAction)
        case .plainText, .unavailable:
            Text(details.releaseNotes)
                .font(.body)
                .textSelection(.enabled)
        }
    }

    private func availableFooter(_ details: AppUpdateDetails) -> some View {
        HStack(spacing: 10) {
            if details.shouldOfferExternalReleaseNotes {
                actionButton(
                    "Open Release Notes in Browser",
                    action: .openReleaseNotes
                )
            }

            Spacer()

            if details.isInformational {
                actionButton(
                    details.primaryActionTitle,
                    action: .learnMore,
                    isDefaultAction: true,
                    isDisabled: details.learnMoreURL == nil
                )
            } else {
                actionButton(
                    details.primaryActionTitle,
                    action: .install,
                    isDefaultAction: true
                )
            }
        }
    }

    private func downloadingFooter(_ progress: AppUpdateProgress) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloading Update")
                    .font(.headline)

                if let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction)
                        .accessibilityLabel("Download progress")
                        .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))

                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Downloading update")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actionButton("Cancel Download", action: .cancel, isCancelAction: true)
        }
    }

    private func extractingFooter(_ progress: Double?) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Preparing Update")
                    .font(.headline)

                if let progress {
                    ProgressView(value: progress)
                        .accessibilityLabel("Preparation progress")
                        .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Preparing update")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("Please wait…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func readyFooter() -> some View {
        HStack(spacing: 10) {
            Text("The update is ready.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            actionButton(
                "Install and Relaunch",
                action: .installAndRelaunch,
                isDefaultAction: true
            )
        }
    }

    private func installingFooter(applicationTerminated: Bool) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)

            Text(applicationTerminated ? "Installing Update…" : "Waiting for LayoutLock to Quit…")
                .font(.headline)

            Spacer()

            if !applicationTerminated {
                actionButton(
                    "Try Quitting Again",
                    action: .retryTermination,
                    isDefaultAction: true
                )
            }
        }
    }

    private func statusView<Actions: View>(
        symbol: String,
        title: String,
        message: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: symbol)
                .font(.system(size: 46))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.bold())

                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .textSelection(.enabled)
            }

            Spacer()

            actions()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .padding(.top, 24)
    }

    private func actionButton(
        _ title: String,
        action: AppUpdateAction,
        isDefaultAction: Bool = false,
        isCancelAction: Bool = false,
        isDisabled: Bool = false
    ) -> some View {
        Button(title) {
            actionHandler(action)
        }
        .disabled(isDisabled)
        .focused($focusedAction, equals: action)
        .keyboardShortcut(
            isDefaultAction ? .defaultAction : isCancelAction ? .cancelAction : nil
        )
    }

    private var headerTitle: String {
        switch model.phase {
        case .available:
            "Update Available"
        case .downloading:
            "Downloading Update"
        case .extracting:
            "Preparing Update"
        case .ready:
            "Ready to Install"
        case .installing:
            "Installing Update"
        case .checking, .upToDate, .unavailable, .error, .installed:
            "LayoutLock Update"
        }
    }

    private var safeOpenURLAction: OpenURLAction {
        OpenURLAction { url in
            url.scheme?.lowercased() == "https" ? .systemAction(url) : .discarded
        }
    }

    private func handleExitCommand() {
        guard let closeAction = model.phase.closeAction else {
            NSSound.beep()
            return
        }

        actionHandler(closeAction)
    }
}

struct AppUpdateMarkdownBlock: Identifiable {
    enum Kind: Equatable {
        case heading(level: Int)
        case paragraph
        case unorderedListItem
        case orderedListItem(ordinal: Int)
    }

    let id: Int
    let kind: Kind
    let content: AttributedString

    var plainText: String {
        String(content.characters)
    }
}

enum AppUpdateMarkdown {
    static func blocks(from markdown: String) -> [AppUpdateMarkdownBlock] {
        guard let attributed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full)
        ) else {
            return [
                AppUpdateMarkdownBlock(
                    id: 0,
                    kind: .paragraph,
                    content: AttributedString(markdown)
                ),
            ]
        }

        var blocks: [AppUpdateMarkdownBlock] = []
        var currentID: Int?
        var currentKind = AppUpdateMarkdownBlock.Kind.paragraph
        var currentContent = AttributedString()
        var fallbackID = -1

        func appendCurrentBlock() {
            guard let currentID, !currentContent.characters.isEmpty else {
                return
            }

            blocks.append(
                AppUpdateMarkdownBlock(
                    id: currentID,
                    kind: currentKind,
                    content: currentContent
                )
            )
        }

        for run in attributed.runs {
            let components = run.presentationIntent?.components ?? []
            let blockID = components.first?.identity ?? fallbackID

            if blockID != currentID {
                appendCurrentBlock()
                currentID = blockID
                currentKind = kind(from: components)
                currentContent = AttributedString()
                fallbackID -= 1
            }

            currentContent.append(AttributedString(attributed[run.range]))
        }

        appendCurrentBlock()
        return blocks
    }

    private static func kind(
        from components: [PresentationIntent.IntentType]
    ) -> AppUpdateMarkdownBlock.Kind {
        var listItemOrdinal: Int?
        var isOrderedList = false
        var isUnorderedList = false

        for component in components {
            switch component.kind {
            case let .header(level):
                return .heading(level: level)
            case let .listItem(ordinal):
                listItemOrdinal = listItemOrdinal ?? ordinal
            case .orderedList:
                isOrderedList = true
            case .unorderedList:
                isUnorderedList = true
            default:
                break
            }
        }

        if isOrderedList, let listItemOrdinal {
            return .orderedListItem(ordinal: listItemOrdinal)
        }
        if isUnorderedList {
            return .unorderedListItem
        }
        return .paragraph
    }
}

private struct AppUpdateMarkdownView: View {
    let blocks: [AppUpdateMarkdownBlock]

    init(markdown: String) {
        blocks = AppUpdateMarkdown.blocks(from: markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                switch block.kind {
                case let .heading(level):
                    Text(block.content)
                        .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                case .paragraph:
                    Text(block.content)
                        .font(.body)
                case .unorderedListItem:
                    listItem(marker: "•", content: block.content)
                case let .orderedListItem(ordinal):
                    listItem(marker: "\(ordinal).", content: block.content)
                }
            }
        }
    }

    private func listItem(marker: String, content: AttributedString) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(content)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#if DEBUG
@MainActor
enum AppUpdatePreviewFixtures {
    static let details = AppUpdateDetails(
        currentVersion: "1.2.0",
        buildVersion: "130",
        displayVersion: "1.3.0",
        releaseDate: .now,
        releaseNotes: """
        ## What’s New

        - Restores window layouts more reliably across displays.
        - Adds clearer feedback while a layout is being restored.
        - Improves keyboard navigation and accessibility.

        ## Also Improved

        1. Long release notes now remain easy to scan in a flexible scroll area.
        2. Markdown supports **emphasis**, lists, and [secure links](https://layoutlock.app/releases).
        3. Update progress is exposed without interrupting VoiceOver on every tick.

        Resize the window to its minimum size and verify this text remains readable.
        """,
        releaseNotesFormat: .markdown,
        releaseNotesURL: URL(string: "https://layoutlock.app/releases"),
        informationURL: URL(string: "https://layoutlock.app/releases"),
        isCritical: false,
        isInformational: false
    )

    static func model(_ phase: AppUpdatePresentationPhase) -> AppUpdatePresentationModel {
        let model = AppUpdatePresentationModel()
        model.phase = phase
        return model
    }
}

#Preview("Available — Light") {
    AppUpdateView(
        model: AppUpdatePreviewFixtures.model(.available(AppUpdatePreviewFixtures.details)),
        actionHandler: { _ in }
    )
    .preferredColorScheme(.light)
}

#Preview("Available — Dark") {
    AppUpdateView(
        model: AppUpdatePreviewFixtures.model(.available(AppUpdatePreviewFixtures.details)),
        actionHandler: { _ in }
    )
    .preferredColorScheme(.dark)
}

#Preview("Downloading") {
    AppUpdateView(
        model: AppUpdatePreviewFixtures.model(
            .downloading(
                AppUpdatePreviewFixtures.details,
                AppUpdateProgress(receivedBytes: 42, expectedBytes: 100)
            )
        ),
        actionHandler: { _ in }
    )
}

#Preview("Ready") {
    AppUpdateView(
        model: AppUpdatePreviewFixtures.model(.ready(AppUpdatePreviewFixtures.details)),
        actionHandler: { _ in }
    )
}

#Preview("Up to Date") {
    AppUpdateView(
        model: AppUpdatePreviewFixtures.model(
            .upToDate(message: "You’re using the latest version of LayoutLock.")
        ),
        actionHandler: { _ in }
    )
}

#Preview("Error") {
    AppUpdateView(
        model: AppUpdatePreviewFixtures.model(
            .error(
                title: "Unable to Check for Updates",
                message: "The update server could not be reached."
            )
        ),
        actionHandler: { _ in }
    )
}
#endif
