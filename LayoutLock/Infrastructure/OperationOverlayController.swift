import AppKit
import QuartzCore

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

@MainActor
protocol OperationOverlayPresenting: AnyObject {
    func showOverlay(kind: OperationOverlayKind) async
    func showRestoreCompletion(summary: String, detail: String?)
    func hideOverlay()
}

@MainActor
final class NoOpOperationOverlayPresenter: OperationOverlayPresenting {
    nonisolated init() {}

    func showOverlay(kind _: OperationOverlayKind) async {}
    func showRestoreCompletion(summary _: String, detail _: String?) {}
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

    func showRestoreCompletion(summary: String, detail: String?) {
        generation += 1
        closeOverlayWindows()
        closeDisplayRestoreSuggestionWindow()

        let windows = NSScreen.screens.map { screen in
            OperationCompletionToastWindow(screen: screen, summary: summary, detail: detail) { [weak self] in
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

private final class OperationCompletionToastWindow: NSPanel {
    init(
        screen: NSScreen,
        summary: String,
        detail: String?,
        onDismiss: @escaping () -> Void
    ) {
        let visibleFrame = screen.visibleFrame
        let width = min(460, max(280, visibleFrame.width - 48))
        let detailLineCount = detail?.split(separator: "\n", omittingEmptySubsequences: false).count ?? 0
        let height = min(
            visibleFrame.height - 48,
            detail == nil ? 76 : 82 + CGFloat(detailLineCount * 18)
        )
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
        contentView = OperationCompletionToastContentView(
            summary: summary,
            detail: detail,
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

private final class OperationOverlayWindow: NSPanel {
    init(screen: NSScreen, message: String) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        setFrame(screen.frame, display: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        contentView = OperationOverlayContentView(message: message)
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

private final class OperationCompletionToastContentView: NSView {
    private let summary: String
    private let detail: String?
    private let onDismiss: () -> Void

    init(summary: String, detail: String?, onDismiss: @escaping () -> Void) {
        self.summary = summary
        self.detail = detail
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        buildView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func buildView() {
        let icon = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 22, weight: .semibold)
        icon.contentTintColor = .systemGreen
        icon.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = OperationToastCloseButton(target: self, action: #selector(dismiss))

        let summaryLabel = NSTextField(labelWithString: summary)
        summaryLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        summaryLabel.textColor = .labelColor
        summaryLabel.maximumNumberOfLines = 2
        summaryLabel.lineBreakMode = .byTruncatingTail

        var labels = [summaryLabel]
        if let detail {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.maximumNumberOfLines = 6
            detailLabel.lineBreakMode = .byTruncatingTail
            labels.append(detailLabel)
        }

        let textStackView = NSStackView(views: labels)
        textStackView.orientation = .vertical
        textStackView.alignment = .leading
        textStackView.spacing = 4
        textStackView.translatesAutoresizingMaskIntoConstraints = false

        let stackView = NSStackView(views: [icon, textStackView])
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
        toastView.addSubview(closeButton)

        NSLayoutConstraint.activate([
            toastView.leadingAnchor.constraint(equalTo: leadingAnchor),
            toastView.trailingAnchor.constraint(equalTo: trailingAnchor),
            toastView.topAnchor.constraint(equalTo: topAnchor),
            toastView.bottomAnchor.constraint(equalTo: bottomAnchor),

            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            closeButton.widthAnchor.constraint(equalToConstant: OperationToastCloseButton.hitSize),
            closeButton.heightAnchor.constraint(equalToConstant: OperationToastCloseButton.hitSize),
            closeButton.centerYAnchor.constraint(equalTo: toastView.centerYAnchor),
            closeButton.trailingAnchor.constraint(
                equalTo: toastView.trailingAnchor,
                constant: -OperationToastCloseButton.edgeInset
            ),

            stackView.leadingAnchor.constraint(equalTo: toastView.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -10),
            stackView.topAnchor.constraint(greaterThanOrEqualTo: toastView.topAnchor, constant: 14),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: toastView.bottomAnchor, constant: -14),
            stackView.centerYAnchor.constraint(equalTo: toastView.centerYAnchor)
        ])
    }

    @objc private func dismiss() {
        onDismiss()
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

private final class OperationOverlayContentView: NSView {
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
        let backgroundEffectView = NSVisualEffectView()
        backgroundEffectView.material = .underWindowBackground
        backgroundEffectView.blendingMode = .behindWindow
        backgroundEffectView.state = .active
        backgroundEffectView.translatesAutoresizingMaskIntoConstraints = false

        let dimView = NSView()
        dimView.wantsLayer = true
        dimView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        dimView.translatesAutoresizingMaskIntoConstraints = false

        let progressIndicator = NSProgressIndicator()
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .regular
        progressIndicator.startAnimation(nil)
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.alignment = .center

        let stackView = NSStackView(views: [progressIndicator, label])
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

        addSubview(backgroundEffectView)
        addSubview(dimView)
        addSubview(hudView)
        hudView.addSubview(stackView)

        NSLayoutConstraint.activate([
            backgroundEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundEffectView.topAnchor.constraint(equalTo: topAnchor),
            backgroundEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            dimView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dimView.topAnchor.constraint(equalTo: topAnchor),
            dimView.bottomAnchor.constraint(equalTo: bottomAnchor),

            hudView.centerXAnchor.constraint(equalTo: centerXAnchor),
            hudView.centerYAnchor.constraint(equalTo: centerYAnchor),
            hudView.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
            hudView.heightAnchor.constraint(greaterThanOrEqualToConstant: 112),

            stackView.leadingAnchor.constraint(equalTo: hudView.leadingAnchor, constant: 24),
            stackView.trailingAnchor.constraint(equalTo: hudView.trailingAnchor, constant: -24),
            stackView.topAnchor.constraint(equalTo: hudView.topAnchor, constant: 20),
            stackView.bottomAnchor.constraint(equalTo: hudView.bottomAnchor, constant: -20)
        ])
    }
}
