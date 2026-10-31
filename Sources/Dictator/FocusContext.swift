import AppKit
import ApplicationServices

/// What's under the cursor in the frontmost app, read through the Accessibility API (stays on this Mac).
struct FocusContext {
    var appName: String?
    var bundleID: String?
    var textBefore: String?
    var selectedText: String?
    var isSecure = false

    static func capture() -> FocusContext {
        let app = NSWorkspace.shared.frontmostApplication
        var ctx = FocusContext(appName: app?.localizedName, bundleID: app?.bundleIdentifier)
        guard Paster.hasAccessibility, let pid = app?.processIdentifier, pid != ProcessInfo.processInfo.processIdentifier else { return ctx }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        // Electron apps (Slack, Notion, VS Code…) only expose text when asked to.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        guard let focusedRef = attribute(appElement, kAXFocusedUIElementAttribute) else { return ctx }
        let focused = focusedRef as! AXUIElement
        if (attribute(focused, kAXSubroleAttribute) as? String) == (kAXSecureTextFieldSubrole as String) {
            ctx.isSecure = true
            return ctx
        }
        if let selected = attribute(focused, kAXSelectedTextAttribute) as? String, !selected.isEmpty {
            ctx.selectedText = selected
        }
        if let value = attribute(focused, kAXValueAttribute) as? String,
           let rangeRef = attribute(focused, kAXSelectedTextRangeAttribute) {
            var range = CFRange()
            if AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) {
                let ns = value as NSString
                let end = min(max(range.location, 0), ns.length)
                let start = max(0, end - 600)
                ctx.textBefore = ns.substring(with: NSRange(location: start, length: end - start))
            }
        }
        return ctx
    }

    /// The focused text element of the frontmost app (nil for password fields).
    static func focusedElement() -> AXUIElement? {
        guard Paster.hasAccessibility, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let ref = attribute(app, kAXFocusedUIElementAttribute) else { return nil }
        let element = ref as! AXUIElement
        if (attribute(element, kAXSubroleAttribute) as? String) == (kAXSecureTextFieldSubrole as String) { return nil }
        return element
    }

    static func value(of element: AXUIElement) -> String? {
        attribute(element, kAXValueAttribute) as? String
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
