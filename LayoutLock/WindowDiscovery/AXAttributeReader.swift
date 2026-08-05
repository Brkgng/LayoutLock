import ApplicationServices
import CoreGraphics
import Foundation

struct AXAttributeReader {
    typealias AttributeValueProvider = (AXUIElement, CFString) -> CFTypeRef?

    private let attributeValueProvider: AttributeValueProvider

    init(attributeValueProvider: @escaping AttributeValueProvider = AXAttributeReader.copyAttributeValue) {
        self.attributeValueProvider = attributeValueProvider
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
        attributeValueProvider(element, attribute)
    }

    private static func copyAttributeValue(
        from element: AXUIElement,
        attribute: CFString
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)

        switch error {
        case .success:
            return value
        case .attributeUnsupported, .noValue:
            return nil
        default:
            return nil
        }
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
