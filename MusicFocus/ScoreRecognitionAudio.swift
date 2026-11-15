#if MUSICFOCUS_HOMR
import AVFoundation

/// Offline rendering never acquires the shared microphone/speaker session.
/// AAC results are small and play through the existing audition safety gate.
enum ScoreRecognitionAudio {
    struct Result { var piano: Data; var clicks: Data; var duration: Double }
    struct Event: Equatable { var frame: Int64; var midi: UInt8; var on: Bool }
    static func render(_ notes: [ScoreRecognizedNote], beats: Double, tempo: Double) throws -> Result {
        let sampleRate = 22_050.0, secondsPerBeat = 60 / tempo
        let frames = Int64(ceil((beats * secondsPerBeat + 0.45) * sampleRate))
        guard frames > 0, frames < Int64(sampleRate * 601) else { throw ScoreAuditionError.invalid }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let engine = AVAudioEngine(), sampler = AVAudioUnitSampler()
        engine.attach(sampler); engine.connect(sampler, to: engine.mainMixerNode, format: format)
        try sampler.loadSoundBankInstrument(at: ScoreRecognitionModels.resource("YDP-GrandPiano.sf2"), program: 0, bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: 0)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        engine.mainMixerNode.outputVolume = 0.7
        engine.prepare(); try engine.start()
        defer { engine.stop(); engine.disableManualRenderingMode() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audition-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pianoURL = root.appendingPathComponent("piano.m4a"), clicksURL = root.appendingPathComponent("clicks.m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 96_000]
        var pianoFile: AVAudioFile? = try AVAudioFile(forWriting: pianoURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var clickFile: AVAudioFile? = try AVAudioFile(forWriting: clicksURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 1024)!
        let events = scheduledEvents(notes, sampleRate: sampleRate, secondsPerBeat: secondsPerBeat)
        var eventIndex = 0, cursor: Int64 = 0, noProgress = 0, active: [UInt8: Int] = [:]
        let click = try clickSamples(sampleRate: sampleRate)
        while cursor < frames {
            try Task.checkCancellation()
            while eventIndex < events.count, events[eventIndex].frame <= cursor {
                let event = events[eventIndex]
                if event.on {
                    active[event.midi, default: 0] += 1
                    sampler.startNote(event.midi, withVelocity: 82, onChannel: 0)
                } else {
                    active[event.midi] = max(0, (active[event.midi] ?? 0) - 1)
                    if active[event.midi] == 0 { sampler.stopNote(event.midi, onChannel: 0) }
                }
                eventIndex += 1
            }
            let next = eventIndex < events.count ? events[eventIndex].frame : frames
            let count = AVAudioFrameCount(max(1, min(1024, min(frames - cursor, next - cursor))))
            try autoreleasepool {
            let status = try engine.renderOffline(count, to: buffer)
            if status == .success {
                noProgress = 0
                try pianoFile!.write(from: buffer)
                if let channels = buffer.floatChannelData {
                    for i in 0..<Int(buffer.frameLength) {
                        let frame = cursor + Int64(i), beat = Double(frame) / (secondsPerBeat * sampleRate)
                        let beatNumber = floor(beat)
                        let offset = Int(Double(frame) - (beatNumber * secondsPerBeat * sampleRate).rounded())
                        if beatNumber < beats, offset >= 0, offset < click.count {
                            for c in 0..<2 { channels[c][i] = max(-1, min(1, channels[c][i] + click[offset] * 0.3)) }
                        }
                    }
                }
                try clickFile!.write(from: buffer); cursor += Int64(buffer.frameLength)
            } else {
                noProgress += 1
                guard noProgress < 100, status != .error else { throw ScoreAuditionError.invalid }
            }
            }
        }
        // Close encoders before reading their trailers.
        pianoFile = nil; clickFile = nil
        return .init(piano: try Data(contentsOf: pianoURL), clicks: try Data(contentsOf: clicksURL), duration: Double(frames) / sampleRate)
    }
    static func scheduledEvents(_ notes: [ScoreRecognizedNote], sampleRate: Double, secondsPerBeat: Double) -> [Event] {
        var events: [Event] = []
        for note in notes {
            let start = Int64((note.beat * secondsPerBeat * sampleRate).rounded())
            let release = (note.tieRelease ?? note.duration) * 0.06
            let end = Int64(((note.beat + note.duration - release) * secondsPerBeat * sampleRate).rounded())
            events.append(.init(frame: start, midi: UInt8(note.midi), on: true))
            events.append(.init(frame: max(start + 1, end), midi: UInt8(note.midi), on: false))
        }
        events.sort { $0.frame == $1.frame ? (!$0.on && $1.on) : $0.frame < $1.frame }
        return events
    }
    private static func clickSamples(sampleRate: Double) throws -> [Float] {
        guard let url = Bundle.main.url(forResource: "MetronomeMechanical", withExtension: "wav") else { throw ScoreAuditionError.invalid }
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        guard let values = buffer.floatChannelData?[0] else { throw ScoreAuditionError.invalid }
        let ratio = file.processingFormat.sampleRate / sampleRate
        return (0..<Int(Double(buffer.frameLength) / ratio)).map { values[min(Int(Double($0) * ratio), Int(buffer.frameLength) - 1)] }
    }
}
#endif
