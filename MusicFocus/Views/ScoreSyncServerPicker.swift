import SwiftUI

/// Read-only: a room chooses its relay once and invitations carry that node.
struct ScoreSyncServerPicker: View {
    var disabled = false
    @ObservedObject private var region = ScoreServiceRegion.shared
    var body: some View {
        if ScoreSyncAvailability.internet {
            LabeledContent("score.sync.region".localized, value: region.title)
                .accessibilityIdentifier("scoreSyncServiceRegion")
            Text("score.sync.storefrontHint".localized)
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
