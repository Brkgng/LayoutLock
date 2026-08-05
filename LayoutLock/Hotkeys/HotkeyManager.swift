import Carbon
import Foundation

enum HotkeyManagerError: Error {
    case invalidBinding(String)
    case duplicateBinding(String)
    case eventHandlerInstallFailed(OSStatus)
    case registrationFailed(String, OSStatus)
    case registrationFailures([HotkeyManagerError])
}

extension HotkeyManagerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .invalidBinding(snapshotName):
            return "\"\(snapshotName)\" has an invalid hotkey."
        case let .duplicateBinding(snapshotName):
            return "\"\(snapshotName)\" already uses that hotkey."
        case let .eventHandlerInstallFailed(status):
            return "Global hotkey handling could not be installed. Carbon status: \(status)."
        case let .registrationFailed(snapshotName, status):
            return "\"\(snapshotName)\" hotkey could not be registered. Carbon status: \(status)."
        case let .registrationFailures(failures):
            guard let firstFailure = failures.first else {
                return "Some hotkeys could not be registered."
            }

            guard failures.count > 1 else {
                return firstFailure.localizedDescription
            }

            return "\(firstFailure.localizedDescription) \(failures.count - 1) more hotkey(s) could not be registered."
        }
    }
}

protocol HotkeyRegistering {
    func register(
        hotkey: HotkeyBinding,
        hotkeyID: EventHotKeyID
    ) throws -> EventHotKeyRef
    func unregister(_ hotkeyRef: EventHotKeyRef)
}

final class HotkeyManager {
    typealias EventHandlerInstaller = (HotkeyManager) throws -> EventHandlerRef?

    private let callback: (UUID) -> Void
    private let registrar: HotkeyRegistering
    private let eventHandlerInstaller: EventHandlerInstaller
    private let eventHandlerRemover: (EventHandlerRef) -> Void
    private var eventHandler: EventHandlerRef?
    private var didInstallEventHandler = false
    private var hotkeyRefsByID: [UInt32: EventHotKeyRef] = [:]
    private var snapshotIDsByHotkeyID: [UInt32: UUID] = [:]
    private var latestSummaries: [SnapshotSummary] = []
    private(set) var isSuspended = false

    var registeredSnapshotIDs: Set<UUID> {
        Set(snapshotIDsByHotkeyID.values)
    }

    init(
        callback: @escaping (UUID) -> Void,
        registrar: HotkeyRegistering = CarbonHotkeyRegistrar(),
        eventHandlerInstaller: @escaping EventHandlerInstaller = HotkeyManager.installCarbonEventHandler,
        eventHandlerRemover: @escaping (EventHandlerRef) -> Void = { RemoveEventHandler($0) }
    ) {
        self.callback = callback
        self.registrar = registrar
        self.eventHandlerInstaller = eventHandlerInstaller
        self.eventHandlerRemover = eventHandlerRemover
    }

    deinit {
        unregisterAll()
        if let eventHandler {
            eventHandlerRemover(eventHandler)
        }
    }

    func reloadBindings(from summaries: [SnapshotSummary]) throws {
        latestSummaries = summaries
        try installEventHandlerIfNeeded()

        guard !isSuspended else { return }

        try registerAll()
    }

    func suspendBindings() {
        isSuspended = true
        unregisterAll()
    }

    func resumeBindings() throws {
        isSuspended = false
        try registerAll()
    }

    private func registerAll() throws {
        unregisterAll()

        var seenBindings: [(binding: HotkeyBinding, snapshotName: String)] = []
        var failures: [HotkeyManagerError] = []
        var nextHotkeyID: UInt32 = 1

        for summary in latestSummaries {
            guard let hotkey = summary.hotkey else { continue }

            do {
                try HotkeyBindingValidator.validate(hotkey)
            } catch {
                failures.append(.invalidBinding(summary.name))
                continue
            }

            if seenBindings.contains(where: { $0.binding.matches(hotkey) }) {
                failures.append(.duplicateBinding(summary.name))
                continue
            }
            seenBindings.append((hotkey, summary.name))

            let hotkeyID = EventHotKeyID(
                signature: HotkeyManager.hotkeySignature,
                id: nextHotkeyID
            )

            do {
                let hotkeyRef = try registrar.register(
                    hotkey: hotkey,
                    hotkeyID: hotkeyID
                )
                hotkeyRefsByID[nextHotkeyID] = hotkeyRef
                snapshotIDsByHotkeyID[nextHotkeyID] = summary.id
                nextHotkeyID += 1
            } catch let error as CarbonHotkeyRegistrationError {
                failures.append(.registrationFailed(summary.name, error.status))
            } catch let error as HotkeyManagerError {
                failures.append(error)
            } catch {
                failures.append(.registrationFailed(summary.name, -1))
            }
        }

        if !failures.isEmpty {
            throw HotkeyManagerError.registrationFailures(failures)
        }
    }

    private func installEventHandlerIfNeeded() throws {
        guard !didInstallEventHandler else { return }

        eventHandler = try eventHandlerInstaller(self)
        didInstallEventHandler = true
    }

    private static func installCarbonEventHandler(for manager: HotkeyManager) throws -> EventHandlerRef? {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var eventHandler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }

                let manager = Unmanaged<HotkeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                return manager.handleHotkeyEvent(event)
            },
            1,
            &eventType,
            Unmanaged.passUnretained(manager).toOpaque(),
            &eventHandler
        )

        guard status == noErr else {
            throw HotkeyManagerError.eventHandlerInstallFailed(status)
        }

        return eventHandler
    }

    private func handleHotkeyEvent(_ event: EventRef) -> OSStatus {
        guard !isSuspended else { return noErr }

        var hotkeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotkeyID
        )

        guard status == noErr,
              hotkeyID.signature == HotkeyManager.hotkeySignature else {
            return noErr
        }

        handleRegisteredHotkey(id: hotkeyID.id)
        return noErr
    }

    func handleRegisteredHotkey(id: UInt32) {
        guard !isSuspended, let snapshotID = snapshotIDsByHotkeyID[id] else {
            return
        }

        callback(snapshotID)
    }

    private func unregisterAll() {
        for hotkeyRef in hotkeyRefsByID.values {
            registrar.unregister(hotkeyRef)
        }

        hotkeyRefsByID = [:]
        snapshotIDsByHotkeyID = [:]
    }

    private static let hotkeySignature = OSType(
        (UInt32(Character("L").asciiValue!) << 24) |
        (UInt32(Character("L").asciiValue!) << 16) |
        (UInt32(Character("H").asciiValue!) << 8) |
        UInt32(Character("K").asciiValue!)
    )
}

private struct CarbonHotkeyRegistrationError: Error {
    let status: OSStatus
}

private struct CarbonHotkeyRegistrar: HotkeyRegistering {
    func register(
        hotkey: HotkeyBinding,
        hotkeyID: EventHotKeyID
    ) throws -> EventHotKeyRef {
        var hotkeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        guard status == noErr, let hotkeyRef else {
            throw CarbonHotkeyRegistrationError(status: status)
        }

        return hotkeyRef
    }

    func unregister(_ hotkeyRef: EventHotKeyRef) {
        UnregisterEventHotKey(hotkeyRef)
    }
}
