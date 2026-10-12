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

    /// "Today 14:03", "Yesterday 09:00", else "01 Oct 08:05" (as xhisper-history).
    static func describe(_ stamp: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        guard let when = parser.date(from: stamp) else { return stamp }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.timeZone = calendar.timeZone
        out.dateFormat = "HH:mm"
        let clock = out.string(from: when)
        if calendar.isDate(when, inSameDayAs: now) { return "Today " + clock }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(when, inSameDayAs: yesterday) {
            return "Yesterday " + clock
        }
        out.dateFormat = "dd MMM HH:mm"
        return out.string(from: when)
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
