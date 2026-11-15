#if DEBUG && targetEnvironment(simulator)
import Foundation
import AVFoundation

/// Opt-in simulator diagnostics. Writes scores and run-loop timing locally,
/// without recording audio or publishing any additional UI state.
final class PracticeDiagnostics {
    private let writer = DispatchQueue(label: "MusicFocus.diagnostics", qos: .utility)
    private let file: URL
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?
    private var active = true
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var lastSummary = ProcessInfo.processInfo.systemUptime
    private var gaps: [Double] = []

    static func startIfRequested(configuration: PracticeDetectionConfiguration,
                                 silenceConfirmationDelay: TimeInterval) -> PracticeDiagnostics? {
        guard ProcessInfo.processInfo.environment["MUSICFOCUS_DIAGNOSTICS"] == "1" else { return nil }
        return PracticeDiagnostics(configuration: configuration, silenceConfirmationDelay: silenceConfirmationDelay)
    }

    private init(configuration: PracticeDetectionConfiguration, silenceConfirmationDelay: TimeInterval) {
        file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PracticeDiagnostics")
            .appendingPathComponent(UUID().uuidString + ".jsonl")
        record(["event": "start", "date": ISO8601DateFormatter().string(from: Date()),
                "timingMode": "immediate-accounting-delayed-silence-segment",
                "silenceConfirmationDelay": silenceConfirmationDelay,
                "practiceMode": configuration.mode.rawValue,
                "instrumentConfidence": configuration.instrumentConfidence,
                "voiceConfidence": configuration.voiceConfidence])
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        print("Practice diagnostics: \(file.path)")
    }

    func captureReady() {
        let session = AVAudioSession.sharedInstance()
        record(["event": "captureReady", "sampleRate": session.sampleRate,
                "inputs": session.currentRoute.inputs.map(\.portName)])
    }

    func receive(_ update: PracticeDetectionUpdate, segmentation: PracticeSilenceSegmentation.State) {
        record(["event": "analysis", "audioTime": update.endTime,
                "duration": update.evaluatedDuration, "dbFS": update.decibels,
                "instrument": update.scores.instrument, "music": update.scores.music,
                "voice": update.scores.voice, "noise": update.scores.noise,
                "silence": update.scores.silence,
                "drone": update.scores.drone, "otherInstrument": update.scores.otherInstrument, "percussion": update.scores.percussion,
                "synthesizer": update.scores.synthesizer, "keyboard": update.scores.keyboard,
                "specificInstrument": update.scores.specificInstrument,
                "instrumentLabels": update.scores.instrumentClassifications,
                "singing": update.scores.singing, "spokenVoice": update.scores.spokenVoice,
                "yamSinging": update.acoustics.vocalProbability,
                "yamSpeech": update.acoustics.vocalSpeechProbability,
                "yamMusic": update.acoustics.vocalMusicProbability,
                "vocalInferenceMS": update.acoustics.vocalInferenceMS,
                "speechActivity": update.acoustics.speechProbability,
                          "speechPeak": update.acoustics.speechPeakProbability,
                "speechInputDBFS": update.acoustics.analyzedDBFS,
                "resampledThroughTime": update.acoustics.resampledThroughTime,
                "mainsHumRatio": update.acoustics.mainsHumRatio,
                          "mainsHarmonicRatio": update.acoustics.mainsHarmonicRatio,
                "spectralFlatness": update.acoustics.spectralFlatness,
                "strongestBinShare": update.acoustics.strongestBinShare,
                "evidence": update.evidence.rawValue, "practicing": update.isPracticing,
                "segmentActive": segmentation.isActive, "waitingForSilence": segmentation.isWaitingForSilence])
    }

    func stop() {
        guard active else { return }
        record(["event": "stop"])
        active = false
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        gaps.append(max(0, (now - lastTick - 0.1) * 1000))
        lastTick = now
        if now - lastSummary >= 1 {
            let sorted = gaps.sorted()
            record(["event": "mainRunLoop", "samples": sorted.count,
                    "p95DelayMS": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
                    "maxDelayMS": sorted.last ?? 0])
            gaps.removeAll(keepingCapacity: true)
            lastSummary = now
        }
        // Bound collection even if a test session is accidentally left running.
        if now - startedAt >= 300 { stop() }
    }

    private func record(_ values: [String: Any]) {
        guard active else { return }
        var row = values
        row["elapsed"] = ProcessInfo.processInfo.systemUptime - startedAt
        row["unixTime"] = Date().timeIntervalSince1970
        guard var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        let line = data
        let file = file
        writer.async {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: file.path) {
                    FileManager.default.createFile(atPath: file.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                print("Practice diagnostics write failed: \(error.localizedDescription)")
            }
        }
    }

    deinit { timer?.invalidate() }
}
/// Explicitly enabled fixture capture for controlled speaker/microphone tests.
/// Never compiled into device builds. Ordinary score diagnostics do not enable
/// recording. The live detector's worker owns this file; no main/audio-thread IO.
final class PracticeMicrophoneFixtureWriter {
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private var disabled = false
    private let enabled = ProcessInfo.processInfo.environment["MUSICFOCUS_CAPTURE_FIXTURE"] == "1"

    func append(_ buffer: AVAudioPCMBuffer) {
        guard enabled, !disabled else { return }
        do {
            if file == nil {
                let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("PracticeMicrophoneFixtures")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent(UUID().uuidString + ".caf")
                file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
                let metadata: [String: Any] = [
                    "purpose": "Local controlled acoustic regression; explicitly enabled simulator-only recording",
                    "estimatedStartUnix": Date().timeIntervalSince1970 - Double(buffer.frameLength) / buffer.format.sampleRate,
                    "sampleRate": buffer.format.sampleRate, "maximumSeconds": 180]
                try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
                    .write(to: url.deletingPathExtension().appendingPathExtension("json"))
                print("Local microphone test fixture: \(url.path)")
            }
            let limit = AVAudioFramePosition(buffer.format.sampleRate * 180)
            let length = min(AVAudioFramePosition(buffer.frameLength), limit - frames)
            if length > 0 {
                let originalLength = buffer.frameLength
                buffer.frameLength = AVAudioFrameCount(length)
                defer { buffer.frameLength = originalLength }
                try file?.write(from: buffer)
                frames += length
            }
            if frames >= limit { file = nil; disabled = true }
        } catch {
            // Optional fixture recording cannot break the actual detector.
            file = nil
            disabled = true
            print("Microphone fixture capture failed: \(error.localizedDescription)")
        }
    }

    func stop() { file = nil; disabled = true }
}
#endif
