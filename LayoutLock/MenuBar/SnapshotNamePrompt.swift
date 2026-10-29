import AppKit

struct SnapshotNamePrompt {
    @MainActor
    private static var updateConfirmation: UpdateConfirmation?

    static func prompt(defaultName: String) -> String? {
        prompt(
            title: "Save Current Layout",
            message: "Choose a name for this layout.",
            defaultName: defaultName,
            confirmButtonTitle: "Save",
            emptyNameFallback: defaultName
        )
    }

    static func promptRename(currentName: String) -> String? {
        prompt(
            title: "Rename Layout",
            message: "Choose a new name for this layout.",
            defaultName: currentName,
            confirmButtonTitle: "Rename",
            emptyNameFallback: nil
        )
    }

    @MainActor
    static func confirmUpdate(currentName: String, completion: @escaping (Bool) -> Void) {
        let confirmation = updateConfirmation ?? UpdateConfirmation()
        confirmation.update(currentName: currentName, completion: completion)
        updateConfirmation = confirmation

        // Let menu tracking end before bringing the confirmation forward.
        DispatchQueue.main.async {
            guard updateConfirmation === confirmation else { return }
            confirmation.show()
        }
    }

    @MainActor
    private final class UpdateConfirmation: NSObject, NSWindowDelegate {
        private let alert: NSAlert
        private let cancelButton: NSButton
        private var completion: ((Bool) -> Void)?

        override init() {
            let alert = NSAlert()
            self.alert = alert
            alert.alertStyle = .warning
            let updateButton = alert.addButton(withTitle: "Update")
            updateButton.hasDestructiveAction = true
            updateButton.keyEquivalent = ""
            cancelButton = alert.addButton(withTitle: "Cancel")
            cancelButton.keyEquivalent = "\u{1b}"
            super.init()
            updateButton.target = self
            updateButton.action = #selector(confirm)
            cancelButton.target = self
            cancelButton.action = #selector(cancel)
            alert.window.delegate = self
        }

        func update(currentName: String, completion: @escaping (Bool) -> Void) {
            alert.messageText = "Update \"\(currentName)\"?"
            alert.informativeText = "Replace the saved windows with your current setup. The name and hotkey will be kept."
            self.completion = completion
        }

        func show() {
            NSApp.activate(ignoringOtherApps: true)
            centerAlertOnPointerScreen(alert)
            alert.window.defaultButtonCell = cancelButton.cell as? NSButtonCell
            alert.window.makeKeyAndOrderFront(nil)
            alert.window.orderFrontRegardless()
        }

        @objc private func confirm() { finish(confirmed: true) }
        @objc private func cancel() { finish(confirmed: false) }

        func windowWillClose(_ notification: Notification) {
            finish(confirmed: false)
        }

        private func finish(confirmed: Bool) {
            guard let completion else { return }
            self.completion = nil
            alert.window.orderOut(nil)
            if updateConfirmation === self {
                updateConfirmation = nil
            }
            completion(confirmed)
        }
    }

    private static func prompt(
        title: String,
        message: String,
        defaultName: String,
        confirmButtonTitle: String,
        emptyNameFallback: String?
    ) -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmButtonTitle)
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(string: defaultName)
        textField.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        textField.lineBreakMode = .byTruncatingTail
        alert.accessoryView = textField

        NSApp.activate(ignoringOtherApps: true)
        centerAlertOnPointerScreen(alert)

        DispatchQueue.main.async {
            textField.selectText(nil)
        }

        let response = alert.runModal()

        guard response == .alertFirstButtonReturn else {
            return nil
        }

        let enteredName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return enteredName.isEmpty ? emptyNameFallback ?? enteredName : enteredName
    }

    private static func centerAlertOnPointerScreen(_ alert: NSAlert) {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else {
            return
        }

        alert.layout()
        let alertFrame = alert.window.frame
        let visibleFrame = screen.visibleFrame
        alert.window.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - (alertFrame.width / 2),
            y: visibleFrame.midY - (alertFrame.height / 2)
        ))
    }
}
