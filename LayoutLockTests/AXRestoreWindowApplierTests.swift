import ApplicationServices
import CoreGraphics
import XCTest
@testable import LayoutLock

final class AXRestoreWindowApplierTests: XCTestCase {
    func testImmediateVerifiedSuccessUsesPositionSizePositionOrder() async throws {
        let targetFrame = CGRect(x: -1_200, y: 40, width: 900, height: 700)
        let accessor = RecordingGeometryAccessor(
            frame: CGRect(x: 100, y: 100, width: 500, height: 400)
        )
        var sleepCount = 0
        let applier = AXRestoreWindowApplier(
            geometryAccessor: accessor,
            sleeper: { _ in sleepCount += 1 }
        )

        let result = try await applier.apply(
            savedWindow: makeWindowRecord(frame: targetFrame),
            targetFrame: targetFrame,
            to: makeDiscoveredWindow()
        )

        XCTAssertTrue(result.didRestore)
        XCTAssertEqual(accessor.frame, targetFrame)
        XCTAssertEqual(accessor.writeOrder, [.position, .size, .position])
        XCTAssertEqual(sleepCount, 1)
        XCTAssertEqual(result.attemptCount, 1)
        XCTAssertEqual(result.finalObservedFrame, targetFrame)
    }

    func testInitiallyCorrectGeometryThatDriftsDuringSettlingIsRetried() async throws {
        let originalFrame = CGRect(x: 1_000, y: 60, width: 600, height: 500)
        let targetFrame = CGRect(x: -1_300, y: 40, width: 900, height: 700)
        let accessor = RecordingGeometryAccessor(frame: originalFrame)
        var sleepCount = 0
        let applier = AXRestoreWindowApplier(
            geometryAccessor: accessor,
            sleeper: { _ in
                sleepCount += 1
                if sleepCount == 1 {
                    accessor.frame = originalFrame
                }
            }
        )

        let result = try await applier.apply(
            savedWindow: makeWindowRecord(frame: targetFrame),
            targetFrame: targetFrame,
            to: makeDiscoveredWindow(frame: originalFrame)
        )

        XCTAssertTrue(result.didRestore)
        XCTAssertEqual(accessor.frame, targetFrame)
        XCTAssertEqual(
            accessor.writeOrder,
            [.position, .size, .position, .position, .size, .position]
        )
        XCTAssertEqual(sleepCount, 2)
    }

    func testRetryCorrectsResizeThatRevertsFirstCrossMonitorMove() async throws {
        let originalFrame = CGRect(x: 1_100, y: 80, width: 600, height: 500)
        let targetFrame = CGRect(x: -1_400, y: 30, width: 1_000, height: 750)
        let accessor = RecordingGeometryAccessor(frame: originalFrame)
        var positionWriteCount = 0
        accessor.onSetPoint = { point in
            positionWriteCount += 1
            guard positionWriteCount != 2 else {
                return false
            }
            accessor.frame.origin = point
            return true
        }
        var sizeWriteCount = 0
        accessor.onSetSize = { size in
            sizeWriteCount += 1
            accessor.frame.size = size
            if sizeWriteCount == 1 {
                accessor.frame.origin = originalFrame.origin
            }
            return true
        }
        var sleepCount = 0
        let applier = AXRestoreWindowApplier(
            geometryAccessor: accessor,
            sleeper: { _ in sleepCount += 1 }
        )

        let result = try await applier.apply(
            savedWindow: makeWindowRecord(frame: targetFrame),
            targetFrame: targetFrame,
            to: makeDiscoveredWindow(frame: originalFrame)
        )

        XCTAssertTrue(result.didRestore)
        XCTAssertEqual(accessor.frame, targetFrame)
        XCTAssertEqual(
            accessor.writeOrder,
            [.position, .size, .position, .position, .size, .position]
        )
        XCTAssertEqual(sleepCount, 2)
    }

    func testDelayedGeometryCommitSucceedsDuringSettlingInterval() async throws {
        let targetFrame = CGRect(x: -900, y: 50, width: 800, height: 600)
        let accessor = RecordingGeometryAccessor(
            frame: CGRect(x: 900, y: 50, width: 700, height: 500),
            commitsWritesImmediately: false,
            writeResult: false
        )
        var sleptNanoseconds: [UInt64] = []
        let applier = AXRestoreWindowApplier(
            geometryAccessor: accessor,
            sleeper: { nanoseconds in
                sleptNanoseconds.append(nanoseconds)
                accessor.commitPendingFrame()
            }
        )

        let result = try await applier.apply(
            savedWindow: makeWindowRecord(frame: targetFrame),
            targetFrame: targetFrame,
            to: makeDiscoveredWindow()
        )

        XCTAssertTrue(result.didRestore)
        XCTAssertEqual(accessor.frame, targetFrame)
        XCTAssertEqual(sleptNanoseconds, [100_000_000])
        XCTAssertEqual(accessor.writeOrder, [.position, .size, .position])
    }

    func testPersistentMismatchFailsAfterFourAttempts() async throws {
        let targetFrame = CGRect(x: -800, y: 20, width: 900, height: 650)
        let accessor = RecordingGeometryAccessor(
            frame: CGRect(x: 800, y: 20, width: 500, height: 400),
            commitsWritesImmediately: false
        )
        var sleepCount = 0
        let applier = AXRestoreWindowApplier(
            geometryAccessor: accessor,
            sleeper: { _ in sleepCount += 1 }
        )

        let result = try await applier.apply(
            savedWindow: makeWindowRecord(frame: targetFrame),
            targetFrame: targetFrame,
            to: makeDiscoveredWindow()
        )

        XCTAssertFalse(result.didRestore)
        XCTAssertEqual(result.failureReason, RestoreSkipReason.windowGeometryDidNotSettle)
        XCTAssertEqual(sleepCount, 4)
        XCTAssertEqual(accessor.writeOrder.count, 12)
        XCTAssertEqual(result.attemptCount, 4)
        XCTAssertEqual(result.finalObservedFrame, accessor.frame)
    }

    func testFrameExactlyTwoPointsFromTargetIsAccepted() async throws {
        let targetFrame = CGRect(x: 10, y: 20, width: 800, height: 600)
        let observedFrame = CGRect(x: 12, y: 18, width: 802, height: 598)
        let accessor = RecordingGeometryAccessor(
            frame: observedFrame,
            commitsWritesImmediately: false
        )
        var sleepCount = 0
        let applier = AXRestoreWindowApplier(
            geometryAccessor: accessor,
            sleeper: { _ in sleepCount += 1 }
        )

        let result = try await applier.apply(
            savedWindow: makeWindowRecord(frame: targetFrame),
            targetFrame: targetFrame,
            to: makeDiscoveredWindow()
        )

        XCTAssertTrue(result.didRestore)
        XCTAssertEqual(sleepCount, 1)
    }

    func testFrameMoreThanTwoPointsFromTargetIsRejected() async throws {
        let targetFrame = CGRect(x: 10, y: 20, width: 800, height: 600)
        let observedFrame = CGRect(x: 12.01, y: 20, width: 800, height: 600)
        let accessor = RecordingGeometryAccessor(
            frame: observedFrame,
            commitsWritesImmediately: false
        )
        let applier = AXRestoreWindowApplier(
            geometryAccessor: accessor,
            sleeper: { _ in }
        )

        let result = try await applier.apply(
            savedWindow: makeWindowRecord(frame: targetFrame),
            targetFrame: targetFrame,
            to: makeDiscoveredWindow()
        )

        XCTAssertFalse(result.didRestore)
        XCTAssertEqual(result.failureReason, RestoreSkipReason.windowGeometryDidNotSettle)
    }

    func testCancellationDuringSettlingPropagates() async {
        let targetFrame = CGRect(x: -700, y: 20, width: 900, height: 650)
        let accessor = RecordingGeometryAccessor(
            frame: CGRect(x: 700, y: 20, width: 500, height: 400),
            commitsWritesImmediately: false
        )
        let applier = AXRestoreWindowApplier(
            geometryAccessor: accessor,
            sleeper: { _ in throw CancellationError() }
        )

        do {
            _ = try await applier.apply(
                savedWindow: makeWindowRecord(frame: targetFrame),
                targetFrame: targetFrame,
                to: makeDiscoveredWindow()
            )
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            XCTAssertEqual(accessor.writeOrder, [.position, .size, .position])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFrameRestorationRepairsMinimizedWindowWithoutUnminimizing() async throws {
        let targetFrame = CGRect(x: -900, y: 40, width: 800, height: 600)
        let accessor = RecordingGeometryAccessor(frame: CGRect(x: 100, y: 100, width: 500, height: 400))
        var sleepCount = 0
        let applier = AXRestoreWindowApplier(geometryAccessor: accessor, sleeper: { _ in sleepCount += 1 })

        // The synthetic AX handle cannot be unminimized. Geometry compensation must
        // use the injected accessor without trying to change the window's state.
        let result = try await applier.restoreFrame(savedWindow: makeWindowRecord(frame: targetFrame),
            targetFrame: targetFrame, to: makeDiscoveredWindow(isMinimized: true))

        XCTAssertTrue(result.didRestore)
        XCTAssertEqual(accessor.frame, targetFrame)
        XCTAssertEqual(accessor.writeOrder, [.position, .size, .position])
        XCTAssertEqual(sleepCount, 1)
        XCTAssertEqual(result.attemptCount, 1)
        XCTAssertEqual(result.finalObservedFrame, targetFrame)
    }

    func testAlreadyMinimizedWindowAtTargetSkipsGeometryAndStateChanges() async throws {
        let targetFrame = CGRect(x: -900, y: 40, width: 800, height: 600)
        let accessor = RecordingGeometryAccessor(frame: targetFrame)
        let reader = AXAttributeReader(attributeValueProvider: { _, attribute in
            attribute as String == kAXMinimizedAttribute ? kCFBooleanTrue : nil
        })
        let applier = AXRestoreWindowApplier(geometryAccessor: accessor, attributeReader: reader, setMinimized: { _, _ in
            XCTFail("An already minimized window must stay minimized")
            return false
        }, sleeper: { _ in XCTFail("No geometry changes need settling") })

        let result = try await applier.apply(
            savedWindow: makeWindowRecord(frame: targetFrame, isMinimized: true),
            targetFrame: targetFrame, to: makeDiscoveredWindow(isMinimized: true))

        XCTAssertTrue(result.didRestore)
        XCTAssertTrue(accessor.writeOrder.isEmpty)
        XCTAssertEqual(result.attemptCount, 0)
        XCTAssertEqual(result.finalObservedFrame, targetFrame)
    }

    func testMinimizedWindowWithStaleMatchingDiscoveryStillRestoresGeometry() async throws {
        let targetFrame = CGRect(x: -900, y: 40, width: 800, height: 600)
        let accessor = RecordingGeometryAccessor(frame: CGRect(x: 100, y: 100, width: 500, height: 400))
        let reader = AXAttributeReader(attributeValueProvider: { _, attribute in
            attribute as String == kAXMinimizedAttribute ? kCFBooleanTrue : nil
        })
        var stateWrites: [Bool] = []
        let applier = AXRestoreWindowApplier(geometryAccessor: accessor, attributeReader: reader, setMinimized: { value, _ in
            stateWrites.append(value)
            return true
        }, sleeper: { _ in })

        let result = try await applier.apply(
            savedWindow: makeWindowRecord(frame: targetFrame, isMinimized: true),
            targetFrame: targetFrame, to: makeDiscoveredWindow(frame: targetFrame, isMinimized: true))

        XCTAssertTrue(result.didRestore)
        XCTAssertEqual(stateWrites, [false, true])
        XCTAssertEqual(accessor.writeOrder, [.position, .size, .position])
        XCTAssertEqual(result.attemptCount, 1)
        XCTAssertEqual(result.finalObservedFrame, targetFrame)
    }

    func testStaleMinimizedDiscoveryDoesNotSkipRestoringMinimizedState() async throws {
        let targetFrame = CGRect(x: -900, y: 40, width: 800, height: 600)
        let accessor = RecordingGeometryAccessor(frame: targetFrame)
        let reader = AXAttributeReader(attributeValueProvider: { _, attribute in
            attribute as String == kAXMinimizedAttribute ? kCFBooleanFalse : nil
        })
        var stateWrites: [Bool] = []
        let applier = AXRestoreWindowApplier(geometryAccessor: accessor, attributeReader: reader, setMinimized: { value, _ in
            stateWrites.append(value)
            return true
        }, sleeper: { _ in })

        let result = try await applier.apply(
            savedWindow: makeWindowRecord(frame: targetFrame, isMinimized: true),
            targetFrame: targetFrame, to: makeDiscoveredWindow(frame: targetFrame, isMinimized: true))

        XCTAssertTrue(result.didRestore)
        XCTAssertEqual(stateWrites, [false, true])
    }

    func testSavedMinimizedStateIsAppliedAfterGeometryForVisibleAndMinimizedWindows() async throws {
        for initiallyMinimized in [false, true] {
            let targetFrame = CGRect(x: -900, y: 40, width: 800, height: 600)
            let accessor = RecordingGeometryAccessor(frame: CGRect(x: 100, y: 100, width: 500, height: 400))
            var stateWrites: [Bool] = []
            let applier = AXRestoreWindowApplier(geometryAccessor: accessor, setMinimized: { value, _ in
                stateWrites.append(value)
                if value {
                    XCTAssertEqual(accessor.frame, targetFrame)
                    XCTAssertEqual(accessor.writeOrder, [.position, .size, .position])
                } else {
                    XCTAssertTrue(accessor.writeOrder.isEmpty)
                }
                return true
            }, sleeper: { _ in })

            let result = try await applier.apply(
                savedWindow: makeWindowRecord(frame: targetFrame, isMinimized: true),
                targetFrame: targetFrame, to: makeDiscoveredWindow(isMinimized: initiallyMinimized))

            XCTAssertTrue(result.didRestore)
            XCTAssertEqual(stateWrites, initiallyMinimized ? [false, true] : [true])
            XCTAssertEqual(result.attemptCount, 1)
            XCTAssertEqual(result.finalObservedFrame, targetFrame)
        }
    }

    func testSavedVisibleWindowIsUnminimizedBeforeGeometry() async throws {
        let targetFrame = CGRect(x: 10, y: 20, width: 800, height: 600)
        let accessor = RecordingGeometryAccessor(frame: targetFrame)
        var stateWrites: [Bool] = []
        let applier = AXRestoreWindowApplier(geometryAccessor: accessor, setMinimized: { value, _ in
            XCTAssertTrue(accessor.writeOrder.isEmpty)
            stateWrites.append(value)
            return true
        }, sleeper: { _ in })

        let result = try await applier.apply(savedWindow: makeWindowRecord(frame: targetFrame),
            targetFrame: targetFrame, to: makeDiscoveredWindow(isMinimized: true))

        XCTAssertTrue(result.didRestore)
        XCTAssertEqual(stateWrites, [false])
        XCTAssertEqual(accessor.writeOrder, [.position, .size, .position])
    }

    func testFailureToMinimizeIsReportedWithGeometryDiagnostics() async throws {
        let targetFrame = CGRect(x: 10, y: 20, width: 800, height: 600)
        let accessor = RecordingGeometryAccessor(frame: targetFrame)
        var stateWrites: [Bool] = []
        let applier = AXRestoreWindowApplier(geometryAccessor: accessor, setMinimized: { value, _ in
            stateWrites.append(value)
            return false
        }, sleeper: { _ in })

        let result = try await applier.apply(
            savedWindow: makeWindowRecord(frame: targetFrame, isMinimized: true),
            targetFrame: targetFrame, to: makeDiscoveredWindow())

        XCTAssertFalse(result.didRestore)
        XCTAssertEqual(stateWrites, [true])
        XCTAssertEqual(result.failureReason, RestoreSkipReason.restoreFailed)
        XCTAssertEqual(result.attemptCount, 1)
        XCTAssertEqual(result.finalObservedFrame, targetFrame)
    }

    func testFailureToUnminimizeDoesNotAttemptGeometry() async throws {
        let targetFrame = CGRect(x: 10, y: 20, width: 800, height: 600)
        let accessor = RecordingGeometryAccessor(frame: CGRect(x: 100, y: 100, width: 500, height: 400))
        var stateWrites: [Bool] = []
        let applier = AXRestoreWindowApplier(geometryAccessor: accessor, setMinimized: { value, _ in
            stateWrites.append(value)
            return false
        }, sleeper: { _ in })

        let result = try await applier.apply(
            savedWindow: makeWindowRecord(frame: targetFrame, isMinimized: true),
            targetFrame: targetFrame, to: makeDiscoveredWindow(isMinimized: true))

        XCTAssertFalse(result.didRestore)
        XCTAssertEqual(stateWrites, [false])
        XCTAssertTrue(accessor.writeOrder.isEmpty)
        XCTAssertEqual(result.failureReason, RestoreSkipReason.restoreFailed)
    }

    func testSavedMinimizedStateIsRestoredEvenWhenGeometryFails() async throws {
        let targetFrame = CGRect(x: -900, y: 40, width: 800, height: 600)
        let accessor = RecordingGeometryAccessor(frame: CGRect(x: 100, y: 100, width: 500, height: 400),
            commitsWritesImmediately: false)
        var stateWrites: [Bool] = []
        let applier = AXRestoreWindowApplier(geometryAccessor: accessor, setMinimized: { value, _ in
            stateWrites.append(value)
            return true
        }, sleeper: { _ in })

        let result = try await applier.apply(
            savedWindow: makeWindowRecord(frame: targetFrame, isMinimized: true),
            targetFrame: targetFrame, to: makeDiscoveredWindow(isMinimized: true))

        XCTAssertFalse(result.didRestore)
        XCTAssertEqual(result.failureReason, RestoreSkipReason.windowGeometryDidNotSettle)
        XCTAssertEqual(stateWrites, [false, true])
    }

    func testCancellationRestoresSavedMinimizedStateAndPropagates() async {
        let targetFrame = CGRect(x: 10, y: 20, width: 800, height: 600)
        let accessor = RecordingGeometryAccessor(frame: CGRect(x: 100, y: 100, width: 500, height: 400))
        var stateWrites: [Bool] = []
        let applier = AXRestoreWindowApplier(geometryAccessor: accessor, setMinimized: { value, _ in
            stateWrites.append(value)
            return true
        }, sleeper: { _ in throw CancellationError() })

        do {
            _ = try await applier.apply(
                savedWindow: makeWindowRecord(frame: targetFrame, isMinimized: true),
                targetFrame: targetFrame, to: makeDiscoveredWindow(isMinimized: true))
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            XCTAssertEqual(stateWrites, [false, true])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFrameRestorationDoesNotRetryMismatchDespiteConfiguredAttemptLimit() async throws {
        let originalFrame = CGRect(x: 100, y: 100, width: 500, height: 400)
        let targetFrame = CGRect(x: -900, y: 40, width: 800, height: 600)
        let accessor = RecordingGeometryAccessor(frame: originalFrame, commitsWritesImmediately: false)
        var sleepCount = 0
        let applier = AXRestoreWindowApplier(geometryAccessor: accessor, attemptLimit: 7,
                                             sleeper: { _ in sleepCount += 1 })

        let result = try await applier.restoreFrame(savedWindow: makeWindowRecord(frame: targetFrame),
            targetFrame: targetFrame, to: makeDiscoveredWindow())

        XCTAssertFalse(result.didRestore)
        XCTAssertEqual(result.failureReason, RestoreSkipReason.windowGeometryDidNotSettle)
        XCTAssertEqual(accessor.writeOrder, [.position, .size, .position])
        XCTAssertEqual(sleepCount, 1)
        XCTAssertEqual(result.attemptCount, 1)
        XCTAssertEqual(result.finalObservedFrame, originalFrame)
    }

    private func makeWindowRecord(frame: CGRect, isMinimized: Bool = false) -> WindowRecord {
        WindowRecord(
            bundleIdentifier: "org.mozilla.firefoxdeveloperedition",
            pidAtCapture: 42,
            windowTitle: "Firefox Developer Edition",
            role: "AXWindow",
            subrole: "AXStandardWindow",
            frame: CGRectCodable(frame),
            displayID: nil,
            normalizedFrame: NormalizedRect(
                xRatio: 0,
                yRatio: 0,
                widthRatio: 0.5,
                heightRatio: 0.5
            ),
            zOrderHint: nil,
            isMinimized: isMinimized,
            isFullscreen: false,
            isVisible: true,
            captureSignature: WindowSignature(
                bundleIdentifier: "org.mozilla.firefoxdeveloperedition",
                owningPid: 42,
                windowTitle: "Firefox Developer Edition",
                role: "AXWindow",
                subrole: "AXStandardWindow",
                capturedFrame: CGRectCodable(frame),
                cgWindowID: nil
            )
        )
    }

    private func makeDiscoveredWindow(
        frame: CGRect = CGRect(x: 100, y: 100, width: 500, height: 400),
        isMinimized: Bool = false
    ) -> DiscoveredWindow {
        DiscoveredWindow(
            axElement: AXUIElementCreateSystemWide(),
            title: "Firefox Developer Edition",
            role: "AXWindow",
            subrole: "AXStandardWindow",
            frame: frame,
            isMinimized: isMinimized,
            isFullscreen: false,
            isMain: true,
            isVisible: true,
            cgWindowID: nil,
            ownerName: "Firefox Developer Edition",
            cgLayer: 0,
            zOrderHint: 0,
            isOnScreen: true
        )
    }
}

private final class RecordingGeometryAccessor: RestoreWindowGeometryAccessing {
    enum Write: Equatable {
        case position
        case size
    }

    var frame: CGRect
    var onSetPoint: ((CGPoint) -> Bool)?
    var onSetSize: ((CGSize) -> Bool)?
    private(set) var writeOrder: [Write] = []

    private var pendingFrame: CGRect
    private let commitsWritesImmediately: Bool
    private let writeResult: Bool

    init(
        frame: CGRect,
        commitsWritesImmediately: Bool = true,
        writeResult: Bool = true
    ) {
        self.frame = frame
        pendingFrame = frame
        self.commitsWritesImmediately = commitsWritesImmediately
        self.writeResult = writeResult
    }

    func point(from _: AXUIElement, attribute _: CFString) -> CGPoint? {
        frame.origin
    }

    func size(from _: AXUIElement, attribute _: CFString) -> CGSize? {
        frame.size
    }

    func setPoint(
        _ point: CGPoint,
        on _: AXUIElement,
        attribute _: CFString
    ) -> Bool {
        writeOrder.append(.position)
        pendingFrame.origin = point
        if let onSetPoint {
            return onSetPoint(point)
        }
        if commitsWritesImmediately {
            frame.origin = point
        }
        return writeResult
    }

    func setSize(
        _ size: CGSize,
        on _: AXUIElement,
        attribute _: CFString
    ) -> Bool {
        writeOrder.append(.size)
        pendingFrame.size = size
        if let onSetSize {
            return onSetSize(size)
        }
        if commitsWritesImmediately {
            frame.size = size
        }
        return writeResult
    }

    func commitPendingFrame() {
        frame = pendingFrame
    }
}
