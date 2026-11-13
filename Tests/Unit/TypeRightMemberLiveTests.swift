//
//  TypeRightMemberLiveTests.swift
//  TypeRight
//
//  The member flow against a backend running on this Mac (meetcaption-server with the typeright
//  product, which gives no free uses), with real HTTP: a new Mac has no membership and asks nothing;
//  a license code registers it; a card without a membership gets 402 in TypeRight's own words; a
//  rejected token is renewed for the same account; buying and the portal without Stripe. Runs only
//  when pointed at a loopback backend:
//  TEST_RUNNER_TYPERIGHT_LIVE_API=http://127.0.0.1:8820 xcodebuild test … -only-testing:TextWardenTests/TypeRightMemberLiveTests
//

@testable import TextWarden
import XCTest

@MainActor
final class TypeRightMemberLiveTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
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
        // A new Mac on the member plan: no membership, blocked, and nothing asked of the backend yet.
        XCTAssertEqual(m.state, .noMember)
        XCTAssertEqual(m.aiStatus, .memberBlocked(.noMember))
        XCTAssertFalse(m.registered)

        // A code that is not a TypeRight code: this registers the Mac (no free uses come with it).
        let badCode = await caughtMember { try await m.activate(code: "TR-AAAA-BBBB-CCCC") }
        XCTAssertEqual(badCode?.code, "bad-code")
        XCTAssertTrue(m.registered)
        await m.refresh()
        XCTAssertNil(m.lastError)
        XCTAssertEqual(m.state, .noMember)

        // A card anyway (the coach would not send one): 402, no membership, not retried.
        let first = UUID()
        let none = await caughtMember { _ = try await m.chatData(card("Task: translate. 预约", first), use: first, timeout: 15) }
        XCTAssertEqual(none?.code, "trial-closed")
        XCTAssertEqual(none?.kind, .noMember)
        XCTAssertFalse(MemberText.detail(m.explain(try XCTUnwrap(none))).contains("试用"))

        // The same Mac with a token the backend does not know: registers again, same account.
        let other = try service(api, device: String(device), token: "trd_not_a_real_token")
        let again = UUID()
        let renewed = await caughtMember { _ = try await other.chatData(card("Task: check. I has a question.", again), use: again, timeout: 15) }
        XCTAssertEqual(renewed?.code, "trial-closed")
        XCTAssertTrue(other.registered)
        XCTAssertEqual(other.state, .noMember)

        // Buying and the portal before Stripe is set up.
        let buy = await caughtMember { try await m.buy(plan: "month", currency: "cny", mode: "sub") }
        XCTAssertTrue(["not-ready", "pay-upstream"].contains(buy?.code ?? ""), buy?.code ?? "nil")
        let portal = await caughtMember { try await m.openPortal() }
        XCTAssertEqual(portal?.code, "no-customer")
        try await m.unbind()
        XCTAssertEqual(m.state, .noMember)
    }
}
