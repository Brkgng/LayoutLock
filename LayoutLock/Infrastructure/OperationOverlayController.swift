import AppKit
import QuartzCore
import Symbols

@MainActor
enum OperationOverlayKind {
    case save
    case restore

    var message: String {
        switch self {
        case .save:
            return "Saving layout..."
        case .restore:
            return "Restoring layout..."
        }
    }
}

struct RestoreCompletionMessage {
    let title: String
    let summary: String
    let issues: [RestoreCompletionIssue]
    let hasIssues: Bool
    var isFailure = false

    var symbolName: String {
        isFailure ? "xmark.circle.fill" : hasIssues ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    var tintColor: NSColor {
        isFailure ? .systemRed : hasIssues ? .systemOrange : .systemGreen
    }
}

struct RestoreCompletionIssue {
    let appName: String
    let context: String?
    let reason: String
    var actions: [RestoreCompletionAction] = []
}

struct RestoreCompletionAction {
    let title: String
    let perform: @MainActor () -> Void
}

@MainActor
protocol OperationOverlayPresenting: AnyObject {
    func showOverlay(kind: OperationOverlayKind) async
    func updateRestoreProgress(_ message: String, layoutName: String)
    func showRestoreProgressInBackground(_ message: String, layoutName: String)
    func showRestoreCompletion(_ completion: RestoreCompletionMessage)
    func hideOverlay()
}

extension OperationOverlayPresenting {
    func updateRestoreProgress(_: String, layoutName _: String) {}
    func showRestoreProgressInBackground(_: String, layoutName _: String) {}
}

@MainActor
final class NoOpOperationOverlayPresenter: OperationOverlayPresenting {
    nonisolated init() {}

    func showOverlay(kind _: OperationOverlayKind) async {}
    func showRestoreCompletion(_: RestoreCompletionMessage) {}
    func hideOverlay() {}
}

@MainActor
final class OperationOverlayController: OperationOverlayPresenting, StatusNoticePresenting, DisplayRestoreSuggestionPresenting {
    private let minimumVisibleDuration: TimeInterval
    private let completionVisibleDuration: TimeInterval
    private let fadeInDuration: TimeInterval
    private let fadeOutDuration: TimeInterval
    private let presentationBarrier: @MainActor () async -> Void
    private var overlayWindows: [NSWindow] = []
    private var statusNoticeWindow: NSWindow?
    private var displayRestoreSuggestionWindow: NSWindow?
    private var statusNoticeGeneration = 0
    private var shownAt: Date?
    private var generation = 0

    var isDisplayRestoreSuggestionVisible: Bool {
        displayRestoreSuggestionWindow != nil
    }

    init(
        minimumVisibleDuration: TimeInterval = 0.4,
        completionVisibleDuration: TimeInterval = 15,
        fadeInDuration: TimeInterval = 0.12,
        fadeOutDuration: TimeInterval = 0.18,
        presentationBarrier: @escaping @MainActor () async -> Void = OperationOverlayController.defaultPresentationBarrier
    ) {
        self.minimumVisibleDuration = minimumVisibleDuration
        self.completionVisibleDuration = completionVisibleDuration
        self.fadeInDuration = fadeInDuration
        self.fadeOutDuration = fadeOutDuration
        self.presentationBarrier = presentationBarrier
    }

    private static func defaultPresentationBarrier() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func showOverlay(kind: OperationOverlayKind) async {
        generation += 1
        closeOverlayWindows()
        closeDisplayRestoreSuggestionWindow()

        let capturedGeneration = generation
        let windows = NSScreen.screens.map { screen in
            OperationOverlayWindow(screen: screen, message: kind.message)
        }
        overlayWindows = windows

        for window in windows {
            window.alphaValue = 0
            window.orderFrontRegardless()
            window.displayIfNeeded()
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            windows.forEach { $0.animator().alphaValue = 1 }
        } completionHandler: {
        }

        await presentationBarrier()

        guard capturedGeneration == generation,
              !overlayWindows.isEmpty else {
            return
        }

        shownAt = Date()
    }

    func updateRestoreProgress(_ message: String, layoutName: String) {
        for window in overlayWindows {
            (window.contentView as? OperationOverlayContentView)?.updateMessage(message, layoutName: layoutName)
        }
    }

    func showRestoreProgressInBackground(_ message: String, layoutName: String) {
        generation += 1
        closeOverlayWindows()
        guard let screen = screenContainingMousePointer() ?? NSScreen.main else { return }
        let window = OperationOverlayWindow(screen: screen, message: message, layoutName: layoutName, compact: true)
        overlayWindows = [window]
        shownAt = Date()
        window.orderFrontRegardless()
    }

    func showRestoreCompletion(_ completion: RestoreCompletionMessage) {
        generation += 1
        closeOverlayWindows()
        closeDisplayRestoreSuggestionWindow()

        let windows = NSScreen.screens.map { screen in
            OperationCompletionToastWindow(screen: screen, completion: completion) { [weak self] in
                self?.dismissCompletionToast()
            }
        }
        overlayWindows = windows
        shownAt = Date()

        for window in windows {
            window.alphaValue = 0
            window.orderFrontRegardless()
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            windows.forEach { $0.animator().alphaValue = 1 }
        }

        let capturedGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + completionVisibleDuration) { [weak self] in
            guard let self else {
                return
            }

            Task { @MainActor in
                guard capturedGeneration == self.generation else {
                    return
                }

                self.fadeOutAndCloseOverlayWindows()
            }
        }
    }

    func showStatusNotice(message: String, duration: TimeInterval) {
        statusNoticeGeneration += 1
        closeStatusNoticeWindow()

        let screen = screenContainingMousePointer() ?? NSScreen.main
        guard let screen else {
            return
        }

        let window = StatusNoticeWindow(screen: screen, message: message)
        statusNoticeWindow = window
        window.alphaValue = 0
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }

        let capturedGeneration = statusNoticeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self else {
                return
            }

            Task { @MainActor in
                guard capturedGeneration == self.statusNoticeGeneration else {
                    return
                }

                self.fadeOutAndCloseStatusNoticeWindow()
            }
        }
    }

    func showDisplayRestoreSuggestion(
        snapshotName: String,
        restore: @escaping @MainActor () -> Void
    ) {
        closeDisplayRestoreSuggestionWindow()

        let screen = screenContainingMousePointer() ?? NSScreen.main
        guard let screen else {
            return
        }

        let window = DisplayRestoreSuggestionToastWindow(
            screen: screen,
            snapshotName: snapshotName,
            onRestore: { [weak self] in
                self?.hideDisplayRestoreSuggestion()
                restore()
            },
            onDismiss: { [weak self] in
                self?.hideDisplayRestoreSuggestion()
            }
        )
        displayRestoreSuggestionWindow = window
        window.alphaValue = 0
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    func showDisplayRestoreSuggestionChooser(
        options: [DisplayRestoreSuggestionOption],
        restore: @escaping @MainActor (UUID) -> Void
    ) {
        closeDisplayRestoreSuggestionWindow()

        let screen = screenContainingMousePointer() ?? NSScreen.main
        guard let screen else {
            return
        }

        let window = DisplayRestoreSuggestionChooserToastWindow(
            screen: screen,
            options: options,
            onRestore: { [weak self] snapshotID in
                self?.hideDisplayRestoreSuggestion()
                restore(snapshotID)
            },
            onDismiss: { [weak self] in
                self?.hideDisplayRestoreSuggestion()
            }
        )
        displayRestoreSuggestionWindow = window
        window.alphaValue = 0
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    func hideDisplayRestoreSuggestion() {
        fadeOutAndCloseDisplayRestoreSuggestionWindow()
    }

    func hideStatusNotice() {
        statusNoticeGeneration += 1
        fadeOutAndCloseStatusNoticeWindow()
    }

    private func dismissCompletionToast() {
        generation += 1
        fadeOutAndCloseOverlayWindows()
    }

    func hideOverlay() {
        guard !overlayWindows.isEmpty else {
            return
        }

        let capturedGeneration = generation
        let elapsed = shownAt.map { Date().timeIntervalSince($0) } ?? minimumVisibleDuration
        let delay = max(0, minimumVisibleDuration - elapsed)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else {
                return
            }

            Task { @MainActor in
                guard capturedGeneration == self.generation else {
                    return
                }

                self.fadeOutAndCloseOverlayWindows()
            }
        }
    }

    private func fadeOutAndCloseOverlayWindows() {
        let windows = overlayWindows
        guard !windows.isEmpty else {
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            windows.forEach { $0.animator().alphaValue = 0 }
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else {
                    return
                }

                windows.forEach { $0.orderOut(nil) }
                self.overlayWindows.removeAll { window in
                    windows.contains { $0 === window }
                }
                if self.overlayWindows.isEmpty {
                    self.shownAt = nil
                }
            }
        }
    }

    private func closeOverlayWindows() {
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        shownAt = nil
    }

    private func fadeOutAndCloseDisplayRestoreSuggestionWindow() {
        guard let window = displayRestoreSuggestionWindow else {
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self, weak window] in
            Task { @MainActor in
                guard let self, let window else {
                    return
                }

                window.orderOut(nil)
                if self.displayRestoreSuggestionWindow === window {
                    self.displayRestoreSuggestionWindow = nil
                }
            }
        }
    }

    private func closeDisplayRestoreSuggestionWindow() {
        displayRestoreSuggestionWindow?.orderOut(nil)
        displayRestoreSuggestionWindow = nil
    }

    private func fadeOutAndCloseStatusNoticeWindow() {
        guard let window = statusNoticeWindow else {
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self, weak window] in
            Task { @MainActor in
                guard let self, let window else {
                    return
                }

                window.orderOut(nil)
                if self.statusNoticeWindow === window {
                    self.statusNoticeWindow = nil
                }
            }
        }
    }

    private func closeStatusNoticeWindow() {
        statusNoticeWindow?.orderOut(nil)
        statusNoticeWindow = nil
    }

    private func screenContainingMousePointer() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        }
    }
}

private final class StatusNoticeWindow: NSPanel {
    init(screen: NSScreen, message: String) {
        let visibleFrame = screen.visibleFrame
        let width = min(460, max(300, visibleFrame.width - 48))
        let height: CGFloat = 78
        let frame = CGRect(
            x: visibleFrame.midX - (width / 2),
            y: visibleFrame.maxY - height - 28,
            width: width,
            height: height
        )

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        contentView = StatusNoticeContentView(message: message)
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

final class OperationCompletionToastWindow: NSPanel {
    init(
        screen: NSScreen,
        completion: RestoreCompletionMessage,
        onDismiss: @escaping () -> Void
    ) {
        let visibleFrame = screen.visibleFrame
        let width = min(460, visibleFrame.width - 48)
        let toastContent = OperationCompletionToastContentView(
            width: width,
            completion: completion,
            onDismiss: onDismiss
        )
        let height = toastContent.fittingSize.height
        let frame = CGRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.maxY - height - 28,
            width: width,
            height: height
        )

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = false
        level = .statusBar
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        toastContent.frame = CGRect(origin: .zero, size: frame.size)
        contentView = toastContent
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class DisplayRestoreSuggestionToastWindow: NSPanel {
    init(
        screen: NSScreen,
        snapshotName: String,
        onRestore: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        let visibleFrame = screen.visibleFrame
        let width = min(460, max(320, visibleFrame.width - 48))
        let height: CGFloat = 112
        let frame = CGRect(
            x: visibleFrame.midX - (width / 2),
            y: visibleFrame.maxY - height - 28,
            width: width,
            height: height
        )

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = false
        level = .statusBar
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        contentView = DisplayRestoreSuggestionToastContentView(
            snapshotName: snapshotName,
            onRestore: onRestore,
            onDismiss: onDismiss
        )
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

private final class DisplayRestoreSuggestionChooserToastWindow: NSPanel {
    init(
        screen: NSScreen,
        options: [DisplayRestoreSuggestionOption],
        onRestore: @escaping (UUID) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        let visibleFrame = screen.visibleFrame
        let width = min(460, max(320, visibleFrame.width - 48))
        let height: CGFloat = 112
        let frame = CGRect(
            x: visibleFrame.midX - (width / 2),
            y: visibleFrame.maxY - height - 28,
            width: width,
            height: height
        )

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = false
        level = .statusBar
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        contentView = DisplayRestoreSuggestionChooserToastContentView(
            options: options,
            onRestore: onRestore,
            onDismiss: onDismiss
        )
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

final class OperationOverlayWindow: NSPanel {
    init(screen: NSScreen, message: String, layoutName: String? = nil, compact: Bool = false) {
        let visibleFrame = screen.visibleFrame
        let width = min(460, visibleFrame.width - 48)
        let frame = compact ? CGRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.maxY - 160,
            width: width,
            height: 132
        ) : screen.frame
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        setFrame(frame, display: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = compact
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        contentView = OperationOverlayContentView(message: message, layoutName: layoutName, compact: compact)
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

private final class OperationCompletionToastContentView: NSView {
    private let completion: RestoreCompletionMessage
    private let onDismiss: () -> Void

    init(width: CGFloat, completion: RestoreCompletionMessage, onDismiss: @escaping () -> Void) {
        self.completion = completion
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        buildView(width: width)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func buildView(width: CGFloat) {
        let icon = NSImageView(image: NSImage(systemSymbolName: completion.symbolName, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 22, weight: .semibold)
        icon.contentTintColor = completion.tintColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = OperationToastCloseButton(target: self, action: #selector(dismiss))
        let textWidth = width - 98
        let titleLabel = NSTextField(wrappingLabelWithString: completion.title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.preferredMaxLayoutWidth = textWidth

        let summaryLabel = NSTextField(wrappingLabelWithString: completion.summary)
        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.preferredMaxLayoutWidth = textWidth

        let textStackView = NSStackView(views: [titleLabel, summaryLabel])
        textStackView.orientation = .vertical
        textStackView.alignment = .leading
        textStackView.spacing = 4
        textStackView.translatesAutoresizingMaskIntoConstraints = false

        if !completion.issues.isEmpty {
            let detailsButton = NSButton(title: "Details…", target: self, action: #selector(showDetails))
            detailsButton.bezelStyle = .inline
            detailsButton.setAccessibilityLabel("Show restore details")
            textStackView.addArrangedSubview(detailsButton)
        }

        let toastView = NSVisualEffectView()
        toastView.material = .hudWindow
        toastView.blendingMode = .behindWindow
        toastView.state = .active
        toastView.wantsLayer = true
        toastView.layer?.cornerRadius = 14
        toastView.layer?.masksToBounds = true
        toastView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(toastView)
        toastView.addSubview(icon)
        toastView.addSubview(textStackView)
        toastView.addSubview(closeButton)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            toastView.leadingAnchor.constraint(equalTo: leadingAnchor),
            toastView.trailingAnchor.constraint(equalTo: trailingAnchor),
            toastView.topAnchor.constraint(equalTo: topAnchor),
            toastView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 76),

            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            icon.leadingAnchor.constraint(equalTo: toastView.leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: toastView.topAnchor, constant: 16),
            closeButton.widthAnchor.constraint(equalToConstant: OperationToastCloseButton.hitSize),
            closeButton.heightAnchor.constraint(equalToConstant: OperationToastCloseButton.hitSize),
            closeButton.topAnchor.constraint(equalTo: toastView.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: toastView.trailingAnchor, constant: -4),

            titleLabel.widthAnchor.constraint(equalToConstant: textWidth),
            summaryLabel.widthAnchor.constraint(equalToConstant: textWidth),
            textStackView.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            textStackView.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -10),
            textStackView.topAnchor.constraint(equalTo: toastView.topAnchor, constant: 14),
            textStackView.bottomAnchor.constraint(equalTo: toastView.bottomAnchor, constant: -14)
        ])
    }

    @objc private func showDetails() {
        let detailsWindow = RestoreCompletionDetailsWindow(completion: completion)
        let screen = window?.screen ?? NSScreen.main
        onDismiss()
        NSApp.activate(ignoringOtherApps: true)
        if let screen {
            let visibleFrame = screen.visibleFrame
            detailsWindow.setFrameOrigin(NSPoint(
                x: visibleFrame.midX - detailsWindow.frame.width / 2,
                y: visibleFrame.midY - detailsWindow.frame.height / 2
            ))
        }
        detailsWindow.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: detailsWindow)
        detailsWindow.close()
        detailsWindow.selectedAction?.perform()
    }

    @objc private func dismiss() {
        onDismiss()
    }
}

final class RestoreCompletionDetailsWindow: NSPanel, NSWindowDelegate {
    private(set) var selectedAction: RestoreCompletionAction?

    init(completion: RestoreCompletionMessage) {
        let content = RestoreCompletionDetailsContentView(completion: completion)
        super.init(
            contentRect: CGRect(origin: .zero, size: content.fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Restore Details"
        isReleasedWhenClosed = false
        content.frame = CGRect(origin: .zero, size: content.fittingSize)
        contentView = content
        delegate = self
        content.onDismiss = { NSApp.stopModal() }
        content.onAction = { [weak self] action in
            self?.selectedAction = action
            NSApp.stopModal()
        }
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        NSApp.stopModal()
        return false
    }

    override func cancelOperation(_: Any?) {
        NSApp.stopModal()
    }
}

private final class RestoreIssueStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private final class RestoreCompletionDetailsContentView: NSView {
    var onDismiss: (() -> Void)?
    var onAction: ((RestoreCompletionAction) -> Void)?

    init(completion: RestoreCompletionMessage) {
        super.init(frame: .zero)
        let width: CGFloat = 560
        let contentWidth = width - 48
        let icon = NSImageView(image: NSImage(systemSymbolName: completion.symbolName, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 28, weight: .medium)
        icon.contentTintColor = completion.tintColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = Self.label(completion.title, width: contentWidth - 48, size: 19, weight: .semibold)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.toolTip = completion.title
        let summaryLabel = Self.label(completion.summary, width: contentWidth - 48, size: 14)
        summaryLabel.textColor = .secondaryLabelColor
        let headings = NSStackView(views: [titleLabel, summaryLabel])
        headings.orientation = .vertical
        headings.alignment = .leading
        headings.spacing = 6
        let header = NSStackView(views: [icon, headings])
        header.alignment = .top
        header.spacing = 16
        header.translatesAutoresizingMaskIntoConstraints = false

        let rows = RestoreIssueStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        for issue in completion.issues {
            let cardBorderWidth: CGFloat = 0.5
            let textWidth = contentWidth - 32 - 2 * cardBorderWidth
            let appLabel = Self.label(issue.appName, width: textWidth, size: 14, weight: .semibold)
            let reasonLabel = Self.label(issue.reason, width: textWidth, size: 14)
            var labels = [appLabel, reasonLabel]
            if let context = issue.context {
                let contextLabel = Self.label(context, width: textWidth, size: 12)
                contextLabel.textColor = .secondaryLabelColor
                contextLabel.setAccessibilityLabel("Saved window or target: \(context)")
                labels.append(contextLabel)
            }
            let text = NSStackView(views: labels)
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 6
            text.translatesAutoresizingMaskIntoConstraints = false
            if !issue.actions.isEmpty {
                let buttons = issue.actions.map { action in
                    RestoreIssueActionButton(action: action, appName: issue.appName) { [weak self] in
                        self?.onAction?(action)
                    }
                }
                let actions = NSStackView(views: buttons)
                actions.orientation = .horizontal
                actions.spacing = 8
                text.addArrangedSubview(actions)
            }

            let card = NSBox()
            card.boxType = .custom
            card.titlePosition = .noTitle
            card.fillColor = .controlBackgroundColor
            card.borderColor = .separatorColor
            card.borderWidth = cardBorderWidth
            card.cornerRadius = 10
            card.contentViewMargins = .zero
            card.translatesAutoresizingMaskIntoConstraints = false
            let cardContent = card.contentView!
            cardContent.addSubview(text)
            NSLayoutConstraint.activate([
                card.widthAnchor.constraint(equalToConstant: contentWidth),
                text.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor, constant: 16),
                text.trailingAnchor.constraint(equalTo: cardContent.trailingAnchor, constant: -16),
                text.topAnchor.constraint(equalTo: cardContent.topAnchor, constant: 14),
                text.bottomAnchor.constraint(equalTo: cardContent.bottomAnchor, constant: -14)
            ])
            rows.addArrangedSubview(card)
        }

        rows.layoutSubtreeIfNeeded()
        let rowsHeight = ceil(rows.fittingSize.height)
        rows.frame = CGRect(x: 0, y: 0, width: contentWidth, height: rowsHeight)
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = rows
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let doneButton = NSButton(title: "Done", target: self, action: #selector(dismiss))
        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .large
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(scrollView)
        addSubview(doneButton)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),
            scrollView.heightAnchor.constraint(equalToConstant: min(rowsHeight, 320)),
            doneButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 20),
            doneButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            doneButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private static func label(
        _ text: String,
        width: CGFloat,
        size: CGFloat,
        weight: NSFont.Weight = .regular
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = .labelColor
        label.isSelectable = true
        label.preferredMaxLayoutWidth = width
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    @objc private func dismiss() {
        onDismiss?()
    }
}

private final class RestoreIssueActionButton: NSButton {
    private let onPerform: () -> Void

    init(action: RestoreCompletionAction, appName: String, onPerform: @escaping () -> Void) {
        self.onPerform = onPerform
        super.init(frame: .zero)
        title = action.title
        bezelStyle = .rounded
        target = self
        self.action = #selector(performAction)
        setAccessibilityLabel("\(action.title) for \(appName)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func performAction() {
        onPerform()
    }
}

private final class DisplayRestoreSuggestionToastContentView: NSView {
    private let snapshotName: String
    private let onRestore: () -> Void
    private let onDismiss: () -> Void

    init(
        snapshotName: String,
        onRestore: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.snapshotName = snapshotName
        self.onRestore = onRestore
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        buildView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func buildView() {
        let icon = NSImageView(image: NSImage(systemSymbolName: "display.2", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 22, weight: .semibold)
        icon.contentTintColor = .systemBlue
        icon.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = OperationToastCloseButton(target: self, action: #selector(dismiss))

        let titleLabel = NSTextField(labelWithString: "Display changed")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail

        let detailLabel = NSTextField(labelWithString: "Restore \"\(snapshotName)\"?")
        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 1
        detailLabel.lineBreakMode = .byTruncatingTail

        let restoreButton = NSButton(title: "Restore", target: self, action: #selector(restoreLayout))
        restoreButton.bezelStyle = .rounded
        restoreButton.controlSize = .regular
        restoreButton.keyEquivalent = "\r"
        restoreButton.translatesAutoresizingMaskIntoConstraints = false

        let textStackView = NSStackView(views: [titleLabel, detailLabel])
        textStackView.orientation = .vertical
        textStackView.alignment = .leading
        textStackView.spacing = 4
        textStackView.translatesAutoresizingMaskIntoConstraints = false

        let contentStackView = NSStackView(views: [icon, textStackView])
        contentStackView.orientation = .horizontal
        contentStackView.alignment = .centerY
        contentStackView.spacing = 12
        contentStackView.translatesAutoresizingMaskIntoConstraints = false

        let toastView = NSVisualEffectView()
        toastView.material = .hudWindow
        toastView.blendingMode = .behindWindow
        toastView.state = .active
        toastView.wantsLayer = true
        toastView.layer?.cornerRadius = 14
        toastView.layer?.masksToBounds = true
        toastView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(toastView)
        toastView.addSubview(contentStackView)
        toastView.addSubview(closeButton)
        toastView.addSubview(restoreButton)

        NSLayoutConstraint.activate([
            toastView.leadingAnchor.constraint(equalTo: leadingAnchor),
            toastView.trailingAnchor.constraint(equalTo: trailingAnchor),
            toastView.topAnchor.constraint(equalTo: topAnchor),
            toastView.bottomAnchor.constraint(equalTo: bottomAnchor),

            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            closeButton.widthAnchor.constraint(equalToConstant: OperationToastCloseButton.hitSize),
            closeButton.heightAnchor.constraint(equalToConstant: OperationToastCloseButton.hitSize),
            closeButton.topAnchor.constraint(equalTo: toastView.topAnchor, constant: OperationToastCloseButton.edgeInset),
            closeButton.trailingAnchor.constraint(
                equalTo: toastView.trailingAnchor,
                constant: -OperationToastCloseButton.edgeInset
            ),

            contentStackView.leadingAnchor.constraint(equalTo: toastView.leadingAnchor, constant: 16),
            contentStackView.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -10),
            contentStackView.topAnchor.constraint(equalTo: toastView.topAnchor, constant: 16),

            restoreButton.trailingAnchor.constraint(equalTo: toastView.trailingAnchor, constant: -16),
            restoreButton.bottomAnchor.constraint(equalTo: toastView.bottomAnchor, constant: -14),
            restoreButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 84)
        ])
    }

    @objc private func restoreLayout() {
        onRestore()
    }

    @objc private func dismiss() {
        onDismiss()
    }
}

private final class DisplayRestoreSuggestionChooserToastContentView: NSView {
    private let options: [DisplayRestoreSuggestionOption]
    private let onRestore: (UUID) -> Void
    private let onDismiss: () -> Void

    init(
        options: [DisplayRestoreSuggestionOption],
        onRestore: @escaping (UUID) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.options = options
        self.onRestore = onRestore
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        buildView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func buildView() {
        let icon = NSImageView(image: NSImage(systemSymbolName: "display.2", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 22, weight: .semibold)
        icon.contentTintColor = .systemBlue
        icon.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = OperationToastCloseButton(target: self, action: #selector(dismiss))

        let titleLabel = NSTextField(labelWithString: "Display changed")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail

        let detailLabel = NSTextField(labelWithString: "Multiple saved layouts match this display setup.")
        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 1
        detailLabel.lineBreakMode = .byTruncatingTail

        let chooseButton = NSButton(title: "Choose Layout", target: self, action: #selector(chooseLayout(_:)))
        chooseButton.bezelStyle = .rounded
        chooseButton.controlSize = .regular
        chooseButton.translatesAutoresizingMaskIntoConstraints = false

        let textStackView = NSStackView(views: [titleLabel, detailLabel])
        textStackView.orientation = .vertical
        textStackView.alignment = .leading
        textStackView.spacing = 4
        textStackView.translatesAutoresizingMaskIntoConstraints = false

        let contentStackView = NSStackView(views: [icon, textStackView])
        contentStackView.orientation = .horizontal
        contentStackView.alignment = .centerY
        contentStackView.spacing = 12
        contentStackView.translatesAutoresizingMaskIntoConstraints = false

        let toastView = NSVisualEffectView()
        toastView.material = .hudWindow
        toastView.blendingMode = .behindWindow
        toastView.state = .active
        toastView.wantsLayer = true
        toastView.layer?.cornerRadius = 14
        toastView.layer?.masksToBounds = true
        toastView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(toastView)
        toastView.addSubview(contentStackView)
        toastView.addSubview(closeButton)
        toastView.addSubview(chooseButton)

        NSLayoutConstraint.activate([
            toastView.leadingAnchor.constraint(equalTo: leadingAnchor),
            toastView.trailingAnchor.constraint(equalTo: trailingAnchor),
            toastView.topAnchor.constraint(equalTo: topAnchor),
            toastView.bottomAnchor.constraint(equalTo: bottomAnchor),

            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            closeButton.widthAnchor.constraint(equalToConstant: OperationToastCloseButton.hitSize),
            closeButton.heightAnchor.constraint(equalToConstant: OperationToastCloseButton.hitSize),
            closeButton.topAnchor.constraint(equalTo: toastView.topAnchor, constant: OperationToastCloseButton.edgeInset),
            closeButton.trailingAnchor.constraint(
                equalTo: toastView.trailingAnchor,
                constant: -OperationToastCloseButton.edgeInset
            ),

            contentStackView.leadingAnchor.constraint(equalTo: toastView.leadingAnchor, constant: 16),
            contentStackView.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -10),
            contentStackView.topAnchor.constraint(equalTo: toastView.topAnchor, constant: 16),

            chooseButton.trailingAnchor.constraint(equalTo: toastView.trailingAnchor, constant: -16),
            chooseButton.bottomAnchor.constraint(equalTo: toastView.bottomAnchor, constant: -14)
        ])
    }

    @objc private func chooseLayout(_ button: NSButton) {
        let menu = NSMenu()

        for option in options {
            let menuItem = NSMenuItem(
                title: option.snapshotName,
                action: #selector(restoreLayout(_:)),
                keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.representedObject = option.snapshotID
            menu.addItem(menuItem)
        }

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: button.bounds.minX, y: button.bounds.maxY + 4),
            in: button
        )
    }

    @objc private func restoreLayout(_ menuItem: NSMenuItem) {
        guard let snapshotID = menuItem.representedObject as? UUID else {
            return
        }

        onRestore(snapshotID)
    }

    @objc private func dismiss() {
        onDismiss()
    }
}

private final class StatusNoticeContentView: NSView {
    private let message: String

    init(message: String) {
        self.message = message
        super.init(frame: .zero)
        buildView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func buildView() {
        let icon = NSImageView(image: NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 20, weight: .semibold)
        icon.contentTintColor = .systemOrange
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byWordWrapping

        let stackView = NSStackView(views: [icon, label])
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let toastView = NSVisualEffectView()
        toastView.material = .hudWindow
        toastView.blendingMode = .behindWindow
        toastView.state = .active
        toastView.wantsLayer = true
        toastView.layer?.cornerRadius = 14
        toastView.layer?.masksToBounds = true
        toastView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(toastView)
        toastView.addSubview(stackView)

        NSLayoutConstraint.activate([
            toastView.leadingAnchor.constraint(equalTo: leadingAnchor),
            toastView.trailingAnchor.constraint(equalTo: trailingAnchor),
            toastView.topAnchor.constraint(equalTo: topAnchor),
            toastView.bottomAnchor.constraint(equalTo: bottomAnchor),

            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            stackView.leadingAnchor.constraint(equalTo: toastView.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: toastView.trailingAnchor, constant: -16),
            stackView.topAnchor.constraint(greaterThanOrEqualTo: toastView.topAnchor, constant: 14),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: toastView.bottomAnchor, constant: -14),
            stackView.centerYAnchor.constraint(equalTo: toastView.centerYAnchor)
        ])
    }
}

private final class OperationToastCloseButton: NSButton {
    static let hitSize: CGFloat = 32
    static let edgeInset: CGFloat = 4

    private var isHovered = false {
        didSet {
            updateHoverAppearance()
        }
    }
    private var hoverTrackingArea: NSTrackingArea?

    init(target: AnyObject?, action: Selector) {
        super.init(frame: .zero)

        image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        self.target = target
        self.action = action
        bezelStyle = .inline
        isBordered = false
        contentTintColor = .tertiaryLabelColor
        setButtonType(.momentaryChange)
        toolTip = "Dismiss"
        setAccessibilityLabel("Dismiss notification")
        wantsLayer = true
        layer?.cornerRadius = Self.hitSize / 2
        updateHoverAppearance()
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        super.mouseExited(with: event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHoverAppearance()
    }

    private func updateHoverAppearance() {
        contentTintColor = isHovered ? .secondaryLabelColor : .tertiaryLabelColor
        layer?.backgroundColor = isHovered ? NSColor.quaternaryLabelColor.cgColor : NSColor.clear.cgColor
    }
}

final class OperationOverlayContentView: NSView {
    private let label: NSTextField
    private let layoutLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSImageView()

    init(message: String, layoutName: String? = nil, compact: Bool = false) {
        label = NSTextField(wrappingLabelWithString: message)
        super.init(frame: .zero)
        layoutLabel.stringValue = layoutName ?? ""
        layoutLabel.isHidden = layoutName == nil
        buildView(compact: compact)
    }

    func updateMessage(_ message: String, layoutName: String) {
        label.stringValue = message
        layoutLabel.stringValue = layoutName
        layoutLabel.isHidden = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func buildView(compact: Bool) {
        let backgroundEffectView = NSVisualEffectView()
        backgroundEffectView.material = .underWindowBackground
        backgroundEffectView.blendingMode = .behindWindow
        backgroundEffectView.state = .active
        backgroundEffectView.translatesAutoresizingMaskIntoConstraints = false

        let dimView = NSView()
        dimView.wantsLayer = true
        dimView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        dimView.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator.image = NSImage(systemSymbolName: "progress.indicator", accessibilityDescription: "In progress")
        progressIndicator.symbolConfiguration = .init(pointSize: 24, weight: .medium)
        progressIndicator.contentTintColor = compact ? .labelColor : .white
        progressIndicator.addSymbolEffect(.variableColor.iterative, options: .repeating)
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = compact ? .labelColor : .white
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = 412
        label.setContentCompressionResistancePriority(.required, for: .vertical)

        layoutLabel.font = .systemFont(ofSize: 12)
        layoutLabel.textColor = compact ? .secondaryLabelColor : NSColor.white.withAlphaComponent(0.75)
        layoutLabel.alignment = .center
        layoutLabel.lineBreakMode = .byTruncatingMiddle
        layoutLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [label, layoutLabel])
        textStack.orientation = .vertical
        textStack.alignment = .centerX
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let stackView = NSStackView(views: [progressIndicator, textStack])
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let hudView = NSVisualEffectView()
        hudView.material = .hudWindow
        hudView.blendingMode = .withinWindow
        hudView.state = .active
        hudView.wantsLayer = true
        hudView.layer?.cornerRadius = 16
        hudView.layer?.masksToBounds = true
        hudView.translatesAutoresizingMaskIntoConstraints = false

        if !compact {
            addSubview(backgroundEffectView)
            addSubview(dimView)
            NSLayoutConstraint.activate([
                backgroundEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
                backgroundEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
                backgroundEffectView.topAnchor.constraint(equalTo: topAnchor),
                backgroundEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
                dimView.leadingAnchor.constraint(equalTo: leadingAnchor),
                dimView.trailingAnchor.constraint(equalTo: trailingAnchor),
                dimView.topAnchor.constraint(equalTo: topAnchor),
                dimView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
        addSubview(hudView)
        hudView.addSubview(stackView)

        NSLayoutConstraint.activate([
            hudView.centerXAnchor.constraint(equalTo: centerXAnchor),
            hudView.centerYAnchor.constraint(equalTo: centerYAnchor),
            hudView.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
            hudView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            hudView.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            hudView.heightAnchor.constraint(greaterThanOrEqualToConstant: 112),
            progressIndicator.widthAnchor.constraint(equalToConstant: 24),
            progressIndicator.heightAnchor.constraint(equalToConstant: 24),
            label.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            layoutLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            textStack.widthAnchor.constraint(equalTo: stackView.widthAnchor),

            stackView.leadingAnchor.constraint(equalTo: hudView.leadingAnchor, constant: 24),
            stackView.trailingAnchor.constraint(equalTo: hudView.trailingAnchor, constant: -24),
            stackView.topAnchor.constraint(equalTo: hudView.topAnchor, constant: 20),
            stackView.bottomAnchor.constraint(equalTo: hudView.bottomAnchor, constant: -20)
        ])
    }
}
