import Foundation
import StoreKit
import Combine

/// What the relay needs from the subscription: the newest verified transaction, or nil.
@MainActor
protocol ScoreRoomEntitlementSource: AnyObject {
    func currentJWS() async -> String?
    func entitlementChanges() -> AnyPublisher<Void, Never>
}

extension ScoreRoomEntitlementSource {
    func entitlementChanges() -> AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
}

/// A transaction as far as the entitlement decision cares; built from StoreKit or by tests.
struct ScoreRoomTransaction: Equatable {
    var productID: String
    var jws: String
    var verified: Bool
    var purchaseDate: Date
    var expirationDate: Date?
    var revocationDate: Date?
    /// StoreKit keeps a lapsed renewal in `currentEntitlements` during a billing grace period.
    var inGracePeriod = false
}

struct ScoreRoomOffer: Equatable {
    struct Intro: Equatable {
        enum Mode { case freeTrial, payUpFront, payAsYouGo }
        var mode: Mode
        var price: String
        var period: DateComponents
        var count: Int
    }
    var title: String
    var price: String
    var period: DateComponents
    var intro: Intro?
}

enum ScoreRoomPurchaseResult: Equatable { case purchased(ScoreRoomTransaction), pending, cancelled }

/// The App Store calls, behind a seam so the decisions can be tested without it.
@MainActor
protocol ScoreRoomStore: AnyObject {
    func offer() async throws -> ScoreRoomOffer?
    func entitlements() async -> [ScoreRoomTransaction]
    func purchase() async throws -> ScoreRoomPurchaseResult
    func sync() async throws
    /// Yields whenever a transaction arrives outside a purchase (renewal, refund, Ask to Buy approval).
    func updates() -> AsyncStream<Void>
}

@MainActor
final class ScoreRoomSubscription: ObservableObject, ScoreRoomEntitlementSource {
    nonisolated static let productID = "com.FeuxFollets.MusicFocus.rooms.yearly"
    static let shared = ScoreRoomSubscription()

    enum PurchaseState: Equatable {
        case idle, purchasing, restoring, pending, cancelled, purchased, restored, nothingToRestore, failed(String)
    }
    @Published private(set) var offer: ScoreRoomOffer?
    @Published private(set) var offerUnavailable = false
    @Published private(set) var isSubscribed = false
    @Published private(set) var purchaseState = PurchaseState.idle
    private let store: ScoreRoomStore
    private let now: () -> Date
    private var listener: Task<Void, Never>?
    private let transactionChanges = PassthroughSubject<Void, Never>()

    init(store: ScoreRoomStore? = nil, now: @escaping () -> Date = Date.init) {
        self.store = store ?? ScoreRoomAppStore()
        self.now = now
    }

    /// Unverified, revoked, lapsed (outside grace) or other products never count.
    nonisolated static func entitlement(in transactions: [ScoreRoomTransaction], now: Date) -> ScoreRoomTransaction? {
        transactions.filter { transaction in
            transaction.verified && transaction.productID == productID && transaction.revocationDate == nil
                && (transaction.inGracePeriod || (transaction.expirationDate.map { $0 > now } ?? false))
        }.max { $0.purchaseDate < $1.purchaseDate }
    }

    /// Call once at launch; keeps listening for the app's lifetime.
    func start() {
        guard listener == nil else { return }
        let updates = store.updates()
        listener = Task { [weak self] in
            await self?.refresh()
            for await _ in updates {
                guard let self else { return }
                await self.refresh()
                if self.purchaseState == .pending && self.isSubscribed { self.purchaseState = .purchased }
                if self.isSubscribed { self.transactionChanges.send() }
            }
        }
    }

    @discardableResult
    func refresh() async -> ScoreRoomTransaction? {
        let current = Self.entitlement(in: await store.entitlements(), now: now())
        isSubscribed = current != nil
        return current
    }

    /// Queried fresh each time: renewals issue new transactions.
    func currentJWS() async -> String? { await refresh()?.jws }

    /// Resume a pending room after purchase, restore, renewal or Ask to Buy approval.
    /// Successful restore also matters when the local entitlement was already active.
    func entitlementChanges() -> AnyPublisher<Void, Never> {
        Publishers.Merge3(
            $isSubscribed.removeDuplicates().filter { $0 }.map { _ in () },
            $purchaseState.filter { $0 == .purchased || $0 == .restored }.map { _ in () },
            transactionChanges
        ).eraseToAnyPublisher()
    }

    /// A fresh paywall starts without the previous attempt's outcome.
    func clearOutcome() {
        if ![.purchasing, .restoring, .pending].contains(purchaseState) { purchaseState = .idle }
    }

    func loadOffer() async {
        do {
            offer = try await store.offer()
            offerUnavailable = offer == nil
        } catch { offerUnavailable = offer == nil }
    }

    func purchase() async {
        guard purchaseState != .purchasing, purchaseState != .restoring else { return }
        purchaseState = .purchasing
        do {
            switch try await store.purchase() {
            case .purchased(let transaction):
                await refresh()
                purchaseState = transaction.verified && isSubscribed
                    ? .purchased : .failed("score.sync.remotePaywallUnverified".localized)
            case .pending: purchaseState = .pending
            case .cancelled: purchaseState = .cancelled
            }
        } catch StoreKitError.userCancelled {
            purchaseState = .cancelled
        } catch {
            purchaseState = .failed("score.sync.remotePaywallFailed".localizedFormat(error.localizedDescription))
        }
    }

    func restore() async {
        guard purchaseState != .purchasing, purchaseState != .restoring else { return }
        purchaseState = .restoring
        do {
            try await store.sync()
            await refresh()
            purchaseState = isSubscribed ? .restored : .nothingToRestore
        } catch StoreKitError.userCancelled {
            purchaseState = .idle
        } catch {
            purchaseState = .failed("score.sync.remotePaywallFailed".localizedFormat(error.localizedDescription))
        }
    }

    /// "1 year", "1年": the period as StoreKit reports it, in the app's language.
    nonisolated static func describe(_ period: DateComponents) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.year, .month, .weekOfMonth, .day]
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = AppLocalization.locale
        formatter.calendar = calendar
        return formatter.string(from: period) ?? ""
    }

    deinit { listener?.cancel() }
}

extension Product.SubscriptionPeriod {
    var components: DateComponents {
        switch unit {
        case .day: return DateComponents(day: value)
        case .week: return DateComponents(weekOfMonth: value)
        case .month: return DateComponents(month: value)
        case .year: return DateComponents(year: value)
        @unknown default: return DateComponents(day: value)
        }
    }
}

/// The real App Store (or the StoreKit configuration file selected in the scheme).
@MainActor
final class ScoreRoomAppStore: ScoreRoomStore {
    private var product: Product?

    private func loadProduct() async throws -> Product? {
        if let product { return product }
        product = try await Product.products(for: [ScoreRoomSubscription.productID]).first
        return product
    }

    func offer() async throws -> ScoreRoomOffer? {
        guard let product = try await loadProduct(), let subscription = product.subscription else { return nil }
        var intro: ScoreRoomOffer.Intro?
        if let offer = subscription.introductoryOffer, await subscription.isEligibleForIntroOffer {
            let mode: ScoreRoomOffer.Intro.Mode
            switch offer.paymentMode {
            case .freeTrial: mode = .freeTrial
            case .payUpFront: mode = .payUpFront
            default: mode = .payAsYouGo
            }
            intro = .init(mode: mode, price: offer.displayPrice, period: offer.period.components, count: offer.periodCount)
        }
        return .init(title: product.displayName, price: product.displayPrice,
                     period: subscription.subscriptionPeriod.components, intro: intro)
    }

    func entitlements() async -> [ScoreRoomTransaction] {
        var found: [ScoreRoomTransaction] = []
        for await result in Transaction.currentEntitlements {
            guard result.unsafePayloadValue.productID == ScoreRoomSubscription.productID else { continue }
            var transaction = Self.transaction(result)
            if case .verified(let payload) = result, let expiry = payload.expirationDate, expiry <= Date(),
               let group = payload.subscriptionGroupID {
                transaction.inGracePeriod = await Self.inGracePeriod(group: group)
            }
            found.append(transaction)
        }
        return found
    }

    func purchase() async throws -> ScoreRoomPurchaseResult {
        guard let product = try await loadProduct() else { throw StoreKitError.notAvailableInStorefront }
        switch try await product.purchase() {
        case .success(let result):
            if case .verified(let transaction) = result { await transaction.finish() }
            return .purchased(Self.transaction(result))
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: return .cancelled
        }
    }

    func sync() async throws { try await AppStore.sync() }

    func updates() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task.detached {
                for await result in Transaction.updates {
                    if case .verified(let transaction) = result { await transaction.finish() }
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func transaction(_ result: VerificationResult<Transaction>) -> ScoreRoomTransaction {
        let payload = result.unsafePayloadValue
        let verified: Bool
        if case .verified = result { verified = true } else { verified = false }
        return .init(productID: payload.productID, jws: result.jwsRepresentation, verified: verified,
                     purchaseDate: payload.purchaseDate, expirationDate: payload.expirationDate,
                     revocationDate: payload.revocationDate)
    }

    private static func inGracePeriod(group: String) async -> Bool {
        guard let statuses = try? await Product.SubscriptionInfo.status(for: group) else { return false }
        return statuses.contains { status in
            guard case .verified(let renewal) = status.renewalInfo,
                  renewal.currentProductID == ScoreRoomSubscription.productID else { return false }
            return status.state == .inGracePeriod
        }
    }
}
