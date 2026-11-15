import SwiftUI
import MultipeerConnectivity

/// Nearby sync for the score open in the reader. Both iPads open the same score
/// and its Nearby sync panel; one connects, then sends a sync request or starts
/// a live lesson. Discovery runs only while the panel is open or a peer is connected,
/// and stops when the reader closes.
struct ScoreSyncSupport: ViewModifier {
    @ObservedObject var reader: ScoreReaderController
    let score: LibraryScore
    @Binding var presented: Bool
    @Environment(\.scoreExternalWindowID) private var externalWindowID
    @EnvironmentObject private var library: ScoreLibrary
    @StateObject private var session = ScoreSyncSession()
    @StateObject private var nearby = ScoreSyncNearby()
    @State private var showsNearby = !ScoreSyncAvailability.internet
    @StateObject private var remote = ScoreSyncRemote()

    func body(content: Content) -> some View {
        content
            .overlay {
                if let live = session.live {
                    ScoreSyncLiveIndicator(role: live, peer: session.peerName ?? "") { session.stopLive() }
                }
            }
            .overlay(alignment: .bottom) {
                if session.live == .watching && !session.following {
                    Button { session.resumeFollowing() } label: {
                        Label("score.sync.follow".localizedFormat(session.peerName ?? ""), systemImage: "scope")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .padding(.bottom, 24)
                    .accessibilityIdentifier("scoreSyncFollow")
                }
            }
            .sheet(isPresented: $presented, onDismiss: {
                if nearby.connected == nil { showsNearby = false; nearby.stop() }
                reader.focusKeys()
            }) {
                ScoreSyncSheet(session: session, nearby: nearby, remote: remote, score: score, showsNearby: $showsNearby)
                    .presentationDetents([.large])
            }
            .task(id: ScoreSyncAvailability.internet && reader.ready && library.pendingRoomInvite != nil ? library.externalRequestID : nil) {
                if ScoreSyncAvailability.internet, reader.ready, library.pendingRoomInvite != nil, library.handlesExternalFiles(in: externalWindowID) {
                    presented = true
                }
            }
            .task(id: presented) {
                guard presented else { return }
                await prepare()
            }
            // A request must be answered in the panel; bring it back if it was closed.
            .onChange(of: session.incoming?.id) { _, id in if id != nil { presented = true } }
            .onChange(of: nearby.invitation?.id) { _, id in if id != nil { presented = true } }
            .onChange(of: showsNearby) { _, expanded in
                if expanded && presented && session.identity != nil { nearby.start() }
                else if !expanded && nearby.connected == nil { nearby.stop() }
            }
            .onDisappear {
                session.stopLive()
                nearby.stop()
                remote.leave()
            }
    }

    private func prepare() async {
        guard reader.ready else { return }
        if !ScoreSyncAvailability.internet { showsNearby = true }
        if session.identity == nil {
            do {
                let digest = try await library.ensureSourceDigest(score.id)
                let layout = try await library.ensureLayoutDigest(score.id)
                await session.configure(identity: .init(digest: digest, pageCount: score.pageCount, title: score.title, layout: layout),
                                        scoreID: score.id, disk: library.disk, target: reader)
            } catch { reader.errorMessage = error.localizedDescription; return }
        }
        reader.onUserNavigation = { [weak session] in session?.pauseFollowing() }
        session.metronome = Metronome.shared
        // One connection at a time; a second one (nearby or remote) is closed.
        nearby.onConnect = { [weak session] transport in
            guard let session else { return }
            if session.isConnected { transport.disconnect() } else { session.connect(transport) }
        }
        nearby.onDisconnect = { [weak session, weak nearby] in session?.disconnected(from: nearby) }
        remote.onConnect = { [weak session] transport in
            guard let session else { return }
            if session.isConnected { transport.leave() } else { session.connect(transport) }
        }
        remote.onDisconnect = { [weak session, weak remote] in session?.disconnected(from: remote) }
        if showsNearby && presented { nearby.start() }
    }
}

/// Live-lesson indicator up by the camera, so it never covers the toolbar.
/// iPhone: a black capsule growing out of the Dynamic Island / notch (red dot on
/// the left, "Live" on the right). iPad and other screens: a small pill centred in
/// the status bar. Tapping it shows who is connected and Stop.
struct ScoreSyncLiveIndicator: View {
    let role: ScoreSyncSession.LiveRole
    let peer: String
    let stop: () -> Void
    @State private var confirming = false

    /// Status bar height of the key window; SwiftUI insets are not reliable here.
    private var topInset: CGFloat {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return (windows.first(where: \.isKeyWindow) ?? windows.first)?.safeAreaInsets.top ?? 20
    }

    private var title: String {
        role == .watching ? "score.sync.bannerWatching".localizedFormat(peer)
            : "score.sync.bannerPresenting".localizedFormat(peer)
    }

    var body: some View {
        let inset = topInset
        let island = UIDevice.current.userInterfaceIdiom == .phone && inset >= 44
        GeometryReader { geometry in
            Button { confirming = true } label: {
                if island { islandLabel(dynamicIsland: inset >= 51) } else { statusBarLabel }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityIdentifier("scoreSyncLiveIndicator")
            // Dynamic Island centre ≈ 29.5 pt, notch ≈ 15 pt; otherwise mid status bar.
            .position(x: geometry.size.width / 2, y: island ? (inset >= 51 ? 29.5 : 15) : max(10, inset / 2))
        }
        .ignoresSafeArea()
        .confirmationDialog(title, isPresented: $confirming, titleVisibility: .visible) {
            Button("score.sync.stopLive".localized, role: .destructive, action: stop)
                .accessibilityIdentifier("scoreSyncBannerStop")
            Button("Cancel".localized, role: .cancel) { }
        }
    }

    private var shortText: String {
        role == .watching ? "score.sync.watchingShort".localized : "score.sync.liveShort".localized
    }

    private func islandLabel(dynamicIsland: Bool) -> some View {
        // The middle stays black and empty: the island (or notch) sits there.
        HStack(spacing: 0) {
            // Narrow wings: the clock sits left of the island and must stay visible.
            Circle().fill(.red).frame(width: 8, height: 8).frame(width: 26)
            Spacer(minLength: dynamicIsland ? 122 : 156)
            Text(shortText).font(.caption2.weight(.semibold)).foregroundStyle(.white).frame(width: 32)
        }
        .frame(height: dynamicIsland ? 37 : 30)
        .background(.black, in: Capsule())
        .fixedSize()
    }

    private var statusBarLabel: some View {
        HStack(spacing: 5) {
            Circle().fill(.white).frame(width: 6, height: 6)
            Text("\(shortText) · \(peer)").font(.caption2.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
        }
        .padding(.horizontal, 9).frame(height: 18)
        .background(.red, in: Capsule())
        .fixedSize()
    }
}

struct ScoreSyncSheet: View {
    @ObservedObject var session: ScoreSyncSession
    @ObservedObject var nearby: ScoreSyncNearby
    @ObservedObject var remote: ScoreSyncRemote
    @EnvironmentObject private var library: ScoreLibrary
    @Environment(\.scoreExternalWindowID) private var externalWindowID
    let score: LibraryScore
    @Binding var showsNearby: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ScoreSyncNearby.savedName()
    @State private var choice: ScoreSyncSession.Choice?
    @State private var restoring: ScoreSyncBackup?
    @State private var roomCode = ""
    @ObservedObject private var serviceRegion = ScoreServiceRegion.shared
    @ObservedObject private var subscription = ScoreRoomSubscription.shared
    @State private var managingSubscription = false

    var body: some View {
        NavigationStack {
            Form {
                if ScoreSyncAvailability.internet { remoteSection }
                if session.isConnected && session.sameLayout { actionsSection }
                fileSection
                Section {
                    if ScoreSyncAvailability.internet {
                        DisclosureGroup("score.sync.nearby".localized, isExpanded: $showsNearby) {
                            nearbyContents
                        }
                    } else {
                        nearbyContents
                    }
                } header: {
                    if !ScoreSyncAvailability.internet { Text("score.sync.nearby".localized) }
                }
                if let status = session.status {
                    Section { Text(status).font(.callout).accessibilityIdentifier("scoreSyncStatus") }
                }
                backupsSection
            }
            .navigationTitle("score.sync.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done".localized) { dismiss() }.accessibilityIdentifier("scoreSyncDone")
                }
            }
            .alert("score.sync.restoreTitle".localized,
                   isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
                   presenting: restoring) { backup in
                Button("score.sync.restore".localized, role: .destructive) { Task { await session.restore(backup) } }
                Button("Cancel".localized, role: .cancel) { }
            } message: { backup in
                Text("score.sync.restoreMessage".localizedFormat(backup.summary.text))
            }
            .sheet(isPresented: $remote.paywallRequested) { ScoreRoomPaywall(subscription: subscription) }
            .manageSubscriptionsSheet(isPresented: $managingSubscription)
            .task(id: serviceRegion.node) {
                if ScoreSyncAvailability.internet && serviceRegion.node == .global { await subscription.refresh() }
            }
        }
        .alert(nearby.invitation.map { "score.sync.invitationTitle".localizedFormat($0.peer.displayName) } ?? "",
               isPresented: Binding(get: { nearby.invitation != nil }, set: { _ in })) {
            Button("score.sync.connect".localized) { if let invitation = nearby.invitation { nearby.answer(invitation, accept: true) } }
            Button("score.sync.decline".localized, role: .cancel) { if let invitation = nearby.invitation { nearby.answer(invitation, accept: false) } }
        } message: { Text("score.sync.invitationMessage".localized) }
        .background { requestAlerts }
    }

    // MARK: Sections

    @ViewBuilder private var nearbyContents: some View {
        peersSection
        TextField("score.sync.deviceName".localized, text: $name)
            .onSubmit { nearby.rename(name); name = nearby.me.displayName }
            .disabled(nearby.connected != nil)
            .accessibilityIdentifier("scoreSyncName")
    }

    private var fileSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(score.title).font(.headline)
                if let digest = session.identity?.digest {
                    DisclosureGroup("score.sync.fileDetails".localized) {
                        Text("score.sync.fingerprint".localizedFormat(String(digest.prefix(12))))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                } else {
                    Text("score.sync.checking".localized).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: { Text("score.sync.thisFile".localized) }
        footer: { Text("score.sync.howItWorks".localized) }
    }

    @ViewBuilder private var peersSection: some View {
        Group {
            if let peer = nearby.connected {
                connectionStatus("score.sync.connectedTo".localizedFormat(peer.displayName), systemImage: "ipad.landscape")
                Button("score.sync.disconnect".localized, role: .destructive) { nearby.disconnect() }
            } else if remote.isConnected {
                Text("score.sync.nearbyBusy".localized).foregroundStyle(.secondary)
            } else if nearby.nearby.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("score.sync.searching".localized).foregroundStyle(.secondary)
                }
            } else {
                ForEach(nearby.nearby, id: \.self) { peer in
                    HStack {
                        Label(peer.displayName, systemImage: "ipad")
                        Spacer()
                        if nearby.connecting == peer { ProgressView() }
                        else {
                            Button("score.sync.connect".localized) { nearby.invite(peer) }
                                .disabled(nearby.connecting != nil)
                        }
                    }
                }
            }
        }
    }

    private func connectionStatus(_ title: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
            if session.remote == nil {
                Text("score.sync.checkingRemote".localized).font(.caption).foregroundStyle(.secondary)
            } else if session.sameBaseFile {
                Label("score.sync.sameFile".localized, systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
            } else if session.sameLayout {
                Label("score.sync.similarFile".localized, systemImage: "checkmark.seal")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Label("score.sync.differentFile".localized, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// Over the internet: one device opens a room, the other types its number.
    private var invitation: ScoreRoomInvitation? {
        if library.handlesExternalFiles(in: externalWindowID), let invite = library.pendingRoomInvite { return invite }
        guard let url = URL(string: roomCode.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return ScoreRoomInvitation(url: url)
    }

    private var enteredCode: String? {
        guard roomCode.allSatisfy({ $0.isNumber || $0.isWhitespace || $0 == "-" }) else { return nil }
        return ScoreSyncRemote.normalizedCode(roomCode)
    }

    @ViewBuilder private var remoteSection: some View {
        Section {
            if let invite = invitation {
                Text("score.sync.roomInvitationTitle".localizedFormat(invite.code)).font(.headline)
                Text((invite.node == .cn ? "score.sync.inviteViaCN" : "score.sync.inviteViaGlobal").localized)
                    .font(.subheadline).foregroundStyle(.secondary)
                if remote.state != .idle || nearby.connected != nil {
                    Text("score.sync.leaveFirst".localized)
                } else if let identity = session.identity {
                    if serviceRegion.node == .cn && invite.node == .global {
                        Text("score.sync.mainlandHostRequired".localized).foregroundStyle(.secondary)
                    } else if identity.roomKey == invite.digest {
                        Button("score.sync.remoteJoin".localized) {
                            remote.join(invite.code, file: identity.roomKey, on: invite.node.server)
                            roomCode = ""
                            if library.handlesExternalFiles(in: externalWindowID) { library.pendingRoomInvite = nil }
                        }
                        .accessibilityIdentifier("scoreAcceptInvitation")
                    } else {
                        Text("score.sync.chooseOriginal".localized)
                    }
                } else {
                    ProgressView("score.sync.checking".localized)
                }
                Button("Cancel".localized) {
                    roomCode = ""
                    if library.handlesExternalFiles(in: externalWindowID) { library.pendingRoomInvite = nil }
                }
            }
            switch remote.state {
            case .idle where invitation != nil:
                EmptyView()
            case .idle:
                Button {
                    remote.host(ScoreSyncRemote.newCode(), file: session.identity?.roomKey)
                } label: {
                    Label("score.sync.remoteCreate".localized, systemImage: "plus.bubble")
                }
                .disabled(remote.resolvingRegion || remote.checkingSubscription || nearby.connected != nil || session.identity == nil)
                .accessibilityIdentifier("scoreSyncRemoteCreate")
                HStack {
                    TextField("score.sync.remoteCodePlaceholder".localized, text: $roomCode)
                        .keyboardType(.numberPad)
                        .font(.body.monospacedDigit())
                        .accessibilityIdentifier("scoreSyncRemoteCode")
                    Button("score.sync.remoteJoin".localized) {
                        if let code = enteredCode { remote.join(code, file: session.identity?.roomKey) }
                    }
                    .disabled(remote.resolvingRegion || remote.checkingSubscription || enteredCode == nil
                              || nearby.connected != nil || session.identity == nil)
                    .accessibilityIdentifier("scoreSyncRemoteJoin")
                }
            case .waiting(let code):
                roomCodeRow(code)
                if remote.roomConfirmed, let server = remote.roomServer, let digest = session.identity?.roomKey,
                   let invite = ScoreRoomInvitation(server: server, code: code, digest: digest) {
                    ShareLink(item: invite.url, subject: Text("score.sync.shareInvite".localized),
                              message: Text("score.sync.shareMessage".localizedFormat(score.title, code))) {
                        Label("score.sync.shareInvite".localized, systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("scoreShareInvite")
                }
                HStack(spacing: 10) {
                    ProgressView()
                    Text((remote.waitingForHost ? "score.sync.remoteRoomNotOpen" : "score.sync.remoteWaiting").localized)
                        .foregroundStyle(.secondary)
                }
                Button("score.sync.remoteLeave".localized, role: .destructive) { remote.leave() }
            case .connected(let code, let peer):
                roomCodeRow(code)
                connectionStatus("score.sync.remoteConnected".localizedFormat(peer), systemImage: "globe")
                Button("score.sync.remoteLeave".localized, role: .destructive) { remote.leave() }
            case .failed(let code, let message):
                roomCodeRow(code)
                if remote.waitingForHost {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(message).foregroundStyle(.secondary)
                    }
                } else {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if remote.subscriptionRequired {
                    Button("score.sync.remoteSubscribe".localized) { remote.paywallRequested = true }
                        .accessibilityIdentifier("scoreSyncRemoteSubscribe")
                }
                Button("score.sync.remoteLeave".localized, role: .destructive) { remote.leave() }
            }
            if remote.resolvingRegion { ProgressView("score.sync.regionChecking".localized) }
            if remote.checkingSubscription { ProgressView("score.sync.remoteCheckingSubscription".localized) }
            if serviceRegion.node == .global && subscription.isSubscribed {
                Label("score.sync.remoteSubscriptionActive".localized, systemImage: "checkmark.seal.fill")
                Button("score.sync.remoteManageSubscription".localized) { managingSubscription = true }
                    .accessibilityIdentifier("scoreSyncManageSubscription")
            }
            ScoreSyncServerPicker(disabled: remote.state != .idle)
        } header: { Text("score.sync.remote".localized) }
        footer: {
            if serviceRegion.node == .global && !subscription.isSubscribed {
                Text("score.sync.remoteHint".localized + "\n" + "score.sync.remoteHostNeedsSubscription".localized)
            } else {
                Text("score.sync.remoteHint".localized)
            }
        }
    }

    private func roomCodeRow(_ code: String) -> some View {
        HStack {
            Text("score.sync.remoteRoom".localized)
            Spacer()
            Text(code.prefix(3) + " " + code.suffix(3))
                .font(.title2.monospacedDigit().weight(.semibold))
                .textSelection(.enabled)
                .accessibilityIdentifier("scoreSyncRemoteRoom")
        }
    }

    private var actionsSection: some View {
        Section {
            Button { Task { await session.requestSync() } } label: {
                Label("score.sync.requestSync".localized, systemImage: "arrow.left.arrow.right")
            }
            .disabled(session.waiting || session.live != nil || !session.sameBaseFile)
            .accessibilityIdentifier("scoreSyncRequest")
            if session.live == nil {
                Button { session.startLive() } label: {
                    Label("score.sync.startLive".localized, systemImage: "dot.radiowaves.left.and.right")
                }
                .disabled(session.waiting)
                .accessibilityIdentifier("scoreSyncStartLive")
            } else {
                Button(role: .destructive) { session.stopLive() } label: {
                    Label("score.sync.stopLive".localized, systemImage: "stop.circle")
                }
            }
            Toggle(isOn: $session.silencePresenterMetronome) {
                Label("score.sync.silenceMetronome".localized, systemImage: "metronome")
            }
            .disabled(session.live == .watching)
        } footer: { Text("score.sync.actionsHint".localized) }
    }

    private var backupsSection: some View {
        Section {
            if session.backups.isEmpty {
                Text("score.sync.noBackups".localized).foregroundStyle(.secondary)
            }
            ForEach(session.backups) { backup in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(backup.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLocalization.locale)))
                        Text(reason(backup)).font(.caption).foregroundStyle(.secondary)
                        Text(backup.summary.text).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("score.sync.restore".localized) { restoring = backup }
                        .disabled(session.live == .watching)
                }
            }
        } header: { Text("score.sync.backups".localized) }
        footer: { Text("score.sync.backupsHint".localized) }
    }

    private func reason(_ backup: ScoreSyncBackup) -> String {
        switch backup.reason {
        case .sync: return "score.sync.backupSync".localizedFormat(backup.peer)
        case .live: return "score.sync.backupLive".localizedFormat(backup.peer)
        case .restore: return "score.sync.backupRestore".localized
        }
    }

    // MARK: Incoming requests

    /// Two steps: choose the direction, then confirm exactly what is overwritten.
    private var requestAlerts: some View {
        Color.clear
            .alert(requestTitle, isPresented: Binding(get: { session.incoming != nil && choice == nil }, set: { _ in })) {
                if case .live = session.incoming {
                    Button("score.sync.watch".localized) { Task { await session.respond(.takeTheirs) } }
                } else {
                    Button("score.sync.takeTheirs".localized) { choice = .takeTheirs }
                    Button("score.sync.sendMine".localized) { choice = .sendMine }
                }
                Button("score.sync.decline".localized, role: .cancel) { Task { await session.respond(.decline) } }
            } message: { Text(requestMessage) }
            .background {
                Color.clear.alert(confirmTitle, isPresented: Binding(get: { choice != nil && session.incoming != nil }, set: { _ in })) {
                    Button("score.sync.replace".localized, role: .destructive) {
                        let chosen = choice ?? .decline
                        choice = nil
                        Task { await session.respond(chosen) }
                    }
                    Button("Cancel".localized, role: .cancel) { choice = nil }
                } message: { Text(confirmMessage) }
            }
    }

    private var requestTitle: String {
        switch session.incoming {
        case .sync(_, let peer, _, _, _): return "score.sync.requestTitle".localizedFormat(peer)
        case .live(_, let peer): return "score.sync.liveRequestTitle".localizedFormat(peer)
        case nil: return ""
        }
    }

    private var requestMessage: String {
        switch session.incoming {
        case let .sync(_, _, _, theirs, mine):
            return "score.sync.requestMessage".localizedFormat(score.title, theirs.text, mine.text)
        case .live: return "score.sync.liveRequestMessage".localizedFormat(score.title)
        case nil: return ""
        }
    }

    private var confirmTitle: String {
        choice == .sendMine ? "score.sync.confirmSendTitle".localized : "score.sync.confirmTakeTitle".localized
    }

    private var confirmMessage: String {
        guard case let .sync(_, peer, _, theirs, mine) = session.incoming else { return "" }
        return choice == .sendMine
            ? "score.sync.confirmSendMessage".localizedFormat(peer, score.title, theirs.text, mine.text)
            : "score.sync.confirmTakeMessage".localizedFormat(score.title, mine.text, peer, theirs.text)
    }
}
