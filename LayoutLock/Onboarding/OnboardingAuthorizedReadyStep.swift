import SwiftUI

struct OnboardingAuthorizedReadyStep: View {
    let onSetUpBrowsers: () -> Void
    let onOpenDashboard: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            Text("LayoutLock is ready.")
                .font(.largeTitle.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(OnboardingStrings.readyBody)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            OnboardingBrowserTabsCard(onSetUp: onSetUpBrowsers)

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
