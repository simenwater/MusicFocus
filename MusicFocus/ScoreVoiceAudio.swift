import AVFoundation
import Accelerate
import Combine
import UIKit

enum ScoreVoiceError: LocalizedError {
    case permission, unavailable, busy, cancelled
    var errorDescription: String? {
        switch self {
        case .permission: return "score.voicePermission".localized
        case .busy: return "score.voiceBusy".localized
        case .cancelled: return "score.voiceCancelled".localized
        case .unavailable: return "score.voiceUnavailable".localized
        }
    }
}

@MainActor
final class ScoreVoiceAudio: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var playing = false
    @Published private(set) var preparing = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published var error: String?
    var isBusy: Bool { recording || playing || preparing }
    let ownerID = UUID()
    private static weak var activeOwner: ScoreVoiceAudio?
    private let engine = ScoreVoiceAudioEngine()
    private weak var focus: FocusManager?
    private var generation = UUID()
    private var saveRecording: ((TimeInterval) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var loadedURL: URL?

    init() {
        observers = [AVAudioSession.interruptionNotification, UIApplication.didEnterBackgroundNotification,
                     AVAudioSession.routeChangeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                if name == AVAudioSession.interruptionNotification,
                   notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt != AVAudioSession.InterruptionType.began.rawValue { return }
                if name == AVAudioSession.routeChangeNotification,
                   notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt != AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { return }
                Task { @MainActor in await self?.stop() }
            }
        }
    }

    func bind(_ focus: FocusManager) { self.focus = focus }
    private func active(_ value: Bool) { focus?.setVoiceNoteActive(value, owner: ownerID) }

    private func begin() throws -> UUID {
        if let owner = Self.activeOwner, owner !== self, owner.isBusy { throw ScoreVoiceError.busy }
        Self.activeOwner = self
        generation = UUID(); preparing = true; error = nil
        active(true)
        return generation
    }

    func prepare(duration: TimeInterval) {
        guard !isBusy else { return }
        generation = UUID(); engine.shutdown(); loadedURL = nil
        position = 0; self.duration = max(0, duration); error = nil
    }

    func record(to url: URL, saved: @escaping (TimeInterval) -> Void) async {
        guard !recording && !preparing else { return }
        await stop()
        var operation: UUID?
        do {
            let token = try begin(); operation = token
            let granted = await AVAudioApplication.requestRecordPermission()
            guard token == generation else { return }
            guard granted else { throw ScoreVoiceError.permission }
            saveRecording = saved
            loadedURL = nil; position = 0; duration = 0
            try await engine.start(recording: url, playing: nil, update: updateHandler(token))
            guard token == generation else { return }
            preparing = false; recording = true
        } catch {
            if operation == nil { self.error = error.localizedDescription; return }
            guard operation == generation else { return }
            await stop(); self.error = error.localizedDescription
        }
    }

    func play(_ url: URL) async {
        guard !recording && !preparing else { return }
        var operation: UUID?
        do {
            let token = try begin(); operation = token
            if loadedURL == url {
                try await engine.resume(update: updateHandler(token))
            } else {
                await engine.stop()
                guard token == generation else { return }
                try await engine.start(recording: nil, playing: url, offset: position, update: updateHandler(token))
                loadedURL = url
            }
            guard token == generation else { return }
            preparing = false; playing = true
        } catch {
            if operation == nil { self.error = error.localizedDescription; return }
            guard operation == generation else { return }
            await stop(); self.error = error.localizedDescription
        }
    }
    func pause() async {
        let token = generation
        await engine.pause()
        guard token == generation else { return }
        playing = false; active(false)
    }
    func seek(_ seconds: TimeInterval) {
        guard seconds.isFinite, !recording else { return }
        position = min(duration, max(0, seconds)); engine.seek(position)
    }

    func stop() async {
        generation = UUID(); let token = generation; preparing = true
        let save = saveRecording; saveRecording = nil
        let recorded = await engine.stop()
        if let recorded, recorded > 0 { save?(recorded) }
        guard generation == token else { return }
        if recorded == nil, save != nil { error = "score.voiceUnavailable".localized }
        recording = false; playing = false; preparing = false; loadedURL = nil; level = 0
        position = 0; duration = recorded ?? 0
        active(false)
    }

    private func updateHandler(_ token: UUID) -> (ScoreVoiceAudioEngine.Status) -> Void {
        { [weak self] status in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.position = status.position; self.duration = status.duration; self.level = status.level
                if status.finished {
                    if self.recording { await self.stop() }
                    else { self.playing = false; self.active(false) }
                }
            }
        }
    }
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        engine.shutdown()
        let manager = focus, owner = ownerID
        Task { @MainActor in manager?.setVoiceNoteActive(false, owner: owner) }
    }
}

/// File I/O, codecs and session activation never run in a drawing callback or
/// on the main thread. Detection is suspended before acquiring the shared session.
final class ScoreVoiceAudioEngine: @unchecked Sendable {
    struct Status: Sendable {
        var position: TimeInterval
        var duration: TimeInterval
        var level: Float
        var finished: Bool
    }
    private let queue = DispatchQueue(label: "MusicFocus.voiceAudio", qos: .userInitiated)
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var timer: DispatchSourceTimer?
    private var sessionUse: PracticeAudioSessionUse?
    private var preparation: ScoreVoicePlaybackPreparation?
    private var playbackCopy: URL?
    private var revision = 0
    private var update: ((Status) -> Void)?
    private var expectingPlayback = false

    func start(recording url: URL?, playing playback: URL?, offset: TimeInterval = 0, update: @escaping (Status) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.revision += 1
                let revision = self.revision
                let use: PracticeAudioSessionUse = url == nil ? .voicePlayback : .voiceRecording
                PracticeAudioCapture.acquireSharedSession(for: use) { success in
                    self.queue.async {
                        guard success else { continuation.resume(throwing: ScoreVoiceError.unavailable); return }
                        guard self.revision == revision else {
                            PracticeAudioCapture.releaseSharedSession(for: use)
                            continuation.resume(throwing: ScoreVoiceError.cancelled); return
                        }
                        self.sessionUse = use
                        do {
                            if let url {
                                let recorder = try AVAudioRecorder(url: url, settings: [
                                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                    AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 192_000,
                                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                                ])
                                recorder.isMeteringEnabled = true
                                guard recorder.prepareToRecord(), recorder.record() else { throw ScoreVoiceError.unavailable }
                                self.recorder = recorder
                            } else if let playback {
                                let preparation = ScoreVoicePlaybackPreparation()
                                self.preparation = preparation
                                preparation.prepare(playback) { result in
                                    self.queue.async {
                                        guard self.revision == revision else {
                                            if case .success(let copy) = result, copy != playback { try? FileManager.default.removeItem(at: copy) }
                                            continuation.resume(throwing: ScoreVoiceError.cancelled)
                                            return
                                        }
                                        self.preparation = nil
                                        do {
                                            let playable = try result.get()
                                            if playable != playback { self.playbackCopy = playable }
                                            let player = try AVAudioPlayer(contentsOf: playable)
                                            player.volume = 1
                                            player.currentTime = offset >= player.duration-0.05 ? 0 : max(0, offset)
                                            guard player.prepareToPlay(), player.play() else { throw ScoreVoiceError.unavailable }
                                            self.player = player; self.expectingPlayback = true
                                            self.update = update
                                            self.startTimer()
                                            continuation.resume()
                                        } catch {
                                            _ = self.stopResources()
                                            continuation.resume(throwing: error)
                                        }
                                    }
                                }
                                return
                            } else {
                                throw ScoreVoiceError.unavailable
                            }
                            self.update = update
                            self.startTimer()
                            continuation.resume()
                        } catch {
                            _ = self.stopResources()
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }
    private func startTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let recorder = self.recorder {
                recorder.updateMeters()
                self.update?(.init(position: recorder.currentTime, duration: recorder.currentTime,
                                   level: pow(10, recorder.averagePower(forChannel: 0)/20), finished: !recorder.isRecording))
            } else if let player = self.player {
                let finished = self.expectingPlayback && !player.isPlaying
                if finished {
                    self.expectingPlayback = false
                    self.timer?.cancel(); self.timer = nil
                    self.releaseSession()
                }
                self.update?(.init(position: finished ? player.duration : player.currentTime,
                                   duration: player.duration, level: 0, finished: finished))
            }
        }
        self.timer = timer; timer.resume()
    }
    func pause() async { await withCheckedContinuation { done in queue.async {
        self.player?.pause(); self.expectingPlayback = false
        self.timer?.cancel(); self.timer = nil
        self.releaseSession()
        done.resume()
    } } }
    func resume(update: @escaping (Status) -> Void) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in queue.async {
            guard self.player != nil else { done.resume(throwing: ScoreVoiceError.unavailable); return }
            self.revision += 1
            let revision = self.revision
            self.releaseSession()
            PracticeAudioCapture.acquireSharedSession(for: .voicePlayback) { success in
                self.queue.async {
                    guard success else { done.resume(throwing: ScoreVoiceError.unavailable); return }
                    guard self.revision == revision, let player = self.player else {
                        PracticeAudioCapture.releaseSharedSession(for: .voicePlayback)
                        done.resume(throwing: ScoreVoiceError.cancelled); return
                    }
                    self.sessionUse = .voicePlayback
                    self.update = update
                    if player.currentTime >= player.duration-0.05 { player.currentTime = 0 }
                    self.expectingPlayback = player.play()
                    if self.expectingPlayback { self.startTimer(); done.resume() }
                    else { self.releaseSession(); done.resume(throwing: ScoreVoiceError.unavailable) }
                }
            }
        } }
    }
    func seek(_ seconds: TimeInterval) { queue.async { self.player?.currentTime = seconds } }
    @discardableResult func stop() async -> TimeInterval? {
        await withCheckedContinuation { done in queue.async { done.resume(returning: self.stopResources()) } }
    }
    private func stopResources() -> TimeInterval? {
        revision += 1; timer?.cancel(); timer = nil
        preparation?.cancel(); preparation = nil
        var duration: TimeInterval?
        if let recorder {
            let url = recorder.url
            recorder.stop()
            duration = (try? AVAudioPlayer(contentsOf: url))?.duration
        }
        recorder = nil; player?.stop(); player = nil; update = nil; expectingPlayback = false
        if let playbackCopy { try? FileManager.default.removeItem(at: playbackCopy) }
        playbackCopy = nil
        releaseSession()
        return duration
    }
    private func releaseSession() {
        guard let use = sessionUse else { return }
        sessionUse = nil
        PracticeAudioCapture.releaseSharedSession(for: use)
    }
    func shutdown() { queue.async { _ = self.stopResources() } }
}

/// Quiet takes get a bounded, constant playback gain with peak headroom.
/// Decode/write in small blocks on a separate worker, so Stop and drawing stay
/// responsive. The original AAC (and its export/backup) is never modified.
final class ScoreVoicePlaybackPreparation: @unchecked Sendable {
    private static let worker = DispatchQueue(label: "MusicFocus.voicePlaybackPreparation", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw ScoreVoiceError.cancelled }
    }
    func prepare(_ source: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        Self.worker.async {
            do { completion(.success(try self.prepareFile(source))) }
            catch {
                // A full temporary disk must not prevent the original from playing.
                do { try self.checkCancellation(); completion(.success(source)) }
                catch { completion(.failure(error)) }
            }
        }
    }
    static func gain(peak: Float, rms: Float) -> Float {
        guard peak.isFinite, rms.isFinite, peak > 0.001, rms > 0.0001 else { return 1 }
        return max(1, min(pow(10, 24.0/20), pow(10, -22.0/20)/rms, pow(10, -1.0/20)/peak))
    }
    func prepareFile(_ source: URL) throws -> URL {
        try checkCancellation()
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384),
              let channels = buffer.floatChannelData else { return source }
        var peak: Float = 0
        var energy: Double = 0
        var count: Double = 0
        while input.framePosition < input.length {
            try checkCancellation()
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            let length = vDSP_Length(buffer.frameLength)
            for channel in 0..<Int(format.channelCount) {
                var maximum: Float = 0, squares: Float = 0
                vDSP_maxmgv(channels[channel], 1, &maximum, length)
                vDSP_svesq(channels[channel], 1, &squares, length)
                peak = max(peak, maximum); energy += Double(squares); count += Double(length)
            }
        }
        var gain = Self.gain(peak: peak, rms: count > 0 ? Float(sqrt(energy/count)) : 0)
        guard gain > 1.05 else { return source }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("MusicFocus-VoicePlayback-\(UUID()).caf")
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: copy) } }
        let output = try AVAudioFile(forWriting: copy, settings: format.settings)
        input.framePosition = 0
        while input.framePosition < input.length {
            try checkCancellation()
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            for channel in 0..<Int(format.channelCount) {
                vDSP_vsmul(channels[channel], 1, &gain, channels[channel], 1, vDSP_Length(buffer.frameLength))
            }
            try output.write(from: buffer)
        }
        try checkCancellation()
        completed = true
        return copy
    }
}
