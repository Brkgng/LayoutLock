import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
@testable import LayoutLock

final class AXAttributeReaderTests: XCTestCase {
    func testReadsTypedAttributesFromInjectedValues() throws {
        let element = AXUIElementCreateSystemWide()
        let child = AXUIElementCreateApplication(123)
        let point = CGPoint(x: 10, y: 20)
        let size = CGSize(width: 300, height: 200)
        let reader = AXAttributeReader { _, attribute in
            switch attribute as String {
            case kAXWindowsAttribute:
                return [child] as CFArray
            case kAXTitleAttribute:
                return "Editor" as CFString
            case kAXURLAttribute:
                return NSURL(string: "https://example.com/document")
            case kAXMinimizedAttribute:
                return NSNumber(value: true)
            case kAXPositionAttribute:
                return makeAXValue(point) as CFTypeRef
            case kAXSizeAttribute:
                return makeAXValue(size) as CFTypeRef
            default:
                return nil
            }
        }

        XCTAssertEqual(reader.elementArray(from: element, attribute: kAXWindowsAttribute as CFString)?.count, 1)
        XCTAssertEqual(reader.string(from: element, attribute: kAXTitleAttribute as CFString), "Editor")
        XCTAssertEqual(
            reader.urlString(from: element, attribute: kAXURLAttribute as CFString),
            "https://example.com/document"
        )
        XCTAssertEqual(reader.bool(from: element, attribute: kAXMinimizedAttribute as CFString), true)
        XCTAssertEqual(reader.point(from: element, attribute: kAXPositionAttribute as CFString), point)
        XCTAssertEqual(reader.size(from: element, attribute: kAXSizeAttribute as CFString), size)
    }

    func testReturnsNilForMissingOrMismatchedValues() {
        let element = AXUIElementCreateSystemWide()
        let reader = AXAttributeReader { _, attribute in
            switch attribute as String {
            case kAXTitleAttribute:
                return NSNumber(value: 1)
            case kAXMinimizedAttribute:
                return "true" as CFString
            case kAXPositionAttribute:
                return makeAXValue(CGSize(width: 10, height: 20)) as CFTypeRef
            case kAXSizeAttribute:
                return "not an AXValue" as CFString
            default:
                return nil
            }
        }

        XCTAssertNil(reader.string(from: element, attribute: kAXTitleAttribute as CFString))
        XCTAssertNil(reader.bool(from: element, attribute: kAXMinimizedAttribute as CFString))
        XCTAssertNil(reader.point(from: element, attribute: kAXPositionAttribute as CFString))
        XCTAssertNil(reader.size(from: element, attribute: kAXSizeAttribute as CFString))
        XCTAssertNil(reader.elementArray(from: element, attribute: kAXWindowsAttribute as CFString))
    }
}
