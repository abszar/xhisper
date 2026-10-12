import AppKit

// Port of xhisper-history: the last dictations, newest first, each with Copy
// and Edit. Edit fixes an entry and learns the corrected words through
// `xhisper-learn diff` (JSON on stdin, never argv). One window at a time: a
// second launch raises the open one.

private let pidFile = Runtime.path("xhisper-history.pid")
private let fadeSeconds = 0.22
private let slidePoints: CGFloat = 24

private func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

final class HistoryWindow: NSWindow {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class HistoryController: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    let path = HistoryStore.defaultPath()
    var window: HistoryWindow!
    let list = NSStackView()
    var entries: [HistoryEntry] = []
    var editing: (entry: HistoryEntry, view: NSTextView)?
    var stale = false
    var fileStamp = ""
    var firstCopy: NSButton?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        window = HistoryWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                               styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Dictation history"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = rgb(0x1a1a1a)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.onEscape = { [unowned self] in
            if self.editing != nil { self.finishEdit(save: false) } else { self.window.close() }
        }

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        list.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 12, right: 12)
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        window.contentView = scroll
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        populate()
        fileStamp = stamp()
        // Live refresh when a new dictation lands while the window is open.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [unowned self] _ in
            let now = self.stamp()
            if now != self.fileStamp { self.fileStamp = now; self.populate() }
        }
        presentAnimated()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        if readPid(pidFile) == getpid() { unlink(pidFile) }
    }

    /// Edit/Close shortcuts (Cmd+C/V/X/A/Z, Cmd+W) need a main menu, even for
    /// an app without a Dock icon.
    func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func stamp() -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: path)
        return "\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\((a?[.size] as? Int) ?? -1)"
    }

    func populate() {
        if editing != nil { stale = true; return }  // don't wipe an edit in progress
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        entries = HistoryStore.load(path)
        firstCopy = nil
        if entries.isEmpty {
            let empty = NSTextField(labelWithString: "No dictations yet")
            empty.textColor = rgb(0x8f8b84)
            list.addArrangedSubview(empty)
        }
        for (index, entry) in entries.enumerated() { list.addArrangedSubview(makeRow(entry, index: index)) }
        // Enter copies the newest dictation.
        firstCopy?.keyEquivalent = "\r"
    }

    func button(_ title: String, _ action: Selector, tag: Int) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.tag = tag
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        return b
    }

    func makeRow(_ entry: HistoryEntry, index: Int) -> NSView {
        let row = NSView()
        row.wantsLayer = true
        row.layer?.backgroundColor = rgb(0x262626).cgColor
        row.layer?.cornerRadius = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        let when = NSTextField(labelWithString: HistoryStore.describe(entry.time))
        when.font = .systemFont(ofSize: 11)
        when.textColor = rgb(0x8f8b84)
        let body = NSTextField(wrappingLabelWithString: entry.text)
        body.isSelectable = true
        body.textColor = rgb(0xeeeae0)
        body.font = .systemFont(ofSize: 13)
        body.preferredMaxLayoutWidth = 400
        let texts = NSStackView(views: [when, body])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 4

        let copy = button("Copy", #selector(copyEntry(_:)), tag: index)
        let edit = button("Edit", #selector(editEntry(_:)), tag: index)
        edit.toolTip = "Fix this dictation; corrected words are learned"
        if firstCopy == nil { firstCopy = copy }
        let buttons = NSStackView(views: [copy, edit])
        buttons.orientation = .vertical
        buttons.spacing = 6

        let content = NSStackView(views: [texts, buttons])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10),
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
        ])
        DispatchQueue.main.async { row.widthAnchor.constraint(equalTo: self.list.widthAnchor, constant: -24).isActive = true }
        row.identifier = NSUserInterfaceItemIdentifier("row\(index)")
        return row
    }

    @objc func copyEntry(_ sender: NSButton) {
        guard entries.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entries[sender.tag].text, forType: .string)
        sender.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { sender.title = "Copy" }
    }

    @objc func editEntry(_ sender: NSButton) {
        guard editing == nil, entries.indices.contains(sender.tag),
              let row = list.arrangedSubviews.first(where: { $0.identifier?.rawValue == "row\(sender.tag)" }),
              let content = row.subviews.first as? NSStackView,
              let texts = content.arrangedSubviews.first as? NSStackView,
              let buttons = content.arrangedSubviews.last as? NSStackView else { return }
        let entry = entries[sender.tag]
        firstCopy?.keyEquivalent = ""  // Enter types a newline while editing
        let scroll = NSTextView.scrollableTextView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 90).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 400).isActive = true
        let view = scroll.documentView as! NSTextView
        view.string = entry.text
        view.backgroundColor = rgb(0x303030)
        view.textColor = rgb(0xeeeae0)
        view.insertionPointColor = rgb(0xeeeae0)
        view.font = .systemFont(ofSize: 13)
        view.delegate = self
        texts.arrangedSubviews.last?.removeFromSuperview()
        texts.addArrangedSubview(scroll)
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let save = button("Save", #selector(saveEdit(_:)), tag: sender.tag)
        save.bezelColor = .controlAccentColor
        buttons.addArrangedSubview(save)
        buttons.addArrangedSubview(button("Cancel", #selector(cancelEdit(_:)), tag: sender.tag))
        editing = (entry, view)
        window.makeFirstResponder(view)
    }

    @objc func saveEdit(_ sender: NSButton) { finishEdit(save: true) }
    @objc func cancelEdit(_ sender: NSButton) { finishEdit(save: false) }

    /// Escape inside the editor cancels the edit (NSTextView would autocomplete).
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) || selector == #selector(NSTextView.complete(_:)) {
            finishEdit(save: false)
            return true
        }
        return false
    }

    func finishEdit(save: Bool) {
        guard let (entry, view) = editing else { return }
        editing = nil
        let newText = view.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if save && !newText.isEmpty && newText != entry.text {
            let learned = learnFromEdit(old: entry.text, new: newText)
            HistoryStore.update(path, entry: entry, newText: newText)
            window.subtitle = learned.isEmpty ? "Saved" : "Learned: " + learned.joined(separator: ", ")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { self.window.subtitle = "" }
        }
        stale = false
        populate()
    }

    /// `xhisper-learn diff`, text over stdin; the words it learned.
    func learnFromEdit(old: String, new: String) -> [String] {
        let learn = ProcessInfo.processInfo.environment["XHISPER_LEARN"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/local/bin/xhisper-learn"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: learn)
        p.arguments = ["diff"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil,
              let body = try? JSONSerialization.data(withJSONObject: ["old": old, "new": new]) else { return [] }
        input.fileHandleForWriting.write(body)
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return [] }
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return out.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Fade in and rise into place, picking up where the pill left off.
    func presentAnimated() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let visible = screen.visibleFrame
        let target = NSPoint(x: (visible.midX - window.frame.width / 2).rounded(), y: visible.minY + 130)
        window.setFrameOrigin(NSPoint(x: target.x, y: target.y - slidePoints))
        window.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        let start = Date()
        Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [unowned self] timer in
            let p = min(1, Date().timeIntervalSince(start) / fadeSeconds)
            let eased = 1 - pow(1 - p, 3)
            self.window.alphaValue = eased
            self.window.setFrameOrigin(NSPoint(x: target.x, y: target.y - slidePoints * (1 - eased)))
            if p >= 1 { timer.invalidate() }
        }
    }

    func raise() {
        populate()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

enum HistoryApp {
    static func main(_ args: [String]) -> Int32 {
        // A second launch raises the open window instead of opening another.
        if let pid = readPid(pidFile), pid != getpid(), isAlive(pid),
           processArgs(pid).dropFirst().first == "history" {
            kill(pid, SIGUSR1)
            return 0
        }
        writePid(pidFile)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = HistoryController()
        app.delegate = controller
        signal(SIGUSR1, SIG_IGN)
        let raise = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        raise.setEventHandler { controller.raise() }
        raise.resume()
        withExtendedLifetime((controller, raise)) { app.run() }
        return 0
    }
}
