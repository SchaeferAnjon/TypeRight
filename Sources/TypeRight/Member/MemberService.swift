//
//  MemberService.swift
//  TypeRight
//
//  Membership without an account: this Mac registers with the backend and the first 100 new Macs
//  get 300 free AI checks; after that a subscription (monthly or yearly, card, renews by itself) or,
//  in yuan, a one-time pass of 1 month or 1 year (WeChat Pay and others, does not renew), 500 checks a day.
//  A license code works on a second Mac (2 per code). Without a key of their own, the AI cards go
//  through the backend (OpenAI-compatible, X-Use-Id: one use number per card); the provider key
//  stays on the server.
//
//  This is the model the "账号与会员" settings page binds to: the plan, the trial and membership
//  state, purchases and the license code. Backend contract: meetcaption-server docs/multi-product.md §4.
//  Ported from GetNewWord's MemberService.swift (same author, GPL-3.0); sync is left out.
//

import AppKit
import Combine
import CryptoKit
import IOKit

// MARK: - Backend address

enum MemberAPI {
    static let product = "typeright"
    static let production = "https://api.us-cloud.uk"
    /// The model the backend uses (it ignores what the app sends).
    static let model = "deepseek-flash"
    /// Debug builds: where to find a local backend (environment first, then UserDefaults).
    static let environmentKey = "TYPERIGHT_API"
    static let defaultsKey = "typeright.api"

    #if DEBUG
        static let isDebugBuild = true
    #else
        static let isDebugBuild = false
    #endif

    /// Release builds always use production. Debug builds only connect when pointed at a backend
    /// (TYPERIGHT_API or `defaults write com.typeright.app typeright.api http://127.0.0.1:8820`),
    /// so they never take one of the first 100 trials. Unit tests run inside the app and never connect.
    static func base(environment: [String: String], defaults: UserDefaults, isDebug: Bool) -> URL? {
        if environment["XCTestConfigurationFilePath"] != nil { return nil }
        guard isDebug else { return URL(string: production) }
        var raw = (environment[environmentKey] ?? defaults.string(forKey: defaultsKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") {
            raw.removeLast()
        }
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    static var current: URL? {
        base(environment: ProcessInfo.processInfo.environment, defaults: .standard, isDebug: isDebugBuild)
    }

    static var arch: String {
        #if arch(arm64)
            "arm64"
        #else
            "x64"
        #endif
    }

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
}

// MARK: - Device fingerprint

enum MemberDevice {
    /// sha256("typeright:" + hardware UUID) in hex: the same Mac reinstalled is still the same Mac and
    /// gets no second trial. The backend only keeps a hash of it.
    static func fingerprint(hardwareUUID: String) -> String {
        SHA256.hash(data: Data("\(MemberAPI.product):\(hardwareUUID)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// This Mac's IOPlatformUUID, or nil when it cannot be read.
    static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else {
            Logger.warning("TypeRight member: no IOPlatformExpertDevice", category: Logger.general)
            return nil
        }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Without a hardware UUID: a random value kept in UserDefaults (changes when the app's data is deleted).
    static func current(defaults: UserDefaults) -> String {
        if let uuid = hardwareUUID() { return fingerprint(hardwareUUID: uuid) }
        let key = "typeright.memberFallbackDevice"
        if let saved = defaults.string(forKey: key), saved.count == 64 { return saved }
        let random = SHA256.hash(data: Data(UUID().uuidString.utf8)).map { String(format: "%02x", $0) }.joined()
        defaults.set(random, forKey: key)
        return random
    }
}

// MARK: - Where the device token lives

/// The device token (trd_…): the keychain in the app, memory in tests. A token is only ever sent to
/// the backend that issued it (a local test backend's token never goes to production).
struct MemberTokenStore {
    var load: () -> String?
    var save: (String?) -> Void

    static func keychain(api: URL?) -> MemberTokenStore {
        let account = "member_device"
        return MemberTokenStore(load: {
            guard let raw = CoachKeychain.string(account: account),
                  let saved = try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8)),
                  saved["api"] == api?.absoluteString else { return nil }
            return saved["token"]
        }, save: { token in
            guard let token, let api,
                  let data = try? JSONEncoder().encode(["api": api.absoluteString, "token": token])
            else {
                CoachKeychain.setString("", account: account)
                return
            }
            if !CoachKeychain.setString(String(decoding: data, as: UTF8.self), account: account) {
                Logger.warning("TypeRight member: could not keep the device token in the keychain", category: Logger.general)
            }
        })
    }

    static func memory(_ initial: String? = nil) -> MemberTokenStore {
        final class Box: @unchecked Sendable { var token: String? }
        let box = Box()
        box.token = initial
        return MemberTokenStore(load: { box.token }, save: { box.token = $0 })
    }
}

extension HTTPURLResponse {
    var stringHeaders: [String: String] {
        var out: [String: String] = [:]
        for (k, v) in allHeaderFields {
            if let k = k as? String { out[k] = v as? String ?? "\(v)" }
        }
        return out
    }
}

// MARK: - The service

@MainActor
final class MemberService: ObservableObject {
    static let shared = MemberService(api: MemberAPI.current, defaults: .standard)

    /// A checkout page that was opened.
    struct Purchase: Equatable {
        let claim: String
        /// sub (renews by itself) or pass (one time, yuan only)
        let mode: String
        /// month or year
        let plan: String
        /// cny or usd
        let currency: String
        let url: URL
        let started: Date
    }

    /// The latest status from the backend (kept from last time until a new one arrives).
    @Published private(set) var status: MemberStatus?
    /// The last request that failed; with an older status the page still shows it, plus a note.
    @Published private(set) var lastError: MemberError?
    /// Waiting for a payment (asks every 3 seconds).
    @Published private(set) var purchase: Purchase?
    /// What registering got: granted / existing / closed / ip-limit / daily-limit
    @Published private(set) var trialResult: String?
    /// Just paid (the page says so).
    @Published var justPaid = false
    /// This Mac has a device token.
    @Published private(set) var registered: Bool
    /// Registering right now.
    @Published private(set) var claiming = false
    /// An error raised elsewhere, to show on the page.
    @Published var notice: MemberError?

    let api: URL?
    var isAvailable: Bool { api != nil }

    var state: MemberState {
        MemberState.of(status, available: isAvailable, failed: lastError != nil, trialResult: trialResult, registered: registered || claiming)
    }

    var isMember: Bool { status?.isMember == true }

    /// How TypeRight works: on-device only, own key, or trial / membership. Never chosen: own when a key
    /// is filled in, otherwise member (AIPlan.resolve).
    var plan: AIPlan {
        get { AIPlan.resolve(stored: defaults.string(forKey: AIPlan.key), hasOwnKey: ownKey() != nil) }
        set {
            objectWillChange.send()
            defaults.set(newValue.rawValue, forKey: AIPlan.key)
            Logger.info("TypeRight member: plan \(newValue.rawValue)", category: Logger.general)
        }
    }

    /// Whether the AI cards are on now and where they go.
    var aiStatus: CoachAIStatus {
        switch plan {
        case .local: return .localOnly
        case .own:
            // A key the provider turned down counts as none until a new one is saved.
            guard let provider = ownKey(), !keyRejected(provider) else { return .noKey }
            return .own(provider)
        case .member:
            let s = state
            return s.blocked ? .memberBlocked(s) : .member
        }
    }

    /// The provider whose key is filled in and ready (replaced in unit tests).
    var ownKey: () -> CoachProvider? = { CoachSettings.isAIReady ? CoachSettings.provider : nil }
    /// The provider answered 401 / 403 to this key (replaced in unit tests).
    var keyRejected: (CoachProvider) -> Bool = { CoachKeyStore.shared.isRejected($0) }
    var pollInterval: Duration = .seconds(3)
    var pollLimit: TimeInterval = 30 * 60
    /// Seconds before a card's second and third request.
    var retryDelays: [Double] = [0.5, 1.5]
    /// A card may send this many chat requests (retries included); the backend allows 3 per use number.
    static let requestsPerUse = 3
    /// A Retry-After longer than this is not waited for: the card gives up.
    static let longestRetryWait: Double = 3
    /// A Stripe checkout page lives for an hour: within this, the same choice reopens the same page instead of a second order.
    static let checkoutReuse: TimeInterval = 55 * 60

    private let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    /// The AI cards' replies, streamed over the AI session (see CoachNet).
    private let lines: CoachNet.Lines
    private let tokens: MemberTokenStore
    private let defaults: UserDefaults
    private let device: () -> String
    private let openURL: (URL) -> Void
    private var registering: Task<String, Error>?
    private var refreshing: Task<Void, Never>?
    private var poll: Task<Void, Never>?
    private var activeObserver: NSObjectProtocol?
    private(set) var checkedAt: Date?
    /// The browser was just opened (checkout, portal): coming back asks at once.
    private var backFromBrowser = false
    /// The last checkout page, kept after "不等了", see checkoutReuse.
    private var lastCheckout: Purchase?
    private static let cacheKey = "typeright.memberCache"

    private struct Cache: Codable {
        var api: String
        var status: MemberStatus?
        var trialResult: String?
    }

    init(api: URL?, defaults: UserDefaults, tokens: MemberTokenStore? = nil,
         device: (() -> String)? = nil,
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
         send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
         lines: @escaping CoachNet.Lines = CoachNet.lines)
    {
        self.lines = lines
        self.api = api
        self.defaults = defaults
        let tokens = tokens ?? .keychain(api: api)
        self.tokens = tokens
        registered = api != nil && tokens.load() != nil
        self.device = device ?? { MemberDevice.current(defaults: defaults) }
        self.openURL = openURL
        self.send = send
        // Last time's status shows until the backend answers.
        if let api, let data = defaults.data(forKey: Self.cacheKey),
           let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.api == api.absoluteString
        {
            status = cache.status
            trialResult = cache.trialResult
        }
    }

    private var memberMode: Bool { plan == .member }

    private func storeToken(_ token: String?) {
        tokens.save(token)
        registered = token != nil
    }

    /// At launch: ask once if on the member plan and registered; ask again when the app comes to the
    /// front (at most once a minute). Never registers by itself.
    func start() {
        if memberMode, registered { Task { await refresh() } }
        guard activeObserver == nil else { return }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.appBecameActive() }
        }
    }

    private func appBecameActive() {
        let force = backFromBrowser
        backFromBrowser = false
        // Own-key and on-device users are left alone, except right after a checkout or the portal.
        guard registered, memberMode || force else { return }
        Task { await refresh(maxAge: force ? 0 : 60) }
    }

    // MARK: Registering and status

    /// Registers this Mac and claims the trial, keeping the device token; returns the token if there
    /// is one already. Calls at the same time share one registration. Only called when someone really
    /// uses the membership: the first AI card on the member plan, choosing that plan, buying, a code.
    func ensureDevice() async throws -> String {
        guard api != nil else { throw MemberError.unavailable }
        if let token = tokens.load() { return token }
        if let task = registering { return try await task.value }
        let task = Task { () throws -> String in
            let body = try JSONSerialization.data(withJSONObject: [
                "device": self.device(), "platform": "darwin", "arch": MemberAPI.arch, "version": MemberAPI.version,
            ])
            let (data, _) = try await self.call("POST", "device", body: body, auth: false)
            let r = try MemberStatus.registration(from: data)
            self.storeToken(r.token)
            // Registering again (token lost) only says existing: keep the first answer to explain a missing trial.
            if r.trial != "existing" || self.trialResult == nil { self.trialResult = r.trial }
            self.lastError = nil
            self.checkedAt = Date()
            self.apply(r.status)
            Logger.info("TypeRight member: registered, trial \(r.trial), plan \(r.status.plan), left \(r.status.trial.left)", category: Logger.general)
            return r.token
        }
        registering = task
        claiming = true
        defer {
            registering = nil
            claiming = false
        }
        return try await task.value
    }

    /// The member plan was chosen: register and claim the trial now. If the backend cannot be reached
    /// that is only noted; the first AI card tries again.
    func claimTrial() async {
        guard api != nil, !registered else { return }
        do {
            _ = try await ensureDevice()
        } catch {
            lastError = error as? MemberError ?? .network
            Logger.info("TypeRight member: claiming the trial failed: \(lastError?.code ?? "?")", category: Logger.general)
        }
    }

    /// Asks for the latest status (another Mac used some, a refund, an expiry: only the backend knows).
    /// Unreachable keeps the old one. maxAge: with a status checked less than this many seconds ago,
    /// do not ask. Never registers: that would take a trial for someone who has not used the membership.
    func refresh(maxAge: TimeInterval = 0) async {
        guard api != nil, registered else { return }
        if let task = refreshing { return await task.value }
        if maxAge > 0, status != nil, let at = checkedAt, Date().timeIntervalSince(at) < maxAge { return }
        let task = Task {
            do {
                let data = try await self.request("GET", "status")
                guard let s = try? JSONDecoder().decode(MemberStatus.self, from: data) else { throw MemberError.badReply }
                self.apply(s)
                self.lastError = nil
            } catch {
                self.lastError = error as? MemberError ?? .network
                Logger.info("TypeRight member: status failed: \(self.lastError?.code ?? "?")", category: Logger.general)
            }
            self.checkedAt = Date()
        }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func apply(_ s: MemberStatus) {
        status = s
        if let api, let data = try? JSONEncoder().encode(Cache(api: api.absoluteString, status: s, trialResult: trialResult)) {
            defaults.set(data, forKey: Self.cacheKey)
        }
    }

    /// Before an error is shown: add what explains it from this Mac's status (why no trial, until
    /// when a pass runs, whether a daily limit is the cost cap).
    func explain(_ e: MemberError) -> MemberError {
        var e = e
        switch e.code {
        case "trial-closed": e.miss = .of(status?.trialResult ?? trialResult)
        case "pass-active": e.until = MemberStatus.date(status?.memberUntil)
        // Two daily limits: 500 uses, or this license's cost for the day. /status says which in limitBy;
        // right after a 429, before asking: a trial has no daily count, so it is the cost; a member
        // with uses left today hit the cost too.
        case "daily-limit":
            if let by = status?.limitBy, status?.reason == "daily-limit" { e.costCap = by == "cost" }
            else if status?.isMember != true { e.costCap = true }
            else { e.costCap = (status?.today?.left ?? 0) > 0 }
        default: break
        }
        return e
    }

    // MARK: License code

    /// Moves this Mac onto the license with this code (case, spaces and a missing TR- are fine).
    func activate(code: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["code": code])
        apply(try decodeStatus(await request("POST", "license/activate", body: body)))
        lastError = nil
        Logger.info("TypeRight member: activated a license code, plan \(status?.plan ?? "?")", category: Logger.general)
    }

    /// This Mac goes back to its own trial license (whatever is left of it).
    func unbind() async throws {
        apply(try decodeStatus(await request("POST", "license/unbind")))
        Logger.info("TypeRight member: unbound this Mac", category: Logger.general)
    }

    // MARK: Buying

    /// Opens a checkout: mode sub (renews by itself) or pass (one time, yuan only), plan month or year,
    /// currency cny or usd. The browser shows the payment page; then every 3 seconds, for up to 30
    /// minutes, the backend is asked whether it was paid. The same choice within the hour (after
    /// "不等了") asks about that order first and reopens its page rather than opening a second order.
    func buy(plan: String, currency: String, mode: String) async throws {
        if let last = lastCheckout, last.plan == plan, last.mode == mode, last.currency == currency,
           Date().timeIntervalSince(last.started) < Self.checkoutReuse
        {
            switch await checkClaim(last.claim) {
            case "paid":
                return
            case "expired":
                break
            default:
                justPaid = false
                purchase = last
                backFromBrowser = true
                Logger.info("TypeRight member: checkout reopened \(mode) \(plan) \(currency)", category: Logger.general)
                openURL(last.url)
                startPolling(last.claim)
                return
            }
        }
        struct Checkout: Decodable { let url: String; let claim: String }
        let data: Data
        do {
            data = try await request("POST", "checkout", body: JSONSerialization.data(withJSONObject: ["plan": plan, "currency": currency, "mode": mode]))
        } catch var e as MemberError where e.code == "upstream" {
            e.code = "pay-upstream" // the payment service, not the member AI
            throw e
        } catch let e as MemberError where e.code == "already-paid" {
            // The earlier page was paid after all: ask for the status; a member counts as paid.
            await refresh()
            guard isMember else { throw e }
            lastCheckout = nil
            justPaid = true
            Logger.info("TypeRight member: an earlier checkout was already paid", category: Logger.general)
            return
        }
        guard let r = try? JSONDecoder().decode(Checkout.self, from: data), let url = URL(string: r.url) else { throw MemberError.badReply }
        justPaid = false
        let p = Purchase(claim: r.claim, mode: mode, plan: plan, currency: currency, url: url, started: Date())
        purchase = p
        lastCheckout = p
        backFromBrowser = true
        Logger.info("TypeRight member: checkout \(mode) \(plan) \(currency)", category: Logger.general)
        openURL(url)
        startPolling(r.claim)
    }

    /// "不等了": stop asking; the page stays valid, and the same choice within the hour reopens it.
    func cancelPurchase() {
        poll?.cancel()
        poll = nil
        purchase = nil
    }

    /// Asks once whether an order was paid; paid updates the status. paid / expired / pending, nil when it could not ask.
    private func checkClaim(_ claim: String) async -> String? {
        guard let data = try? await request("GET", "checkout/\(claim)"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let result = obj["status"] as? String
        switch result {
        case "paid":
            if let s = try? JSONDecoder().decode(MemberStatus.self, from: data) { apply(s) }
            lastError = nil
            checkedAt = Date()
            justPaid = true
            purchase = nil
            lastCheckout = nil
            Logger.info("TypeRight member: paid, plan \(status?.plan ?? "?")", category: Logger.general)
        case "expired":
            Logger.info("TypeRight member: checkout expired", category: Logger.general)
            if purchase?.claim == claim { purchase = nil }
            if lastCheckout?.claim == claim { lastCheckout = nil }
        default:
            break
        }
        return result
    }

    private func startPolling(_ claim: String) {
        poll?.cancel()
        poll = Task { [weak self] in
            let started = Date()
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: self.pollInterval)
                guard !Task.isCancelled else { return }
                if Date().timeIntervalSince(started) > self.pollLimit { break }
                switch await self.checkClaim(claim) {
                case "paid", "expired":
                    self.poll = nil
                    return
                default:
                    continue // not paid yet, or the network hiccuped: keep waiting
                }
            }
            self?.purchase = nil
            self?.poll = nil
        }
    }

    /// 管理订阅: opens Stripe's customer portal (cancel, switch monthly / yearly, change card, invoices).
    /// Coming back to the app asks for the status at once.
    func openPortal() async throws {
        struct Portal: Decodable { let url: String }
        let data: Data
        do {
            data = try await request("POST", "portal")
        } catch var e as MemberError where ["not-ready", "upstream"].contains(e.code) {
            e.code = "portal-" + e.code // the portal, not "购买还没开通" or the member AI
            throw e
        }
        guard let r = try? JSONDecoder().decode(Portal.self, from: data), let url = URL(string: r.url) else { throw MemberError.badReply }
        backFromBrowser = true
        openURL(url)
    }

    // MARK: AI cards

    /// One AI card's chat request through the backend; the reply's lines (a stream of events when the
    /// body asks for one) come back once its status is 200. Every request of the card carries the card's
    /// use number, so the backend counts the card once whatever is retried; at most `requestsPerUse` go
    /// out, and only before a reply has started. A rejected device token is renewed (same Mac, same
    /// account) and the card sent again; when renewing fails, its error comes back. The AI behind the
    /// backend being away or too many requests are retried after a short wait; no network, no uses left
    /// and today's limit come back at once as a MemberError (see `kind`).
    func chat(_ body: Data, use: UUID, timeout: TimeInterval) async throws -> AsyncThrowingStream<String, Error> {
        let useID = use.uuidString.lowercased()
        var renewed = false
        var last = MemberError.network
        for attempt in 0 ..< Self.requestsPerUse {
            // After a rejected token this registers again (same Mac, same account).
            let token = try await ensureDevice()
            do {
                let (reply, headers) = try await callLines("POST", "chat/completions", body: body, token: token,
                                                           headers: ["X-Use-Id": useID], timeout: timeout)
                noteResponse(headers: headers, error: nil)
                return reply
            } catch let e as MemberError {
                last = e
                Logger.info("TypeRight member: card request \(attempt + 1) failed: \(e.code) \(e.status)", category: Logger.llm)
                if e.code == "bad-device", !renewed {
                    renewed = true
                    if tokens.load() == token { storeToken(nil) }
                    continue
                }
                // Someone typing has moved on long before a long Retry-After is over.
                guard e.isRetryable, attempt + 1 < Self.requestsPerUse, (e.retryAfter ?? 0) <= Self.longestRetryWait else { break }
                let wait = retryDelays.indices.contains(attempt) ? retryDelays[attempt] : (retryDelays.last ?? 0)
                try await Task.sleep(for: .seconds(max(wait, e.retryAfter ?? 0)))
            }
        }
        if last.changesStatus { await refresh() }
        throw last
    }

    /// The coach found the member plan blocked: ask again at most every 10 minutes, so a purchase or a
    /// renewal made elsewhere (another Mac on the same code, the website) unblocks it without a restart.
    func recheckWhileBlocked() {
        guard state != .unavailable else { return }
        Task { await refresh(maxAge: 600) }
    }

    /// The device token was rejected: register again. True when a new token came.
    func renewToken(_ used: String) async -> Bool {
        if tokens.load() == used { storeToken(nil) }
        do {
            return try await ensureDevice() != used
        } catch {
            Logger.info("TypeRight member: renewing the device token failed: \((error as? MemberError)?.code ?? "?")", category: Logger.general)
            return false
        }
    }

    /// The uses left after a card (X-Uses-Kind / X-Uses-Left / X-Uses-Reset) go straight into the status.
    func noteResponse(headers: [String: String], error: MemberError?) {
        if error != nil { return }
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        guard var s = status, let left = header("X-Uses-Left").flatMap(Int.init) else { return }
        switch header("X-Uses-Kind") {
        case "trial":
            s.trial.left = left
            s.trial.used = max(0, s.trial.total - left)
            if left <= 0, !s.isMember {
                s.plan = "none"
                s.canUse = false
                s.reason = s.trial.granted ? "trial-used-up" : "trial-closed"
            }
        case "sub":
            if var today = s.today {
                today.left = left
                today.used = max(0, today.limit - left)
                if let reset = header("X-Uses-Reset").flatMap(Double.init) { today.resetAt = reset }
                s.today = today
            }
            if left <= 0 {
                s.canUse = false
                s.reason = "daily-limit"
                s.limitBy = "uses"
            } else if s.reason == "daily-limit", s.limitBy != "cost" {
                // The first card after midnight UTC: yesterday's "used up" goes, or it would show again with tonight's reset time.
                s.canUse = true
                s.reason = nil
            }
        default: return
        }
        if s != status { apply(s) }
    }

    // MARK: Requests

    private func decodeStatus(_ data: Data) throws -> MemberStatus {
        guard let s = try? JSONDecoder().decode(MemberStatus.self, from: data) else { throw MemberError.badReply }
        return s
    }

    /// A request with this Mac's token. A rejected token (401 bad-device) registers again once and sends again.
    private func request(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        let token = try await ensureDevice()
        do {
            return try await call(method, path, body: body, token: token).0
        } catch let e as MemberError where e.code == "bad-device" {
            guard await renewToken(token) else { throw e }
            return try await call(method, path, body: body, token: ensureDevice()).0
        }
    }

    private func request(_ method: String, _ path: String, body: Data?, token: String?, auth: Bool,
                         headers: [String: String], timeout: TimeInterval) throws -> URLRequest
    {
        guard let api else { throw MemberError.unavailable }
        var req = URLRequest(url: api.appendingPathComponent("v1/\(MemberAPI.product)/\(path)"), timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("TypeRight/\(MemberAPI.version)", forHTTPHeaderField: "User-Agent")
        if auth, let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.httpBody = body
        return req
    }

    /// Like `call`, but the reply is handed on line by line as it arrives.
    private func callLines(_ method: String, _ path: String, body: Data, token: String,
                           headers: [String: String], timeout: TimeInterval) async throws -> (AsyncThrowingStream<String, Error>, [String: String])
    {
        let req = try request(method, path, body: body, token: token, auth: true, headers: headers, timeout: timeout)
        let reply: AsyncThrowingStream<String, Error>, response: URLResponse
        do {
            (response, reply) = try await lines(req)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            Logger.info("TypeRight member: \(method) \(path) got no answer: \((error as? URLError)?.code.rawValue.description ?? String(describing: type(of: error)))", category: Logger.general)
            throw MemberError.network
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let replyHeaders = http?.stringHeaders ?? [:]
        if (200 ..< 300).contains(status) { return (reply, replyHeaders) }
        let error = MemberError.from(status: status, body: await CoachNet.body(of: reply), headers: replyHeaders)
        Logger.info("TypeRight member: \(method) \(path) → \(status) \(error.code)", category: Logger.general)
        throw error
    }

    /// One request to /v1/typeright/<path> (20 seconds unless told otherwise). A reply that is not 2xx
    /// throws its MemberError; no reply at all throws `.network`.
    private func call(_ method: String, _ path: String, body: Data? = nil, token: String? = nil, auth: Bool = true,
                      headers: [String: String] = [:], timeout: TimeInterval = 20) async throws -> (Data, [String: String])
    {
        let req = try request(method, path, body: body, token: token, auth: auth, headers: headers, timeout: timeout)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await send(req)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            Logger.info("TypeRight member: \(method) \(path) got no answer: \((error as? URLError)?.code.rawValue.description ?? String(describing: type(of: error)))", category: Logger.general)
            throw MemberError.network
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let replyHeaders = http?.stringHeaders ?? [:]
        if (200 ..< 300).contains(status) { return (data, replyHeaders) }
        let error = MemberError.from(status: status, body: data, headers: replyHeaders)
        Logger.info("TypeRight member: \(method) \(path.hasPrefix("checkout/") ? "checkout/…" : path) → \(status) \(error.code)", category: Logger.general)
        throw error
    }
}
