import SwiftUI

/// Observe frequent meter changes here, not through the app's FocusManager.
struct PracticeAudioStatusView: View {
    @ObservedObject var monitor: AudioMonitor

    var body: some View {
        VStack(spacing: 10) {
            AudioLevelIndicator(decibels: monitor.decibels, isActive: monitor.isMonitoring)
            MusicProbabilityIndicator(probability: monitor.musicProbability,
                                      isActive: monitor.isMonitoring,
                                      title: monitor.detectionConfiguration.mode == .singing ?
                                        "歌声／乐器检测".localized : "Instrument Detection".localized)
            if !monitor.detectionMessage.isEmpty {
                Text(monitor.detectionMessage.localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(monitor.detectionConfiguration.mode == .singing ?
                 (monitor.isPlayingMusic ? "已检测到歌声或乐器".localized : "尚未检测到歌声或乐器".localized) :
                 (monitor.isPlayingMusic ? "Instrument sound detected".localized :
                    "No instrument sound detected".localized))
                .font(.subheadline)
                .foregroundColor(monitor.isPlayingMusic ? .green : .orange)
                .animation(.easeInOut, value: monitor.isPlayingMusic)
            if monitor.noiseGateTriggered {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption)
                    Text(monitor.noiseGateMessage.localized).font(.caption).fontWeight(.medium)
                }
                .foregroundColor(.red)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
                .transition(.scale.combined(with: .opacity))
            }
        }
    }
}

struct PracticeModePicker: View {
    @EnvironmentObject var focusManager: FocusManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("练习模式".localized, selection: Binding(
                get: { focusManager.practiceMode },
                set: { focusManager.selectPracticeMode($0) })) {
                ForEach(PracticeMode.allCases) { mode in
                    Text(mode.title.localized).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .disabled(focusManager.isActive)
            .accessibilityIdentifier("practiceModePicker")
            Text(focusManager.practiceMode.explanation.localized)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if focusManager.isActive {
                Text("结束本次练习后可切换模式".localized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
