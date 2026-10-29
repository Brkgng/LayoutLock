import AppKit
import SwiftUI

struct DashboardInactiveAppsView: View {
    let snapshot: Snapshot
    let appIdentityResolver: DashboardAppIdentityResolver
    let runningBundleIdentifiers: Set<String>
    @State private var unavailableBundleIdentifiers: Set<String> = []

    private var inactiveApps: [DashboardInactiveAppSummary] {
        DashboardSnapshotPresentation.inactiveAppSummaries(
            for: snapshot,
            runningBundleIdentifiers: runningBundleIdentifiers,
            unavailableBundleIdentifiers: unavailableBundleIdentifiers,
            identityResolver: { appIdentityResolver.identity(for: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Inactive Apps")
                .font(.headline)

            if snapshot.windows.isEmpty {
                Text("No windows were saved in this layout.")
                    .foregroundStyle(DashboardVisualStyle.supportingText)
            } else if inactiveApps.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("All saved apps are running.")
                        .foregroundStyle(DashboardVisualStyle.supportingText)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("LayoutLock will try to open installed apps before restoring. Apps that cannot be found are skipped; their saved windows stay in this layout.")
                        .font(.footnote)
                        .foregroundStyle(DashboardVisualStyle.supportingText)

                    ForEach(inactiveApps) { app in
                        DashboardInactiveAppRow(app: app)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCardSurface(cornerRadius: 14)
        .onAppear(perform: refreshAvailability)
        .onChange(of: snapshot.windows.map(\.bundleIdentifier)) { _, _ in
            refreshAvailability()
        }
        .onChange(of: snapshot.windows.map(\.applicationBundleURL)) { _, _ in
            refreshAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAvailability()
        }
        .onChange(of: runningBundleIdentifiers) { _, _ in
            refreshAvailability()
        }
    }

    private func refreshAvailability() {
        unavailableBundleIdentifiers = Self.unavailableApplications(in: snapshot,
            runningBundleIdentifiers: runningBundleIdentifiers,
            registeredApplicationURL: { NSWorkspace.shared.existingApplicationURL(withBundleIdentifier: $0) })
    }

    static func unavailableApplications(in snapshot: Snapshot, runningBundleIdentifiers: Set<String>,
        registeredApplicationURL: (String) -> URL?) -> Set<String> {
        Set(Dictionary(grouping: snapshot.windows, by: \.bundleIdentifier).filter { bundle, windows in
            !runningBundleIdentifiers.contains(bundle) &&
                !windows.contains(where: {
                    $0.applicationBundleURL?.validatedApplicationBundleURL(withBundleIdentifier: bundle) != nil
                }) && registeredApplicationURL(bundle) == nil
        }.keys)
    }
}

private struct DashboardInactiveAppRow: View {
    let app: DashboardInactiveAppSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: app.identity.icon)
                .resizable()
                .frame(width: 28, height: 28)
                .cornerRadius(6)

            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text("\(app.windowCount) \(app.windowCount == 1 ? "window" : "windows")")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(DashboardVisualStyle.supportingText)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(app.statusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(app.isAvailable ? DashboardVisualStyle.supportingText : .orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
                .help(app.isAvailable ? "LayoutLock will try to open this app." : "Saved windows will be skipped until this app becomes available.")
        }
        .padding(.vertical, 4)
    }
}
