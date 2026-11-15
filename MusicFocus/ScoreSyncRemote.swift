import Foundation
import Combine

/// Public internet rooms are a development-only feature until the service is
/// ready for release. This cannot be enabled by saved settings or an invitation.
enum ScoreSyncAvailability {
    #if DEBUG
    static let internet = true
    #else
    static let internet = false
    #endif
}

struct ScoreRoomInvitation: Equatable {
    enum Node: String {
        case cn, global
        var server: String { self == .cn ? "wss://feuxfollets.top/mfsync" : "wss://712art.com/mfsync" }
        init?(server: String) {
            guard let node = [Node.cn, .global].first(where: { $0.server == server }) else { return nil }
            self = node
        }
    }
    let node: Node
    let code: String
    let digest: String
    var url: URL { URL(string: "musicfocus://join/\(node.rawValue)/\(code)/\(digest)")! }
    init?(server: String, code: String, digest: String) {
        guard let node = Node(server: server),
              code.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }),
              digest.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        self.node = node; self.code = code; self.digest = digest
    }
    init?(url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard url.scheme == "musicfocus", url.host == "join", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil, parts.count == 3,
              let node = Node(rawValue: parts[0]) else { return nil }
        self.init(server: node.server, code: parts[1], digest: parts[2])
    }
}

@MainActor
final class ScoreSyncRemote: NSObject, ObservableObject, ScoreSyncTransport {
    enum State: Equatable {
        case idle, waiting(code: String), connected(code: String, peer: String), failed(code: String, message: String)
    }
    // Legacy mapping retained for migrations/tests; production routing uses StoreKit.
    nonisolated static func defaultServer(for region: String?) -> String {
        region == "CN" ? ScoreRoomInvitation.Node.cn.server : ScoreRoomInvitation.Node.global.server
    }
    @Published private(set) var state = State.idle
    @Published private(set) var roomConfirmed = false
    @Published private(set) var resolvingRegion = false
    @Published private(set) var checkingSubscription = false
    /// Set when "create room" on the international node finds no subscription; the panel shows the paywall.
    @Published var paywallRequested = false
    /// The relay (or a reconnect) refused the room for want of a subscription.
    @Published private(set) var subscriptionRequired = false
    /// A joiner arrived before the host opened the room; retries continue.
    @Published private(set) var waitingForHost = false
    private(set) var roomServer: String?
    private(set) var roomNode: ScoreRoomInvitation.Node?
    private(set) var hosting = false
    var onConnect: ((ScoreSyncRemote) -> Void)?
    var onDisconnect: (() -> Void)?
    var onReceive: ((Data) -> Void)?
    var peerName: String { if case let .connected(_, peer) = state { return peer }; return "" }
    var code: String? {
        switch state {
        case .idle: return nil
        case .waiting(let code), .connected(let code, _), .failed(let code, _): return code
        }
    }
    var isConnected: Bool { if case .connected = state { return true }; return false }
    private let defaults: UserDefaults
    private let urlSession: URLSession
    private let serviceRegion: ScoreServiceRegion
    private let entitlement: ScoreRoomEntitlementSource
    private var entitlementObservation: AnyCancellable?
    private var task: URLSessionWebSocketTask?
    private var retry: Task<Void, Never>?
    private var joining: Task<Void, Never>?
    private var opening: Task<Void, Never>?
    private var roomFile: String?
    private var failures = 0
    #if DEBUG
    /// Tests redirect sockets here so they never reach a public relay.
    var makeTask: ((URL) -> URLSessionWebSocketTask)?
    private var testServerOverride: String?
    var server: String {
        get { testServerOverride ?? serviceRegion.node?.server ?? ScoreRoomInvitation.Node.cn.server }
        set { testServerOverride = newValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    #else
    var server: String { serviceRegion.node?.server ?? ScoreRoomInvitation.Node.cn.server }
    #endif
    init(defaults: UserDefaults = .standard, serviceRegion: ScoreServiceRegion? = nil,
         entitlement: ScoreRoomEntitlementSource? = nil) {
        self.defaults = defaults; self.serviceRegion = serviceRegion ?? .shared
        self.entitlement = entitlement ?? ScoreRoomSubscription.shared
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        urlSession = URLSession(configuration: configuration)
        super.init()
        entitlementObservation = self.entitlement.entitlementChanges()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.resumeAfterSubscriptionChange() }
            }
    }
    func canJoin(_ invitation: ScoreRoomInvitation) -> Bool {
        ScoreSyncAvailability.internet && serviceRegion.permits(invitation.node)
    }
    nonisolated static func newCode() -> String { String(format: "%06d", Int.random(in: 0..<1_000_000)) }
    nonisolated static func normalizedCode(_ text: String) -> String? {
        let digits = text.filter(\.isASCII).filter(\.isNumber)
        return digits.count == 6 ? digits : nil
    }
    /// The relay pairs only devices whose room URL names the same file.
    nonisolated static func roomFile(for digest: String?) -> String? {
        guard let digest, digest.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return String(digest.prefix(16))
    }
    nonisolated static func roomURL(server: String, code: String, name: String, file: String, host: Bool = false) -> URL? {
        var components = URLComponents(string: server.hasSuffix("/") ? String(server.dropLast()) : server)
        components?.path += "/v1/rooms/\(code)"
        components?.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "file", value: file)]
            + (host ? [URLQueryItem(name: "host", value: "1")] : [])
        guard let url = components?.url, ["ws", "wss"].contains(url.scheme ?? "") else { return nil }
        return url
    }
    /// The message for a relay close code that should not be retried; nil means try again.
    nonisolated static func stopMessageKey(forCloseCode closeCode: Int) -> String? {
        switch closeCode {
        case 4002: return "score.sync.remoteSubscriptionRequired"
        case 4003: return "score.sync.remoteDifferentScore"
        case 4004: return "score.sync.remoteBadServer"
        case 4008: return "score.sync.remoteExpired"
        case 4009: return "score.sync.remoteFull"
        case 4029: return "score.sync.remoteTooManyAttempts"
        default: return nil
        }
    }
    /// The message while a closed room is retried.
    nonisolated static func retryMessageKey(forCloseCode closeCode: Int) -> String {
        switch closeCode {
        case 4010: return "score.sync.remoteRoomNotOpen"
        case 4011: return "score.sync.remoteSubscriptionUnavailable"
        default: return "score.sync.remoteRetrying"
        }
    }
    enum HostRequirement: Equatable { case none, subscription, knownRegion }
    /// Only opening a room on the international node is paid; joining and mainland China are free.
    nonisolated static func hostRequirement(node: ScoreRoomInvitation.Node?, hosting: Bool) -> HostRequirement {
        guard hosting else { return .none }
        guard let node else { return .knownRegion }
        return node == .global ? .subscription : .none
    }
    nonisolated static func entitlementFrame(jws: String) -> String {
        let frame = try? JSONSerialization.data(withJSONObject: ["type": "entitlement", "jws": jws], options: [.sortedKeys])
        return frame.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    /// Backs off so a long outage stays well under the relay's join limit.
    nonisolated static func retryDelay(afterFailures failures: Int) -> Duration {
        .seconds([3, 6, 12, 30][min(max(failures, 0), 3)])
    }

    /// Opens a new room as its host ("create room").
    func host(_ code: String, file digest: String?) { start(code, file: digest, on: nil, hosting: true) }

    /// `digest` is the score's SHA-256; joining fails while it is not yet known.
    func join(_ code: String, file digest: String?, on invitedServer: String? = nil) {
        start(code, file: digest, on: invitedServer, hosting: false)
    }

    private func start(_ code: String, file digest: String?, on invitedServer: String?, hosting: Bool) {
        leave()
        self.hosting = hosting
        guard ScoreSyncAvailability.internet else {
            setState(.failed(code: code, message: "score.sync.remoteDisabled".localized))
            return
        }
        guard let file = Self.roomFile(for: digest) else {
            setState(.failed(code: code, message: "score.sync.remoteNoScore".localized))
            return
        }
        roomFile = file
        #if DEBUG
        if let testServerOverride {
            roomServer = invitedServer ?? testServerOverride
            roomNode = invitedServer.flatMap(ScoreRoomInvitation.Node.init(server:)) ?? serviceRegion.node
            open(code)
            return
        }
        #endif
        if serviceRegion.node != nil { joinResolved(code, invitedServer: invitedServer); return }
        resolvingRegion = true
        joining = Task { [weak self] in
            guard let self else { return }
            await self.serviceRegion.refresh()
            guard !Task.isCancelled else { return }
            self.resolvingRegion = false
            self.joinResolved(code, invitedServer: invitedServer)
        }
    }

    private func joinResolved(_ code: String, invitedServer: String?) {
        guard let own = serviceRegion.node else {
            setState(.failed(code: code, message: "score.sync.regionUnavailable".localized)); return
        }
        let node: ScoreRoomInvitation.Node
        if let invitedServer {
            guard let known = ScoreRoomInvitation.Node(server: invitedServer) else {
                setState(.failed(code: code, message: "score.sync.remoteBadServer".localized)); return
            }
            node = known
        } else { node = own }
        guard serviceRegion.permits(node) else {
            setState(.failed(code: code, message: "score.sync.mainlandHostRequired".localized)); return
        }
        roomServer = node.server
        roomNode = node
        open(code)
    }

    func leave() {
        joining?.cancel(); joining = nil; resolvingRegion = false
        opening?.cancel(); opening = nil; checkingSubscription = false
        roomConfirmed = false; subscriptionRequired = false; waitingForHost = false; paywallRequested = false
        retry?.cancel()
        retry = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        roomServer = nil
        roomNode = nil
        hosting = false
        roomFile = nil
        failures = 0
        setState(.idle)
    }

    func send(_ data: Data) throws {
        guard ScoreSyncAvailability.internet, isConnected, let task, let code else { throw ScoreSyncError.invalidPayload }
        task.send(.data(data)) { [weak self] error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // WebSocket sends finish asynchronously. Losing this write
                    // invalidates the session; reconnect starts a fresh sync.
                    self?.closed(task, code: code)
                }
            }
        }
    }

    // MARK: Connection

    private func open(_ code: String) {
        #if DEBUG
        guard let server = roomServer, let roomFile else { return }
        guard let url = Self.roomURL(server: server, code: code, name: ScoreSyncNearby.savedName(defaults),
                                     file: roomFile, host: hosting) else {
            setState(.failed(code: code, message: "score.sync.remoteBadServer".localized))
            return
        }
        switch Self.hostRequirement(node: roomNode, hosting: hosting) {
        case .none: connect(url, code: code, first: nil)
        case .knownRegion: setState(.failed(code: code, message: "score.sync.regionUnavailable".localized))
        case .subscription:
            // Every attempt, reconnects included, presents the newest transaction.
            checkingSubscription = true
            opening = Task { [weak self] in
                let jws = await self?.entitlement.currentJWS()
                guard let self, !Task.isCancelled, self.task == nil else { return }
                self.opening = nil
                self.checkingSubscription = false
                if let jws { self.connect(url, code: code, first: Self.entitlementFrame(jws: jws)) }
                else { self.refuseHost(code) }
            }
        }
        #else
        // Keep the actual WebSocket construction out of distribution builds.
        leave()
        setState(.failed(code: code, message: "score.sync.remoteDisabled".localized))
        #endif
    }

    #if DEBUG
    private func connect(_ url: URL, code: String, first frame: String?) {
        let task = makeTask?(url) ?? urlSession.webSocketTask(with: url)
        task.maximumMessageSize = 32 * 1024 * 1024
        self.task = task
        if case .connected = state {} else { setState(.waiting(code: code)) }
        task.resume()
        if let frame {
            task.send(.string(frame)) { [weak self] error in
                guard error != nil else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.closed(task, code: code) } }
            }
        }
        receive(on: task, code: code)
    }
    #endif

    /// No subscription: a first attempt shows the paywall; a reconnect stops with a message.
    private func refuseHost(_ code: String) {
        let firstAttempt = state == .idle
        retry?.cancel(); retry = nil
        subscriptionRequired = true
        // Retain the room, file and pinned node while the paywall is open.
        setState(.failed(code: code, message: "score.sync.remoteSubscriptionRequired".localized))
        if firstAttempt { paywallRequested = true }
    }

    private func resumeAfterSubscriptionChange() {
        guard ScoreSyncAvailability.internet, subscriptionRequired, hosting, roomNode == .global,
              roomServer != nil, roomFile != nil, let code, task == nil, !checkingSubscription else { return }
        subscriptionRequired = false
        paywallRequested = false
        failures = 0
        open(code)
    }

    private func receive(on task: URLSessionWebSocketTask, code: String) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.task === task else { return }
                    switch result {
                    case .success(let message):
                        self.handle(message, code: code)
                        self.receive(on: task, code: code)
                    case .failure:
                        self.closed(task, code: code)
                    }
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, code: String) {
        switch message {
        case .data(let data):
            if isConnected { onReceive?(data) }
        case .string(let text):
            struct Control: Decodable { var type: String; var name: String? }
            guard let control = try? JSONDecoder().decode(Control.self, from: Data(text.utf8)) else { return }
            switch control.type {
            case "peer":
                roomConfirmed = true; failures = 0; waitingForHost = false
                setState(.connected(code: code, peer: control.name ?? ""))
            case "waiting", "left":
                roomConfirmed = true; failures = 0; waitingForHost = false
                setState(.waiting(code: code))
            default: break
            }
        @unknown default: break
        }
    }

    /// Network trouble: keep the room and try again; a refusal by the relay stops.
    private func closed(_ task: URLSessionWebSocketTask, code: String) {
        guard self.task === task else { return }
        roomConfirmed = false
        let closeCode = task.closeCode.rawValue
        self.task = nil
        task.cancel(with: .goingAway, reason: nil)
        retry?.cancel()
        retry = nil
        if let key = Self.stopMessageKey(forCloseCode: closeCode) {
            waitingForHost = false
            // The mainland relay never asks for one; never offer a purchase there.
            subscriptionRequired = closeCode == 4002 && roomNode == .global
            setState(.failed(code: code, message: key.localized))
        } else {
            waitingForHost = closeCode == 4010
            setState(.failed(code: code, message: Self.retryMessageKey(forCloseCode: closeCode).localized))
            let delay = Self.retryDelay(afterFailures: failures)
            failures += 1
            retry = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.task == nil, self.code == code else { return }
                self.open(code)
            }
        }
    }

    private func setState(_ new: State) {
        let wasConnected = isConnected
        state = new
        if isConnected && !wasConnected { onConnect?(self) }
        else if !isConnected && wasConnected { onDisconnect?() }
    }
}
