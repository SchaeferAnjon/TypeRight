//
//  TypeRightMemberLiveTests.swift
//  TypeRight
//
//  The whole member flow against a backend running on this Mac (meetcaption-server with the typeright
//  product), with real HTTP: register and claim the trial, cards through the backend counted once
//  (retries and failures free), the trial used up, a rejected token renewed, a wrong code, buying and
//  the portal without Stripe, the anonymous check-in. Runs only when pointed at a loopback backend:
//  TEST_RUNNER_TYPERIGHT_LIVE_API=http://127.0.0.1:8820 xcodebuild test … -only-testing:TextWardenTests/TypeRightMemberLiveTests
//  Start that backend with TYPERIGHT_TRIAL_USES=3 so the trial runs out quickly.
//

@testable import TextWarden
import XCTest

@MainActor
final class TypeRightMemberLiveTests: XCTestCase {
    private var suites: [String] = []
    private var dir: URL?

    override func tearDown() async throws {
        for suite in suites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func newDefaults() throws -> UserDefaults {
        let suite = "TypeRightTests.live.\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func service(_ api: URL, device: String, token: String? = nil) throws -> MemberService {
        let m = MemberService(api: api, defaults: try newDefaults(), tokens: .memory(token), device: { device }, openURL: { _ in })
        m.ownKey = { nil }
        m.plan = .member
        m.retryDelays = [0.1, 0.1]
        return m
    }

    private func card(_ prompt: String, _ use: UUID) throws -> Data {
        try JSONSerialization.data(withJSONObject: CoachAI.requestBody(prompt, maxTokens: 300, via: .member(use: use)))
    }

    private func caughtMember(_ work: () async throws -> Void) async -> MemberError? {
        do {
            try await work()
            return nil
        } catch {
            return error as? MemberError
        }
    }

    func testWholeFlowAgainstALocalBackend() async throws {
        guard let raw = ProcessInfo.processInfo.environment["TYPERIGHT_LIVE_API"], let api = URL(string: raw),
              ["127.0.0.1", "localhost"].contains(api.host ?? "")
        else {
            throw XCTSkip("set TYPERIGHT_LIVE_API to a backend on this Mac")
        }
        let device = (0 ..< 4).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }.joined().prefix(64)
        let m = try service(api, device: String(device))
        XCTAssertEqual(m.state, .notClaimed)
        XCTAssertEqual(m.aiStatus, .member)

        // Choosing the member plan registers this Mac and claims the trial.
        await m.claimTrial()
        XCTAssertNil(m.lastError)
        XCTAssertEqual(m.trialResult, "granted")
        let total = try XCTUnwrap(m.status?.trial.total)
        XCTAssertGreaterThan(total, 1)
        XCTAssertEqual(m.state, .trial(left: total, total: total))

        // One card: an answer, and one use gone (from the reply's headers).
        let first = UUID()
        let reply = try await m.chat(card("Task: translate. 预约", first), use: first, timeout: 15)
        XCTAssertEqual(try JSONDecoder().decode(CoachTranslation.self, from: CoachAI.content(of: reply)).english, "book")
        XCTAssertEqual(m.state, .trial(left: total - 1, total: total))
        // The same card sent again (a retry) is not counted again.
        _ = try await m.chat(card("Task: translate. 预约", first), use: first, timeout: 15)
        XCTAssertEqual(m.state, .trial(left: total - 1, total: total))
        // A card whose AI fails every time: 3 requests, then busy, and nothing counted.
        let failing = UUID()
        let outage = await caughtMember { _ = try await m.chat(card("ALWAYS_FAIL", failing), use: failing, timeout: 15) }
        XCTAssertEqual(outage?.code, "upstream")
        XCTAssertEqual(outage?.kind, .busy)
        await m.refresh()
        XCTAssertEqual(m.state, .trial(left: total - 1, total: total))

        // Use up the rest; then the trial is used up and the coach stops asking.
        for _ in 1 ..< total {
            let use = UUID()
            _ = try await m.chat(card("Task: check. I has a question.", use), use: use, timeout: 15)
        }
        XCTAssertEqual(m.state, .trialUsedUp)
        XCTAssertEqual(m.aiStatus, .memberBlocked(.trialUsedUp))
        let late = UUID()
        let usedUp = await caughtMember { _ = try await m.chat(card("Task: check. I has a question.", late), use: late, timeout: 15) }
        XCTAssertEqual(usedUp?.code, "trial-used-up")
        XCTAssertEqual(usedUp?.kind, .usedUp)

        // The same Mac with a token the backend does not know: registers again (existing), same account.
        let other = try service(api, device: String(device), token: "trd_not_a_real_token")
        let again = UUID()
        let renewed = await caughtMember { _ = try await other.chat(card("Task: check. I has a question.", again), use: again, timeout: 15) }
        XCTAssertEqual(renewed?.code, "trial-used-up")
        XCTAssertTrue(other.registered)
        XCTAssertEqual(other.trialResult, "existing")
        XCTAssertEqual(other.state, .trialUsedUp)

        // A code that is not a TypeRight code; buying and the portal before Stripe is set up.
        let badCode = await caughtMember { try await m.activate(code: "TR-AAAA-BBBB-CCCC") }
        XCTAssertEqual(badCode?.code, "bad-code")
        let buy = await caughtMember { try await m.buy(plan: "month", currency: "cny", mode: "sub") }
        XCTAssertTrue(["not-ready", "pay-upstream"].contains(buy?.code ?? ""), buy?.code ?? "nil")
        let portal = await caughtMember { try await m.openPortal() }
        XCTAssertEqual(portal?.code, "no-customer")
        try await m.unbind()
        XCTAssertEqual(m.state, .trialUsedUp)

        // The anonymous check-in, once agreed.
        let pingDefaults = try newDefaults()
        pingDefaults.set(true, forKey: UsageConsent.key)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TypeRightLive-\(UUID().uuidString)", isDirectory: true)
        dir = folder
        let ping = UsagePing(file: folder.appendingPathComponent("usage-ping.json"), endpoint: api.appendingPathComponent("v1/ping"),
                             defaults: pingDefaults, plan: { .member })
        let sent = await ping.tick()
        XCTAssertEqual(sent, .sent)
    }
}
