import SwiftUI

/**
 * @struct BadgeGuideView
 * @description 勋章说明页面
 */
struct BadgeGuideView: View {
    @Environment(\.dismiss) private var dismiss
    
    private let badgeLevels = BadgeLevel.allCases
    
    private func getTimeRangeText(_ range: ClosedRange<Double>) -> String {
        TimeFormatter.formatBadgeRange(range)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Earn badges by reaching daily practice time requirements. Only the highest level badge is displayed for each day.".localized)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } header: {
                    Text("Badge Rules".localized)
                }

                Section {
                    ForEach(badgeLevels, id: \.self) { level in
                        HStack(spacing: 16) {
                            BadgeView(badge: Badge(level: level), size: 30)
                                .frame(width: 60)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(level.displayName)
                                    .font(.headline)

                                Text("Practice time: %@".localizedFormat(getTimeRangeText(level.timeRange)))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Badge Levels".localized)
                } footer: {
                    Text("Keep practicing and collect all badges!".localized)
                }
            }
            .navigationTitle("Badge Guide".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close".localized) {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    BadgeGuideView()
}
