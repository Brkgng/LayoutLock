import AppKit
import SwiftUI

struct DashboardInactiveAppsView: View {
    let snapshot: Snapshot
    let appIdentityResolver: DashboardAppIdentityResolver
    let runningBundleIdentifiers: Set<String>

    private var inactiveApps: [DashboardInactiveAppSummary] {
        DashboardSnapshotPresentation.inactiveAppSummaries(
            for: snapshot,
            runningBundleIdentifiers: runningBundleIdentifiers,
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
                    Text("LayoutLock will try to open these apps before restoring. If an app does not open, its saved windows may be skipped.")
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

            Text("Not Running")
                .font(.caption.weight(.medium))
                .foregroundStyle(DashboardVisualStyle.supportingText)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
        .padding(.vertical, 4)
    }
}
