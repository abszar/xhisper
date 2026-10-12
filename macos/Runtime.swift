import Foundation
import Darwin

// Shared plumbing for every Xhisper subcommand. Foundation/Darwin only: this
// file is also compiled into the selftest (make check).

let xhisperVersion = "1.4"

enum Runtime {
    /// Same rule as xhisper.sh: $XHISPER_RUNTIME_DIR, else $XDG_RUNTIME_DIR/xhisper,
    /// else the per-user temp dir (macOS has no XDG_RUNTIME_DIR). Private (0700):
    /// it holds the recording, the log and the LLM request body.
    static let dir: String = {
        let env = ProcessInfo.processInfo.environment
        var path: String
        if let d = env["XHISPER_RUNTIME_DIR"], !d.isEmpty {
            path = d
        } else if let x = env["XDG_RUNTIME_DIR"], !x.isEmpty {
            path = x + "/xhisper"
        } else {
            path = (darwinUserTempDir() as NSString).appendingPathComponent("xhisper")
        }
        mkdir(path, 0o700)
        if access(path, W_OK) != 0 {
            path = NSHomeDirectory() + "/.cache/xhisper"
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        chmod(path, 0o700)
        return path
    }()

    static func path(_ name: String) -> String { dir + "/" + name }

    static func darwinUserTempDir() -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count) > 0 { return String(cString: buf) }
        return NSTemporaryDirectory()
    }
}

/// First number in a pid file ("PID" or xhisper.pid's "PID EPOCH").
func readPid(_ file: String) -> pid_t? {
    guard let s = try? String(contentsOfFile: file, encoding: .utf8),
          let first = s.split(whereSeparator: { $0 == " " || $0 == "\n" }).first else { return nil }
    return pid_t(first)
}

func writePid(_ file: String) {
    try? "\(getpid())".write(toFile: file, atomically: false, encoding: .utf8)
}

func isAlive(_ pid: pid_t) -> Bool { pid > 0 && kill(pid, 0) == 0 }

/// Process start time in seconds since the epoch (kinfo_proc.p_starttime).
func startTime(_ pid: pid_t) -> Double? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let tv = info.kp_proc.p_un.__p_starttime
    return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
}

/// argv of a process (KERN_PROCARGS2), or [] when unreadable.
func processArgs(_ pid: pid_t) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
    let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
    var i = 4
    while i < size && buf[i] != 0 { i += 1 }  // executable path
    while i < size && buf[i] == 0 { i += 1 }  // padding
    var args: [String] = []
    while args.count < argc && i < size {
        let start = i
        while i < size && buf[i] != 0 { i += 1 }
        args.append(String(decoding: buf[start..<i], as: UTF8.self))
        i += 1
    }
    return args
}

/// Every process of the current user.
func userProcessIDs() -> [pid_t] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
    let stride = MemoryLayout<kinfo_proc>.stride
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
    size = procs.count * stride
    guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
    return procs.prefix(size / stride).map { $0.kp_proc.p_pid }
}

/// Fire-and-forget launch: own session, stdio on /dev/null, PATH lookup.
@discardableResult
func spawnDetached(_ argv: [String]) -> pid_t? {
    guard !argv.isEmpty else { return nil }
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    defer { cargs.forEach { free($0) } }
    var pid: pid_t = 0
    return posix_spawnp(&pid, argv[0], &actions, &attr, &cargs, environ) == 0 ? pid : nil
}

/// One "[HH:mm:ss] message" line appended to a private log file.
func appendLine(_ file: String, _ message: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    let line = "[\(f.string(from: Date()))] \(message)\n"
    let fd = open(file, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    guard fd >= 0 else { return }
    _ = line.withCString { write(fd, $0, strlen($0)) }
    close(fd)
}

/// Accessibility reports the caret in UTF-16 units; Python indexes code
/// points. Converts one to the other, clamped to the end of the string.
func scalarOffset(_ s: String, utf16 offset: Int) -> Int {
    guard offset >= 0 else { return -1 }
    let units = Array(s.utf16.prefix(offset))
    return String(decoding: units, as: UTF16.self).unicodeScalars.count
}

/// Web content (Chrome, Electron) reports the caret on an empty last line just
/// before the newline that opened it; the caret is really after it.
func webCaretOnEmptyLastLine(_ caret: Int, selection: Int, utf16: [UInt16], isWeb: Bool) -> Int {
    guard isWeb, selection == 0, caret >= 0, caret == utf16.count - 1, utf16[caret] == 10 else { return caret }
    return caret + 1
}
