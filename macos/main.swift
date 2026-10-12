import Foundation

// Xhisper.app: the macOS side of xhisper. One binary, one subcommand per job,
// the way xhispertool dispatches on its name on Linux.
//   hotkey   Option then Control toggles dictation (LaunchAgent)
//   notify   the overlay pill            (xhisper-notify on Linux)
//   history  the dictation history window (xhisper-history on Linux)
//   ax       focused text field as JSON, for xhisper-learn
//   front    frontmost app: bundle id, name, window title
//   paste    Cmd+V into the focused app

let arguments = Array(CommandLine.arguments.dropFirst())
let subcommand = arguments.first ?? "history"  // double-clicking the app opens the history
let rest = Array(arguments.dropFirst())

func notBuiltYet() -> Int32 {
    FileHandle.standardError.write(Data("Xhisper: \(subcommand) not built yet\n".utf8))
    return 1
}

switch subcommand {
case "notify": exit(notBuiltYet())
case "history": exit(notBuiltYet())
case "hotkey": exit(notBuiltYet())
case "ax": exit(notBuiltYet())
case "front": exit(notBuiltYet())
case "paste": exit(notBuiltYet())
case "--version", "-V": print("Xhisper \(xhisperVersion)"); exit(0)
default:
    FileHandle.standardError.write(Data("usage: Xhisper hotkey|notify|history|ax|front|paste|--version\n".utf8))
    exit(1)
}
