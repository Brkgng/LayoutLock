import AppKit

struct SnapshotNamePrompt {
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
