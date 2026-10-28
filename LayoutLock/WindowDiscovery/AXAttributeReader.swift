import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

struct AXAttributeReader {
    typealias AttributeValueProvider = (AXUIElement, CFString) -> CFTypeRef?
    private typealias WindowIDFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    // ApplicationServices is already linked. The private symbol remains optional at runtime.
    private static let windowIDFunction: WindowIDFunction? = {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: WindowIDFunction.self)
    }()

    static func windowID(from element: AXUIElement) -> CGWindowID? {
        guard let resolve = windowIDFunction else { return nil }
        var windowID: CGWindowID = 0
        guard resolve(element, &windowID) == .success, windowID != 0 else { return nil }
        return windowID
    }

    struct AttributeResult {
        let value: CFTypeRef?
        let error: AXError
    }

    private let attributeResultProvider: (AXUIElement, CFString) -> AttributeResult

    init(attributeValueProvider: AttributeValueProvider? = nil) {
        if let attributeValueProvider {
            self.attributeResultProvider = {
                AttributeResult(value: attributeValueProvider($0, $1), error: .success)
            }
        } else {
            self.attributeResultProvider = Self.copyAttributeResult
        }
    }

    init(attributeResultProvider: @escaping (AXUIElement, CFString) -> AttributeResult) {
        self.attributeResultProvider = attributeResultProvider
    }

    func windows(from element: AXUIElement) -> (elements: [AXUIElement], error: AXError) {
        let result = attributeResultProvider(element, kAXWindowsAttribute as CFString)
        guard result.error == .success else { return ([], result.error) }
        guard let elements = result.value as? [AXUIElement] else { return ([], result.error) }
        return (elements, .success)
    }

    func elementArray(
        from element: AXUIElement,
        attribute: CFString
    ) -> [AXUIElement]? {
        guard let value = copyAttributeValue(from: element, attribute: attribute) else {
            return nil
        }

        return value as? [AXUIElement]
    }

    func element(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        guard let value = copyAttributeValue(from: element, attribute: attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    func string(
        from element: AXUIElement,
        attribute: CFString
    ) -> String? {
        guard let value = copyAttributeValue(from: element, attribute: attribute) else {
            return nil
        }

        return value as? String
    }

    func urlString(
        from element: AXUIElement,
        attribute: CFString
    ) -> String? {
        guard let value = copyAttributeValue(from: element, attribute: attribute) else {
            return nil
        }

        if let string = value as? String {
            return string
        }
        if let url = value as? URL {
            return url.absoluteString
        }
        if let url = value as? NSURL {
            return url.absoluteString
        }

        return nil
    }

    func bool(
        from element: AXUIElement,
        attribute: CFString
    ) -> Bool? {
        guard let value = copyAttributeValue(from: element, attribute: attribute) else {
            return nil
        }

        if let number = value as? NSNumber {
            return number.boolValue
        }

        return nil
    }

    func point(
        from element: AXUIElement,
        attribute: CFString
    ) -> CGPoint? {
        value(
            from: element,
            attribute: attribute,
            axValueType: .cgPoint
        )
    }

    func size(
        from element: AXUIElement,
        attribute: CFString
    ) -> CGSize? {
        value(
            from: element,
            attribute: attribute,
            axValueType: .cgSize
        )
    }

    @discardableResult
    func setBool(
        _ value: Bool,
        on element: AXUIElement,
        attribute: CFString
    ) -> Bool {
        AXUIElementSetAttributeValue(
            element,
            attribute,
            value ? kCFBooleanTrue : kCFBooleanFalse
        ) == .success
    }

    @discardableResult
    func setPoint(
        _ point: CGPoint,
        on element: AXUIElement,
        attribute: CFString
    ) -> Bool {
        var mutablePoint = point
        guard let value = AXValueCreate(.cgPoint, &mutablePoint) else {
            return false
        }

        return AXUIElementSetAttributeValue(element, attribute, value) == .success
    }

    @discardableResult
    func setSize(
        _ size: CGSize,
        on element: AXUIElement,
        attribute: CFString
    ) -> Bool {
        var mutableSize = size
        guard let value = AXValueCreate(.cgSize, &mutableSize) else {
            return false
        }

        return AXUIElementSetAttributeValue(element, attribute, value) == .success
    }

    @discardableResult
    func performAction(
        _ action: CFString,
        on element: AXUIElement
    ) -> Bool {
        AXUIElementPerformAction(element, action) == .success
    }

    private func copyAttributeValue(
        from element: AXUIElement,
        attribute: CFString
    ) -> CFTypeRef? {
        let result = attributeResultProvider(element, attribute)
        return result.error == .success ? result.value : nil
    }

    private static func copyAttributeResult(
        from element: AXUIElement,
        attribute: CFString
    ) -> AttributeResult {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        return AttributeResult(value: value, error: error)
    }

    private func value<T>(
        from element: AXUIElement,
        attribute: CFString,
        axValueType: AXValueType
    ) -> T? {
        guard let value = copyAttributeValue(from: element, attribute: attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard
              AXValueGetType(axValue) == axValueType else {
            return nil
        }

        switch axValueType {
        case .cgPoint:
            var point = CGPoint.zero
            guard AXValueGetValue(axValue, .cgPoint, &point) else {
                return nil
            }

            return point as? T
        case .cgSize:
            var size = CGSize.zero
            guard AXValueGetValue(axValue, .cgSize, &size) else {
                return nil
            }

            return size as? T
        default:
            return nil
        }
    }
}
