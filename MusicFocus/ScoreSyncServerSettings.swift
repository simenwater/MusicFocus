import Foundation
import StoreKit
import Combine

/// Service territory follows the App Store storefront, never the device's
/// language, Locale region, or a previously entered custom relay URL.
@MainActor
final class ScoreServiceRegion: ObservableObject {
    static let shared = ScoreServiceRegion()
    static let cacheKey = "score.sync.verifiedStorefront.v1"
    @Published private(set) var countryCode: String?
    private let defaults: UserDefaults
    private var updates: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, countryCode: String? = nil, observesStorefront: Bool = true) {
        self.defaults = defaults
        let cached = countryCode ?? defaults.string(forKey: Self.cacheKey)
        self.countryCode = cached.flatMap { code in
            let value = code.uppercased()
            return value.count == 3 && value.utf8.allSatisfy({ (65...90).contains($0) }) ? value : nil
        }
        if ScoreSyncAvailability.internet && observesStorefront {
            updates = Task { [weak self] in
                await self?.refresh()
                for await storefront in Storefront.updates {
                    guard !Task.isCancelled else { return }
                    self?.accept(storefront.countryCode)
                }
            }
        }
    }
    func refresh() async {
        guard ScoreSyncAvailability.internet else { return }
        if let storefront = await Storefront.current { accept(storefront.countryCode) }
    }
    func accept(_ country: String) {
        let code = country.uppercased()
        guard code.count == 3, code.utf8.allSatisfy({ (65...90).contains($0) }) else { return }
        countryCode = code
        defaults.set(code, forKey: Self.cacheKey)
    }
    var node: ScoreRoomInvitation.Node? {
        guard let countryCode else { return nil }
        return countryCode == "CHN" ? .cn : .global
    }
    var title: String {
        switch node {
        case .cn: return "score.sync.region.china".localized
        case .global: return "score.sync.region.international".localized
        case nil: return "score.sync.regionUnknown".localized
        }
    }
    func permits(_ node: ScoreRoomInvitation.Node) -> Bool {
        guard ScoreSyncAvailability.internet else { return false }
        guard let own = self.node else { return false }
        return own != .cn || node == .cn
    }
    deinit { updates?.cancel() }
}
