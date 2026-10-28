import SwiftUI

struct DashboardSnapshotPreviewView: View {
    let snapshot: Snapshot
    let appIdentityResolver: DashboardAppIdentityResolver
    let removeWindow: (WindowRecord) -> Void
    let editOpeningTargets: (WindowRecord) -> Void
    let reorderWindows: (_ displayID: UInt32, _ orderedWindowIDs: [UUID]) -> Bool

    private var displayColumns: [GridItem] {
        let columnCount = displayModels.count > 1 ? 2 : 1

        return Array(
            repeating: GridItem(.flexible(minimum: 240, maximum: 560), spacing: 20, alignment: .top),
            count: columnCount
        )
    }

    private var displayModels: [DashboardDisplayPreviewModel] {
        DashboardSnapshotPresentation.displayPreviewModels(for: snapshot)
    }

    private var unassignedWindows: [WindowRecord] {
        DashboardSnapshotPresentation.unassignedWindows(in: snapshot)
    }

    private var displayPreviewEmptyMessage: String? {
        DashboardSnapshotPresentation.displayPreviewEmptyMessage(for: snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Layout Preview")
                .font(.headline)

            if let displayPreviewEmptyMessage {
                Text(displayPreviewEmptyMessage)
                    .foregroundStyle(DashboardVisualStyle.supportingText)
            } else {
                LazyVGrid(columns: displayColumns, alignment: .leading, spacing: 20) {
                    ForEach(displayModels) { model in
                        DashboardDisplayPreviewColumn(
                            model: model,
                            appIdentityResolver: appIdentityResolver,
                            removeWindow: removeWindow,
                            editOpeningTargets: editOpeningTargets,
                            reorderWindows: reorderWindows
                        )
                        .frame(maxWidth: 560, alignment: .topLeading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !unassignedWindows.isEmpty {
                Divider()

                DashboardUnassignedWindowsView(
                    windows: unassignedWindows,
                    appIdentityResolver: appIdentityResolver,
                    removeWindow: removeWindow,
                    editOpeningTargets: editOpeningTargets
                )
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCardSurface(cornerRadius: 14)
    }
}

private struct DashboardDisplayPreviewColumn: View {
    let model: DashboardDisplayPreviewModel
    let appIdentityResolver: DashboardAppIdentityResolver
    let removeWindow: (WindowRecord) -> Void
    let editOpeningTargets: (WindowRecord) -> Void
    let reorderWindows: (_ displayID: UInt32, _ orderedWindowIDs: [UUID]) -> Bool

    private let canvasHeight: CGFloat = 174

    private var displayName: String {
        model.display.localizedName ?? "Display \(model.display.id)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                if model.display.isPrimary {
                    Text("Primary")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(DashboardVisualStyle.supportingText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }

                Spacer(minLength: 8)

                Text("\(model.windows.count) \(model.windows.count == 1 ? "window" : "windows")")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(DashboardVisualStyle.supportingText)
                    .lineLimit(1)
            }
            .frame(height: 22)

            DashboardDisplayCanvas(
                display: model.display,
                windows: model.windows,
                appIdentityResolver: appIdentityResolver
            )
            .frame(maxWidth: .infinity)
            .frame(height: canvasHeight)

            if !model.windows.isEmpty {
                Divider()

                DashboardDisplayWindowList(
                    displayID: model.display.id,
                    windows: model.windows,
                    appIdentityResolver: appIdentityResolver,
                    removeWindow: removeWindow,
                    editOpeningTargets: editOpeningTargets,
                    reorderWindows: reorderWindows
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct DashboardDisplayCanvas: View {
    let display: DisplayRecord
    let windows: [WindowRecord]
    let appIdentityResolver: DashboardAppIdentityResolver

    private var groups: [DashboardWindowPreviewGroup] {
        DashboardSnapshotPresentation.windowPreviewGroups(
            for: windows,
            displayID: display.id,
            displayFrame: display.frameRect
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = DashboardDisplayPreviewLayout(
                displayFrame: display.frameRect,
                size: proxy.size
            )
            let displaySurfaceFrame = layout.scaledDisplayFrame

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.45))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )

                displaySurface(layout: layout, surfaceFrame: displaySurfaceFrame)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func displaySurface(
        layout: DashboardDisplayPreviewLayout,
        surfaceFrame: CGRect
    ) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

            ForEach(groups) { group in
                let frontmostWindow = group.frontmostWindow
                let previewFrame = DashboardSnapshotPresentation.previewFrame(
                    for: frontmostWindow,
                    in: display
                )

                DashboardWindowPreview(
                    window: frontmostWindow,
                    frame: layout.surfaceLocalFrame(for: previewFrame),
                    identity: appIdentityResolver.identity(for: frontmostWindow.bundleIdentifier),
                    showsDetailedLabel: true
                )
            }
        }
        .frame(width: surfaceFrame.width, height: surfaceFrame.height)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .position(x: surfaceFrame.midX, y: surfaceFrame.midY)
    }
}

private struct DashboardWindowPreview: View {
    let window: WindowRecord
    let frame: CGRect
    let identity: DashboardAppIdentity
    let showsDetailedLabel: Bool

    private var opacity: Double {
        if window.isMinimized || !window.isVisible {
            return 0.38
        }

        return 1
    }

    private var fillOpacity: Double {
        window.isFullscreen ? 0.48 : 0.36
    }

    private var strokeOpacity: Double {
        0.82
    }

    private var strokeWidth: CGFloat {
        return window.isFullscreen ? 2 : 1
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(identity.accentColor.opacity(fillOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(identity.accentColor.opacity(strokeOpacity), lineWidth: strokeWidth)
                )

            if showsDetailedLabel {
                DashboardWindowLabel(window: window, identity: identity, size: frame.size)
                    .padding(5)
            }
        }
        .opacity(opacity)
        .frame(width: max(frame.width, 10), height: max(frame.height, 10))
        .clipped()
        .position(x: frame.midX, y: frame.midY)
    }
}

private struct DashboardWindowLabel: View {
    let window: WindowRecord
    let identity: DashboardAppIdentity
    let size: CGSize

    private var showsIcon: Bool {
        size.width >= 22 && size.height >= 22
    }

    private var showsName: Bool {
        size.width >= 74 && size.height >= 34
    }

    private var showsTitle: Bool {
        size.width >= 130 && size.height >= 58
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showsIcon {
                HStack(spacing: 4) {
                    Image(nsImage: identity.icon)
                        .resizable()
                        .frame(width: 14, height: 14)
                        .cornerRadius(3)

                    if showsName {
                        Text(identity.name)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            if showsTitle,
               let description = DashboardSnapshotPresentation.primaryWindowDescription(
                   for: window,
                   applicationName: identity.name
               ) {
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(DashboardVisualStyle.supportingText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .foregroundStyle(.primary)
    }
}

private struct DashboardDisplayWindowList: View {
    let displayID: UInt32
    let windows: [WindowRecord]
    let appIdentityResolver: DashboardAppIdentityResolver
    let removeWindow: (WindowRecord) -> Void
    let editOpeningTargets: (WindowRecord) -> Void
    let reorderWindows: (_ displayID: UInt32, _ orderedWindowIDs: [UUID]) -> Bool

    @State private var orderedWindowIDs: [UUID] = []

    private var displayOrderedWindows: [WindowRecord] {
        let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let currentWindowIDs = Set(windows.map(\.id))

        guard orderedWindowIDs.count == windows.count,
              Set(orderedWindowIDs) == currentWindowIDs else {
            return DashboardSnapshotPresentation.windowsForDisplayList(windows)
        }

        return orderedWindowIDs.compactMap { windowsByID[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(displayOrderedWindows) { window in
                DashboardDisplayWindowRow(
                    window: window,
                    identity: appIdentityResolver.identity(for: window.bundleIdentifier),
                    removeWindow: {
                        removeWindow(window)
                    },
                    editOpeningTargets: {
                        editOpeningTargets(window)
                    },
                    moveUp: {
                        moveWindow(window.id, by: -1)
                    },
                    moveDown: {
                        moveWindow(window.id, by: 1)
                    }
                )
                .draggable(window.id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let item = items.first,
                          let draggedWindowID = UUID(uuidString: item) else {
                        return false
                    }

                    return moveWindow(draggedWindowID, droppingOn: window.id)
                }
            }
        }
        .padding(.top, 2)
        .onAppear {
            synchronizeOrder()
        }
        .onChange(of: windows.map(\.id)) { _, _ in
            synchronizeOrder()
        }
        .onChange(of: windows.map(\.zOrderHint)) { _, _ in
            synchronizeOrder()
        }
    }

    private func synchronizeOrder() {
        orderedWindowIDs = DashboardSnapshotPresentation.windowsForDisplayList(windows).map(\.id)
    }

    @discardableResult
    private func moveWindow(_ windowID: UUID, droppingOn targetWindowID: UUID) -> Bool {
        guard windowID != targetWindowID else {
            return false
        }

        var reorderedWindowIDs = displayOrderedWindows.map(\.id)
        guard let sourceIndex = reorderedWindowIDs.firstIndex(of: windowID),
              let targetIndex = reorderedWindowIDs.firstIndex(of: targetWindowID) else {
            return false
        }

        let movedWindowID = reorderedWindowIDs.remove(at: sourceIndex)
        let insertionIndex = min(targetIndex, reorderedWindowIDs.count)
        reorderedWindowIDs.insert(movedWindowID, at: insertionIndex)
        return commitOrder(reorderedWindowIDs)
    }

    private func moveWindow(_ windowID: UUID, by offset: Int) {
        var reorderedWindowIDs = displayOrderedWindows.map(\.id)
        guard let sourceIndex = reorderedWindowIDs.firstIndex(of: windowID) else {
            return
        }

        let targetIndex = sourceIndex + offset
        guard reorderedWindowIDs.indices.contains(targetIndex) else {
            return
        }

        reorderedWindowIDs.swapAt(sourceIndex, targetIndex)
        _ = commitOrder(reorderedWindowIDs)
    }

    private func commitOrder(_ reorderedWindowIDs: [UUID]) -> Bool {
        guard reorderWindows(displayID, reorderedWindowIDs) else {
            return false
        }

        withAnimation(.snappy(duration: 0.16)) {
            orderedWindowIDs = reorderedWindowIDs
        }
        return true
    }
}

private struct DashboardDisplayWindowRow: View {
    let window: WindowRecord
    let identity: DashboardAppIdentity
    let removeWindow: () -> Void
    let editOpeningTargets: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void

    @State private var isHovered = false
    @FocusState private var isOpeningTargetsButtonFocused: Bool
    @FocusState private var isRemoveButtonFocused: Bool

    var body: some View {
        HStack(alignment: rowAlignment, spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tertiary)
                .frame(width: 14)
                .help("Drag to change restore order")
                .accessibilityHidden(true)

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(identity.accentColor)
                .frame(width: 8, height: 18)

            Image(nsImage: identity.icon)
                .resizable()
                .frame(width: 18, height: 18)
                .cornerRadius(4)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(identity.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)

                    ForEach(stateLabels, id: \.self) { state in
                        Text(state)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(DashboardVisualStyle.supportingText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }

                ForEach(window.openingConfiguration.effectiveTargets) { target in
                    DashboardOpeningTargetLabel(
                        target: target,
                        editOpeningTargets: editOpeningTargets
                    )
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                if openingTargetCapabilities.showsEditor {
                    DashboardEditOpeningTargetsButton(
                        hasTargets: !window.openingConfiguration.effectiveTargets.isEmpty,
                        editOpeningTargets: editOpeningTargets
                    )
                    .focused($isOpeningTargetsButtonFocused)
                }

                DashboardRemoveWindowButton(
                    removeWindow: removeWindow
                )
                .focused($isRemoveButtonFocused)
            }
            .opacity(showsActions ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityAction(named: "Move Earlier in Restore Order") {
            moveUp()
        }
        .accessibilityAction(named: "Move Later in Restore Order") {
            moveDown()
        }
    }

    private var openingTargetCapabilities: DashboardOpeningTargetCapabilities {
        DashboardOpeningTargetCapabilities.resolve(for: window)
    }

    private var rowAlignment: VerticalAlignment {
        window.openingConfiguration.effectiveTargets.isEmpty ? .center : .top
    }

    private var showsActions: Bool {
        isHovered || isOpeningTargetsButtonFocused || isRemoveButtonFocused
    }

    private var stateLabels: [String] {
        var labels: [String] = []

        if window.isFullscreen {
            labels.append("Fullscreen")
        }

        if window.isMinimized {
            labels.append("Minimized")
        } else if !window.isVisible {
            labels.append("Hidden")
        }

        return labels
    }
}

private struct DashboardUnassignedWindowsView: View {
    let windows: [WindowRecord]
    let appIdentityResolver: DashboardAppIdentityResolver
    let removeWindow: (WindowRecord) -> Void
    let editOpeningTargets: (WindowRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Unassigned Windows")
                .font(.subheadline.weight(.semibold))

            ForEach(windows) { window in
                DashboardUnassignedWindowRow(
                    window: window,
                    identity: appIdentityResolver.identity(for: window.bundleIdentifier),
                    editOpeningTargets: {
                        editOpeningTargets(window)
                    },
                    removeWindow: {
                        removeWindow(window)
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DashboardUnassignedWindowRow: View {
    let window: WindowRecord
    let identity: DashboardAppIdentity
    let editOpeningTargets: () -> Void
    let removeWindow: () -> Void

    @State private var isHovered = false
    @FocusState private var isOpeningTargetsButtonFocused: Bool
    @FocusState private var isRemoveButtonFocused: Bool

    var body: some View {
        HStack(alignment: window.openingConfiguration.effectiveTargets.isEmpty ? .center : .top, spacing: 8) {
            Image(nsImage: identity.icon)
                .resizable()
                .frame(width: 18, height: 18)
                .cornerRadius(4)

            VStack(alignment: .leading, spacing: 3) {
                Text(identity.name)
                    .font(.caption)
                    .lineLimit(1)

                ForEach(window.openingConfiguration.effectiveTargets) { target in
                    DashboardOpeningTargetLabel(
                        target: target,
                        editOpeningTargets: editOpeningTargets
                    )
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                if openingTargetCapabilities.showsEditor {
                    DashboardEditOpeningTargetsButton(
                        hasTargets: !window.openingConfiguration.effectiveTargets.isEmpty,
                        editOpeningTargets: editOpeningTargets
                    )
                    .focused($isOpeningTargetsButtonFocused)
                }

                DashboardRemoveWindowButton(removeWindow: removeWindow)
                    .focused($isRemoveButtonFocused)
            }
            .opacity(showsActions ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var showsActions: Bool {
        isHovered || isOpeningTargetsButtonFocused || isRemoveButtonFocused
    }

    private var openingTargetCapabilities: DashboardOpeningTargetCapabilities {
        DashboardOpeningTargetCapabilities.resolve(for: window)
    }
}

private struct DashboardOpeningTargetLabel: View {
    let target: WindowOpenTarget
    let editOpeningTargets: () -> Void

    var body: some View {
        if target.isMissing() {
            Button(action: editOpeningTargets) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                    targetName
                }
                .foregroundStyle(.orange)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit saved resources to locate this missing \(target.kind == .folder ? "folder" : "file")")
            .accessibilityLabel("Missing \(target.compactDisplayName)")
            .accessibilityHint("Edit saved resources for this saved window")
        } else {
            targetName
                .foregroundStyle(DashboardVisualStyle.supportingText)
        }
    }

    private var targetName: some View {
        Text(target.compactDisplayName)
            .font(.caption2)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

private struct DashboardEditOpeningTargetsButton: View {
    let hasTargets: Bool
    let editOpeningTargets: () -> Void

    private var label: String {
        hasTargets ? "Edit Saved Resources" : "Add Saved Resources"
    }

    var body: some View {
        Button(action: editOpeningTargets) {
            Image(systemName: hasTargets ? "pencil.circle" : "plus.circle")
                .symbolRenderingMode(.hierarchical)
                .imageScale(.medium)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(label)
        .frame(width: 22, height: 22)
        .accessibilityLabel(label)
    }
}

private struct DashboardRemoveWindowButton: View {
    let removeWindow: () -> Void

    var body: some View {
        Button {
            removeWindow()
        } label: {
            Image(systemName: "minus.circle")
                .symbolRenderingMode(.hierarchical)
                .imageScale(.medium)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .accessibilityLabel("Remove Window from Layout")
        }
        .buttonStyle(.plain)
        .help("Remove Window from Layout")
        .frame(width: 22, height: 22)
        .accessibilityLabel("Remove Window from Layout")
    }
}

struct DashboardDisplayPreviewLayout {
    let displayFrame: CGRect
    let size: CGSize

    var scaledDisplayFrame: CGRect {
        let displayBounds = normalizedDisplayBounds
        let insetBounds = CGRect(origin: .zero, size: size).insetBy(dx: 10, dy: 10)
        let scale = min(
            insetBounds.width / max(displayBounds.width, 1),
            insetBounds.height / max(displayBounds.height, 1)
        )
        let contentWidth = displayBounds.width * scale
        let contentHeight = displayBounds.height * scale

        return CGRect(
            x: insetBounds.minX + ((insetBounds.width - contentWidth) / 2),
            y: insetBounds.minY + ((insetBounds.height - contentHeight) / 2),
            width: contentWidth,
            height: contentHeight
        )
    }

    func scaledFrame(for rect: CGRect) -> CGRect {
        let displayBounds = normalizedDisplayBounds
        let surfaceFrame = scaledDisplayFrame
        let scale = min(
            surfaceFrame.width / max(displayBounds.width, 1),
            surfaceFrame.height / max(displayBounds.height, 1)
        )
        let xOffset = surfaceFrame.minX - (displayBounds.minX * scale)
        let yOffset = surfaceFrame.minY - (displayBounds.minY * scale)

        return CGRect(
            x: (rect.minX * scale) + xOffset,
            y: (rect.minY * scale) + yOffset,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    func surfaceLocalFrame(for rect: CGRect) -> CGRect {
        let scaledFrame = scaledFrame(for: rect)
        let surfaceFrame = scaledDisplayFrame

        return scaledFrame.offsetBy(
            dx: -surfaceFrame.minX,
            dy: -surfaceFrame.minY
        )
    }

    private var normalizedDisplayBounds: CGRect {
        displayFrame.isNull || displayFrame.isEmpty
            ? CGRect(x: 0, y: 0, width: 1, height: 1)
            : displayFrame
    }
}
