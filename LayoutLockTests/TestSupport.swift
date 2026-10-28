import ApplicationServices
import Carbon
import CoreGraphics
import Foundation
import XCTest
@testable import LayoutLock

enum TestFixtures {
    static let createdAt = Date(timeIntervalSince1970: 100)
    static let updatedAt = Date(timeIntervalSince1970: 200)
    static let bundleIdentifier = "com.example.editor"
    static let windowTitle = "Window"
    static let windowRole = "AXWindow"
    static let windowSubrole = "AXStandardWindow"
    static let windowFrame = CGRect(x: 10, y: 20, width: 300, height: 200)
}

final class TestTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

func makeDisplayRecord(
    id: UInt32 = 1,
    localizedName: String? = "Display",
    frame: CGRect = CGRect(x: 0, y: 0, width: 1000, height: 800),
    visibleFrame: CGRect? = nil,
    isPrimary: Bool = true,
    vendorID: UInt32? = nil,
    productID: UInt32? = nil,
    serialNumber: UInt32? = nil
) -> DisplayRecord {
    DisplayRecord(
        id: id,
        localizedName: localizedName,
        frame: CGRectCodable(frame),
        visibleFrame: CGRectCodable(visibleFrame ?? frame),
        backingScaleFactor: 2,
        isPrimary: isPrimary,
        vendorID: vendorID,
        productID: productID,
        serialNumber: serialNumber
    )
}

func makeWindowRecord(
    id: UUID = UUID(),
    bundleIdentifier: String = TestFixtures.bundleIdentifier,
    pidAtCapture: Int32 = 42,
    windowTitle: String? = TestFixtures.windowTitle,
    role: String = TestFixtures.windowRole,
    subrole: String? = TestFixtures.windowSubrole,
    frame: CGRect = TestFixtures.windowFrame,
    displayID: UInt32? = 1,
    normalizedFrame: NormalizedRect = NormalizedRect(
        xRatio: 0.1,
        yRatio: 0.1,
        widthRatio: 0.3,
        heightRatio: 0.25
    ),
    zOrderHint: Int? = nil,
    isMinimized: Bool = false,
    isFullscreen: Bool = false,
    isVisible: Bool = true,
    cgWindowID: UInt32? = nil,
    openingConfiguration: WindowOpeningConfiguration = WindowOpeningConfiguration()
) -> WindowRecord {
    WindowRecord(
        id: id,
        bundleIdentifier: bundleIdentifier,
        pidAtCapture: pidAtCapture,
        windowTitle: windowTitle,
        role: role,
        subrole: subrole,
        frame: CGRectCodable(frame),
        displayID: displayID,
        normalizedFrame: normalizedFrame,
        zOrderHint: zOrderHint,
        isMinimized: isMinimized,
        isFullscreen: isFullscreen,
        isVisible: isVisible,
        captureSignature: WindowSignature(
            bundleIdentifier: bundleIdentifier,
            owningPid: pidAtCapture,
            windowTitle: windowTitle,
            role: role,
            subrole: subrole,
            capturedFrame: CGRectCodable(frame),
            cgWindowID: cgWindowID
        ),
        openingConfiguration: openingConfiguration
    )
}

func makeSnapshot(
    id: UUID = UUID(),
    name: String = "Coding",
    createdAt: Date = TestFixtures.createdAt,
    updatedAt: Date = TestFixtures.updatedAt,
    displays: [DisplayRecord] = [makeDisplayRecord()],
    primaryDisplayID: UInt32? = 1,
    windows: [WindowRecord] = [makeWindowRecord()],
    hotkey: HotkeyBinding? = nil,
    isPinned: Bool = false
) -> Snapshot {
    Snapshot(
        id: id,
        name: name,
        createdAt: createdAt,
        updatedAt: updatedAt,
        sourceDisplayState: DisplayState(
            displays: displays,
            primaryDisplayID: primaryDisplayID
        ),
        windows: windows,
        hotkey: hotkey,
        isPinned: isPinned
    )
}

func makeHotkey(
    keyCode: UInt32 = 40,
    modifiers: UInt32 = UInt32(cmdKey | optionKey),
    displayString: String = "Command-Option-K"
) -> HotkeyBinding {
    HotkeyBinding(
        keyCode: keyCode,
        modifiers: modifiers,
        displayString: displayString
    )
}

func makeDiscoveredWindow(
    axElement: AXUIElement = AXUIElementCreateSystemWide(),
    documentURL: URL? = nil,
    documentURLs: [URL] = [],
    documentTitles: [String] = [],
    title: String? = TestFixtures.windowTitle,
    role: String = TestFixtures.windowRole,
    subrole: String? = TestFixtures.windowSubrole,
    frame: CGRect = TestFixtures.windowFrame,
    isMinimized: Bool = false,
    isFullscreen: Bool = false,
    isMain: Bool = true,
    isVisible: Bool = true,
    cgWindowID: CGWindowID? = nil,
    ownerName: String? = nil,
    cgLayer: Int? = nil,
    zOrderHint: Int? = nil,
    isOnScreen: Bool? = true
) -> DiscoveredWindow {
    DiscoveredWindow(
        axElement: axElement,
        documentURL: documentURL,
        documentURLs: documentURLs,
        documentTitles: documentTitles,
        title: title,
        role: role,
        subrole: subrole,
        frame: frame,
        isMinimized: isMinimized,
        isFullscreen: isFullscreen,
        isMain: isMain,
        isVisible: isVisible,
        cgWindowID: cgWindowID,
        ownerName: ownerName,
        cgLayer: cgLayer,
        zOrderHint: zOrderHint,
        isOnScreen: isOnScreen
    )
}

func makeAXValue(_ point: CGPoint) -> AXValue {
    var mutablePoint = point
    return AXValueCreate(.cgPoint, &mutablePoint)!
}

func makeAXValue(_ size: CGSize) -> AXValue {
    var mutableSize = size
    return AXValueCreate(.cgSize, &mutableSize)!
}
