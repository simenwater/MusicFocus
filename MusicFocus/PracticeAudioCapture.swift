import AVFoundation

/// Voice review temporarily replaces measurement processing. Playback uses the
/// media route (speaker without accessories), without forcing headphones off.
enum PracticeAudioSessionUse: Hashable {
    case practice, voiceRecording, voicePlayback

    static func preferred(in owners: [Self: Int]) -> Self? {
        [.voiceRecording, .voicePlayback, .practice].first { owners[$0, default: 0] > 0 }
    }

    var category: AVAudioSession.Category {
        self == .voicePlayback ? .playback : .playAndRecord
    }
    var mode: AVAudioSession.Mode { self == .practice ? .measurement : .default }
    var options: AVAudioSession.CategoryOptions {
        self == .voicePlayback ? [.mixWithOthers] : [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP]
    }
}

/// Resource ownership is confined to PracticeAudioCapture's serial worker.
/// The protocol lets lifecycle tests simulate a slow device without using a mic.
protocol PracticeCaptureResources: AnyObject {
    func start(configuration: PracticeDetectionConfiguration,
               onResult: @escaping (PracticeDetectionUpdate) -> Void,
               onReset: @escaping () -> Void,
               onError: @escaping (Error) -> Void) throws
    func configure(_ configuration: PracticeDetectionConfiguration)
    func stop()
}

/// Session activation, model loading and engine teardown can block. None runs
/// on the UI thread. A shared queue also prevents an old stop from deactivating
/// a newer capture's AVAudioSession during rapid stop/start or route changes.
final class PracticeAudioCapture {
    private static let worker = DispatchQueue(label: "MusicFocus.captureLifecycle", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false
    private var resources: PracticeCaptureResources?
    private let makeResources: () -> PracticeCaptureResources

    init(makeResources: @escaping () -> PracticeCaptureResources = { DevicePracticeCapture() }) {
        self.makeResources = makeResources
    }

    /// App launch/foreground preparation shares capture's queue so it cannot
    /// block the UI or overwrite measurement mode while capture is active.
    static func prepareIdleAudioSession() {
        worker.async { DevicePracticeCapture.prepareIdleAudioSession() }
    }

    /// Ownership and mode changes are serialized with capture teardown.
    /// Voice review takes precedence until it pauses/stops; the metronome
    /// retains its lease throughout. `completion` runs on the capture queue.
    static func acquireSharedSession(for use: PracticeAudioSessionUse = .practice,
                                     _ completion: @escaping (Bool) -> Void) {
        worker.async {
            do {
                try DevicePracticeCapture.acquireSession(for: use)
                completion(true)
            } catch {
                print("配置音频会话失败: \(error.localizedDescription)")
                completion(false)
            }
        }
    }

    static func releaseSharedSession(for use: PracticeAudioSessionUse = .practice) {
        worker.async { DevicePracticeCapture.releaseSession(for: use) }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func start(configuration: PracticeDetectionConfiguration,
               onStarted: @escaping () -> Void,
               onResult: @escaping (PracticeDetectionUpdate) -> Void,
               onReset: @escaping () -> Void,
               onError: @escaping (Error) -> Void) {
        Self.worker.async { [self] in
            guard !isCancelled else { return }
            let resource = makeResources()
            resources = resource
            do {
                try resource.start(configuration: configuration,
                                   onResult: { [weak self] update in
                    guard let self, !self.isCancelled else { return }
                    onResult(update)
                }, onReset: { [weak self] in
                    guard let self, !self.isCancelled else { return }
                    onReset()
                }, onError: { [weak self] error in
                    guard let self, !self.isCancelled else { return }
                    onError(error)
                })
                if isCancelled {
                    resource.stop()
                    resources = nil
                } else {
                    onStarted()
                }
            } catch {
                resource.stop()
                resources = nil
                if !isCancelled { onError(error) }
            }
        }
    }

    func configure(_ configuration: PracticeDetectionConfiguration) {
        Self.worker.async { [self] in
            guard !isCancelled else { return }
            resources?.configure(configuration)
        }
    }

    func stop() {
        lock.lock()
        cancelled = true
        lock.unlock()
        Self.worker.async { [self] in
            resources?.stop()
            resources = nil
        }
    }
}

private final class DevicePracticeCapture: PracticeCaptureResources {
    // Read and written only on PracticeAudioCapture.worker.
    private static var sessionOwners: [PracticeAudioSessionUse: Int] = [:]
    private var engine: AVAudioEngine?
    private var tappedNode: AVAudioNode?
    private var detector: LivePracticeDetector?
    private var ownsSession = false

    static func prepareIdleAudioSession() {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard PracticeAudioSessionUse.preferred(in: sessionOwners) == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            print("配置音频会话失败: \(error.localizedDescription)")
        }
    }

    func start(configuration: PracticeDetectionConfiguration,
               onResult: @escaping (PracticeDetectionUpdate) -> Void,
               onReset: @escaping () -> Void,
               onError: @escaping (Error) -> Void) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        try Self.acquireSession()
        ownsSession = true
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw PracticeAnalysisError.invalidAudio
        }
        let rate = format.sampleRate
        let detector = try LivePracticeDetector(
            sampleRate: rate, configuration: configuration,
            onResult: onResult, onReset: onReset, onError: onError,
            onAudio: { samples, position in
                PracticePitchFeed.shared.submit(samples, startFrame: position, sampleRate: rate)
            })
        self.detector = detector
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, time in
            let hostSeconds = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : 0
            detector.enqueue(buffer, at: time.sampleTime, hostSeconds: hostSeconds)
        }
        tappedNode = input
        try engine.start()
    }

    func configure(_ configuration: PracticeDetectionConfiguration) {
        detector?.configure(configuration)
    }

    func stop() {
        dispatchPrecondition(condition: .notOnQueue(.main))
        tappedNode?.removeTap(onBus: 0)
        tappedNode = nil
        engine?.stop()
        engine = nil
        detector?.cancel()
        detector = nil
        if ownsSession {
            ownsSession = false
            Self.releaseSession()
        }
    }

    private static func configureSession(for use: PracticeAudioSessionUse) throws {
        let session = AVAudioSession.sharedInstance()
        if session.category != use.category || session.mode != use.mode || session.categoryOptions != use.options {
            try session.setCategory(use.category, mode: use.mode, options: use.options)
        }
        if use == .practice { try session.setPreferredSampleRate(44_100) }
        try session.setActive(true)
    }

    static func acquireSession(for use: PracticeAudioSessionUse = .practice) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        var owners = sessionOwners
        owners[use, default: 0] += 1
        do {
            try configureSession(for: PracticeAudioSessionUse.preferred(in: owners)!)
            sessionOwners = owners
        } catch {
            if let previous = PracticeAudioSessionUse.preferred(in: sessionOwners) {
                try? configureSession(for: previous)
            }
            throw error
        }
    }

    static func releaseSession(for use: PracticeAudioSessionUse = .practice) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard sessionOwners[use, default: 0] > 0 else { return }
        sessionOwners[use, default: 0] -= 1
        if let remaining = PracticeAudioSessionUse.preferred(in: sessionOwners) {
            do { try configureSession(for: remaining) }
            catch { print("恢复音频会话失败: \(error.localizedDescription)") }
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
