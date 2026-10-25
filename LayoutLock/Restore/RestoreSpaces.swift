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

    static let unavailable = Self(inventory: { _ in nil }, membership: { _ in nil }, submitMove: { _, _ in false })

    // Resolving private capabilities is deferred until an actual restore, never app/test startup.
    static let live = Self(
        inventory: { NativeRestoreSpaces.shared?.inventory(displayIDs: $0) },
        membership: { NativeRestoreSpaces.shared?.membership(windowID: $0) },
        submitMove: { windowID, spaceID in
            await MainActor.run { NativeRestoreSpaces.shared?.submit(windowID: windowID, spaceID: spaceID) ?? false }
        },
        applicationWindowIDs: { CGWindowMetadataReader().readWindowIDs(processIdentifier: $0) }
    )
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
        ordinaryWindow: Bool
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
        guard destinationsAreUnchanged(inventory) else { return .unconfirmed }
        if source == destination { return .alreadyVisible }
        guard !Task.isCancelled, await access.submitMove(windowID, destination) else { return .unconfirmed }
        // A submission is asynchronous. Do not retry using another mover on failure/timeout.
        for attempt in 0..<40 {
            guard !Task.isCancelled, destinationsAreUnchanged(inventory) else { return .unconfirmed }
            if access.membership(windowID) == [destination] { return .moved }
            if attempt < 39 { await sleeper() }
        }
        return .unconfirmed
    }

    func destinationsAreUnchanged(_ inventory: RestoreSpaceInventory) -> Bool {
        access.inventory(Array(inventory.activeByDisplay.keys))?.activeByDisplay == inventory.activeByDisplay
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

    func candidate(for saved: WindowRecord, savedWindows: [WindowRecord], applications: [UnexposedApplicationWindows])
        -> (pid: pid_t, window: CGWindowMetadata)?
    {
        let targets = saved.openingConfiguration.effectiveTargets
        let automaticNonbrowserWebHint =
            !saved.openingConfiguration.isManual && targets.allSatisfy { $0.kind == .webURL }
            && !BrowserAutomationBrowser.allCases.contains { $0.bundleIdentifier == saved.bundleIdentifier }
        // Explicit targets and browser opens can intentionally create a different window.
        guard targets.isEmpty || automaticNonbrowserWebHint,
            !saved.isFullscreen, saved.role == "AXWindow", saved.subrole == "AXStandardWindow",
            savedWindows.filter({ $0.bundleIdentifier == saved.bundleIdentifier }).count == 1
        else { return nil }
        let owners = applications.filter { $0.bundleIdentifier == saved.bundleIdentifier }
        guard owners.count == 1, let owner = owners.first else { return nil }
        let eligible = owner.windows.filter {
            guard $0.processIdentifier == owner.pid, $0.windowID != 0, $0.layer == 0,
                $0.bounds.origin.x.isFinite, $0.bounds.origin.y.isFinite,
                $0.bounds.size.width.isFinite, $0.bounds.size.height.isFinite,
                $0.bounds.size.width > 0, $0.bounds.size.height > 0,
                let spaces = membership($0.windowID), spaces.count == 1,
                let space = spaces.first, ordinarySpaceIDs.contains(space)
            else { return false }
            return true
        }
        let titleMatches = eligible.filter {
            guard let title = saved.windowTitle?.nonEmptyValue else { return false }
            return $0.title?.nonEmptyValue == title
        }
        let selected = titleMatches.count == 1 ? titleMatches.first : (eligible.count == 1 ? eligible.first : nil)
        let titledCount = eligible.count { $0.title?.nonEmptyValue != nil }
        let screenCaptureAllowed = CGPreflightScreenCaptureAccess()
        AppLogger.restore.info(
            "Space recovery candidates bundle=\(saved.bundleIdentifier, privacy: .public) pid=\(owner.pid) screenCaptureAllowed=\(screenCaptureAllowed) rawCount=\(owner.windows.count) eligibleCount=\(eligible.count) titledCount=\(titledCount) exactTitleCount=\(titleMatches.count) selectedWindowID=\(selected?.windowID ?? 0)."
        )
        guard let selected else { return nil }
        return (owner.pid, selected)
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
