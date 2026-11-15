import Foundation

enum PracticeMode: String, CaseIterable, Codable, Identifiable {
    case focusedInstrument
    case instrumentWithSpeech
    case singing

    var id: String { rawValue }
    var title: String {
        switch self {
        case .focusedInstrument: return "专注练琴"
        case .instrumentWithSpeech: return "边讲边练"
        case .singing: return "声乐／弹唱"
        }
    }
    var explanation: String {
        switch self {
        case .focusedInstrument: return "只计入乐器练习；检测到人声时暂停。"
        case .instrumentWithSpeech: return "允许边说边弹和带配乐讲解；只有说话时暂停。"
        case .singing: return "计入清唱、哼唱、弹唱和乐器伴奏；普通说话时暂停。"
        }
    }
}

/// All times are audio times, not wall-clock times. Live audio and file tests use
/// this same policy. Scores are independent classifier confidences, not a sum.
struct PracticeDetectionConfiguration {
    var instrumentConfidence: Double = 0.40
    var voiceConfidence: Double = 0.35
    var mode: PracticeMode = .focusedInstrument
    /// True while the app's own metronome is audible (plus a short tail).
    var metronomeActive = false
}

/// Measurements from exactly the classifier's existing one-second window.
/// No future frames, pause hold, or minimum consecutive-result requirement.
struct PracticeAcousticFeatures {
    var vocalProbability: Double = 0
    var vocalSpeechProbability: Double = 0
    var vocalMusicProbability: Double = 0
    var vocalInferenceMS: Double = 0
    var speechProbability: Double = 0
    var speechPeakProbability: Double = 0
    var analyzedDBFS: Double = -160
    var resampledThroughTime: Double = 0
    var mainsHumRatio: Double = 0
    var mainsHarmonicRatio: Double = 0
    var spectralFlatness: Double = 0
    var strongestBinShare: Double = 0
    /// Share of the window that exactly repeated the metronome's previous bar.
    var metronomeRepeatShare: Double = 0
}

struct PracticeSoundScores {
    // Raw labels for local diagnostics; a model label is not a reliable UI identity.
    let instrumentClassifications: [String: Double]
    let instrument: Double
    let music: Double
    let voice: Double
    let noise: Double
    let silence: Double
    let drone: Double
    let otherInstrument: Double
    let percussion: Double
    let synthesizer: Double
    let keyboard: Double
    let specificInstrument: Double
    let singing: Double
    let spokenVoice: Double

    // Exclude bells, alarms, tuning forks and generic impacts: periodicity alone
    // is not evidence that someone is practising an instrument.
    static let instrumentLabels: Set<String> = [
        "plucked_string_instrument", "guitar", "electric_guitar", "bass_guitar",
        "acoustic_guitar", "steel_guitar_slide_guitar", "guitar_tapping", "guitar_strum",
        "banjo", "sitar", "mandolin", "zither", "ukulele", "keyboard_musical",
        "piano", "electric_piano", "organ", "electronic_organ", "hammond_organ",
        "synthesizer", "harpsichord", "percussion", "drum_kit", "drum", "snare_drum",
        "bass_drum", "timpani", "tabla", "cymbal", "hi_hat", "tambourine",
        "rattle_instrument", "gong", "mallet_percussion", "marimba_xylophone",
        "glockenspiel", "vibraphone", "steelpan", "brass_instrument", "french_horn",
        "trumpet", "trombone", "bowed_string_instrument", "violin_fiddle", "cello",
        "double_bass", "wind_instrument", "flute", "saxophone", "clarinet", "oboe",
        "bassoon", "harp", "harmonica", "accordion", "bagpipes", "didgeridoo",
        "shofar", "theremin"
    ]
    static let voiceLabels: Set<String> = [
        "speech", "shout", "yell", "children_shouting", "screaming", "whispering",
        "laughter", "chatter", "crowd", "babble", "singing", "choir_singing",
        "yodeling", "rapping", "humming", "whistling", "cough", "sneeze"
    ]
    static let singingLabels: Set<String> = [
        "singing", "choir_singing", "yodeling", "humming"
    ]

    init(classifications: [String: Double]) {
        func score(_ value: Double) -> Double {
            value.isFinite ? min(1, max(0, value)) : 0
        }
        instrumentClassifications = classifications.filter { Self.instrumentLabels.contains($0.key) }
            .mapValues { score($0) }
        instrument = classifications.filter { Self.instrumentLabels.contains($0.key) }
            .map { score($0.value) }.max() ?? 0
        synthesizer = score(classifications["synthesizer"] ?? 0)
        keyboard = score(classifications["keyboard_musical"] ?? 0)
        specificInstrument = classifications.filter {
            Self.instrumentLabels.contains($0.key) &&
            !["synthesizer", "keyboard_musical"].contains($0.key)
        }.map { score($0.value) }.max() ?? 0
        let droneLabels: Set<String> = ["didgeridoo", "theremin"]
        drone = droneLabels.map { score(classifications[$0] ?? 0) }.max() ?? 0
        otherInstrument = classifications.filter {
            Self.instrumentLabels.contains($0.key) && !droneLabels.contains($0.key)
        }.map { score($0.value) }.max() ?? 0
        percussion = ["percussion", "drum_kit", "drum", "snare_drum", "bass_drum",
                      "timpani", "tabla", "cymbal", "hi_hat", "tambourine", "rattle_instrument"]
            .map { score(classifications[$0] ?? 0) }.max() ?? 0
        music = score(classifications["music"] ?? 0)
        voice = classifications.filter { Self.voiceLabels.contains($0.key) }
            .map { score($0.value) }.max() ?? 0
        singing = Self.singingLabels.map { score(classifications[$0] ?? 0) }.max() ?? 0
        spokenVoice = classifications.filter {
            Self.voiceLabels.contains($0.key) && !Self.singingLabels.contains($0.key)
        }.map { score($0.value) }.max() ?? 0
        silence = score(classifications["silence"] ?? 0)
        noise = classifications.filter {
            !Self.instrumentLabels.contains($0.key) &&
            !Self.voiceLabels.contains($0.key) &&
            !["music", "orchestra", "silence"].contains($0.key)
        }.map { score($0.value) }.max() ?? 0
    }
}

enum PracticeEvidence: String {
    case music, speech, noise, silence
}

struct PracticeDetectionUpdate {
    let endTime: TimeInterval
    let evaluatedDuration: TimeInterval
    let decibels: Float
    let scores: PracticeSoundScores
    let evidence: PracticeEvidence
    let isPracticing: Bool
    let noiseRatio: Double
    let exitedForNoise: Bool
    var acoustics = PracticeAcousticFeatures()
}

struct PracticeDetectionPolicy {
    var configuration: PracticeDetectionConfiguration
    private(set) var isPracticing = false
    private var lastEnd: TimeInterval?
    private var lastMusicEnd: TimeInterval?
    private var backgroundLevels: [Float] = []

    init(configuration: PracticeDetectionConfiguration = .init()) {
        self.configuration = configuration
    }

    mutating func consume(scores: PracticeSoundScores, decibels: Float,
                          endTime: TimeInterval,
                          acoustics: PracticeAcousticFeatures = .init()) -> PracticeDetectionUpdate? {
        guard endTime.isFinite, endTime > 0, decibels.isFinite,
              lastEnd == nil || endTime > lastEnd! else { return nil }

        // Missing audio cannot carry the lower continuation threshold into a
        // new stream. Its first valid result can still start immediately.
        if let lastEnd, endTime - lastEnd > 1.5 {
            isPracticing = false
            lastMusicEnd = nil
        }
        let duration = min(0.5, endTime - (lastEnd ?? max(0, endTime - 0.5)))
        lastEnd = endTime

        let sortedBackground = backgroundLevels.sorted()
        let floor = sortedBackground.isEmpty ? Float(-78) :
            sortedBackground[(sortedBackground.count - 1) / 5]
        // This is a soft, adaptive gate AFTER classification. Confident quiet
        // instruments can bypass it; digital silence can never count as music.
        let softGate = max(-85, min(-60, floor + 5))
        let followingInstrument = lastMusicEnd.map { endTime - $0 <= 1 } ?? false
        let quietNoteDecay = followingInstrument && scores.instrument >= 0.40 &&
            scores.music >= 0.40 && scores.voice < 0.20
        // Half a dB of tolerance around the adaptive floor avoids a hard cliff
        // for weak, corroborated music when sample-accurate RMS replaces a
        // capture-block approximation. All speech/noise vetoes still apply.
        let nearGateInstrument = decibels >= softGate - 0.5 && scores.instrument >= 0.40 &&
            scores.music >= 0.70 && scores.voice < 0.10 && acoustics.speechProbability < 0.10
        // Exact RMS can be slightly below the previous -90 dBFS cutoff on a
        // fading note. Protect strong evidence or the existing quiet-note decay
        // rule in the next 2 dB; digital silence remains far below this bound.
        let veryQuietInstrument = decibels > -92 && (scores.instrument >= 0.65 || quietNoteDecay) &&
            scores.music >= 0.40 && scores.voice < 0.10 && acoustics.speechProbability < 0.10
        let audible = (decibels > -90 &&
            (decibels >= softGate || scores.instrument >= 0.65 || quietNoteDecay || nearGateInstrument)) || veryQuietInstrument
        // Only an uninterrupted musical result can use the weak-tail threshold.
        // Any non-music result ends the segment immediately.
        let instrumentThreshold = isPracticing ? min(0.28, configuration.instrumentConfidence) :
            configuration.instrumentConfidence
        let instrumentEvidence = scores.instrument >= instrumentThreshold &&
            (scores.music >= 0.25 || scores.instrument >= 0.65) &&
            (scores.noise < 0.80 || scores.instrument >= 0.65)
        // Independent labels can both score highly on processed speech. Voice
        // vetoes both instrument and generic music on this very result.
        // Reed instruments can trigger the speech-activity model. Resolve only
        // that model's veto when both sound classifiers strongly support music
        // in this same window and independently report very little human voice.
        // Apple's voice/singing and the processed-speech/noise vetoes below
        // remain authoritative; no previous or future windows are consulted.
        let corroboratedInstrument = scores.specificInstrument >= 0.80 &&
            scores.music >= 0.85 && scores.voice < 0.20 && scores.singing < 0.04 &&
            acoustics.vocalMusicProbability >= 0.95 &&
            acoustics.vocalSpeechProbability < 0.005 && acoustics.vocalProbability < 0.005
        let independentSpeech = !corroboratedInstrument &&
            (acoustics.speechProbability >= 0.30 ||
             (acoustics.speechProbability >= 0.12 && scores.voice >= 0.10))
        // Reverberant speech can dominate the synthesizer label while Apple's
        // speech label is weak. Require both voice classifiers and a dispersed
        // spectrum in this same window. Concentrated musical harmonics and a
        // stronger specific instrument protect quiet notes from this veto.
        // This does not change the weak-note threshold or delay either transition.
        let syntheticSpeech = scores.synthesizer >= 0.40 &&
            scores.synthesizer >= scores.specificInstrument &&
            acoustics.speechProbability >= 0.12 && scores.voice >= 0.02 &&
            acoustics.strongestBinShare < 0.07
        // Sustained vowels may resemble instruments to either classifier.
        // Require agreement from two independent classifiers on this window.
        // This veto is specific to the user's strict, no-voice practice mode.
        let corroboratedSinging = configuration.mode == .focusedInstrument &&
            scores.singing >= 0.05 && acoustics.vocalProbability >= 0.05
        let voiceEvidence = (corroboratedSinging || scores.voice >= configuration.voiceConfidence ||
                             independentSpeech || syntheticSpeech) && decibels > -90
        // A confident typing/noise label must not lose to a weaker instrument
        // label. Keep a substantial margin: low strings can also resemble cows.
        let dominantNoise = scores.noise >= 0.95 && scores.noise >= scores.instrument + 0.20
        // Motors can resemble didgeridoos. Require acoustic corroboration of
        // electrical hum or a broadband transient; never reject bass by volume
        // or frequency alone, and let stronger concrete instrument labels win.
        let mechanicalRumble = scores.drone >= 0.40 && scores.drone > scores.otherInstrument &&
            (acoustics.mainsHumRatio >= 0.65 ||
             (acoustics.spectralFlatness >= 0.01 && acoustics.strongestBinShare < 0.05))
        // 100/120 Hz power-line harmonics lie between equal-tempered notes.
        // Strong concrete instrument evidence still wins (including detuned bass).
        // Keep the 50/60 Hz fundamental out of this stronger veto: it overlaps
        // very low musical notes. Broadband evidence needs a weak instrument
        // label and never vetoes a confidently classified percussion sound.
        let electricalRumble = acoustics.mainsHarmonicRatio >= 0.50 && scores.otherInstrument < 0.65
        let broadbandNoise = acoustics.spectralFlatness >= 0.015 &&
            acoustics.strongestBinShare < 0.06 && scores.instrument < 0.65 && scores.percussion < 0.40
        let genericMusicEvidence = scores.instrument >= min(0.20, configuration.instrumentConfidence) && scores.music >= (isPracticing ? 0.65 : 0.80) &&
            scores.voice < configuration.voiceConfidence && scores.noise < 0.55
        // Optional mixed practice: speech presence alone is not a reason to
        // discard a concrete instrument. Generic music/keyboard/synth labels
        // cannot rescue speech. Near-continuous speech needs stronger musical
        // evidence; no history, consecutive hits or additional audio is used.
        let mixedInstrument = configuration.mode != .focusedInstrument &&
            scores.specificInstrument >= max(0.50, configuration.instrumentConfidence) &&
            scores.music >= 0.70 &&
            scores.specificInstrument >= scores.synthesizer + 0.15 &&
            scores.specificInstrument > scores.drone &&
            scores.noise < 0.55 &&
            (acoustics.speechProbability < 0.85 ||
             (scores.specificInstrument >= 0.70 && scores.music >= 0.90))
        // VAD detects the human voice, including singing; it cannot veto the
        // explicit vocal target in this mode. A singing label must corroborate
        // music and exceed ordinary spoken-voice evidence.
        let appleVocal = scores.singing >= 0.50 &&
            (scores.music >= 0.40 || scores.singing >= 0.85)
        // Quiet a cappella often has a weak generic music label. Independent
        // singing AND music evidence can corroborate it, while spoken evidence
        // remains low. Preserve existing accepted singing and accompaniment.
        let corroboratedVocal = scores.singing >= 0.40 && acoustics.vocalProbability >= 0.05 &&
            acoustics.vocalMusicProbability >= 0.03 && acoustics.vocalSpeechProbability < 0.35
        let vocalPractice = configuration.mode == .singing && (appleVocal || corroboratedVocal) &&
            scores.singing >= scores.spokenVoice + 0.10 && scores.noise < 0.55
        let vocalAudible = decibels > -90 && (decibels >= softGate || scores.singing >= 0.65)
        // The app's own metronome reaches the microphone as a periodic tick that
        // Apple can label only as a generic synthesizer/keyboard; YAMNet hears
        // almost no music in it. While it plays, instrument music needs either a
        // concrete instrument label or YAMNet's independent music score.
        // Played or sung notes never repeat the previous bar sample for sample;
        // a window that does is the metronome alone (see MetronomeCanceller).
        let metronomeTick = configuration.metronomeActive &&
            ((scores.specificInstrument < 0.50 && acoustics.vocalMusicProbability < 0.30) ||
             acoustics.metronomeRepeatShare >= 0.80)
        var evidence: PracticeEvidence
        if voiceEvidence && !mixedInstrument && !vocalPractice {
            evidence = .speech
        } else if audible && (dominantNoise || mechanicalRumble || electricalRumble || broadbandNoise) {
            evidence = .noise
        } else if vocalAudible && vocalPractice {
            evidence = .music
        } else if audible && (instrumentEvidence || genericMusicEvidence) && !metronomeTick {
            evidence = .music
        } else if decibels <= -90 || decibels < softGate ||
                    (scores.silence > 0.75 && scores.voice < 0.3 && scores.noise < 0.3) {
            evidence = .silence
        } else {
            evidence = .noise
        }
        // Ticks keep the room from ever sounding silent. Treat non-voice sound
        // as silence while the metronome plays: it still never counts, but a
        // short pause between phrases gets the user's silence confirmation
        // delay instead of an immediate noise interruption.
        if configuration.metronomeActive && evidence == .noise {
            evidence = .silence
        }

        // Never learn quiet notes as background. Keep a rolling lower quantile
        // rather than letting a single loud sound raise the weak-note gate.
        if scores.instrument < 0.15 && scores.music < 0.20 && scores.voice < configuration.voiceConfidence {
            backgroundLevels.append(max(-95, decibels))
            if backgroundLevels.count > 60 { backgroundLevels.removeFirst() }
        }

        // Evidence classification stays immediate. Silence confirmation is
        // applied separately by PracticeSilenceSegmentation; it never changes
        // these thresholds or makes a silent window count as practice.
        let wasPracticing = isPracticing
        isPracticing = evidence == .music
        lastMusicEnd = isPracticing ? endTime : nil
        let isNoise = evidence == .noise || evidence == .speech
        let noiseRatio: Double = isNoise ? 1 : 0
        let exitedForNoise = wasPracticing && !isPracticing && isNoise

        return PracticeDetectionUpdate(
            endTime: endTime, evaluatedDuration: duration, decibels: decibels,
            scores: scores, evidence: evidence, isPracticing: isPracticing,
            noiseRatio: noiseRatio, exitedForNoise: exitedForNoise, acoustics: acoustics)
    }
}
