import AppKit

final class HotkeyCapturePrompt {
    static func prompt(
        snapshotName: String,
        unavailableHotkeys: [(binding: HotkeyBinding, snapshotName: String)]
    ) -> HotkeyBinding? {
        let window = HotkeyCaptureWindow(
            snapshotName: snapshotName,
            unavailableHotkeys: unavailableHotkeys
        )
        let controller = HotkeyCaptureWindowController(window: window)
        window.captureView.onCancel = { [weak controller] in
            controller?.cancel()
        }
        window.captureView.onCapture = { [weak controller] binding in
            controller?.capture(binding)
        }

        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: window)
        controller.closePromptWindow()

        guard response == .OK else {
            return nil
        }

        return controller.capturedBinding
    }
}

private final class HotkeyCaptureWindowController: NSWindowController, NSWindowDelegate {
    var capturedBinding: HotkeyBinding?
    private var hasStoppedModal = false

    override init(window: NSWindow?) {
        super.init(window: window)
        window?.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func capture(_ binding: HotkeyBinding) {
        capturedBinding = binding
        stopModal(withCode: .OK)
    }

    func cancel() {
        stopModal(withCode: .cancel)
    }

    func closePromptWindow() {
        if let captureWindow = window as? HotkeyCaptureWindow {
            captureWindow.captureView.onCancel = nil
            captureWindow.captureView.onCapture = nil
        }

        window?.delegate = nil
        window?.close()
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        cancel()
        return false
    }

    private func stopModal(withCode code: NSApplication.ModalResponse) {
        guard !hasStoppedModal else { return }

        hasStoppedModal = true
        NSApp.stopModal(withCode: code)
    }
}

private final class HotkeyCaptureWindow: NSWindow {
    let captureView: HotkeyCaptureView

    init(
        snapshotName: String,
        unavailableHotkeys: [(binding: HotkeyBinding, snapshotName: String)]
    ) {
        captureView = HotkeyCaptureView(
            snapshotName: snapshotName,
            unavailableHotkeys: unavailableHotkeys
        )
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        title = "Set Layout Hotkey"
        isReleasedWhenClosed = false
        contentView = captureView
    }

    override var canBecomeKey: Bool {
        true
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        makeFirstResponder(captureView)
    }
}

private final class HotkeyCaptureView: NSView {
    var onCapture: ((HotkeyBinding) -> Void)?
    var onCancel: (() -> Void)?

    private let unavailableHotkeys: [(binding: HotkeyBinding, snapshotName: String)]
    private let messageLabel = NSTextField(labelWithString: "Press a shortcut using Command, Option, or Control.")

    init(
        snapshotName: String,
        unavailableHotkeys: [(binding: HotkeyBinding, snapshotName: String)]
    ) {
        self.unavailableHotkeys = unavailableHotkeys
        super.init(frame: .zero)
        buildView(snapshotName: snapshotName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }

        do {
            let binding = try HotkeyBindingValidator.binding(from: event)
            if let duplicate = unavailableHotkeys.first(where: { $0.binding.matches(binding) }) {
                messageLabel.stringValue = "\"\(duplicate.snapshotName)\" already uses that hotkey."
                return
            }

            onCapture?(binding)
        } catch {
            messageLabel.stringValue = error.localizedDescription
        }
    }

    private func buildView(snapshotName: String) {
        let titleLabel = NSTextField(labelWithString: snapshotName)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.lineBreakMode = .byTruncatingTail

        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [cancelButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .trailing
        buttonRow.distribution = .gravityAreas

        let stackView = NSStackView(views: [titleLabel, messageLabel, buttonRow])
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 14
        stackView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -20),
            buttonRow.widthAnchor.constraint(equalTo: stackView.widthAnchor)
        ])
    }

    @objc private func cancel() {
        onCancel?()
    }
}
