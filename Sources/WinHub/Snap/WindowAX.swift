import AppKit
import ApplicationServices

/// Accessibility helpers for finding and moving the window under the cursor.
enum WindowAX {
    /// The top-level window element at a screen point (top-left origin), or nil.
    static func window(atTopLeft point: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              var current = element else { return nil }

        // The hit element is usually a control; climb to its window ancestor.
        for _ in 0..<12 {
            if role(of: current) == (kAXWindowRole as String) { return current }
            guard let next = parent(of: current) else { break }
            current = next
        }
        return nil
    }

    static func position(of window: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
        return point
    }

    /// Move and resize a window to a Cocoa (bottom-left) rect. Position is set
    /// twice — some apps clamp a resize against the old position, so a second set
    /// after sizing lands it where we want.
    static func setFrame(_ window: AXUIElement, cocoaRect: CGRect) {
        let ax = ScreenGeometry.axRect(fromCocoa: cocoaRect)
        var origin = ax.origin
        var size = ax.size
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let parent = value else { return nil }
        return (parent as! AXUIElement)
    }
}
