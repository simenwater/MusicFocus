#if DEBUG || MUSICFOCUS_HOMR
import AVFoundation
import Combine
import UIKit

/// All decoding and audio-session work is serialized off the drawing thread.
final class ScoreAuditionAudio: @unchecked Sendable {
    struct Status: Sendable { var time: Double; var playing: Bool }
    private let queue = DispatchQueue(label: "MusicFocus.scoreAudition", qos: .userInitiated)
    private var player: AVAudioPlayer?
    private var timer: DispatchSourceTimer?
    private var hasSession = false
    private var temporaryAudio: URL?
    private let preparationLock = NSLock()
    private var preparationEpoch = 0
    func cancelPreparation() { preparationLock.lock(); preparationEpoch += 1; preparationLock.unlock() }
    private func currentEpoch() -> Int { preparationLock.lock(); defer { preparationLock.unlock() }; return preparationEpoch }

    func start(data: Data, duration: Double, time: Double, rate: Double,
               loop: ScoreAuditionLoop? = nil,
               update: @escaping @Sendable (Status) -> Void) async throws {
        let epoch = currentEpoch()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.stopResources()
                guard epoch == self.currentEpoch() else { continuation.resume(throwing: CancellationError()); return }
                PracticeAudioCapture.acquireSharedSession(for: .voicePlayback) { acquired in
                    self.queue.async {
                        guard acquired else { continuation.resume(throwing: ScoreAuditionError.invalid); return }
                        self.hasSession = true
                        do {
                            let player: AVAudioPlayer
                            if let loop {
                                guard loop.isValid(for: duration) else { throw ScoreAuditionError.invalid }
                                player = try self.loopPlayer(data: data, duration: duration, loop: loop, epoch: epoch)
                                player.numberOfLoops = -1
                            } else { player = try AVAudioPlayer(data: data) }
                            guard player.duration.isFinite, abs(player.duration - (loop?.duration ?? duration)) < 0.35 else { throw ScoreAuditionError.invalid }
                            player.enableRate = true; player.rate = Float(rate); player.volume = 1
                            player.currentTime = min(max(0, time - (loop?.start ?? 0)), player.duration)
                            guard epoch == self.currentEpoch() else { throw CancellationError() }
                            guard player.prepareToPlay(), player.play() else { throw ScoreAuditionError.invalid }
                            self.player = player
                            let timer = DispatchSource.makeTimerSource(queue: self.queue)
                            timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(5))
                            timer.setEventHandler { [weak engine = self] in
                                guard let engine, let player = engine.player else { return }
                                let playing = player.isPlaying
                                update(.init(time: playing ? player.currentTime + (loop?.start ?? 0) : duration, playing: playing))
                                if !playing { engine.stopResources() }
                            }
                            self.timer = timer; timer.resume()
                            continuation.resume()
                        } catch {
                            self.stopResources(); continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }

    func setRate(_ rate: Double) { queue.async { self.player?.rate = Float(rate) } }
    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { self.stopResources(); continuation.resume() }
        }
    }
    func shutdown() { cancelPreparation(); queue.async { self.stopResources() } }
    private func stopResources() {
        timer?.cancel(); timer = nil
        player?.stop(); player = nil
        if let directory = temporaryAudio { try? FileManager.default.removeItem(at: directory); temporaryAudio = nil }
        if hasSession { hasSession = false; PracticeAudioCapture.releaseSharedSession(for: .voicePlayback) }
    }

    /// Decode just the selected range to PCM. AVAudioPlayer repeats this file
    /// in its audio clock; the UI timer never performs the loop jump.
    private func loopPlayer(data: Data, duration: Double, loop: ScoreAuditionLoop, epoch: Int) throws -> AVAudioPlayer {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audition-loop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryAudio = root
        let source = root.appendingPathComponent("source.audio"), clip = root.appendingPathComponent("loop.caf")
        try data.write(to: source)
        let input = try AVAudioFile(forReading: source)
        let rate = input.processingFormat.sampleRate
        guard abs(Double(input.length) / rate - duration) < 0.35 else { throw ScoreAuditionError.invalid }
        let start = AVAudioFramePosition((loop.start * rate).rounded())
        let end = min(input.length, AVAudioFramePosition((loop.end * rate).rounded()))
        guard start >= 0, end > start else { throw ScoreAuditionError.invalid }
        input.framePosition = start
        var output: AVAudioFile? = try AVAudioFile(forWriting: clip, settings: input.processingFormat.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096)!
        let total = end - start, fade = min(Int64(rate * 0.002), total / 4)
        var written: Int64 = 0
        while written < total {
            guard epoch == currentEpoch() else { throw CancellationError() }
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, total - written)))
            guard buffer.frameLength > 0 else { throw ScoreAuditionError.invalid }
            if let channels = buffer.floatChannelData, fade > 0 {
                for i in 0..<Int(buffer.frameLength) {
                    let offset = written + Int64(i)
                    let gain = Float(min(1, min(Double(offset) / Double(fade), Double(total - 1 - offset) / Double(fade))))
                    for channel in 0..<Int(buffer.format.channelCount) { channels[channel][i] *= gain }
                }
            }
            try output!.write(from: buffer); written += Int64(buffer.frameLength)
        }
        output = nil
        return try AVAudioPlayer(contentsOf: clip)
    }
}

@MainActor
final class ScoreAuditionPlayer: ObservableObject {
    @Published private(set) var package: ScoreAuditionPackage?
    @Published private(set) var playing = false
    @Published private(set) var preparing = false
    @Published private(set) var scrubbing = false
    @Published private(set) var seekRevision = 0
    @Published private(set) var completionRevision = 0
    @Published private(set) var position = 0.0
    @Published private(set) var rate = 1.0
    @Published private(set) var clicks = false
    @Published private(set) var loop: ScoreAuditionLoop?
    @Published private(set) var loopEnabled = false
    @Published private(set) var selectingLoop = false
    @Published private(set) var loopAnchor: ScoreAuditionPackage.Cue?
    @Published var error: String?
    private(set) var packageRevision = 0
    /// The overlay reads this lightweight snapshot without publishing PDF state.
    private(set) var visualTime = 0.0
    private(set) var visualUpdatedAt = CACurrentMediaTime()
    private let audio = ScoreAuditionAudio()
    private weak var focus: FocusManager?
    private weak var voice: ScoreVoiceAudio?
    private let owner = UUID()
    private var token = UUID()
    private var lastPublication = 0.0
    private var resumeAfterScrubbing = false
    private var pendingPackage: ScoreAuditionPackage?
    private var voiceSubscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    /// Serializes starts/stops including asynchronous session acquisition.
    private var operation: Task<Void, Never>?
    private func trace(_ event: String) {
        if ProcessInfo.processInfo.arguments.contains("-audition-trace") {
            let line = "AUDITION \(event) pos=\(position) playing=\(playing) preparing=\(preparing) scrub=\(scrubbing) resume=\(resumeAfterScrubbing) loop=\(loopEnabled)\n"
            let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("audition-trace.txt")
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            if let handle = try? FileHandle(forWritingTo: url) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)); try? handle.close() }
        }
    }

    init() {
        observers = [UIApplication.didEnterBackgroundNotification, AVAudioSession.interruptionNotification,
                     AVAudioSession.routeChangeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if name == AVAudioSession.interruptionNotification,
                   note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt != AVAudioSession.InterruptionType.began.rawValue { return }
                if name == AVAudioSession.routeChangeNotification,
                   note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt != AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { return }
                Task { @MainActor in self?.pause() }
            }
        }
    }

    func bind(focus: FocusManager, voice: ScoreVoiceAudio) {
        self.focus = focus; self.voice = voice
        voiceSubscription = voice.objectWillChange.sink { [weak self, weak voice] _ in
            Task { @MainActor in if voice?.isBusy == true { self?.pause() } }
        }
    }

    func load(_ package: ScoreAuditionPackage) {
        pendingPackage = nil
        packageRevision += 1
        pause(); self.package = package; position = 0; visualTime = 0; clicks = false; error = nil
        loop = nil; loopEnabled = false; selectingLoop = false; loopAnchor = nil
    }
    func unload() {
        pause(); package = nil; pendingPackage = nil; packageRevision += 1
        loop = nil; loopEnabled = false; cancelLoopSelection()
    }

    func play() {
        trace("play")
        if !playing, !preparing, !scrubbing, loop == nil, !selectingLoop, let prepared = pendingPackage {
            offer(prepared, page: package?.cues.last(where: { $0.time <= position })?.page ?? prepared.cues.first?.page ?? 1)
        }
        guard let package, !playing, !preparing, !scrubbing else { return }
        guard voice?.isBusy != true else { error = ScoreAuditionError.busy.localizedDescription; return }
        Metronome.shared.stop()
        let previous = operation
        let current = UUID(); token = current
        if let loop, loopEnabled, !loop.contains(position) { position = loop.start }
        else if position >= package.duration - 0.05 { position = 0 }
        let start = position, data = clicks ? (package.audioWithClicks ?? package.audio) : package.audio
        let activeLoop = loopEnabled ? loop : nil
        preparing = true; error = nil
        focus?.setVoiceNoteActive(true, owner: owner)
        operation = Task { [weak self] in
            await previous?.value
            guard let self, self.token == current else { return }
            do {
                try await self.audio.start(data: data, duration: package.duration, time: start, rate: self.rate, loop: activeLoop) { [weak self] status in
                    Task { @MainActor in self?.receive(status, token: current) }
                }
                guard self.token == current else { return }
                self.audio.setRate(self.rate)
                self.preparing = false; self.playing = true
            } catch {
                guard self.token == current else { return }
                self.preparing = false; self.playing = false
                self.trace("audio error \(error)")
                self.focus?.setVoiceNoteActive(false, owner: self.owner)
                self.error = error.localizedDescription
            }
        }
    }

    /// Longer prepared previews replace a paused timeline only. Keep the same
    /// printed note and occurrence when earlier pages/repeats change its time.
    func offer(_ prepared: ScoreAuditionPackage, page: Int) {
        guard prepared.sourceSHA256 == package?.sourceSHA256 || package == nil else { return }
        if playing || preparing || scrubbing || loop != nil || selectingLoop { pendingPackage = prepared; return }
        let old = package, time = position, oldRate = rate, oldClicks = clicks
        let anchor = old?.cues.last { $0.time <= time && $0.page == page }
        var target = prepared.cues.first(where: { $0.page == page }).flatMap { cue in prepared.bars?.first(where: { $0.measure == cue.measure })?.start } ?? 0
        if let anchor {
            func matches(_ cue: ScoreAuditionPackage.Cue) -> Bool {
                cue.page == anchor.page && cue.staff == anchor.staff && abs(cue.x - anchor.x) < 0.1 && abs(cue.y - anchor.y) < 0.1
            }
            let count = old?.cues.filter { matches($0) && $0.time <= anchor.time }.count ?? 1
            let candidates = prepared.cues.filter(matches)
            if !candidates.isEmpty {
                let cue = candidates[min(max(0, count - 1), candidates.count - 1)]
                target = cue.time + min(max(0, time - anchor.time), cue.duration)
            }
        }
        load(prepared); rate = oldRate; clicks = oldClicks && prepared.audioWithClicks != nil
        seek(target)
    }

    func followReaderPage(_ page: Int) {
        guard !playing, !preparing, !scrubbing, loop == nil, !selectingLoop,
              let prepared = pendingPackage ?? package,
              let cue = prepared.cues.first(where: { $0.page == page }) else { return }
        if pendingPackage != nil { offer(prepared, page: page) }
        seek(prepared.bars?.first(where: { $0.measure == cue.measure })?.start ?? cue.time)
    }

    func pause() {
        trace("pause")
        scrubbing = false; resumeAfterScrubbing = false
        audio.cancelPreparation()
        let previous = operation
        let current = UUID(); token = current
        if playing { position = min(package?.duration ?? 0, visualPosition) }
        visualTime = position; playing = false; preparing = false
        operation = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.audio.stop()
            // Keep detection suspended until the speaker has actually stopped.
            if self.token == current { self.focus?.setVoiceNoteActive(false, owner: self.owner) }
        }
    }

    func seek(_ time: Double) {
        trace("seek \(time)")
        guard time.isFinite, let package else { return }
        let resume = playing || preparing
        // Invalidate queued audio-clock updates before committing a new position.
        // During a drag audio is already paused; only preview the target until release.
        if !scrubbing { pause() }
        if let loop, loopEnabled, !loop.contains(time) { loopEnabled = false }
        position = min(package.duration, max(0, time)); visualTime = position; visualUpdatedAt = CACurrentMediaTime()
        if !scrubbing { seekRevision += 1 }
        if resume, !scrubbing, position < package.duration - 0.05 { play() }
    }
    func beginScrubbing() {
        trace("begin scrub")
        guard !scrubbing else { return }
        let resume = playing || preparing
        pause(); scrubbing = true; resumeAfterScrubbing = resume
        cancelLoopSelection()
    }
    func endScrubbing() {
        trace("end scrub")
        guard scrubbing else { return }
        let resume = resumeAfterScrubbing
        scrubbing = false; resumeAfterScrubbing = false
        seekRevision += 1
        if resume, let package, position < package.duration - 0.05 { play() }
    }
    func tap(_ cue: ScoreAuditionPackage.Cue) {
        guard let package else { return }
        if selectingLoop {
            if let anchor = loopAnchor, let selected = package.loop(from: anchor, through: cue) {
                pause(); loop = selected; loopEnabled = true; selectingLoop = false; loopAnchor = nil
                position = selected.start; visualTime = position; visualUpdatedAt = CACurrentMediaTime(); play()
            } else { loopAnchor = cue }
        } else { seek(cue.time); play() }
    }
    func beginLoopSelection() { pause(); selectingLoop = true; loopAnchor = nil }
    func cancelLoopSelection() { selectingLoop = false; loopAnchor = nil }
    func setLoopEnabled(_ enabled: Bool) {
        guard loop != nil, enabled != loopEnabled else { return }
        let resume = playing || preparing
        pause(); loopEnabled = enabled
        if resume { play() }
    }
    func clearLoop() { setLoopEnabled(false); loop = nil; cancelLoopSelection() }
    func setRate(_ value: Double) {
        guard value.isFinite else { return }
        visualTime = visualPosition; visualUpdatedAt = CACurrentMediaTime()
        rate = min(1.5, max(0.5, value)); audio.setRate(rate)
    }
    func setClicks(_ enabled: Bool) {
        guard package?.audioWithClicks != nil, enabled != clicks else { return }
        let resume = playing || preparing
        pause(); clicks = enabled
        if resume { play() }
    }
    var visualPosition: Double {
        let time = visualTime + (playing ? max(0, CACurrentMediaTime() - visualUpdatedAt) * rate : 0)
        if playing, loopEnabled, let loop { return loop.start + max(0, time - loop.start).truncatingRemainder(dividingBy: loop.duration) }
        return min(package?.duration ?? 0, time)
    }
    private func receive(_ status: ScoreAuditionAudio.Status, token: UUID) {
        guard self.token == token else { return }
        visualTime = status.time; visualUpdatedAt = CACurrentMediaTime()
        if visualUpdatedAt - lastPublication >= 0.2 || !status.playing {
            position = status.time; lastPublication = visualUpdatedAt
        }
        if !status.playing {
            trace("audio completed \(status.time)")
            playing = false; preparing = false
            focus?.setVoiceNoteActive(false, owner: owner)
            completionRevision += 1
        }
    }
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        audio.shutdown()
        let focus = focus, owner = owner
        Task { @MainActor in focus?.setVoiceNoteActive(false, owner: owner) }
    }
}
#endif
