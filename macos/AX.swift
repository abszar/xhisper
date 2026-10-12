import AppKit
import ApplicationServices

// Accessibility reads: the frontmost app (tone and terminal detection) and,
// for xhisper-learn, the focused text field. Field text goes to stdout only,
// never to argv or a log.
enum AXCommand {
    static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success ? value : nil
    }

    static func element(_ v: CFTypeRef?) -> AXUIElement? {
        guard let v = v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// bundleId<TAB>appName<TAB>windowTitle. Bundle id plays the role of the
    /// X11 window class; the title needs Accessibility and is empty without it.
    static func front() -> Int32 {
        let app = NSWorkspace.shared.frontmostApplication
        var title = ""
        if let app = app {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.5)
            if let window = element(copy(appElement, kAXFocusedWindowAttribute)) {
                title = (copy(window, kAXTitleAttribute) as? String) ?? ""
            }
        }
        func clean(_ s: String?) -> String {
            (s ?? "").replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        print("\(clean(app?.bundleIdentifier))\t\(clean(app?.localizedName))\t\(clean(title))")
        return 0
    }
}
