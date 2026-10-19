import Foundation

// `Xhisper media pause|play|status`: pause the Now Playing app while a
// dictation records, resume it after. The MediaRemote calls live in
// Contents/Frameworks/libXhisperMedia.dylib and run inside /usr/bin/perl (see
// macos/media/XhisperMedia.swift for why). This side only spawns perl, relays
// its one-word answer and caps it at three seconds, so a stuck media daemon can
// never hold up a recording.
enum Media {
    static let perlScript = """
    use DynaLoader;
    my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die "xhisper media: " . DynaLoader::dl_error() . "\\n";
    my $sym = DynaLoader::dl_find_symbol($lib, "xhisper_media") or die "xhisper media: no entry point\\n";
    DynaLoader::dl_install_xsub("main::xhisper_media", $sym)->();
    """

    static func main(_ args: [String]) -> Int32 {
        let command = args.first ?? "status"
        guard ["pause", "play", "status"].contains(command) else {
            FileHandle.standardError.write(Data("usage: Xhisper media pause|play|status\n".utf8))
            return 2
        }
        let library = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libXhisperMedia.dylib").path
        guard FileManager.default.fileExists(atPath: library) else {
            FileHandle.standardError.write(Data("xhisper media: \(library) is missing\n".utf8))
            return 1
        }
        let perl = Process()
        perl.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        perl.arguments = ["-e", perlScript, library]
        var environment = ProcessInfo.processInfo.environment
        environment["XHISPER_MEDIA_CMD"] = command
        perl.environment = environment
        let output = Pipe()
        perl.standardOutput = output
        perl.standardError = FileHandle.standardError
        do { try perl.run() } catch {
            FileHandle.standardError.write(Data("xhisper media: \(error)\n".utf8))
            return 1
        }
        let deadline = Date().addingTimeInterval(3)
        while perl.isRunning && Date() < deadline { usleep(5_000) }
        if perl.isRunning {
            perl.terminate()
            print("timeout")
            return 1
        }
        let answer = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        print(answer.trimmingCharacters(in: .whitespacesAndNewlines))
        return perl.terminationStatus
    }
}
