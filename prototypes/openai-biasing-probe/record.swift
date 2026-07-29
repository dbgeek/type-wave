// Record the A/B corpus in a human voice (wayfinder ticket #313, map #310).
//
// Prompts one line at a time and writes <id>.wav (mono, 24 kHz, 16-bit LE) -- exactly
// the format ab.py replays -- so the real-voice pass differs from the `say` pass in the
// audio and nothing else.
//
//   swift prototypes/openai-biasing-probe/record.swift <corpus.json> <outdir>
//
// corpus.json comes from:  python3 prototypes/openai-biasing-probe/ab.py corpus
// Hold nothing: press Return to start a clip, Return again to stop. `r` re-records the
// line you just did; `q` quits early (clips already written are kept).

import AVFoundation
import Foundation

struct Line: Decodable { let id: String; let say: String }

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: record.swift <corpus.json> <outdir>\n".data(using: .utf8)!)
    exit(2)
}
let lines = try JSONDecoder().decode([Line].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let settings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatLinearPCM),
    AVSampleRateKey: 24000.0,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsBigEndianKey: false,
    AVLinearPCMIsFloatKey: false,
]

// Ask once, up front: the TCC prompt should land before the user is mid-sentence.
let gate = DispatchSemaphore(value: 0)
var granted = false
AVCaptureDevice.requestAccess(for: .audio) { ok in granted = ok; gate.signal() }
gate.wait()
guard granted else {
    FileHandle.standardError.write("microphone access denied -- grant it to this terminal in System Settings > Privacy & Security > Microphone\n".data(using: .utf8)!)
    exit(1)
}

func prompt(_ s: String) -> String {
    print(s, terminator: "")
    return readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? "q"
}

print("\nRecording \(lines.count) lines to \(outDir.path)")
print("Read each line ALOUD AS WRITTEN -- say \"whisper dot C P P\", not \"whisper cpp\".")
print("Speak at your normal dictation pace, into your normal dictation mic.\n")

var i = 0
while i < lines.count {
    let line = lines[i]
    let url = outDir.appendingPathComponent("\(line.id).wav")
    print("── \(line.id)  (\(i + 1)/\(lines.count))")
    print("   \"\(line.say)\"")
    if prompt("   Return to start (q to quit): ") == "q" { break }

    let rec = try AVAudioRecorder(url: url, settings: settings)
    guard rec.record() else {
        FileHandle.standardError.write("failed to start recorder\n".data(using: .utf8)!)
        exit(1)
    }
    print("   ● recording…", terminator: "")
    let after = prompt(" Return to stop: ")
    rec.stop()
    let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("   ✓ \(line.id).wav  \(String(format: "%.1f", Double(bytes) / 48000.0))s\n")
    if after == "r" { continue }  // same index again
    i += 1
}
print("done — \(outDir.path)")
