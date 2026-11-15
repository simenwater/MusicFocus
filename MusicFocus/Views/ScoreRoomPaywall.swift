import SwiftUI
import StoreKit

/// Opening internet rooms on the international node. Never shown for mainland China.
struct ScoreRoomPaywall: View {
    @ObservedObject var subscription: ScoreRoomSubscription
    @Environment(\.dismiss) private var dismiss
    @State private var managing = false
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyURL = URL(string: "https://feuxfollets.top/apps/MusicFocus/privacy.html")!

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "globe").font(.system(size: 44)).foregroundStyle(.tint)
                        Text("score.sync.remotePaywallTitle".localized).font(.title2.weight(.semibold))
                        Text("score.sync.remotePaywallSubtitle".localized)
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    Label("score.sync.remotePaywallOpen".localized, systemImage: "plus.bubble")
                    Label("score.sync.remotePaywallJoinFree".localized, systemImage: "person.2")
                    Label("score.sync.remotePaywallLocalFree".localized, systemImage: "ipad.landscape")
                }
                purchaseSection
                Section {
                    Button("score.sync.remotePaywallRestore".localized) { Task { await subscription.restore() } }
                        .disabled(busy)
                        .accessibilityIdentifier("scoreRoomRestore")
                    Button("score.sync.remoteManageSubscription".localized) { managing = true }
                        .accessibilityIdentifier("scoreRoomManage")
                } footer: { disclosure }
            }
            .navigationTitle("score.sync.remotePaywallTitle".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done".localized) { dismiss() }.accessibilityIdentifier("scoreRoomPaywallDone")
                }
            }
        }
        .manageSubscriptionsSheet(isPresented: $managing)
        .task {
            subscription.clearOutcome()
            await subscription.refresh()
            await subscription.loadOffer()
        }
        .onChange(of: subscription.purchaseState) { _, state in
            if state == .purchased || state == .restored { dismiss() }
        }
    }

    private var busy: Bool { [.purchasing, .restoring].contains(subscription.purchaseState) }

    @ViewBuilder private var purchaseSection: some View {
        Section {
            if subscription.isSubscribed {
                Label("score.sync.remotePaywallSubscribed".localized, systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else if let offer = subscription.offer {
                LabeledContent(offer.title, value: price(offer))
                if let intro = offer.intro { Text(introText(intro)).font(.subheadline).foregroundStyle(.secondary) }
                Button {
                    Task { await subscription.purchase() }
                } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView() } else { Text("score.sync.remotePaywallSubscribe".localized).bold() }
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || subscription.purchaseState == .pending)
                .accessibilityIdentifier("scoreRoomSubscribe")
            } else if subscription.offerUnavailable {
                Text("score.sync.remotePaywallUnavailable".localized).foregroundStyle(.secondary)
                Button("score.sync.remotePaywallRetry".localized) { Task { await subscription.loadOffer() } }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            if let message = stateMessage {
                Label(message.text, systemImage: message.icon).font(.callout).foregroundStyle(message.color)
                    .accessibilityIdentifier("scoreRoomPurchaseState")
            }
        }
    }

    private var stateMessage: (text: String, icon: String, color: Color)? {
        switch subscription.purchaseState {
        case .pending: return ("score.sync.remotePaywallPending".localized, "hourglass", .secondary)
        case .cancelled: return ("score.sync.remotePaywallCancelled".localized, "xmark.circle", .secondary)
        case .nothingToRestore: return ("score.sync.remotePaywallNothingToRestore".localized, "info.circle", .secondary)
        case .failed(let message): return (message, "exclamationmark.triangle", .orange)
        case .idle, .purchasing, .restoring, .purchased, .restored: return nil
        }
    }

    private func price(_ offer: ScoreRoomOffer) -> String {
        "score.sync.remotePaywallPrice".localizedFormat(offer.price, ScoreRoomSubscription.describe(offer.period))
    }

    private func introText(_ intro: ScoreRoomOffer.Intro) -> String {
        var total = intro.period
        for unit in [Calendar.Component.year, .month, .weekOfMonth, .day] {
            if let value = total.value(for: unit) { total.setValue(value * max(intro.count, 1), for: unit) }
        }
        let length = ScoreRoomSubscription.describe(total), each = ScoreRoomSubscription.describe(intro.period)
        switch intro.mode {
        case .freeTrial: return "score.sync.remotePaywallIntroFree".localizedFormat(length)
        case .payUpFront: return "score.sync.remotePaywallIntroPayUpFront".localizedFormat(intro.price, length)
        case .payAsYouGo: return "score.sync.remotePaywallIntroPayAsYouGo".localizedFormat(intro.price, each, length)
        }
    }

    /// Apple's auto-renewal disclosure, with the title, length and price as StoreKit reports them.
    @ViewBuilder private var disclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let offer = subscription.offer {
                Text("score.sync.remotePaywallDisclosure".localizedFormat(
                    offer.title, ScoreRoomSubscription.describe(offer.period), offer.price))
            }
            HStack(spacing: 16) {
                Link("score.sync.remotePaywallTerms".localized, destination: Self.termsURL)
                Link("score.sync.remotePaywallPrivacy".localized, destination: Self.privacyURL)
            }
            .font(.footnote)
        }
    }
}
