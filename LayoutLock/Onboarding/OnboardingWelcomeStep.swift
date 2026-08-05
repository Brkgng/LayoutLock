import AppKit
import SwiftUI

struct OnboardingWelcomeStep: View {
    let onGetStarted: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 82, height: 82)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(OnboardingStrings.welcomeTitle)
                    .font(.largeTitle.weight(.semibold))

                Text(OnboardingStrings.welcomeBody)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(OnboardingStrings.freePlanBody)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Get Started") {
                onGetStarted()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
