import Foundation

/// One connected nearby iPad. Multipeer in the app, an in-memory loopback in tests.
@MainActor
protocol ScoreSyncTransport: AnyObject {
    var peerName: String { get }
    /// Called on the main actor, in the order the peer sent the data.
    var onReceive: ((Data) -> Void)? { get set }
    func send(_ data: Data) throws
}

/// Paired in-memory transports; delivery is asynchronous like the real network.
@MainActor
final class ScoreSyncLoopback: ScoreSyncTransport {
    let peerName: String
    var onReceive: ((Data) -> Void)?
    private weak var other: ScoreSyncLoopback?
    private var delivery: Task<Void, Never>?
    init(peerName: String) { self.peerName = peerName }

    static func pair(_ a: String, _ b: String) -> (ScoreSyncLoopback, ScoreSyncLoopback) {
        let first = ScoreSyncLoopback(peerName: b), second = ScoreSyncLoopback(peerName: a)
        first.other = second; second.other = first
        return (first, second)
    }

    func send(_ data: Data) throws {
        guard let other else { throw ScoreSyncError.invalidPayload }
        let previous = delivery
        delivery = Task { @MainActor in
            await previous?.value
            other.onReceive?(data)
        }
    }
}

/// The per-score sync protocol between two iPads, independent of the network.
///
/// - Full sync: the initiator sends its annotations with the request; the receiver
///   chooses "take theirs" or "send mine". Whichever side is overwritten first
///   saves a backup of its own annotations.
/// - Live lesson: the presenter streams changed pages (ink + fingerings) and PDF
///   annotation edits, throttled; the viewer's copy follows. One direction only.
///   The viewer also follows the presenter's page, zoom and scrolling until the
///   viewer scrolls by hand; `resumeFollowing()` catches up again.
@MainActor
final class ScoreSyncSession: ObservableObject {
    enum Incoming: Identifiable, Equatable {
        case sync(id: UUID, peer: String, theirs: ScoreAnnotationSnapshot, theirSummary: ScoreAnnotationSummary, mySummary: ScoreAnnotationSummary)
        case live(id: UUID, peer: String)
        var id: UUID {
            switch self { case .sync(let id, _, _, _, _), .live(let id, _): return id }
        }
    }
    enum Choice { case takeTheirs, sendMine, decline }
    enum LiveRole: Equatable { case presenting, watching }

    @Published private(set) var identity: ScoreSyncIdentity?
    @Published private(set) var remote: ScoreSyncIdentity?
    @Published private(set) var peerName: String?
    @Published private(set) var incoming: Incoming?
    @Published private(set) var waiting = false
    @Published private(set) var live: LiveRole?
    @Published private(set) var status: String?
    @Published private(set) var backups: [ScoreSyncBackup] = []
    /// Viewer only: showing what the presenter shows.
    @Published private(set) var following = true
    var liveInterval: Duration = .milliseconds(350)
    var viewportInterval: Duration = .milliseconds(120)
    var retryInterval: Duration = .seconds(1)
    /// Remote-controlled during a live lesson (the app's shared metronome).
    var metronome: Metronome?
    /// Presenter: the own metronome only keeps time; the viewer's device clicks.
    @Published var silencePresenterMetronome = UserDefaults.standard.object(forKey: "score.sync.silenceMetronome") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(silencePresenterMetronome, forKey: "score.sync.silenceMetronome")
            if live == .presenting { metronome?.silenced = silencePresenterMetronome }
        }
    }

    var isConnected: Bool { transport != nil }
    var sameBaseFile: Bool {
        guard let identity, let remote else { return false }
        return identity.sameBaseFile(as: remote)
    }
    /// Enough for a live lesson: identical bytes or the same page layout.
    var sameLayout: Bool {
        guard let identity, let remote else { return false }
        return identity.sameLayout(as: remote)
    }

    private var scoreID: UUID?
    private var disk: ScoreLibraryDisk?
    private weak var target: ScoreSyncTarget?
    private var transport: ScoreSyncTransport?
    private var pendingRequest: UUID?
    private var queue: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var lastSent: ScoreAnnotationSnapshot?
    private var viewportTask: Task<Void, Never>?
    private var lastViewport: ScoreSyncViewport?
    private var lastMetronome: ScoreSyncMetronome?
    private var connectionRevision = 0
    private var liveRevision = 0
    private var pushingLive = false
    private var controlsViewerMetronome = false
    private var outgoing: [ScoreSyncMessage] = []
    private var retryTask: Task<Void, Never>?

    func configure(identity: ScoreSyncIdentity, scoreID: UUID, disk: ScoreLibraryDisk, target: ScoreSyncTarget) async {
        self.identity = identity
        self.scoreID = scoreID
        self.disk = disk
        self.target = target
        await reloadBackups()
    }

    func connect(_ transport: ScoreSyncTransport) {
        if self.transport != nil { disconnected() }
        connectionRevision += 1
        let revision = connectionRevision
        self.transport = transport
        peerName = transport.peerName
        status = nil
        transport.onReceive = { [weak self] data in
            guard let self, self.isCurrent(revision) else { return }
            self.enqueue(data, revision: revision)
        }
        sendControl(.hello)
    }

    /// `from`: only that transport's loss ends the session (nearby and remote can both be open).
    func disconnected(from lost: ScoreSyncTransport? = nil) {
        guard let current = transport, lost == nil || lost === current else { return }
        connectionRevision += 1
        queue?.cancel()
        queue = nil
        retryTask?.cancel()
        retryTask = nil
        outgoing.removeAll()
        transport?.onReceive = nil
        transport = nil
        stopLiveLocally()
        remote = nil
        peerName = nil
        incoming = nil
        pendingRequest = nil
        waiting = false
        status = "score.sync.disconnected".localized
    }

    /// Waits until every message received so far has been handled (tests, teardown).
    func settle() async {
        while let current = queue {
            await current.value
            if queue == current { break }
        }
    }

    // MARK: Full sync

    func requestSync() async {
        guard sameBaseFile, !waiting, incoming == nil, live == nil, outgoing.isEmpty, let target else { return }
        let revision = connectionRevision
        waiting = true
        do {
            let mine = try await target.currentAnnotations()
            guard isCurrent(revision) else { return }
            let id = UUID()
            pendingRequest = id
            waiting = true
            status = "score.sync.waitingForChoice".localizedFormat(peerName ?? "")
            if !send(.syncRequest(id: id, snapshot: mine)) {
                pendingRequest = nil
                waiting = false
            }
        } catch {
            guard isCurrent(revision) else { return }
            waiting = false
            status = error.localizedDescription
        }
    }

    func respond(_ choice: Choice) async {
        guard let request = incoming else { return }
        let revision = connectionRevision
        incoming = nil
        waiting = true
        defer { if isCurrent(revision), pendingRequest == nil { waiting = false } }
        switch (request, choice) {
        case let (.sync(id, peer, theirs, _, _), .takeTheirs):
            do {
                try await backupAndReplace(with: theirs, scope: .everything, reason: .sync, peer: peer, revision: revision)
                guard isCurrent(revision) else { return }
                status = "score.sync.tookTheirs".localizedFormat(peer)
                sendControl(.syncReply(id: id, reply: .tookYours))
            } catch {
                guard isCurrent(revision) else { return }
                sendControl(.syncReply(id: id, reply: .failed))
                status = error.localizedDescription
            }
        case let (.sync(id, peer, _, _, _), .sendMine):
            guard let target, let mine = try? await target.currentAnnotations() else {
                if isCurrent(revision) { sendControl(.syncReply(id: id, reply: .failed)) }; return
            }
            guard isCurrent(revision) else { return }
            // Their confirmation (or failure) answers this same request id.
            pendingRequest = id
            waiting = true
            status = "score.sync.sentMine".localizedFormat(peer)
            sendControl(.syncPush(id: id, snapshot: mine))
        case let (.sync(id, _, _, _, _), .decline):
            status = nil
            sendControl(.syncReply(id: id, reply: .declined))
        case let (.live(id, peer), .takeTheirs):
            // The presenter's full snapshot follows; back up what it will replace.
            do {
                if let target, let disk, let scoreID {
                    let current = try await target.currentAnnotations()
                    guard isCurrent(revision) else { return }
                    try await disk.backupAnnotations(current, scoreID: scoreID, reason: .live, peer: peer)
                    await reloadBackups()
                }
                guard isCurrent(revision) else { return }
                live = .watching
                status = "score.sync.watching".localizedFormat(peer)
                sendControl(.liveReply(id: id, accepted: true))
            } catch {
                guard isCurrent(revision) else { return }
                sendControl(.liveReply(id: id, accepted: false))
                status = error.localizedDescription
            }
        case let (.live(id, _), _):
            sendControl(.liveReply(id: id, accepted: false))
        }
    }

    // MARK: Live lesson

    func startLive() {
        guard sameLayout, live == nil, incoming == nil, !waiting, outgoing.isEmpty else { return }
        let id = UUID()
        pendingRequest = id
        waiting = true
        status = "score.sync.waitingForLive".localizedFormat(peerName ?? "")
        if !send(.liveRequest(id: id)) {
            pendingRequest = nil
            waiting = false
        }
    }

    func stopLive() {
        guard live != nil else { return }
        stopLiveLocally()
        status = "score.sync.liveEnded".localized
        sendControl(.liveEnd)
    }

    /// Sends what changed since the last update. The loop calls this every
    /// `liveInterval`; tests call it directly.
    func pushLiveChanges() async {
        guard live == .presenting, !pushingLive, outgoing.isEmpty, let target else { return }
        let revision = connectionRevision, lesson = liveRevision
        pushingLive = true
        defer { if liveRevision == lesson { pushingLive = false } }
        guard let now = try? await target.currentAnnotations(), isCurrent(revision),
              liveRevision == lesson, live == .presenting else { return }
        // A failed first snapshot must be retried before incremental updates.
        guard let last = lastSent else {
            if send(.liveFull(now)) { lastSent = now; clearSendFailure() }
            return
        }
        var delivered = last
        let pages = Set(now.drawings.keys).union(last.drawings.keys).union(now.fingerings.keys).union(last.fingerings.keys)
        for page in pages.sorted() where now.drawings[page] != last.drawings[page]
            || (now.fingerings[page] ?? []) != (last.fingerings[page] ?? []) {
            if send(.livePage(page: page, drawing: now.drawings[page], fingerings: now.fingerings[page] ?? [])) {
                delivered.drawings[page] = now.drawings[page]
                delivered.fingerings[page] = now.fingerings[page]
            }
        }
        if now.edits != last.edits, send(.liveEdits(now.edits)) { delivered.edits = now.edits }
        lastSent = delivered
        if delivered == now { clearSendFailure() }
    }

    /// Sends the presenter's view if it moved. Runs every `viewportInterval`.
    func pushViewport() {
        guard live == .presenting, lastSent != nil, outgoing.isEmpty, let viewport = target?.currentViewport() else { return }
        if let lastViewport, viewport.isClose(to: lastViewport) { return }
        if send(.liveViewport(viewport)) { lastViewport = viewport }
    }

    /// Sends the presenter's metronome settings if they changed.
    func pushMetronome() {
        guard live == .presenting, lastSent != nil, outgoing.isEmpty, let metronome else { return }
        let state = ScoreSyncMetronome(metronome)
        guard state != lastMetronome else { return }
        if send(.liveMetronome(state)) { lastMetronome = state }
    }

    /// The viewer moved the score by hand: stop following until asked.
    func pauseFollowing() {
        guard live == .watching, following else { return }
        following = false
    }

    func resumeFollowing() {
        guard live == .watching else { return }
        following = true
        if let lastViewport { target?.showViewport(lastViewport) }
    }

    private func startPresenting() {
        liveRevision += 1
        let lesson = liveRevision
        live = .presenting
        if silencePresenterMetronome { metronome?.silenced = true }
        status = "score.sync.presenting".localizedFormat(peerName ?? "")
        liveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.live == .presenting, self.liveRevision == lesson {
                await self.pushLiveChanges()
                do { try await Task.sleep(for: self.liveInterval) } catch { return }
            }
        }
        viewportTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.live == .presenting, self.liveRevision == lesson {
                self.pushViewport()
                self.pushMetronome()
                do { try await Task.sleep(for: self.viewportInterval) } catch { return }
            }
        }
    }

    private func stopLiveLocally() {
        liveRevision += 1
        pushingLive = false
        liveTask?.cancel()
        liveTask = nil
        viewportTask?.cancel()
        viewportTask = nil
        lastSent = nil
        lastViewport = nil
        lastMetronome = nil
        if live == .presenting { metronome?.silenced = false }
        if controlsViewerMetronome { metronome?.stop() }
        controlsViewerMetronome = false
        following = true
        live = nil
    }

    // MARK: Backups

    func restore(_ backup: ScoreSyncBackup) async {
        guard let disk, let scoreID else { return }
        do {
            let snapshot = try await disk.backupSnapshot(backup, scoreID: scoreID)
            try await backupAndReplace(with: snapshot, scope: .everything, reason: .restore, peer: "")
            status = "score.sync.restored".localized
        } catch { status = error.localizedDescription }
    }

    private func reloadBackups() async {
        guard let disk, let scoreID else { return }
        backups = (try? await disk.syncBackups(scoreID)) ?? []
    }

    private func backupAndReplace(with incoming: ScoreAnnotationSnapshot, scope: ScoreAnnotationSnapshot.Scope,
                                  reason: ScoreSyncBackup.Reason, peer: String, revision: Int? = nil) async throws {
        guard let target, let disk, let scoreID else { throw ScoreSyncError.invalidPayload }
        let current = try await target.currentAnnotations()
        if let revision, !isCurrent(revision) { throw CancellationError() }
        try await disk.backupAnnotations(current, scoreID: scoreID, reason: reason, peer: peer)
        await reloadBackups()
        if let revision, !isCurrent(revision) { throw CancellationError() }
        try await target.replaceAnnotations(with: current.merging(incoming, scope: scope), durable: true)
    }

    // MARK: Messages

    private func isCurrent(_ revision: Int) -> Bool {
        transport != nil && connectionRevision == revision
    }

    private func clearSendFailure() {
        if status == "score.sync.sendFailed".localized { status = nil }
    }

    @discardableResult
    private func send(_ message: ScoreSyncMessage) -> Bool {
        guard let transport, let identity else { return false }
        do {
            let data = try ScoreSyncCodec.encode(.init(app: ScoreSyncCodec.appVersion, identity: identity, message: message))
            try transport.send(data)
            return true
        } catch {
            status = "score.sync.sendFailed".localized
            return false
        }
    }

    /// Retry control messages in order without reapplying annotations or making
    /// duplicate backups. Live snapshots use their own dirty state instead.
    private func sendControl(_ message: ScoreSyncMessage) {
        guard transport != nil else { return }
        if outgoing.isEmpty, send(message) { return }
        outgoing.append(message)
        guard retryTask == nil else { return }
        let revision = connectionRevision
        retryTask = Task { [weak self] in
            while let self, self.isCurrent(revision), !Task.isCancelled {
                do { try await Task.sleep(for: self.retryInterval) } catch { return }
                guard self.isCurrent(revision) else { return }
                while let first = self.outgoing.first {
                    guard self.send(first) else { break }
                    self.outgoing.removeFirst()
                }
                if self.outgoing.isEmpty {
                    self.retryTask = nil
                    self.clearSendFailure()
                    return
                }
            }
        }
    }

    /// Messages are handled one at a time so live pages apply in order.
    private func enqueue(_ data: Data, revision: Int) {
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.isCurrent(revision) else { return }
            await self.handle(data, revision: revision)
        }
    }

    private func handle(_ data: Data, revision: Int) async {
        let envelope: ScoreSyncEnvelope
        do { envelope = try ScoreSyncCodec.decode(data) }
        catch { status = error.localizedDescription; return }
        guard let identity else { return }
        remote = envelope.identity
        let same = identity.sameBaseFile(as: envelope.identity)
        let similar = identity.sameLayout(as: envelope.identity)
        let peer = peerName ?? ""
        switch envelope.message {
        case .hello:
            if !similar { status = "score.sync.differentFile".localized }
            else if !same { status = "score.sync.similarFile".localized }
        case let .syncRequest(id, snapshot):
            guard same else { sendControl(.syncReply(id: id, reply: .differentFile)); return }
            guard incoming == nil, !waiting, live == nil, let target,
                  let theirs = try? snapshot.validated(pageCount: identity.pageCount),
                  let mine = try? await target.currentAnnotations() else {
                if isCurrent(revision) { sendControl(.syncReply(id: id, reply: .declined)) }; return
            }
            guard isCurrent(revision) else { return }
            incoming = .sync(id: id, peer: peer, theirs: theirs, theirSummary: theirs.summary, mySummary: mine.summary)
        case let .syncReply(id, reply):
            guard id == pendingRequest else { return }
            pendingRequest = nil
            waiting = false
            switch reply {
            case .tookYours: status = "score.sync.theyTookYours".localizedFormat(peer)
            case .sendingMine: break
            case .declined: status = "score.sync.declined".localizedFormat(peer)
            case .differentFile: status = "score.sync.differentFile".localized
            case .failed: status = "score.sync.failed".localized
            }
        case let .syncPush(id, snapshot):
            // Only accepted in answer to our own request.
            guard id == pendingRequest, same else { return }
            do {
                try await backupAndReplace(with: try snapshot.validated(pageCount: identity.pageCount),
                                           scope: .everything, reason: .sync, peer: peer, revision: revision)
                guard isCurrent(revision) else { return }
                pendingRequest = nil
                waiting = false
                status = "score.sync.theySentTheirs".localizedFormat(peer)
                sendControl(.syncReply(id: id, reply: .tookYours))
            } catch {
                guard isCurrent(revision) else { return }
                pendingRequest = nil
                waiting = false
                sendControl(.syncReply(id: id, reply: .failed))
                status = error.localizedDescription
            }
        case let .liveRequest(id):
            guard similar, incoming == nil, !waiting, live == nil else { sendControl(.liveReply(id: id, accepted: false)); return }
            incoming = .live(id: id, peer: peer)
        case let .liveReply(id, accepted):
            guard id == pendingRequest else { return }
            pendingRequest = nil
            waiting = false
            if accepted && similar { startPresenting() } else { status = "score.sync.declined".localizedFormat(peer) }
        case let .liveFull(snapshot):
            await applyLive(snapshot, scope: .everything, same: similar, revision: revision)
        case let .livePage(page, drawing, fingerings):
            await applyLive(.init(drawings: drawing.map { [page: $0] } ?? [:], fingerings: [page: fingerings]),
                            scope: .pages([page]), same: similar, revision: revision)
        case let .liveEdits(edits):
            await applyLive(.init(edits: edits), scope: .edits, same: similar, revision: revision)
        case let .liveMetronome(state):
            guard live == .watching, similar, let metronome, Metronome.tempoRange.contains(state.tempo) else { return }
            controlsViewerMetronome = true
            state.apply(to: metronome)
        case let .liveViewport(viewport):
            guard live == .watching, similar, let checked = try? viewport.validated(pageCount: identity.pageCount) else { return }
            lastViewport = checked
            if following { target?.showViewport(checked) }
        case .liveEnd:
            guard live != nil else { return }
            stopLiveLocally()
            status = "score.sync.liveEnded".localized
        }
    }

    private func applyLive(_ incoming: ScoreAnnotationSnapshot, scope: ScoreAnnotationSnapshot.Scope, same: Bool, revision: Int) async {
        guard live == .watching, same, let target, let identity else { return }
        let lesson = liveRevision
        do {
            let checked = try incoming.validated(pageCount: identity.pageCount)
            if case .pages(let pages) = scope, !pages.allSatisfy((1...identity.pageCount).contains) { throw ScoreSyncError.invalidPayload }
            let current = try await target.currentAnnotations()
            guard isCurrent(revision), liveRevision == lesson, live == .watching else { return }
            try await target.replaceAnnotations(with: current.merging(checked, scope: scope), durable: false)
        } catch { if isCurrent(revision) { status = error.localizedDescription } }
    }
}
