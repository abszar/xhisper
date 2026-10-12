import Foundation

// Live level meter for the recording pill, same algorithm as xhisper-notify:
// read the newest 50 ms of the WAV that rec is writing (16-bit mono 16 kHz),
// normalise between a tracked noise floor and a decaying speech peak.
let levelWindowBytes = 1600     // last 50 ms of audio
let levelPushSeconds = 0.045    // one new bar value per ~45 ms, scrolling left
let levelMinSpanDB = 18.0       // quietest dynamic range stretched to full height

/// RMS of little-endian 16-bit samples in dBFS, nil without samples.
func rmsDB(_ data: Data) -> Double? {
    let n = data.count / 2
    guard n > 0 else { return nil }
    var sum = 0.0
    data.withUnsafeBytes { raw in
        for i in 0..<n {
            let s = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)))
            sum += s * s
        }
    }
    return 20 * log10(max((sum / Double(n)).squareRoot(), 1.0) / 32768)
}

/// Level of the newest audio in the recording, nil until it holds any.
func readTailDB(path: String) -> Double? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    guard let size = try? fh.seekToEnd(), size >= UInt64(44 + levelWindowBytes) else { return nil }
    let offset = max(UInt64(44), (size - UInt64(levelWindowBytes)) & ~UInt64(1))
    guard (try? fh.seek(toOffset: offset)) != nil,
          let data = try? fh.read(upToCount: levelWindowBytes) else { return nil }
    return rmsDB(data.prefix(data.count & ~1))
}

struct LevelMeter {
    private(set) var levels: [Double]
    private(set) var level = 0.0
    private var noiseFloor: Double?
    private var peakDB = 0.0

    init(bars: Int) { levels = Array(repeating: 0, count: bars) }

    /// Push one bar value, normalised so any mic gain fills the pill.
    mutating func push(db: Double) {
        if noiseFloor == nil { noiseFloor = db; peakDB = db + levelMinSpanDB }
        // Floor follows quiet passages down at once and creeps up slowly;
        // the peak jumps up with speech and decays about 7 dB per second.
        let floor = min(db, noiseFloor! + 0.05)
        noiseFloor = floor
        peakDB = max(db, peakDB - 0.3)
        let span = max(peakDB - floor, levelMinSpanDB)
        let target = min(1.0, max(0.0, (db - floor - 3) / span))
        // Fast attack, softer release, so syllables pop and pauses settle.
        level += (target - level) * (target > level ? 0.7 : 0.35)
        levels = Array(levels.dropFirst()) + [level]
    }
}
