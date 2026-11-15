import SwiftUI

struct ScoreCoverControls: View {
    @ObservedObject var reader: ScoreReaderController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("score.cover".localized).font(.subheadline.weight(.semibold))
                Spacer()
                if reader.selectedCover != nil {
                    Button { reader.deleteSelectedCover() } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Delete".localized).accessibilityIdentifier("scoreCoverDelete")
                    Button { reader.selectCover(nil) } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close".localized).accessibilityIdentifier("scoreCoverDismiss")
                }
            }.buttonStyle(.plain).frame(minHeight: 36)
            HStack(spacing: 12) {
                Button { reader.chooseCoverColor(.white) } label: {
                    HStack(spacing: 5) { swatch(.white); Text("score.coverWhite".localized) }
                }.accessibilityIdentifier("scorePageCoverWhite")
                Button { reader.chooseCoverColor(UIColor(red: 0.97, green: 0.94, blue: 0.85, alpha: 1)) } label: {
                    HStack(spacing: 5) { swatch(Color(red: 0.97,green: 0.94,blue: 0.85)); Text("score.coverPaper".localized) }
                }.accessibilityIdentifier("scorePageCoverPaper")
                Spacer(minLength: 0)
                ColorPicker("score.customColor".localized,selection: Binding(
                    get: { Color(uiColor: (reader.selectedCover?.color ?? reader.coverColor).uiColor) },
                    set: { reader.chooseCoverColor(UIColor($0)) }),supportsOpacity: false)
                    .labelsHidden().accessibilityIdentifier("scorePageCoverColor")
            }.font(.caption).lineLimit(1).minimumScaleFactor(0.8).buttonStyle(.bordered).tint(.primary).frame(minHeight: 44)
            Text("score.pageCoverHint".localized).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scoreCoverControls")
    }
    private func swatch(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 16,height: 16).overlay(Circle().stroke(.gray.opacity(0.5),lineWidth: 1))
    }
}
