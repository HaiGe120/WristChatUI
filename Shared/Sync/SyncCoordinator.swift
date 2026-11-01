import Foundation
import Combine
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif
import SwiftData

/// Bridges the iOS app and the watchOS app over `WatchConnectivity`. Each
/// target instantiates the same `SyncCoordinator.shared` (its own copy, since
/// the two apps run in separate processes) and they exchange three kinds of
/// state:
///
/// 1. **Endpoint list + active endpoint ID** — the iPhone is the source of
///    truth; the watch asks for the catalog on first activation and then
///    receives updates via the application-context snapshot.
/// 2. **API keys** — the keychain does NOT bridge between iOS and watchOS
///    (no shared access group is possible across the iOS/watchOS boundary),
///    so we mirror keys over the WC session and store them in each app's
///    own keychain. The transport is encrypted in transit and stays
///    on-device; this is the standard trade-off for a paired companion app.
/// 3. **Conversations and messages** — when a new chat or message lands on
///    one side, we publish it; on receipt we upsert by UUID into the local
///    SwiftData store. Each `Conversation` and `Message` already carries a
///    stable `id`, so merging is append-with-dedup and safe across
///    interleaved writes from both sides.
///
/// `updateApplicationContext` carries the latest endpoint snapshot (the
/// latest call wins, no queue), while `transferUserInfo` reliably queues
/// per-event payloads (new chat, new message) so they aren't lost if the
/// receiving device is briefly out of range.
@MainActor
public final class SyncCoordinator: NSObject, ObservableObject {
    public static let shared = SyncCoordinator()

    @Published public private(set) var activationState: SyncActivationState = .unknown
    @Published public private(set) var isCompanionReachable: Bool = false
    @Published public private(set) var lastSyncedAt: Date?
    @Published public private(set) var lastError: String?

    public enum SyncActivationState: String, Sendable {
        case unknown, unsupported, inactive, activated
    }

    /// True when running in a build target that has WatchConnectivity
    /// available. The framework is available on both iOS and watchOS, so
    /// this is always true in this project; we keep the guard so unit
    /// tests on macOS can no-op the session.
    private var isSupported: Bool {
        #if canImport(WatchConnectivity)
        return WCSession.isSupported()
        #else
        return false
        #endif
    }

    private var hasActivated = false
    private weak var sessionDelegate: AnyObject?
    private var searchObserver: NSObjectProtocol?

    /// Set by the entry point (iPhone) on launch and by the user's
    /// "Sync now" action. Tells the coordinator to (re)publish the
    /// current endpoint catalog, API keys, and conversation list to
    /// the companion as soon as the WCSession is `.activated` AND the
    /// companion is reachable. WCSession's `activate()` is async, so
    /// calling `publishEndpoints` / `transferUserInfo` synchronously
    /// after `activate()` throws "WatchConnectivity session has not
    /// been activated". Deferring the publish until the activation
    /// callback fires is the canonical fix.
    private var needsBootstrap = false

    private override init() {
        super.init()
        #if os(iOS)
        searchObserver = NotificationCenter.default.addObserver(forName: SearchSourceStore.didChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.publishSearchSources() }
        }
        #endif
    }

    /// Wire up `WCSession` and become the delegate. Safe to call multiple
    /// times; subsequent calls are no-ops.
    public func activate() {
        guard isSupported else {
            activationState = .unsupported
            return
        }
        guard !hasActivated else { return }
        hasActivated = true
        #if canImport(WatchConnectivity)
        let session = WCSession.default
        session.delegate = self
        session.activate()
        #endif
    }

    /// Schedule a full re-publish of the local state to the companion
    /// (iPhone -> watch direction) or a re-request of the companion's
    /// state (watch -> iPhone direction). The work is deferred until
    /// `WCSession` reports `.activated` AND the companion is
    /// reachable, so it's safe to call this from `init()` and from
    /// the "Sync now" button regardless of the current activation
    /// state. Calling it multiple times is harmless — the last call
    /// wins (everything is idempotent), and we never publish twice
    /// for a single activation cycle.
    public func requestBootstrap() {
        needsBootstrap = true
        flushPendingBootstrapIfReady()
    }

    /// Drain the pending bootstrap if the session is ready. Called
    /// from the activation + reachability delegate callbacks and
    /// from `requestBootstrap()` itself.
    private func flushPendingBootstrapIfReady() {
        #if canImport(WatchConnectivity)
        guard isSupported else {
            needsBootstrap = false
            return
        }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        // We do not require `isReachable` here because
        // `updateApplicationContext` is delivered out-of-band and
        // does not need the companion to be foregrounded. The
        // transferUserInfo mirror call inside `publishEndpoints`
        // only fires when reachable, so a non-reachable session is
        // still useful for the application-context snapshot.
        guard needsBootstrap else { return }
        needsBootstrap = false

        if EndpointStore.isPrimaryForEndpoints {
            // iPhone side: push endpoints + API keys + conversations.
            publishEndpoints(
                EndpointStore.shared.endpoints,
                activeID: EndpointStore.shared.activeEndpointID
            )
            // pushAllAPIKeys uses sendMessage when the watch is
            // reachable (one round-trip, confirmed) and falls back to
            // one transferUserInfo per key otherwise. This replaces
            // the previous per-key transferUserInfo loop, which the
            // user reported as not delivering to the watch.
            pushAllAPIKeys()
            publishSearchSources()
            let context = DataStore.shared.mainContext
            let descriptor = FetchDescriptor<Conversation>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
            let convs = (try? context.fetch(descriptor)) ?? []
            if !convs.isEmpty {
                publishConversations(convs.map { ConversationSnapshot($0) })
            }
        } else {
            // Watch side: ask the iPhone for its state. These are
            // guarded by activation state internally; if the phone
            // is not reachable they will surface an error to
            // `lastError` that the user can clear by tapping
            // "Sync now" later.
            requestEndpoints()
            requestConversations()
            requestSearchSources()
        }
        #endif
    }

    // MARK: - Publishing

    /// Push the current endpoint catalog to the companion. Called after any
    /// `EndpointStore` mutation on the iPhone, and used as a reply to the
    /// watch's startup request.
    public func publishEndpoints(_ endpoints: [EndpointConfig], activeID: UUID?) {
        let payload = EndpointsPayload(
            endpoints: endpoints,
            activeID: activeID,
            sentAt: Date()
        )
        #if canImport(WatchConnectivity)
        guard isSupported else { return }
        let session = WCSession.default
        do {
            let data = try Self.encoder.encode(payload)
            let context: [String: Any] = [
                SyncMessageKey.kind: SyncMessageKind.endpoints.rawValue,
                SyncMessageKey.payload: data
            ]
            // Latest-wins snapshot: any companion that becomes reachable
            // will pick this up.
            try session.updateApplicationContext(context)
        } catch {
            lastError = "publishEndpoints failed: \(error.localizedDescription)"
            return
        }
        // Mirror as a queued reliable message so a connected companion
        // that comes online gets it via transferUserInfo too.
        if session.activationState == .activated {
            transferUserInfo(kind: .endpoints, payload: payload)
        }
        #endif
    }

    /// Separate provisioning path: search secrets never travel as chat-provider API keys.
    public func publishSearchSources() {
        #if os(iOS) && canImport(WatchConnectivity)
        guard isSupported, WCSession.default.activationState == .activated else { return }
        transferUserInfo(kind: .searchSources, payload: SearchSourceStore.shared.companionPayload())
        #endif
    }

    public func requestSearchSources() {
        #if os(watchOS) && canImport(WatchConnectivity)
        guard isSupported, WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        WCSession.default.sendMessage([SyncMessageKey.kind: SyncMessageKind.requestSearchSources.rawValue], replyHandler: { [weak self] reply in
            Task { @MainActor in self?.handle(kind: .searchSources, raw: reply) }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in self?.lastError = "Reconnect to iPhone to provision search sources." }
        })
        #endif
    }

    /// Mirror an API key update to the companion. Sent only on the iPhone;
    /// ignored on the watch (a watch-initiated key change pushes a similar
    /// payload up via `sendMessage`).
    public func publishAPIKey(_ value: String, for endpointID: UUID) {
        let payload = APIKeyPayload(endpointID: endpointID, value: value, sentAt: Date())
        #if canImport(WatchConnectivity)
        guard isSupported else { return }
        let session = WCSession.default
        guard session.activationState == .activated else {
            // Session not yet active. The bootstrap (requestBootstrap)
            // is responsible for replaying this when activation
            // completes; nothing to do here.
            return
        }
        // Three-tier delivery, in order of preference:
        //   1. `sendMessage` — only works when the watch is reachable
        //      RIGHT NOW, but it has a replyHandler so we can confirm
        //      receipt (or surface a transport error to lastError).
        //   2. `transferUserInfo` — queued by the system and delivered
        //      when the watch is reachable, even if the watch app is
        //      not currently in the foreground.
        //   3. `updateApplicationContext` — latest-wins snapshot; used
        //      as a backstop so a brand-new install of the watch app
        //      sees the latest key on first launch.
        if session.isReachable {
            let message: [String: Any] = [
                SyncMessageKey.kind: SyncMessageKind.apiKey.rawValue,
                SyncMessageKey.payload: (try? Self.encoder.encode(payload)) ?? Data()
            ]
            session.sendMessage(message, replyHandler: { _ in
                Task { @MainActor in self.lastSyncedAt = Date() }
            }) { error in
                Task { @MainActor in
                    self.lastError = "sendMessage(apiKey) failed: \(error.localizedDescription)"
                    // Fall back to transferUserInfo so the key is
                    // still queued for later delivery.
                    self.transferUserInfo(kind: .apiKey, payload: payload)
                }
            }
            return
        }
        transferUserInfo(kind: .apiKey, payload: payload)
        #endif
    }

    /// Push the full set of saved API keys in one go. Used by the
    /// iPhone's bootstrap, by "Sync now", and by reachability-change
    /// recovery. Bundles every key (including empty values to clear
    /// stale entries) into a single `sendMessage` when reachable;
    /// otherwise falls back to one `transferUserInfo` per key (so a
    /// bulk refresh is not gated on the watch being online).
    public func pushAllAPIKeys() {
        #if canImport(WatchConnectivity)
        guard isSupported else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let keys: [APIKeyPayload] = EndpointStore.shared.endpoints.compactMap { ep in
            guard let stored = EndpointStore.shared.apiKey(for: ep.id) else { return nil }
            return APIKeyPayload(endpointID: ep.id, value: stored, sentAt: Date())
        }
        let bulk = APIKeysPayload(keys: keys, sentAt: Date())
        if session.isReachable {
            if let data = try? Self.encoder.encode(bulk) {
                let message: [String: Any] = [
                    SyncMessageKey.kind: SyncMessageKind.apiKeys.rawValue,
                    SyncMessageKey.payload: data
                ]
                session.sendMessage(message, replyHandler: { _ in
                    Task { @MainActor in self.lastSyncedAt = Date() }
                }) { error in
                    Task { @MainActor in
                        self.lastError = "sendMessage(apiKeys) failed: \(error.localizedDescription)"
                        // Fall back to one transferUserInfo per key.
                        for k in keys {
                            self.transferUserInfo(kind: .apiKey, payload: k)
                        }
                    }
                }
                return
            }
        }
        for k in keys {
            transferUserInfo(kind: .apiKey, payload: k)
        }
        #endif
    }

    /// Ask the iPhone for every saved API key. Sent by the watch
    /// during its bootstrap and on user-triggered resync. The iPhone
    /// replies via the sendMessage replyHandler with an
    /// `APIKeysPayload`; the watch applies it to its own keychain.
    public func requestAPIKeys() {
        #if canImport(WatchConnectivity)
        guard isSupported, WCSession.default.activationState == .activated else { return }
        let session = WCSession.default
        guard session.isReachable else {
            // No reachable peer to ask; the bootstrap on the iPhone
            // side will push the keys when the watch becomes reachable.
            return
        }
        let message: [String: Any] = [
            SyncMessageKey.kind: SyncMessageKind.requestAPIKeys.rawValue
        ]
        session.sendMessage(message, replyHandler: { reply in
            // The reply is itself an `apiKeys` kind payload. The
            // normal receive path handles it; nothing to do here.
            Task { @MainActor in self.lastSyncedAt = Date() }
        }) { error in
            Task { @MainActor in self.lastError = "requestAPIKeys failed: \(error.localizedDescription)" }
        }
        #endif
    }

    /// Push a conversation and its messages. `Conversation` is `@Model`
    /// (SwiftData), so we serialize a plain-value shape rather than the
    /// managed instance.
    public func publishConversation(_ conversation: ConversationSnapshot) {
        #if canImport(WatchConnectivity)
        guard isSupported, WCSession.default.activationState == .activated else { return }
        transferUserInfo(kind: .conversation, payload: conversation)
        #endif
    }

    /// Bulk variant of `publishConversation` used to seed the companion
    /// on cold start (and to mirror a large number of changes in one
    /// shot). The companion's `SyncInbox` upserts each snapshot
    /// individually, so this is just a delivery convenience — the
    /// per-event stream still drives live traffic.
    public func publishConversations(_ snapshots: [ConversationSnapshot]) {
        #if canImport(WatchConnectivity)
        guard isSupported, WCSession.default.activationState == .activated else { return }
        guard !snapshots.isEmpty else { return }
        let payload = ConversationsPayload(conversations: snapshots, sentAt: Date())
        transferUserInfo(kind: .conversations, payload: payload)
        #endif
    }

    /// Tell the companion that a conversation was deleted on this side
    /// so the other side can drop its mirror. Receiving a delete for an
    /// unknown id is a no-op; we don't treat it as an error so a
    /// transient ordering issue (delete before initial sync) doesn't
    /// brick the receiver.
    public func publishDeleteConversation(_ id: UUID) {
        #if canImport(WatchConnectivity)
        guard isSupported, WCSession.default.activationState == .activated else { return }
        let payload = DeleteConversationPayload(conversationID: id, sentAt: Date())
        transferUserInfo(kind: .deleteConversation, payload: payload)
        #endif
    }

    public func publishMessage(_ message: MessageSnapshot, in conversationID: UUID) {
        #if canImport(WatchConnectivity)
        guard isSupported, WCSession.default.activationState == .activated else { return }
        let payload = MessageEnvelope(conversationID: conversationID, message: message, sentAt: Date())
        transferUserInfo(kind: .message, payload: payload)
        #endif
    }

    /// Ask the companion for its current endpoint catalog. Used by the
    /// watch on first launch (and on the iPhone when the user pulls-to-
    /// refresh) so the receiver can reply with the latest snapshot.
    public func requestEndpoints() {
        #if canImport(WatchConnectivity)
        guard isSupported, WCSession.default.activationState == .activated else { return }
        let message: [String: Any] = [
            SyncMessageKey.kind: SyncMessageKind.requestEndpoints.rawValue
        ]
        WCSession.default.sendMessage(message, replyHandler: nil) { error in
            Task { @MainActor in self.lastError = "requestEndpoints failed: \(error.localizedDescription)" }
        }
        #endif
    }

    /// Ask the companion for its full conversation catalog (one-shot
    /// reply, used to seed the watch on first launch and to recover
    /// after the watch has been reinstalled). The receiver walks its
    /// local SwiftData store and replies with a `ConversationsPayload`
    /// containing every conversation it has.
    public func requestConversations() {
        #if canImport(WatchConnectivity)
        guard isSupported, WCSession.default.activationState == .activated else { return }
        let message: [String: Any] = [
            SyncMessageKey.kind: SyncMessageKind.requestConversations.rawValue
        ]
        WCSession.default.sendMessage(message, replyHandler: nil) { error in
            Task { @MainActor in self.lastError = "requestConversations failed: \(error.localizedDescription)" }
        }
        #endif
    }

    /// Ask the paired iPhone to write the current conversation catalog to
    /// iCloud. The watch does not own the iCloud container directly; keeping
    /// the export on iOS avoids adding iCloud provisioning requirements to
    /// the embedded watchOS app.
    public func requestConversationBackup(replyHandler: @escaping (ConversationBackupReply) -> Void) {
        #if canImport(WatchConnectivity)
        guard isSupported, WCSession.default.activationState == .activated else {
            replyHandler(.failure("Watch sync is not active."))
            return
        }
        let session = WCSession.default
        guard session.isReachable else {
            replyHandler(.failure("The paired iPhone is not reachable."))
            return
        }
        let message: [String: Any] = [
            SyncMessageKey.kind: SyncMessageKind.requestConversationBackup.rawValue
        ]
        session.sendMessage(message, replyHandler: { reply in
            Task { @MainActor in
                guard let kindRaw = reply[SyncMessageKey.kind] as? String,
                      kindRaw == SyncMessageKind.conversationBackupResult.rawValue,
                      let data = reply[SyncMessageKey.payload] as? Data,
                      let payload = try? Self.decoder.decode(ConversationBackupResultPayload.self, from: data) else {
                    replyHandler(.failure("The iPhone did not return a backup result."))
                    return
                }
                self.lastSyncedAt = Date()
                if payload.succeeded {
                    replyHandler(.success(conversationCount: payload.conversationCount, fileName: payload.fileName))
                } else {
                    replyHandler(.failure(payload.message))
                }
            }
        }) { error in
            Task { @MainActor in
                self.lastError = "requestConversationBackup failed: \(error.localizedDescription)"
                replyHandler(.failure(error.localizedDescription))
            }
        }
        #else
        replyHandler(.failure("Watch sync is not supported."))
        #endif
    }

    /// Ask the paired iPhone to restore the latest iCloud backup into its
    /// SwiftData store, then use the normal conversation pull to mirror the
    /// restored rows back onto the watch.
    public func requestConversationRestore(replyHandler: @escaping (ConversationBackupReply) -> Void) {
        #if canImport(WatchConnectivity)
        guard isSupported, WCSession.default.activationState == .activated else {
            replyHandler(.failure("Watch sync is not active."))
            return
        }
        let session = WCSession.default
        guard session.isReachable else {
            replyHandler(.failure("The paired iPhone is not reachable."))
            return
        }
        let message: [String: Any] = [
            SyncMessageKey.kind: SyncMessageKind.requestConversationRestore.rawValue
        ]
        session.sendMessage(message, replyHandler: { reply in
            Task { @MainActor in
                guard let kindRaw = reply[SyncMessageKey.kind] as? String,
                      kindRaw == SyncMessageKind.conversationRestoreResult.rawValue,
                      let data = reply[SyncMessageKey.payload] as? Data,
                      let payload = try? Self.decoder.decode(ConversationBackupResultPayload.self, from: data) else {
                    replyHandler(.failure("The iPhone did not return a restore result."))
                    return
                }
                self.lastSyncedAt = Date()
                if payload.succeeded {
                    replyHandler(.success(conversationCount: payload.conversationCount, fileName: payload.fileName))
                } else {
                    replyHandler(.failure(payload.message))
                }
            }
        }) { error in
            Task { @MainActor in
                self.lastError = "requestConversationRestore failed: \(error.localizedDescription)"
                replyHandler(.failure(error.localizedDescription))
            }
        }
        #else
        replyHandler(.failure("Watch sync is not supported."))
        #endif
    }

    // MARK: - Internal helpers

    #if canImport(WatchConnectivity)
    private func transferUserInfo<T: Encodable>(kind: SyncMessageKind, payload: T) {
        do {
            let data = try Self.encoder.encode(payload)
            let userInfo: [String: Any] = [
                SyncMessageKey.kind: kind.rawValue,
                SyncMessageKey.payload: data
            ]
            WCSession.default.transferUserInfo(userInfo)
        } catch {
            lastError = "transferUserInfo(\(kind)) failed: \(error.localizedDescription)"
        }
    }
    #endif

    fileprivate static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    fileprivate static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

#if canImport(WatchConnectivity)
extension SyncCoordinator: @preconcurrency WCSessionDelegate {
    public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.activationState = activationState == .activated ? .activated : .inactive
            self.isCompanionReachable = session.isReachable
            if let error {
                self.lastError = "WCSession activation error: \(error.localizedDescription)"
            }
            // Activation just finished (succeeded or failed). If we
            // are now `.activated`, drain any deferred bootstrap.
            self.flushPendingBootstrapIfReady()
        }
    }

    #if !os(watchOS)
    // The "did become inactive" / "did deactivate" callbacks are
    // unavailable on watchOS — the watch only ever has one paired
    // session, so Apple removed them. We still implement them on iOS
    // because the iPhone may pair with a different watch mid-session
    // and needs to re-activate.
    public func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor in
            self.activationState = .inactive
            self.isCompanionReachable = false
        }
    }

    public func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor in
            self.activationState = .inactive
            self.isCompanionReachable = false
            // Re-activate; on iOS the session may need this after switching
            // watches. On watchOS this is a no-op for the active pair.
            WCSession.default.activate()
        }
    }
    #endif

    public func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isCompanionReachable = session.isReachable
            // The companion just became reachable — if we tried to
            // bootstrap while it was offline, retry now.
            self.flushPendingBootstrapIfReady()
            #if os(watchOS)
            if session.isReachable { self.requestSearchSources() }
            #endif
        }
    }

    // Application context = cheap, latest-wins endpoint snapshot.
    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let kindRaw = applicationContext[SyncMessageKey.kind] as? String,
              let kind = SyncMessageKind(rawValue: kindRaw) else { return }
        handle(kind: kind, raw: applicationContext)
    }

    // transferUserInfo payloads: reliable, queued.
    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let kindRaw = userInfo[SyncMessageKey.kind] as? String,
              let kind = SyncMessageKind(rawValue: kindRaw) else { return }
        handle(kind: kind, raw: userInfo)
    }

    public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let kindRaw = message[SyncMessageKey.kind] as? String,
              let kind = SyncMessageKind(rawValue: kindRaw) else { return }
        handle(kind: kind, raw: message)
    }

    public func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let kindRaw = message[SyncMessageKey.kind] as? String,
              let kind = SyncMessageKind(rawValue: kindRaw) else {
            replyHandler([:])
            return
        }
        if kind == .requestSearchSources {
            #if os(iOS)
            if let data = try? Self.encoder.encode(SearchSourceStore.shared.companionPayload()) {
                replyHandler([SyncMessageKey.kind: SyncMessageKind.searchSources.rawValue, SyncMessageKey.payload: data])
            } else { replyHandler([:]) }
            #else
            replyHandler([:])
            #endif
            return
        }
        // For requestEndpoints, reply with endpoints + keys in a
        // single EndpointsAndKeysPayload so the watch can refresh
        // both stores in one round-trip. This is the reliable path
        // the user can trigger from the watch side (or that runs
        // automatically on the watch's bootstrap).
        if kind == .requestEndpoints {
            let snapshot = EndpointStore.shared.endpoints
            let activeID = EndpointStore.shared.activeEndpointID
            let keys: [APIKeyPayload] = snapshot.compactMap { ep in
                guard let stored = EndpointStore.shared.apiKey(for: ep.id) else { return nil }
                return APIKeyPayload(endpointID: ep.id, value: stored, sentAt: Date())
            }
            let payload = EndpointsAndKeysPayload(
                endpoints: snapshot,
                activeID: activeID,
                keys: keys,
                sentAt: Date()
            )
            if let data = try? Self.encoder.encode(payload) {
                let reply: [String: Any] = [
                    SyncMessageKey.kind: SyncMessageKind.endpointsAndKeys.rawValue,
                    SyncMessageKey.payload: data
                ]
                replyHandler(reply)
                Task { @MainActor in self.lastSyncedAt = Date() }
                return
            }
            replyHandler([:])
            return
        }
        // Watch-initiated "give me the keys" request. Reply with
        // the current keychain contents so the watch can re-seed
        // itself even when the iPhone-initiated push didn't land.
        if kind == .requestAPIKeys {
            let keys: [APIKeyPayload] = EndpointStore.shared.endpoints.compactMap { ep in
                guard let stored = EndpointStore.shared.apiKey(for: ep.id) else { return nil }
                return APIKeyPayload(endpointID: ep.id, value: stored, sentAt: Date())
            }
            let payload = APIKeysPayload(keys: keys, sentAt: Date())
            if let data = try? Self.encoder.encode(payload) {
                let reply: [String: Any] = [
                    SyncMessageKey.kind: SyncMessageKind.apiKeys.rawValue,
                    SyncMessageKey.payload: data
                ]
                replyHandler(reply)
                Task { @MainActor in self.lastSyncedAt = Date() }
                return
            }
            replyHandler([:])
            return
        }
        if kind == .requestConversations {
            // Pull every conversation (with messages) from the local
            // SwiftData store and send it back. Done as one big payload
            // because replyHandler is single-shot; the receiver can
            // decode it as a single ConversationsPayload with potentially
            // many entries.
            let context = DataStore.shared.mainContext
            let descriptor = FetchDescriptor<Conversation>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
            let convs = (try? context.fetch(descriptor)) ?? []
            let snapshots = convs.map { ConversationSnapshot($0) }
            let payload = ConversationsPayload(conversations: snapshots, sentAt: Date())
            if let data = try? Self.encoder.encode(payload) {
                let reply: [String: Any] = [
                    SyncMessageKey.kind: SyncMessageKind.conversations.rawValue,
                    SyncMessageKey.payload: data
                ]
                replyHandler(reply)
                Task { @MainActor in self.lastSyncedAt = Date() }
                return
            }
            replyHandler([:])
            return
        }
        if kind == .requestConversationBackup {
            let context = DataStore.shared.mainContext
            let descriptor = FetchDescriptor<Conversation>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
            let convs = (try? context.fetch(descriptor)) ?? []
            let result: ConversationBackupResultPayload
            do {
                let backup = try ConversationBackupStore.writeBackup(for: convs)
                result = ConversationBackupResultPayload(
                    succeeded: true,
                    conversationCount: backup.conversationCount,
                    fileName: backup.fileName,
                    message: "Saved \(backup.conversationCount) chat\(backup.conversationCount == 1 ? "" : "s") to \(backup.fileName)."
                )
            } catch {
                result = ConversationBackupResultPayload(
                    succeeded: false,
                    conversationCount: convs.count,
                    fileName: nil,
                    message: error.localizedDescription
                )
            }
            if let data = try? Self.encoder.encode(result) {
                let reply: [String: Any] = [
                    SyncMessageKey.kind: SyncMessageKind.conversationBackupResult.rawValue,
                    SyncMessageKey.payload: data
                ]
                replyHandler(reply)
                Task { @MainActor in self.lastSyncedAt = Date() }
                return
            }
            replyHandler([:])
            return
        }
        if kind == .requestConversationRestore {
            let context = DataStore.shared.mainContext
            let result: ConversationBackupResultPayload
            do {
                let restore = try ConversationBackupStore.restoreLatestBackup(into: context)
                self.publishConversations(restore.conversations)
                result = ConversationBackupResultPayload(
                    succeeded: true,
                    conversationCount: restore.conversationCount,
                    fileName: restore.fileName,
                    message: "Restored \(restore.conversationCount) chat\(restore.conversationCount == 1 ? "" : "s") from \(restore.fileName)."
                )
            } catch {
                result = ConversationBackupResultPayload(
                    succeeded: false,
                    conversationCount: 0,
                    fileName: nil,
                    message: error.localizedDescription
                )
            }
            if let data = try? Self.encoder.encode(result) {
                let reply: [String: Any] = [
                    SyncMessageKey.kind: SyncMessageKind.conversationRestoreResult.rawValue,
                    SyncMessageKey.payload: data
                ]
                replyHandler(reply)
                Task { @MainActor in self.lastSyncedAt = Date() }
                return
            }
            replyHandler([:])
            return
        }
        handle(kind: kind, raw: message)
        replyHandler([:])
    }

    private func handle(kind: SyncMessageKind, raw: [String: Any]) {
        guard let payloadData = raw[SyncMessageKey.payload] as? Data else { return }
        Task { @MainActor in
            do {
                switch kind {
                case .searchSources:
                    #if os(watchOS)
                    let payload = try Self.decoder.decode(SearchSourceCompanionPayload.self, from: payloadData)
                    try SearchSourceStore.shared.applyCompanionPayload(payload)
                    #endif
                case .requestSearchSources:
                    break
                case .endpoints:
                    let payload = try Self.decoder.decode(EndpointsPayload.self, from: payloadData)
                    // Defense in depth: never apply a catalog wipe from
                    // an empty payload. The legitimate path for "user
                    // deleted their last endpoint" is via the next non-
                    // empty save on the originating device, not a stray
                    // empty snapshot.
                    if payload.endpoints.isEmpty { break }
                    EndpointStore.shared.applyRemoteEndpoints(payload.endpoints, activeID: payload.activeID)
                case .apiKey:
                    let payload = try Self.decoder.decode(APIKeyPayload.self, from: payloadData)
                    applyAPIKeyPayload(payload)
                case .apiKeys:
                    let payload = try Self.decoder.decode(APIKeysPayload.self, from: payloadData)
                    for k in payload.keys { applyAPIKeyPayload(k) }
                case .endpointsAndKeys:
                    let payload = try Self.decoder.decode(EndpointsAndKeysPayload.self, from: payloadData)
                    if !payload.endpoints.isEmpty {
                        EndpointStore.shared.applyRemoteEndpoints(payload.endpoints, activeID: payload.activeID)
                    }
                    for k in payload.keys { applyAPIKeyPayload(k) }
                case .conversation:
                    let snapshot = try Self.decoder.decode(ConversationSnapshot.self, from: payloadData)
                    SyncInbox.shared.upsertConversation(snapshot)
                case .message:
                    let envelope = try Self.decoder.decode(MessageEnvelope.self, from: payloadData)
                    SyncInbox.shared.upsertMessage(envelope.message, in: envelope.conversationID)
                case .requestEndpoints:
                    // No payload expected; receivers shouldn't normally see
                    // this. If they do (e.g. a request sent to themselves),
                    // the watch-side will treat it as a no-op.
                    break
                case .requestAPIKeys:
                    // Same as above; the response goes back over the
                    // session reply path, not through this receive branch.
                    break
                case .requestConversations:
                    // Same as above; the response goes back over the session
                    // reply path, not through this receive branch.
                    break
                case .conversations:
                    let payload = try Self.decoder.decode(ConversationsPayload.self, from: payloadData)
                    SyncInbox.shared.upsertConversations(payload.conversations)
                case .deleteConversation:
                    let payload = try Self.decoder.decode(DeleteConversationPayload.self, from: payloadData)
                    SyncInbox.shared.deleteConversation(payload.conversationID)
                case .requestConversationBackup, .conversationBackupResult, .requestConversationRestore, .conversationRestoreResult:
                    break
                }
                self.lastSyncedAt = Date()
            } catch {
                self.lastError = "decode(\(kind)) failed: \(error.localizedDescription)"
            }
        }
    }
}
#endif

// MARK: - Shared apply helpers

#if canImport(WatchConnectivity)
/// Write a received API key into the local keychain. Centralised here
/// so the four inbound paths (apiKey, apiKeys, endpointsAndKeys, and
/// the same set decoded from a legacy transferUserInfo) all share the
/// same write semantics — including the empty-value "clear key" case.
@MainActor
private func applyAPIKeyPayload(_ payload: APIKeyPayload) {
    guard EndpointStore.shared.endpoints.first(where: { $0.id == payload.endpointID })?.authentication != .chatGPT else { return }
    let account = "\(payload.endpointID.uuidString).apikey"
    if payload.value.isEmpty {
        KeychainStore.delete(account)
    } else {
        KeychainStore.set(payload.value, for: account)
    }
}
#endif

// MARK: - Wire keys

public enum SyncMessageKey {
    static let kind = "kind"
    static let payload = "payload"
}

public enum SyncMessageKind: String, Codable, Sendable {
    case searchSources
    case requestSearchSources
    case endpoints
    case apiKey
    case apiKeys
    case endpointsAndKeys
    case conversation
    case conversations
    case message
    case requestEndpoints
    case requestAPIKeys
    case requestConversations
    case deleteConversation
    case requestConversationBackup
    case conversationBackupResult
    case requestConversationRestore
    case conversationRestoreResult
}

// MARK: - Payloads

public struct EndpointsPayload: Codable, Sendable {
    let endpoints: [EndpointConfig]
    let activeID: UUID?
    let sentAt: Date
}

/// Bulk snapshot of every conversation in the local SwiftData store. Used
/// to seed the companion on first launch (or on manual resync) so a fresh-
/// install watch immediately sees the iPhone's chat history without
/// waiting for a per-conversation publish.
public struct ConversationsPayload: Codable, Sendable {
    let conversations: [ConversationSnapshot]
    let sentAt: Date
}

public struct APIKeyPayload: Codable, Sendable {
    let endpointID: UUID
    let value: String
    let sentAt: Date
}

/// Bulk snapshot of every saved API key. Used by the iPhone in response
/// to `requestAPIKeys` and as a part of `endpointsAndKeys` so the watch
/// can pull the whole truth in a single round-trip. Empty values are
/// preserved (so the receiver can also clear keys), and skipped entirely
/// only when there is no keychain entry at all for that endpoint.
public struct APIKeysPayload: Codable, Sendable {
    let keys: [APIKeyPayload]
    let sentAt: Date
}

/// Bundles endpoint catalog + API keys in a single payload. The
/// `requestEndpoints` reply now uses this shape so a single sendMessage
/// round-trip on the iPhone→watch side updates both stores atomically.
/// Watch-side receipt applies the endpoints (replacing the local seed)
/// and then writes each key into the watch keychain. This is the
/// reliable sync path that replaces the previous transferUserInfo
/// (which is queued, requires the watch app to be running, and silently
/// dropped the write when the watch keychain entitlement was missing).
public struct EndpointsAndKeysPayload: Codable, Sendable {
    let endpoints: [EndpointConfig]
    let activeID: UUID?
    let keys: [APIKeyPayload]
    let sentAt: Date
}

/// Plain-value shape of a `Conversation` suitable for cross-process
/// transport. Built from the SwiftData model on the way out and turned
/// back into a `Conversation` on the way in (see `SyncInbox`).
public struct ConversationSnapshot: Codable, Sendable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var endpointID: UUID
    var endpointName: String
    var model: String
    var systemPrompt: String
    var messages: [MessageSnapshot]

    init(_ conversation: Conversation) {
        self.id = conversation.id
        self.title = conversation.title
        self.createdAt = conversation.createdAt
        self.updatedAt = conversation.updatedAt
        self.endpointID = conversation.endpointID
        self.endpointName = conversation.endpointName
        self.model = conversation.model
        self.systemPrompt = conversation.systemPrompt
        self.messages = conversation.sortedMessages.map(MessageSnapshot.init)
    }
}

public struct MessageSnapshot: Codable, Sendable {
    let id: UUID
    var roleRaw: String
    var content: String
    var createdAt: Date
    var orderIndex: Int
    var responseMetadata: ResponseMetadata?

    init(_ message: Message) {
        self.id = message.id
        self.roleRaw = message.roleRaw
        self.content = message.content
        self.createdAt = message.createdAt
        self.orderIndex = message.orderIndex
        self.responseMetadata = message.responseMetadata
    }
}

public struct MessageEnvelope: Codable, Sendable {
    let conversationID: UUID
    let message: MessageSnapshot
    let sentAt: Date
}

public enum ConversationBackupReply: Sendable {
    case success(conversationCount: Int, fileName: String?)
    case failure(String)
}

public struct ConversationBackupResultPayload: Codable, Sendable {
    let succeeded: Bool
    let conversationCount: Int
    let fileName: String?
    let message: String
}

/// Tells the companion that a conversation was deleted on this side.
/// The receiver drops the matching local row (and its messages via
/// the SwiftData cascade rule) but does not republish the delete,
/// preventing an iPhone↔watch ping-pong.
public struct DeleteConversationPayload: Codable, Sendable {
    let conversationID: UUID
    let sentAt: Date
}
