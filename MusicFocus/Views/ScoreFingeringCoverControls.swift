import SwiftUI

struct ScoreFingeringCoverControls: View {
    @Binding var enabled: Bool
    @Binding var style: ScoreFingeringCover

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("score.fingeringCover".localized, isOn: $enabled)
                .accessibilityIdentifier("scoreFingeringCover")
            if enabled {
                HStack(spacing: 12) {
                    ColorPicker("score.coverColor".localized, selection: Binding(
                        get: { Color(uiColor: style.color.uiColor) },
                        set: { style.color = .init(UIColor($0)) }), supportsOpacity: false)
                        .accessibilityIdentifier("scoreFingeringCoverColor")
                    Button { style.color = .init(.white) } label: {
                        Circle().fill(.white).overlay(Circle().stroke(.gray, lineWidth: 1)).frame(width: 24, height: 24)
                            .frame(width: 44, height: 44)
                    }.buttonStyle(.plain).accessibilityLabel("score.coverWhite".localized).accessibilityIdentifier("scoreCoverWhite")
                    Button { style.color = .init(UIColor(red: 0.97, green: 0.94, blue: 0.85, alpha: 1)) } label: {
                        Circle().fill(Color(red: 0.97, green: 0.94, blue: 0.85)).overlay(Circle().stroke(.gray, lineWidth: 1))
                            .frame(width: 24, height: 24).frame(width: 44, height: 44)
                    }.buttonStyle(.plain).accessibilityLabel("score.coverPaper".localized).accessibilityIdentifier("scoreCoverPaper")
                }
                Stepper(value: $style.padding, in: ScoreFingeringCover.paddingRange, step: 0.5) {
                    Text("score.coverPadding".localized + " · " + style.padding.formatted(.number.precision(.fractionLength(1))) + " pt")
                        .font(.subheadline).monospacedDigit()
                }.accessibilityIdentifier("scoreCoverPadding")
                Text("score.coverHint".localized).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
