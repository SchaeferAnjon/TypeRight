//
//  UsagePing.swift
//  TypeRight
//
//  The daily anonymous check-in (POST /v1/ping, docs/multi-product.md §4.10): the first 100 Macs get
//  free AI checks, so we need to count how many people use TypeRight. Nothing is sent until the user
//  agrees (UsageConsent.yes); never asked and "no" both send nothing, and before agreeing not even the
//  random id is made. The body is only: a random id made on this Mac (not a hardware id), version,
//  platform, arch, plan (member / own / local), lang (the system language) and product. No typed text,
//  key, name or email; no Authorization header.
//  Once per local day: looked at 5 seconds after launch and then hourly (so a Mac left on past midnight
//  reports the next day too). A failure (offline, 4xx, 5xx, 10 s timeout) is only logged and the day
//  does not count, so the next hour tries again. Debug builds only report when pointed at a backend
//  (MemberAPI.base); unit tests never do.
//  Ported from GetNewWord's UsagePing.swift (same author, GPL-3.0).
//

import Combine
import Foundation

enum UsageConsent: String, Sendable {
    case unasked, yes, no

    /// Stored as a Bool under the key the privacy settings toggle has always used; missing = never asked.
    static let key = "typeright.anonymousReport"

    static func load(from defaults: UserDefaults) -> UsageConsent {
        switch defaults.object(forKey: key) as? Bool {
        case true?: .yes
        case false?: .no
        case nil: .unasked
        }
    }
}

@MainActor
final class UsagePing: ObservableObject {
    struct Body: Codable, Equatable {
        let id: String
        let version: String
        let platform: String
        let arch: String
        let plan: String
        let lang: String
        let product: String
    }

    enum Outcome: Equatable { case off, done, sent, failed }

    private struct State: Codable {
        var id: String?
        var day: String?
    }

    static let shared = UsagePing(
        file: (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true))
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.typeright.app", isDirectory: true)
            .appendingPathComponent("usage-ping.json"),
        endpoint: MemberAPI.current?.appendingPathComponent("v1/ping"),
        defaults: .standard,
        plan: { MemberService.shared.plan }
    )

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 10
        return URLSession(configuration: c)
    }()

    /// Whether the user agreed; the onboarding question and the privacy toggle bind to this.
    @Published private(set) var consent: UsageConsent

    let file: URL
    let endpoint: URL?
    var firstLook: Duration = .seconds(5)
    var interval: Duration = .seconds(3600)
    private let defaults: UserDefaults
    private let plan: () -> AIPlan
    private let now: () -> Date
    private let send: @Sendable (URLRequest) async throws -> Int
    private var loop: Task<Void, Never>?
    private var busy: Task<Outcome, Never>?

    init(file: URL, endpoint: URL?, defaults: UserDefaults, plan: @escaping () -> AIPlan, now: @escaping () -> Date = Date.init,
         send: @escaping @Sendable (URLRequest) async throws -> Int = { request in
             let (_, response) = try await UsagePing.session.data(for: request)
             return (response as? HTTPURLResponse)?.statusCode ?? 0
         })
    {
        self.file = file
        self.endpoint = endpoint
        self.defaults = defaults
        self.plan = plan
        self.now = now
        self.send = send
        consent = UsageConsent.load(from: defaults)
    }

    /// At launch: when there is somewhere to report to, look after a few seconds and then every hour.
    /// Each look sends only with consent.
    func start() {
        guard endpoint != nil else { return }
        loop?.cancel()
        loop = Task { [weak self] in
            try? await Task.sleep(for: self?.firstLook ?? .seconds(5))
            while !Task.isCancelled {
                guard let self else { return }
                _ = await self.tick()
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    /// The user answered (onboarding question or the privacy toggle). Agreeing reports today right
    /// away if today was not reported yet.
    func answer(_ agree: Bool) {
        defaults.set(agree, forKey: UsageConsent.key)
        consent = agree ? .yes : .no
        Logger.info("TypeRight ping: consent \(consent.rawValue)", category: Logger.general)
        if agree { Task { _ = await tick() } }
    }

    /// One look: with consent and today not reported yet, report. Looks at the same time share one.
    func tick() async -> Outcome {
        if let busy { return await busy.value }
        let task = Task { await run() }
        busy = task
        let outcome = await task.value
        busy = nil
        return outcome
    }

    /// The local date, 2026-11-11 (not UTC: before 8 am in China would still be yesterday).
    nonisolated static func localDay(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// What one report sends; version, plan and lang are read each time.
    func body(id: String) -> Body {
        let lang = Locale.preferredLanguages.first?.split(separator: "-").first.map(String.init) ?? "?"
        return Body(id: id, version: MemberAPI.version, platform: "darwin", arch: MemberAPI.arch,
                    plan: plan().rawValue, lang: lang, product: MemberAPI.product)
    }

    private func run() async -> Outcome {
        guard let endpoint, consent == .yes else { return .off }
        var state = read()
        let day = Self.localDay(now())
        if state.day == day { return .done }
        let id = state.id.flatMap { UUID(uuidString: $0) != nil ? $0 : nil } ?? UUID().uuidString.lowercased()
        state.id = id
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("TypeRight", forHTTPHeaderField: "User-Agent")
        do {
            request.httpBody = try JSONEncoder().encode(body(id: id))
            let status = try await send(request)
            guard (200 ..< 300).contains(status) else {
                Logger.info("TypeRight ping: HTTP \(status)", category: Logger.general)
                write(state)
                return .failed
            }
        } catch {
            Logger.info("TypeRight ping: failed: \((error as? URLError)?.code.rawValue.description ?? String(describing: type(of: error)))", category: Logger.general)
            write(state)
            return .failed
        }
        state.day = day
        write(state)
        Logger.info("TypeRight ping: sent for \(day)", category: Logger.general)
        return .sent
    }

    private func read() -> State {
        guard let data = try? Data(contentsOf: file) else { return State() }
        return (try? JSONDecoder().decode(State.self, from: data)) ?? State()
    }

    private func write(_ state: State) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: file, options: .atomic)
        } catch {
            Logger.warning("TypeRight ping: can't write \(file.lastPathComponent): \(error.localizedDescription)", category: Logger.general)
        }
    }
}
