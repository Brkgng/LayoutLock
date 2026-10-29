import SwiftUI

struct OnboardingReadyStep: View {
    let onSetUpBrowsers: () -> Void
    let onInstallRaycast: () -> Void
    let onOpenDashboard: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "rectangle.3.group.bubble.left.fill")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)

            Text(OnboardingStrings.readyTitle)
                .font(.largeTitle.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(OnboardingStrings.readyBody)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            OnboardingBrowserTabsCard(onSetUp: onSetUpBrowsers)
            OnboardingRaycastCard(onInstall: onInstallRaycast)

            OnboardingCompletionButtons(
                primaryTitle: "Open Dashboard",
                onPrimary: onOpenDashboard,
                secondaryTitle: "Done",
                onSecondary: onDone
            )
        }
        .frame(maxWidth: 430)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct OnboardingRaycastCard: View {
    let onInstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "command")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Raycast (Optional)")
                    .fontWeight(.medium)
                Text("Save and restore layouts without leaving Raycast.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Install Extension", action: onInstall)
                .accessibilityLabel("Install LayoutLock Raycast Extension")
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct OnboardingBrowserTabsCard: View {
    let onSetUp: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "puzzlepiece")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Browser Tabs (Optional)")
                    .fontWeight(.medium)
                Text("Save Safari, Chrome, or Brave tabs with layouts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Set Up…", action: onSetUp)
                .accessibilityLabel("Set Up Browser Tab Capture")
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct OnboardingCompletionButtons: View {
    let primaryTitle: String
    let onPrimary: () -> Void
    let secondaryTitle: String
    let onSecondary: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(secondaryTitle) {
                onSecondary()
            }

            Button(primaryTitle) {
                onPrimary()
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
        .padding(.top, 4)
    }
}
