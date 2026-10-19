import Foundation

// Pause and resume whatever macOS shows as Now Playing (a YouTube tab, Music,
// Spotify, a podcast...), so a dictation does not talk over a video.
//
// This is built as a separate dylib, libXhisperMedia.dylib, and never linked
// into Xhisper itself: since macOS 15.4 the private MediaRemote framework
// answers only processes with an Apple entitlement, and the only way for a
// third-party program to use it is to run inside an Apple-signed host. So
// `Xhisper media` runs /usr/bin/perl, which loads this library through
// DynaLoader and calls xhisper_media() (a perl XSUB: two pointers it ignores).
// The command comes in through XHISPER_MEDIA_CMD, the answer goes to stdout:
//   pause  -> "paused" (it was playing and is paused now), "idle" (nothing
//             playing) or "unconfirmed" (sent twice, state never changed)
//   play   -> "played" or "unconfirmed"
//   status -> "playing" or "paused"
// Only the playback state is read, never the title, so nothing about what was
// playing is logged.

private typealias IsPlayingFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
private typealias SendCommandFn = @convention(c) (Int32, CFDictionary?) -> Bool

private let commandPlay: Int32 = 0
private let commandPause: Int32 = 2

private func finish(_ text: String, _ code: Int32) -> Never {
    print(text)
    fflush(stdout)
    exit(code)
}

@_cdecl("xhisper_media")
public func xhisperMedia(_ perl: UnsafeMutableRawPointer?, _ cv: UnsafeMutableRawPointer?) {
    let command = ProcessInfo.processInfo.environment["XHISPER_MEDIA_CMD"] ?? "status"
    guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
          let isPlayingSymbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying"),
          let sendSymbol = dlsym(handle, "MRMediaRemoteSendCommand") else {
        finish("unavailable", 1)
    }
    let isPlaying = unsafeBitCast(isPlayingSymbol, to: IsPlayingFn.self)
    let send = unsafeBitCast(sendSymbol, to: SendCommandFn.self)

    func currentlyPlaying(timeout: Double) -> Bool? {
        let answered = DispatchSemaphore(value: 0)
        var playing = false
        isPlaying(DispatchQueue.global()) { state in
            playing = state
            answered.signal()
        }
        return answered.wait(timeout: .now() + timeout) == .success ? playing : nil
    }
    guard let playing = currentlyPlaying(timeout: 1.0) else { finish("unavailable", 1) }

    // MRMediaRemoteSendCommand only queues the command for mediaremoted: a
    // process that exits right after it loses about one command in four
    // (2026-10-19: the video kept playing, or never came back). So stay until
    // the player really is in the wanted state, ~150 ms, and send it once more
    // if it is not there after 0.5 s.
    func sendAndConfirm(_ command: Int32, wantPlaying: Bool) -> Bool {
        for _ in 0..<2 {
            _ = send(command, nil)
            for _ in 0..<10 {
                usleep(50_000)
                if currentlyPlaying(timeout: 0.2) == wantPlaying { return true }
            }
        }
        return false
    }

    switch command {
    case "pause":
        guard playing else { finish("idle", 0) }
        finish(sendAndConfirm(commandPause, wantPlaying: false) ? "paused" : "unconfirmed", 0)
    case "play":
        if playing { finish("played", 0) }
        finish(sendAndConfirm(commandPlay, wantPlaying: true) ? "played" : "unconfirmed", 0)
    default:
        finish(playing ? "playing" : "paused", 0)
    }
}
