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

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1.0)  // also the default for every element
        if let el = element(copy(system, kAXFocusedUIElementAttribute)) { return el }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return element(copy(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute))
    }

    /// role, text and caret (in code points, like Python indices); nil once
    /// the element is gone.
    static func snapshot(_ el: AXUIElement) -> [String: Any]? {
        guard let role = copy(el, kAXRoleAttribute) as? String else { return nil }
        guard let text = copy(el, kAXValueAttribute) as? String else { return ["role": role] }
        var caret = -1
        if let r = copy(el, kAXSelectedTextRangeAttribute), CFGetTypeID(r) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(r as! AXValue, .cfRange, &range) {
                let utf16 = webCaretOnEmptyLastLine(range.location, selection: range.length,
                                                    utf16: Array(text.utf16), isWeb: isWebContent(el))
                caret = scalarOffset(text, utf16: utf16)
            }
        }
        return ["role": role, "text": text, "caret": caret]
    }

    /// A field inside a web page (Chrome, Electron): it exposes DOM attributes.
    static func isWebContent(_ el: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(el, &names) == .success, let list = names as? [String] else { return false }
        return list.contains("AXDOMClassList") || list.contains("AXDOMIdentifier")
    }

    static func emit(_ object: [String: Any]) {
        var object = object
        // Tell xhisper-learn why nothing was readable (it logs a permission hint).
        if !AXIsProcessTrusted() { object["denied"] = true }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    /// `ax`: one JSON line. `ax --follow`: pin the element, one line per stdin line.
    static func main(_ args: [String]) -> Int32 {
        let el = focusedElement()
        if args.contains("--follow") {
            while readLine() != nil { emit(el.flatMap(snapshot) ?? ["gone": true]) }
        } else {
            emit(el.flatMap(snapshot) ?? [:])
        }
        return 0
    }
}
