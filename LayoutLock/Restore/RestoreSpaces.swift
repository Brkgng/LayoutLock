import AppKit
import CoreGraphics
import Darwin
import ObjectiveC

/// Ephemeral destinations: the desktop visible on each physical display when Restore starts.
struct RestoreSpaceInventory: Equatable {
    let activeByDisplay: [UInt32: UInt64]
    let ordinarySpaceIDs: Set<UInt64>
}

struct RestoreSpaceAccess {
    var inventory: ([UInt32]) -> RestoreSpaceInventory?
    var membership: (CGWindowID) -> Set<UInt64>?
    var submitMove: (CGWindowID, UInt64) async -> Bool
    var applicationWindowIDs: (pid_t) -> [CGWindowID]? = { _ in nil }
    var windowMetadata: (pid_t, CGWindowID) -> CGWindowMetadata? = { _, _ in nil }

    static let unavailable = Self(inventory: { _ in nil }, membership: { _ in nil }, submitMove: { _, _ in false })

    // Resolving private capabilities is deferred until an actual restore, never app/test startup.
    static let live = Self(
        inventory: { NativeRestoreSpaces.shared?.inventory(displayIDs: $0) },
        membership: { NativeRestoreSpaces.shared?.membership(windowID: $0) },
        submitMove: { windowID, spaceID in
            await MainActor.run { NativeRestoreSpaces.shared?.submit(windowID: windowID, spaceID: spaceID) ?? false }
        },
        applicationWindowIDs: { CGWindowMetadataReader().readWindowIDs(processIdentifier: $0) },
        windowMetadata: { pid, windowID in
            CGWindowMetadataReader().readWindowMetadata(processIdentifiers: [pid])[pid]?
                .first { $0.windowID == windowID }
        }
    )
}

struct RestoreWindowInspection {
    let pid: pid_t
    let windowID: CGWindowID
    let sourceSpaceID: UInt64
    let originalFrame: CGRect
    let destinationSpaceID: UInt64

    static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= 2 && abs(lhs.origin.y - rhs.origin.y) <= 2 &&
            abs(lhs.width - rhs.width) <= 2 && abs(lhs.height - rhs.height) <= 2
    }

    func matchesOriginalFrame(_ frame: CGRect) -> Bool {
        Self.framesMatch(originalFrame, frame)
    }
}

enum RestoreSpaceOutcome: String {
    case alreadyVisible, moved, unavailable, ineligible, identityUnconfirmed, unconfirmed

    // Ineligible gathering never submitted a move; retain the existing AX geometry behavior.
    var permitsGeometry: Bool { self != .unconfirmed }
}

struct RestoreSpaceCoordinator {
    let access: RestoreSpaceAccess
    var sleeper: () async -> Void = { try? await Task.sleep(nanoseconds: 50_000_000) }

    func prepare(
        windowID: CGWindowID?,
        displayID: UInt32?,
        inventory: RestoreSpaceInventory?,
        ordinaryWindow: Bool,
        expectedSourceSpace: UInt64? = nil
    ) async -> RestoreSpaceOutcome {
        guard ordinaryWindow else { return .ineligible }
        guard let windowID else { return .identityUnconfirmed }
        guard let inventory else { return .unavailable }
        guard let displayID,
            let destination = inventory.activeByDisplay[displayID],
            inventory.ordinarySpaceIDs.contains(destination),
            let membership = access.membership(windowID), membership.count == 1,
            let source = membership.first, inventory.ordinarySpaceIDs.contains(source)
        else {
            return .ineligible
        }
        if let expectedSourceSpace, source != expectedSourceSpace { return .ineligible }
        if source == destination {
            // An unrelated display's change must not block a window already on its intended visible Space.
            return destinationIsUnchanged(displayID: displayID, inventory: inventory) ? .alreadyVisible : .unconfirmed
        }
        guard destinationsAreUnchanged(inventory) else { return .unconfirmed }
        guard !Task.isCancelled, await access.submitMove(windowID, destination) else { return .unconfirmed }
        // A submission is asynchronous. Do not retry using another mover on failure/timeout.
        for attempt in 0..<40 {
            guard !Task.isCancelled, destinationsAreUnchanged(inventory) else { return .unconfirmed }
            if access.membership(windowID) == [destination] { return .moved }
            if attempt < 39 { await sleeper() }
        }
        return .unconfirmed
    }

    func inspection(
        for candidate: CGWindowMetadata,
        pid: pid_t,
        displayID: UInt32?,
        inventory: RestoreSpaceInventory
    ) -> RestoreWindowInspection? {
        guard candidate.processIdentifier == pid,
            candidate.layer == 0, candidate.bounds.width > 0, candidate.bounds.height > 0,
            candidate.bounds.origin.x.isFinite, candidate.bounds.origin.y.isFinite,
            candidate.bounds.width.isFinite, candidate.bounds.height.isFinite,
            let window = freshWindow(windowID: candidate.windowID, pid: pid),
            RestoreWindowInspection.framesMatch(candidate.bounds, window.bounds),
            let displayID, let destination = inventory.activeByDisplay[displayID],
            let membership = access.membership(window.windowID), membership.count == 1,
            let source = membership.first, source != destination,
            inspectionSpacesAreCurrent(source: source, destination: destination, inventory: inventory)
        else { return nil }
        return RestoreWindowInspection(pid: pid, windowID: window.windowID,
            sourceSpaceID: source, originalFrame: window.bounds, destinationSpaceID: destination)
    }

    func settledWindow(
        windowID: CGWindowID,
        pid: pid_t,
        inSpace spaceID: UInt64,
        inventory: RestoreSpaceInventory
    ) async -> CGWindowMetadata? {
        var stableFrame: CGRect?
        var stableObservations = 0
        for attempt in 0..<40 {
            guard !Task.isCancelled,
                inspectionSpacesAreCurrent(source: spaceID, destination: spaceID, inventory: inventory),
                access.membership(windowID) == [spaceID],
                let window = freshWindow(windowID: windowID, pid: pid)
            else { return nil }
            if let stableFrame, RestoreWindowInspection.framesMatch(stableFrame, window.bounds) {
                stableObservations += 1
            } else {
                stableFrame = window.bounds
                stableObservations = 1
            }
            // Allow the native move to finish adjusting bounds before treating drift as user input.
            if attempt >= 10, stableObservations >= 7 { return window }
            if attempt < 39 { await sleeper() }
        }
        return nil
    }

    func returnWindow(
        _ inspection: RestoreWindowInspection,
        expectedFrame: CGRect,
        inventory: RestoreSpaceInventory
    ) async -> Bool {
        guard !Task.isCancelled,
            inspectionSpacesAreCurrent(source: inspection.sourceSpaceID,
                destination: inspection.destinationSpaceID, inventory: inventory),
            let window = freshWindow(windowID: inspection.windowID, pid: inspection.pid),
            let membership = access.membership(inspection.windowID)
        else { return false }
        if membership == [inspection.sourceSpaceID] {
            return inspection.matchesOriginalFrame(window.bounds)
        }
        guard membership == [inspection.destinationSpaceID],
            RestoreWindowInspection.framesMatch(window.bounds, expectedFrame),
            await access.submitMove(inspection.windowID, inspection.sourceSpaceID)
        else { return false }
        for attempt in 0..<40 {
            guard !Task.isCancelled,
                inspectionSpacesAreCurrent(source: inspection.sourceSpaceID,
                    destination: inspection.destinationSpaceID, inventory: inventory),
                freshWindow(windowID: inspection.windowID, pid: inspection.pid) != nil,
                let spaces = access.membership(inspection.windowID)
            else { return false }
            if spaces == [inspection.sourceSpaceID] { return true }
            guard spaces == [inspection.destinationSpaceID] else { return false }
            if attempt < 39 { await sleeper() }
        }
        return false
    }

    private func freshWindow(windowID: CGWindowID, pid: pid_t) -> CGWindowMetadata? {
        guard pid > 0, windowID != 0,
            let window = access.windowMetadata(pid, windowID),
            window.processIdentifier == pid, window.windowID == windowID, window.layer == 0,
            window.bounds.width > 0, window.bounds.height > 0,
            window.bounds.origin.x.isFinite, window.bounds.origin.y.isFinite,
            window.bounds.width.isFinite, window.bounds.height.isFinite
        else { return nil }
        return window
    }

    private func inspectionSpacesAreCurrent(
        source: UInt64,
        destination: UInt64,
        inventory: RestoreSpaceInventory
    ) -> Bool {
        guard inventory.ordinarySpaceIDs.contains(source), inventory.ordinarySpaceIDs.contains(destination),
            let current = access.inventory(Array(inventory.activeByDisplay.keys)),
            current.activeByDisplay == inventory.activeByDisplay
        else { return false }
        return current.ordinarySpaceIDs.contains(source) && current.ordinarySpaceIDs.contains(destination)
    }

    func destinationsAreUnchanged(_ inventory: RestoreSpaceInventory) -> Bool {
        access.inventory(Array(inventory.activeByDisplay.keys))?.activeByDisplay == inventory.activeByDisplay
    }

    private func destinationIsUnchanged(displayID: UInt32, inventory: RestoreSpaceInventory) -> Bool {
        guard let destination = inventory.activeByDisplay[displayID],
            let current = access.inventory([displayID]), current.ordinarySpaceIDs.contains(destination) else { return false }
        return current.activeByDisplay[displayID] == destination
    }

    func canStack(window: DiscoveredWindow, displayID: UInt32?, inventory: RestoreSpaceInventory?) -> Bool {
        guard let windowID = window.cgWindowID else { return false }
        guard let inventory else { return window.isOnScreen == true }
        guard destinationsAreUnchanged(inventory), let displayID,
            let destination = inventory.activeByDisplay[displayID]
        else { return false }
        return access.membership(windowID) == [destination]
    }

    func canActivate(windowID: CGWindowID?, processIdentifier: pid_t, inventory: RestoreSpaceInventory?) -> Bool {
        guard let inventory, let windowID, destinationsAreUnchanged(inventory),
            let windowIDs = access.applicationWindowIDs(processIdentifier), windowIDs.contains(windowID)
        else { return false }
        let visibleSpaces = Set(inventory.activeByDisplay.values)
        var targetConfirmed = false
        for id in windowIDs {
            guard let spaces = access.membership(id) else { return false }
            // WindowServer also lists menu/pseudo windows with no Space membership.
            if spaces.isEmpty { continue }
            guard spaces.count == 1, let space = spaces.first,
                inventory.ordinarySpaceIDs.contains(space), visibleSpaces.contains(space)
            else { return false }
            if id == windowID { targetConfirmed = true }
        }
        return targetConfirmed && destinationsAreUnchanged(inventory)
    }

}

/// Recovery uses current owner and Space membership; saved CG IDs are never replayed.
struct RestoreCGWindowRecovery {
    let ordinarySpaceIDs: Set<UInt64>
    let membership: (CGWindowID) -> Set<UInt64>?

    static func requiresLocalTargetInspection(for saved: WindowRecord) -> Bool {
        let configuration = saved.openingConfiguration
        return !saved.isMinimized && !configuration.isManual && !configuration.effectiveTargets.isEmpty &&
            configuration.effectiveTargets.allSatisfy { $0.kind != .webURL && $0.url.isFileURL } &&
            !BrowserAutomationBrowser.allCases.contains { $0.bundleIdentifier == saved.bundleIdentifier }
    }

    func candidate(for saved: WindowRecord, savedWindows: [WindowRecord], applications: [UnexposedApplicationWindows],
        excludingWindowIDs: Set<CGWindowID> = [])
        -> (pid: pid_t, window: CGWindowMetadata)?
    {
        let targets = saved.openingConfiguration.effectiveTargets
        let automaticNonbrowserWebHint =
            !saved.openingConfiguration.isManual && targets.allSatisfy { $0.kind == .webURL }
            && !BrowserAutomationBrowser.allCases.contains { $0.bundleIdentifier == saved.bundleIdentifier }
        // Automatic local resources must be verified after moving the inspection candidate.
        // Manual targets and browser opens can intentionally create a different window.
        guard targets.isEmpty || automaticNonbrowserWebHint || Self.requiresLocalTargetInspection(for: saved),
            !saved.isFullscreen, saved.role == "AXWindow",
            saved.subrole == "AXStandardWindow" || saved.captureSignature.source == .coreGraphics
        else { return nil }
        let savedForBundle = savedWindows.filter { $0.bundleIdentifier == saved.bundleIdentifier }
        let owners = applications.filter { $0.bundleIdentifier == saved.bundleIdentifier }
        let folders = Set(targets.filter { $0.kind == .folder }.map { $0.url.standardizedFileURL })
        let eligible = owners.flatMap { owner in owner.windows.compactMap { window -> (pid: pid_t, window: CGWindowMetadata)? in
            let ownerFolders = Set(owner.documentURLs.filter { $0.isFileURL && $0.hasDirectoryPath }.map(\.standardizedFileURL))
            guard folders.isEmpty || ownerFolders.isEmpty || !folders.isDisjoint(with: ownerFolders) else { return nil }
            guard window.processIdentifier == owner.pid, window.windowID != 0, window.layer == 0,
                !excludingWindowIDs.contains(window.windowID),
                window.bounds.origin.x.isFinite, window.bounds.origin.y.isFinite,
                window.bounds.width.isFinite, window.bounds.height.isFinite,
                window.bounds.width > 0, window.bounds.height > 0,
                let spaces = membership(window.windowID), spaces.count == 1,
                let space = spaces.first, ordinarySpaceIDs.contains(space)
            else { return nil }
            return (owner.pid, window)
        } }
        if let title = saved.windowTitle?.nonEmptyValue,
            savedForBundle.count(where: { $0.windowTitle?.nonEmptyValue == title }) == 1 {
            let matching = eligible.filter { $0.window.title?.nonEmptyValue == title }
            if matching.count == 1 { return matching.first }
        }
        // A process resource (for example a project folder) is useful only when it
        // identifies one saved window and one current owner/window unambiguously.
        if !folders.isEmpty {
            let matchingSaved = savedForBundle.filter { window in
                window.openingConfiguration.effectiveTargets.contains {
                    $0.kind == .folder && folders.contains($0.url.standardizedFileURL)
                }
            }
            let matchingOwners = Set(owners.filter { owner in
                owner.documentURLs.contains { $0.isFileURL && folders.contains($0.standardizedFileURL) }
            }.map(\.pid))
            let matching = eligible.filter { matchingOwners.contains($0.pid) }
            if matchingSaved.count == 1, matching.count == 1 { return matching.first }
        }
        return savedForBundle.count == 1 && eligible.count == 1 ? eligible.first : nil
    }
}

/// The private ABI is optional. Capability discovery is not evidence that a move succeeded.
private final class NativeRestoreSpaces {
    private typealias Connection = @convention(c) () -> Int32
    private typealias CopyDisplays = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopyMembership = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias Initialize =
        @convention(c) (UnsafeMutableRawPointer, Selector, NSArray, UInt64) -> Unmanaged<AnyObject>?
    private typealias Perform = @convention(c) (AnyObject, Selector) -> Void

    static let shared: NativeRestoreSpaces? = {
        // This bridge has only been reported on macOS 26. Older systems retain geometry restore.
        guard #available(macOS 26, *) else { return nil }
        return NativeRestoreSpaces()
    }()

    private let handle: UnsafeMutableRawPointer
    private let connection: Connection
    private let copyDisplays: CopyDisplays
    private let copyMembership: CopyMembership
    private let operationClass: AnyClass
    private let initializer: Method
    private let performer: Method
    private let initSelector = NSSelectorFromString("initWithWindows:spaceID:")
    private let performSelector = NSSelectorFromString("performWithWMBridgeDelegate")

    private init?() {
        guard
            let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL)
        else { return nil }
        guard let connectionSymbol = dlsym(library, "SLSMainConnectionID"),
            let displaysSymbol = dlsym(library, "SLSCopyManagedDisplaySpaces"),
            let membershipSymbol = dlsym(library, "SLSCopySpacesForWindows"),
            let operationClass = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation"),
            let initializer = class_getInstanceMethod(operationClass, initSelector),
            let performer = class_getInstanceMethod(operationClass, performSelector),
            method_getNumberOfArguments(initializer) == 4,
            method_getNumberOfArguments(performer) == 2
        else {
            dlclose(library)
            return nil
        }
        handle = library
        connection = unsafeBitCast(connectionSymbol, to: Connection.self)
        copyDisplays = unsafeBitCast(displaysSymbol, to: CopyDisplays.self)
        copyMembership = unsafeBitCast(membershipSymbol, to: CopyMembership.self)
        self.operationClass = operationClass
        self.initializer = initializer
        self.performer = performer
    }

    deinit { dlclose(handle) }

    func inventory(displayIDs: [UInt32]) -> RestoreSpaceInventory? {
        let connectionID = connection()
        guard connectionID != 0,
            let rows = copyDisplays(connectionID)?.takeRetainedValue() as? [[String: Any]], !rows.isEmpty
        else { return nil }
        var activeByDisplay: [UInt32: UInt64] = [:]
        var ordinary: Set<UInt64> = []
        for row in rows {
            guard let name = row["Display Identifier"] as? String,
                let spaces = row["Spaces"] as? [[String: Any]],
                let current = row["Current Space"] as? [String: Any], let currentID = spaceID(current)
            else { return nil }
            for space in spaces {
                guard let id = spaceID(space), let type = space["type"] as? NSNumber else { return nil }
                if type.intValue == 0 { ordinary.insert(id) }
            }
            // With separate Spaces disabled WindowServer uses "Main" for the shared desktop.
            let matches = displayIDs.filter { displayID in
                if name == "Main" { return rows.count == 1 }
                guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return false }
                return (CFUUIDCreateString(nil, uuid) as String).caseInsensitiveCompare(name) == .orderedSame
            }
            for displayID in matches { activeByDisplay[displayID] = currentID }
        }
        guard activeByDisplay.count == Set(displayIDs).count else { return nil }
        return RestoreSpaceInventory(activeByDisplay: activeByDisplay, ordinarySpaceIDs: ordinary)
    }

    func membership(windowID: CGWindowID) -> Set<UInt64>? {
        let connectionID = connection()
        guard connectionID != 0,
            let values = copyMembership(connectionID, 0x7, [NSNumber(value: windowID)] as CFArray)?.takeRetainedValue()
                as? [NSNumber]
        else { return nil }
        let ids = values.compactMap { UInt64($0.stringValue) }.filter { $0 > 0 }
        guard ids.count == values.count else { return nil }
        return Set(ids)
    }

    @MainActor
    func submit(windowID: CGWindowID, spaceID: UInt64) -> Bool {
        guard let allocation = (operationClass as AnyObject).perform(NSSelectorFromString("alloc")) else {
            return false
        }
        let initialize = unsafeBitCast(method_getImplementation(initializer), to: Initialize.self)
        // alloc/init owns one reference; consume the initialized object's ownership exactly once.
        guard
            let operation = initialize(
                allocation.toOpaque(), initSelector, [NSNumber(value: windowID)] as NSArray, spaceID)?
                .takeRetainedValue()
        else { return false }
        let perform = unsafeBitCast(method_getImplementation(performer), to: Perform.self)
        perform(operation, performSelector)
        return true
    }

    private func spaceID(_ row: [String: Any]) -> UInt64? {
        let managed = (row["ManagedSpaceID"] as? NSNumber).flatMap { UInt64($0.stringValue) }
        let legacy = (row["id64"] as? NSNumber).flatMap { UInt64($0.stringValue) }
        if let managed, let legacy, managed != legacy { return nil }
        guard let id = managed ?? legacy, id > 0 else { return nil }
        return id
    }
}
