import Foundation

enum SilenceConfirmationSettings {
    static let defaultDelay: TimeInterval = 3
    static let delayRange: ClosedRange<TimeInterval> = 0...60
    static let presets = [0, 3, 5, 8, 10, 15, 20, 30, 45, 60]
    static let storageKey = "silenceConfirmationDelay"

    static func normalized(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? min(delayRange.upperBound, max(delayRange.lowerBound, value.rounded())) : defaultDelay
    }
}

/// Segment continuity only. Raw music evidence and effective practice time
/// remain immediate, so waiting for silence never adds practice time.
struct PracticeSilenceSegmentation {
    struct State: Equatable {
        var isActive = false
        var isWaitingForSilence = false
    }

    private(set) var state = State()
    private var silenceStart: TimeInterval?
    private var lastEnd: TimeInterval?

    mutating func consume(_ update: PracticeDetectionUpdate, delay: TimeInterval) -> State {
        guard update.endTime.isFinite, lastEnd == nil || update.endTime > lastEnd! else { return state }
        if let lastEnd, update.endTime - lastEnd > 1.5 {
            state = State()
            silenceStart = nil
        }
        lastEnd = update.endTime

        if update.isPracticing {
            state = State(isActive: true)
            silenceStart = nil
        } else if update.evidence == .silence && state.isActive {
            let delay = SilenceConfirmationSettings.normalized(delay)
            if silenceStart == nil { silenceStart = update.endTime }
            let waiting = delay > 0 && update.endTime - silenceStart! < delay
            state = State(isActive: waiting, isWaitingForSilence: waiting)
        } else {
            // Speech, noise and missing input never receive a silence grace period.
            state = State()
            silenceStart = nil
        }
        return state
    }
}
