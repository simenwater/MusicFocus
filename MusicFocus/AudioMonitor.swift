import Foundation
import AVFoundation
import AVFAudio
import Combine
import UIKit

extension Notification.Name {
    static let musicConfirmed = Notification.Name("musicConfirmed")
    static let musicStopped = Notification.Name("musicStopped")
}

struct PracticeMonitorState: Equatable {
    var isMonitoring = false
    var decibels: Float = -160
    var isPlayingMusic = false
    var isWaitingForSilence = false
    var musicProbability: Float = 0
    var currentNoiseRatio: Float = 0
    var noiseGateTriggered = false
    var noiseGateMessage = ""
    var detectionMessage = ""
}

/// Main-thread facade for capture, UI and focus notifications. Classification
/// runs in LivePracticeDetector. PracticeDetectionPolicy owns raw evidence;
/// PracticeSilenceSegmentation separately confirms silent interruptions.
class AudioMonitor: NSObject, ObservableObject {
    // Publish one coherent snapshot, rather than seven notifications per result.
    @Published private(set) var state = PracticeMonitorState()
    var isMonitoring: Bool { state.isMonitoring }
    var decibels: Float { state.decibels }
    var isPlayingMusic: Bool { state.isPlayingMusic }
    var isWaitingForSilence: Bool { state.isWaitingForSilence }
    var musicProbability: Float { state.musicProbability }
    var currentNoiseRatio: Float { state.currentNoiseRatio }
    var noiseGateTriggered: Bool { state.noiseGateTriggered }
    var noiseGateMessage: String { state.noiseGateMessage }
    var detectionMessage: String { state.detectionMessage }

    var onMusicInterrupted: (() -> Void)?
    var onMusicResumed: (() -> Void)?
    var onSilencePending: ((Date) -> Void)?
    var onSilenceResumed: ((Date) -> Void)?
    private(set) var silenceConfirmationDelay = SilenceConfirmationSettings.defaultDelay
    private var segmentation = PracticeSilenceSegmentation()
    private(set) var detectionConfiguration = PracticeDetectionConfiguration()
    private(set) var currentInstrumentType: InstrumentType = .custom

    private var voiceSuspended = false
    private var resumeAfterVoice = false
    private var capture: PracticeAudioCapture?
    private var generation = UUID()
    private var isMusicConfirmed = false
    private var lastResultTime: TimeInterval = 0
    private var watchdog: Timer?
    private var volumeHistory: [Float] = []
    private var wasMonitoringBeforeBackground = false
    private var resumeAfterInterruption = false
    #if DEBUG && targetEnvironment(simulator)
    private var diagnostics: PracticeDiagnostics?
    #endif

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification, object: nil)
    }

    func updateConfiguration(threshold: Float, instrumentType: InstrumentType) {
        currentInstrumentType = instrumentType
        // Historical per-instrument dB presets no longer discard quiet notes.
        // The classifier considers all instrument labels and adapts to background.
    }

    func updatePracticeMode(_ mode: PracticeMode) {
        detectionConfiguration.mode = mode
        capture?.configure(detectionConfiguration)
    }

    func updateMetronomeActive(_ active: Bool) {
        guard detectionConfiguration.metronomeActive != active else { return }
        detectionConfiguration.metronomeActive = active
        capture?.configure(detectionConfiguration)
    }

    func updateSilenceConfirmationDelay(_ delay: TimeInterval) {
        silenceConfirmationDelay = SilenceConfirmationSettings.normalized(delay)
    }

    func startMonitoring() {
        if voiceSuspended { resumeAfterVoice = true; return }
        guard !isMonitoring else { return }
        #if DEBUG && targetEnvironment(simulator)
        diagnostics = PracticeDiagnostics.startIfRequested(configuration: detectionConfiguration,
            silenceConfirmationDelay: silenceConfirmationDelay)
        #endif
        generation = UUID()
        let sessionID = generation
        volumeHistory.removeAll()
        resetDetection(notify: false)
        updateState {
            // Includes requested startup so a second tap cannot start another
            // capture, and Stop also cancels a model that is still loading.
            $0.isMonitoring = true
            $0.detectionMessage = "正在启动声音检测…"
        }
        let capture = PracticeAudioCapture()
        self.capture = capture
        capture.start(configuration: detectionConfiguration,
                onStarted: { [weak self] in
                    DispatchQueue.main.async {
                        guard let self, self.generation == sessionID, self.isMonitoring else { return }
                        #if DEBUG && targetEnvironment(simulator)
                        self.diagnostics?.captureReady()
                        #endif
                        self.updateState { $0.detectionMessage = "正在聆听乐器声音…" }
                        self.lastResultTime = ProcessInfo.processInfo.systemUptime
                        self.watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                            guard let self, self.isMonitoring else { return }
                            if ProcessInfo.processInfo.systemUptime - self.lastResultTime > 6 {
                                self.failMonitoring(PracticeAnalysisError.stalledInput)
                            }
                        }
                    }
                },
                onResult: { [weak self] update in
                    DispatchQueue.main.async {
                        guard let self, self.generation == sessionID, self.isMonitoring else { return }
                        self.receive(update)
                    }
                }, onReset: { [weak self] in
                    DispatchQueue.main.async {
                        guard let self, self.generation == sessionID, self.isMonitoring else { return }
                        self.resetDetection(notify: true)
                        self.updateState { $0.detectionMessage = "声音输入恢复中…" }
                    }
                }, onError: { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self, self.generation == sessionID else { return }
                        self.failMonitoring(error)
                    }
                })
    }

    func setVoiceNoteSuspended(_ suspended: Bool) {
        guard voiceSuspended != suspended else { return }
        voiceSuspended = suspended
        if suspended {
            resumeAfterVoice = isMonitoring
            stopMonitoring(preserveVoiceResume: true)
        } else {
            let shouldResume = resumeAfterVoice
            resumeAfterVoice = false
            if shouldResume {
                if UIApplication.shared.applicationState == .background { wasMonitoringBeforeBackground = true }
                else { startMonitoring() }
            }
        }
    }

    func stopMonitoring(preserveVoiceResume: Bool = false) {
        if !preserveVoiceResume { resumeAfterVoice = false }
        #if DEBUG && targetEnvironment(simulator)
        diagnostics?.stop()
        diagnostics = nil
        #endif
        // Invalidate pending results BEFORE tearing down the tap/analysis queue.
        generation = UUID()
        resumeAfterInterruption = false
        wasMonitoringBeforeBackground = false
        watchdog?.invalidate()
        watchdog = nil
        capture?.stop()
        capture = nil
        isMusicConfirmed = false
        segmentation = PracticeSilenceSegmentation()
        if state != PracticeMonitorState() { state = PracticeMonitorState() }
    }

    /// Called on the main thread after capture's generation check.
    func receive(_ update: PracticeDetectionUpdate, at now: Date = Date()) {
        guard !voiceSuspended else { return }
        let wasWaiting = segmentation.state.isWaitingForSilence
        let segment = segmentation.consume(update, delay: silenceConfirmationDelay)
        #if DEBUG && targetEnvironment(simulator)
        diagnostics?.receive(update, segmentation: segment)
        #endif
        lastResultTime = ProcessInfo.processInfo.systemUptime
        var next = state
        next.decibels = update.decibels
        next.musicProbability = update.evidence == .music ?
            Float(max(update.scores.instrument, update.scores.music,
                      detectionConfiguration.mode == .singing ? update.scores.singing : 0)) : 0
        next.currentNoiseRatio = Float(update.noiseRatio)
        next.noiseGateTriggered = update.exitedForNoise
        next.noiseGateMessage = update.exitedForNoise ? "当前未检测到练习声音，已暂停计时" : ""
        // Evidence and time accounting remain immediate; only segment confirmation waits.
        next.isPlayingMusic = update.isPracticing
        next.isWaitingForSilence = segment.isWaitingForSilence
        if update.evidence == .speech {
            next.detectionMessage = detectionConfiguration.mode == .focusedInstrument ?
                "当前检测到人声，已暂停练琴计时" : "当前主要是说话，未计入练习"
        } else if segment.isWaitingForSilence {
            next.detectionMessage = "无声等待中，不计入练琴时长"
        } else {
            next.detectionMessage = update.isPracticing ? "" :
                (detectionConfiguration.mode == .singing ? "等待歌声或乐器声音" : "等待乐器声音")
        }
        if state != next { state = next }
        volumeHistory.append(update.decibels)
        if volumeHistory.count > 100 { volumeHistory.removeFirst() }

        if segment.isWaitingForSilence && !wasWaiting { onSilencePending?(now) }
        if wasWaiting && update.isPracticing { onSilenceResumed?(now) }
        if segment.isActive && !isMusicConfirmed {
            isMusicConfirmed = true
            onMusicResumed?()
            NotificationCenter.default.post(name: .musicConfirmed, object: self, userInfo: ["date": now])
        } else if !segment.isActive && isMusicConfirmed {
            isMusicConfirmed = false
            onMusicInterrupted?()
            NotificationCenter.default.post(name: .musicStopped, object: self, userInfo: ["date": now])
        }
    }

    private func resetDetection(notify: Bool) {
        let wasConfirmed = isMusicConfirmed
        isMusicConfirmed = false
        segmentation = PracticeSilenceSegmentation()
        updateState {
            $0.isPlayingMusic = false
            $0.isWaitingForSilence = false
            $0.currentNoiseRatio = 0
            $0.noiseGateTriggered = false
            $0.noiseGateMessage = ""
        }
        if notify && wasConfirmed {
            onMusicInterrupted?()
            NotificationCenter.default.post(name: .musicStopped, object: self)
        }
    }

    private func failMonitoring(_ error: Error) {
        resetDetection(notify: true)
        stopMonitoring()
        updateState { $0.detectionMessage = "Audio detection unavailable: %@".localizedFormat(error.localizedDescription) }
    }

    private func updateState(_ change: (inout PracticeMonitorState) -> Void) {
        var next = state
        change(&next)
        if state != next { state = next }
    }

    func setAppBackgroundState(_ inBackground: Bool, shouldStopMonitoring: Bool = true) {
        if inBackground {
            let wasMonitoring = isMonitoring || resumeAfterVoice
            if shouldStopMonitoring { stopMonitoring() }
            wasMonitoringBeforeBackground = wasMonitoring
        } else if wasMonitoringBeforeBackground && !isMonitoring {
            wasMonitoringBeforeBackground = false
            startMonitoring()
        }
    }

    func requestPermission(completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func showPermissionDenied() {
        resetDetection(notify: true)
        updateState { $0.detectionMessage = "请在系统设置中允许麦克风访问，再开始练琴检测。" }
    }

    func getRecentVolumeHistory(count: Int = 20) -> [Float] {
        Array(volumeHistory.suffix(max(0, count)))
    }

    func getRecentTempoEstimates(count: Int = 10) -> [Int] {
        [] // Activity classification cannot measure tempo.
    }

    @objc private func handleAudioSessionInterruption(notification: Notification) {
        guard let info = notification.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch type {
            case .began:
                let wasMonitoring = self.isMonitoring
                self.resetDetection(notify: true)
                self.stopMonitoring()
                self.resumeAfterInterruption = wasMonitoring
                self.updateState { $0.detectionMessage = "麦克风被其他应用占用，等待恢复" }
            case .ended:
                let options = AVAudioSession.InterruptionOptions(
                    rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                if self.resumeAfterInterruption && options.contains(.shouldResume) {
                    self.resumeAfterInterruption = false
                    self.startMonitoring()
                }
            @unknown default: break
            }
        }
    }

    @objc private func handleRouteChange(notification: Notification) {
        guard let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: value),
              reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isMonitoring else { return }
            self.resetDetection(notify: true)
            self.stopMonitoring()
            // Rebuild with the new route's actual sample rate/channel count.
            self.startMonitoring()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        watchdog?.invalidate()
        capture?.stop()
    }
}
