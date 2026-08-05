import SwiftUI

enum OnboardingStrings {
    static let welcomeTitle = "LayoutLock"
    static let welcomeBody = "Save your window layout. Restore it anytime from the menu bar or with a keyboard shortcut."
    static let freePlanBody = "Start free with up to \(LayoutLockProConfiguration.freeLayoutLimit) saved layouts."
    static let permissionTitle = "Accessibility Access Required"
    static let permissionBody = "LayoutLock uses Accessibility access to inspect and move windows when you save or restore a layout. Saved layouts stay on this Mac."
    static let waitingBody = "When you return, access will be checked automatically."
    static let successTitle = "Accessibility Enabled"
    static let successBody = "You can now save and restore layouts."
    static let readyTitle = "You're ready to save your first layout."
    static let readyBody = "Arrange your windows the way you want, then save the current layout from the dashboard."
}

struct OnboardingPermissionEducationView: View {
    let showsSuccess: Bool
    let hasOpenedSystemSettings: Bool
    let onOpenSystemSettings: () -> Void
    let onCheckAgain: () -> Void
    let onDismiss: (() -> Void)?

    init(
        showsSuccess: Bool,
        hasOpenedSystemSettings: Bool,
        onOpenSystemSettings: @escaping () -> Void,
        onCheckAgain: @escaping () -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        self.showsSuccess = showsSuccess
        self.hasOpenedSystemSettings = hasOpenedSystemSettings
        self.onOpenSystemSettings = onOpenSystemSettings
        self.onCheckAgain = onCheckAgain
        self.onDismiss = onDismiss
    }

    var body: some View {
        if showsSuccess {
            successContent
        } else {
            permissionContent
        }
    }

    private var successContent: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(OnboardingStrings.successTitle)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(OnboardingStrings.successBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var permissionContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(OnboardingStrings.permissionTitle)
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(OnboardingStrings.permissionBody)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            permissionPath

            if hasOpenedSystemSettings {
                Text(OnboardingStrings.waitingBody)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(OnboardingStrings.waitingBody)
            }

            HStack(spacing: 10) {
                Button("Open System Settings") {
                    onOpenSystemSettings()
                }
                .buttonStyle(.borderedProminent)

                Button("Check Again") {
                    onCheckAgain()
                }

                Spacer()

                if let onDismiss {
                    Button("Dismiss") {
                        onDismiss()
                    }
                }
            }
        }
    }

    private var permissionPath: some View {
        ViewThatFits {
            HStack(spacing: 8) {
                PermissionPathStep(systemImage: "gearshape", title: "System Settings")
                PermissionPathSeparator()
                PermissionPathStep(systemImage: "hand.raised.fill", title: "Privacy & Security")
                PermissionPathSeparator()
                PermissionPathStep(systemImage: "accessibility", title: "Accessibility")
                PermissionPathSeparator()
                PermissionPathStep(systemImage: "checkmark.circle", title: "Enable LayoutLock")
            }

            VStack(alignment: .leading, spacing: 8) {
                PermissionPathStep(systemImage: "gearshape", title: "System Settings")
                PermissionPathStep(systemImage: "hand.raised.fill", title: "Privacy & Security")
                PermissionPathStep(systemImage: "accessibility", title: "Accessibility")
                PermissionPathStep(systemImage: "checkmark.circle", title: "Enable LayoutLock")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("System Settings, Privacy and Security, Accessibility, Enable LayoutLock")
    }
}

private struct PermissionPathStep: View {
    let systemImage: String
    let title: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PermissionPathSeparator: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}
