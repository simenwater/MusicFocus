import MultipeerConnectivity
import UIKit

/// Finds nearby iPads over Bluetooth / peer-to-peer Wi-Fi / the local network
/// (MultipeerConnectivity picks). No server and no internet; the session is
/// encrypted and nothing but the advertised name is visible before connecting.
/// One peer at a time: a teacher with one student.
@MainActor
final class ScoreSyncNearby: NSObject, ObservableObject, ScoreSyncTransport {
    nonisolated static let serviceType = "mf-scoresync"
    private static let nameKey = "score.sync.deviceName"
    private static let peerKey = "score.sync.peerID"

    struct Invitation: Identifiable {
        let id = UUID()
        let peer: MCPeerID
        fileprivate let reply: (Bool, MCSession?) -> Void
    }

    @Published private(set) var nearby: [MCPeerID] = []
    @Published private(set) var connected: MCPeerID?
    @Published private(set) var connecting: MCPeerID?
    @Published var invitation: Invitation?
    @Published private(set) var running = false
    var onConnect: ((ScoreSyncNearby) -> Void)?
    var onDisconnect: (() -> Void)?
    var onReceive: ((Data) -> Void)?
    var peerName: String { connected?.displayName ?? "" }

    private(set) var me: MCPeerID
    private var session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser
    private var browser: MCNearbyServiceBrowser
    private let defaults: UserDefaults
    private var early: [Data] = []

    /// UIDevice.name is just "iPad" on current iPadOS, so the name is editable.
    static func savedName(_ defaults: UserDefaults = .standard) -> String {
        let saved = defaults.string(forKey: nameKey)
        let name = safeName(saved ?? UIDevice.current.name)
        // Repair names saved by older builds before constructing MCPeerID.
        if let saved, saved != name { defaults.set(name, forKey: nameKey) }
        return name
    }

    /// MCPeerID's limit is 63 UTF-8 bytes, not 63 characters. Never split a
    /// grapheme (Chinese, emoji, combining marks) or pass an empty string.
    static func safeName(_ raw: String) -> String {
        var name = "", bytes = 0
        for character in raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40) {
            let size = String(character).utf8.count
            guard bytes + size <= 63 else { break }
            name.append(character)
            bytes += size
        }
        return name.isEmpty ? "iPad" : name
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        me = Self.peer(named: Self.savedName(defaults), defaults: defaults)
        session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: nil, serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: me, serviceType: Self.serviceType)
        super.init()
        wire()
    }

    /// Reusing the archived peer ID avoids showing the same iPad twice to others.
    private static func peer(named name: String, defaults: UserDefaults) -> MCPeerID {
        let name = safeName(name)
        if let data = defaults.data(forKey: peerKey),
           let saved = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data),
           saved.displayName == name { return saved }
        let peer = MCPeerID(displayName: name)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: peer, requiringSecureCoding: true) {
            defaults.set(data, forKey: peerKey)
        }
        return peer
    }

    private func wire() {
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    func start() {
        guard !running else { return }
        running = true
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func stop() {
        running = false
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        resetConnection()
        nearby.removeAll()
        early.removeAll()
        invitation?.reply(false, nil)
        invitation = nil
        connecting = nil
        setConnected(nil)
    }

    /// Renaming needs a new peer ID, so it restarts discovery.
    func rename(_ name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let name = Self.safeName(name)
        guard !name.isEmpty, name != me.displayName, connected == nil else { return }
        defaults.set(name, forKey: Self.nameKey)
        let wasRunning = running
        stop()
        me = Self.peer(named: name, defaults: defaults)
        session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: nil, serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: me, serviceType: Self.serviceType)
        wire()
        if wasRunning { start() }
    }

    func invite(_ peer: MCPeerID) {
        guard connected == nil else { return }
        connecting = peer
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 30)
    }

    func answer(_ invitation: Invitation, accept: Bool) {
        if self.invitation?.id == invitation.id { self.invitation = nil }
        let ok = accept && connected == nil
        if ok { connecting = invitation.peer }
        invitation.reply(ok, ok ? session : nil)
    }

    func disconnect() {
        invitation?.reply(false, nil)
        invitation = nil
        resetConnection()
        setConnected(nil)
    }

    /// A reconnect gets a fresh session so late callbacks from the old link
    /// cannot disconnect the new one or deliver stale annotation updates.
    private func resetConnection() {
        session.delegate = nil
        session.disconnect()
        session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        connecting = nil
        early.removeAll()
    }

    func send(_ data: Data) throws {
        guard let connected else { throw ScoreSyncError.invalidPayload }
        try session.send(data, toPeers: [connected], with: .reliable)
    }

    private func setConnected(_ peer: MCPeerID?) {
        guard connected != peer else { return }
        let was = connected
        connected = peer
        let pending = early
        early.removeAll()
        if peer != nil {
            onConnect?(self)
            pending.forEach { onReceive?($0) }
        } else if was != nil { onDisconnect?() }
    }

    fileprivate func stateChanged(_ peer: MCPeerID, _ state: MCSessionState, in changed: MCSession) {
        guard changed === session else { return }
        switch state {
        case .connected:
            if connecting == peer || connecting == nil { connecting = nil; setConnected(peer) }
            else { session.cancelConnectPeer(peer) }
        case .notConnected:
            if connecting == peer { connecting = nil; early.removeAll() }
            if connected == peer { resetConnection(); setConnected(nil) }
        case .connecting: break
        @unknown default: break
        }
    }

    fileprivate func received(_ data: Data, from peer: MCPeerID, in changed: MCSession) {
        guard changed === session else { return }
        if peer == connected { onReceive?(data) }
        // Data can arrive just before the "connected" callback.
        else if peer == connecting { early.append(data) }
    }

    fileprivate func found(_ peer: MCPeerID) {
        guard peer != me, !nearby.contains(peer) else { return }
        nearby.append(peer)
    }

    fileprivate func lost(_ peer: MCPeerID) { nearby.removeAll { $0 == peer } }

    fileprivate func invited(by peer: MCPeerID, reply: @escaping (Bool, MCSession?) -> Void) {
        // The user confirms every connection; a second one is refused.
        guard connected == nil, invitation == nil else { reply(false, nil); return }
        invitation = Invitation(peer: peer, reply: reply)
    }
}

extension ScoreSyncNearby: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    /// The main queue keeps delegate callbacks (and so received messages) in order.
    private nonisolated func onMain(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        onMain { self.stateChanged(peerID, state, in: session) }
    }
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        onMain { self.received(data, from: peerID, in: session) }
    }
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        stream.close()
    }
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        progress.cancel()
    }
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        onMain { self.invited(by: peerID, reply: invitationHandler) }
    }
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {}

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        onMain { self.found(peerID) }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        onMain { self.lost(peerID) }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {}
}
