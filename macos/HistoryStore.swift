import Foundation

// The dictation history written by xhisper.sh (JSON lines {time, text}, 0600,
// trimmed to history-size). Shared by the overlay and the history window.

struct HistoryEntry: Equatable {
    let time: String
    let text: String
}

enum HistoryStore {
    static func defaultPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let p = env["XHISPER_HISTORY_FILE"], !p.isEmpty { return p }
        let state = env["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (NSHomeDirectory() + "/.local/state")
        return state + "/xhisper/history.jsonl"
    }

    static func parse(_ line: Substring) -> HistoryEntry? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let text = obj["text"] as? String, !text.isEmpty else { return nil }
        return HistoryEntry(time: obj["time"] as? String ?? "", text: text)
    }

    /// Newest first.
    static func load(_ path: String) -> [HistoryEntry] {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap(parse).reversed()
    }

    /// Time label for a history row (design A9 "Times"): "Just now" under 1 min, "N min ago"
    /// under 60 min, "N h ago" under 6 h, then "Today 09:12", "Yesterday 14:03", "Mon 17:20"
    /// under 7 days, else "12 Oct 09:30". Clock is 24 h HH:mm (not locale-templated).
    /// Future stamps (clock skew) read "Just now"; an unparsable stamp is returned as is.
    static func describe(_ stamp: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        guard let when = parser.date(from: stamp) else { return stamp }
        let age = now.timeIntervalSince(when)
        if age < 60 { return "Just now" }
        if age < 3600 { return "\(Int(age / 60)) min ago" }
        if age < 6 * 3600 { return "\(Int(age / 3600)) h ago" }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.timeZone = calendar.timeZone
        out.dateFormat = "HH:mm"
        let clock = out.string(from: when)
        if calendar.isDate(when, inSameDayAs: now) { return "Today " + clock }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(when, inSameDayAs: yesterday) {
            return "Yesterday " + clock
        }
        out.dateFormat = age < 7 * 86400 ? "EEE HH:mm" : "dd MMM HH:mm"
        return out.string(from: when)
    }

    /// One display line of an entry: `bullet` is "•" or "N." when the line is a list item.
    struct DisplayLine: Equatable {
        let bullet: String?
        let text: String
    }

    /// Splits stored text into display lines for the list (design A9 "Lists"): "- ", "* ",
    /// "• " become a "•" bullet, "N. " keeps its number, anything else has no bullet.
    /// Display only: Copy and Paste always use the raw stored text.
    static func displayLines(_ text: String) -> [DisplayLine] {
        text.components(separatedBy: "\n").map { line in
            for marker in ["- ", "* ", "\u{2022} "] where line.hasPrefix(marker) {
                return DisplayLine(bullet: "\u{2022}", text: String(line.dropFirst(marker.count)))
            }
            let digits = line.prefix { $0.isASCII && $0.isNumber }
            if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
                return DisplayLine(bullet: digits + ".", text: String(line.dropFirst(digits.count + 2)))
            }
            return DisplayLine(bullet: nil, text: line)
        }
    }

    /// Design A9 "RTL": an entry reads right to left when its first strong
    /// character does (Hebrew, Arabic, Syriac, Thaana, N'Ko and their
    /// presentation forms), like CSS `dir="auto"`. Digits and punctuation are
    /// weak and skipped; no strong character at all means left to right.
    static func isRightToLeft(_ text: String) -> Bool {
        for s in text.unicodeScalars {
            switch s.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
                if s.properties.isAlphabetic { return true }
            default:
                if s.properties.isAlphabetic { return false }
            }
        }
        return false
    }

    /// Same shape as xhisper.sh's `jq -c` line: {"time":...,"text":...}.
    static func encode(_ e: HistoryEntry) -> String {
        func quoted(_ s: String) -> String {
            let data = try! JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
            return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
        }
        return "{\"time\":\(quoted(e.time)),\"text\":\(quoted(e.text))}"
    }

    /// Replace one entry's text in place (matched on time and old text):
    /// temp file created 0600, then renamed over the history.
    @discardableResult
    static func update(_ path: String, entry: HistoryEntry, newText: String) -> Bool {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        var lines = s.components(separatedBy: "\n")
        guard let i = lines.indices.reversed().first(where: { parse(Substring(lines[$0])) == entry }) else { return false }
        lines[i] = encode(HistoryEntry(time: entry.time, text: newText))
        let tmp = path + ".tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return false }
        fchmod(fd, 0o600)
        let bytes = Array(lines.joined(separator: "\n").utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == bytes.count, rename(tmp, path) == 0 else { unlink(tmp); return false }
        return true
    }
}
