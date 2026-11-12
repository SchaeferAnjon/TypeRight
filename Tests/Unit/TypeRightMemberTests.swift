//
//  TypeRightMemberTests.swift
//  TypeRight
//
//  Membership: the backend's status and errors are read right, blocked states block, every error code
//  has plain words; registering, a rejected token, checkout polling, the portal and license codes;
//  AI cards through the backend: one use number per card, at most 3 requests, used up / today's limit /
//  offline / token come back as their own kind. All against a fake backend: nothing leaves this Mac.
//  Ported from GetNewWord's MemberTests.swift.
//

import Combine
@testable import TextWarden
import XCTest

// MARK: - What the backend sends

private let statusJSON = #"""
{"product":"typeright","plan":"trial","code":null,"devices":1,"maxDevices":2,"trialOnly":true,
 "trial":{"granted":true,"total":300,"used":3,"left":297},"subscription":null,"pass":null,"memberUntil":null,
 "autoRenew":false,"expiring":false,"today":null,"canUse":true,"reason":null,
 "prices":{"month":{"cny":990,"usd":199},"year":{"cny":9900,"usd":1990}},"passPrices":{"month":{"cny":990},"year":{"cny":9900}},
 "now":1793232000000}
"""#

private func decodeStatus(_ json: String) throws -> MemberStatus {
    try JSONDecoder().decode(MemberStatus.self, from: Data(json.utf8))
}

/// A status: plan, reason, trial uses left, member until, today's uses.
private func makeStatus(plan: String, left: Int = 0, granted: Bool = true, reason: String? = nil, until: Date? = nil,
                        autoRenew: Bool = false, expiring: Bool = false, todayLeft: Int? = nil, resetAt: Date? = nil,
                        subscription: String? = nil) -> MemberStatus
{
    var s = MemberStatus()
    s.plan = plan
    s.trial = .init(granted: granted, total: granted ? 300 : 0, used: granted ? 300 - left : 0, left: left)
    s.reason = reason
    s.canUse = reason == nil
    s.memberUntil = until.map { $0.timeIntervalSince1970 * 1000 }
    s.autoRenew = autoRenew
    s.expiring = expiring
    if let todayLeft {
        s.today = .init(limit: 500, used: 500 - todayLeft, left: todayLeft, resetAt: (resetAt ?? Date().addingTimeInterval(3600)).timeIntervalSince1970 * 1000)
    }
    if let subscription { s.subscription = .init(status: subscription, plan: "month", currency: "cny", amount: 990) }
    return s
}

private func caught(_ work: () async throws -> Void) async -> Error? {
    do {
        try await work()
        return nil
    } catch {
        return error
    }
}

final class TypeRightMemberStatusTests: XCTestCase {
    func testDecodesTheServerShape() throws {
        let s = try decodeStatus(statusJSON)
        XCTAssertEqual(s.plan, "trial")
        XCTAssertEqual(s.trial, .init(granted: true, total: 300, used: 3, left: 297))
        XCTAssertEqual(s.prices?["year"]?["usd"], 1990)
        XCTAssertEqual(s.passPrices?["month"]?["cny"], 990)
        XCTAssertNil(s.passPrices?["month"]?["usd"])
        XCTAssertTrue(s.canUse && !s.isMember)
        XCTAssertTrue(s.code == nil && s.trialOnly && s.maxDevices == 2)
    }

    /// Fields missing or added by the backend do not lose the status.
    func testToleratesMissingAndExtraFields() throws {
        let s = try decodeStatus(#"{"plan":"member","memberUntil":1795824000000,"brandNew":{"x":1},"sync":null,"voice":null,"today":{"limit":500,"used":12,"left":488,"resetAt":1793318400000}}"#)
        XCTAssertTrue(s.isMember)
        XCTAssertEqual(s.today?.left, 488)
        XCTAssertEqual(s.trial, .init())
        XCTAssertTrue(s.canUse)
    }

    /// The registration reply: `trial` is what registering got, the counts are in trialUses.
    func testRegistrationSplitsTrialResult() throws {
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(statusJSON.utf8)) as? [String: Any])
        obj["trialUses"] = obj["trial"]
        obj["trial"] = "granted"
        obj["token"] = "trd_abc"
        let r = try MemberStatus.registration(from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertEqual(r.token, "trd_abc")
        XCTAssertEqual(r.trial, "granted")
        XCTAssertEqual(r.status.trial.left, 297)
        XCTAssertThrowsError(try MemberStatus.registration(from: Data(#"{"trial":"closed"}"#.utf8))) {
            XCTAssertEqual($0 as? MemberError, .badReply)
        }
    }

    func testDecodesLimitFields() throws {
        let s = try decodeStatus(#"{"plan":"trial","trial":{"granted":false,"total":0,"used":0,"left":0},"canUse":false,"reason":"daily-limit","limitBy":"cost","resetAt":1793318400000,"trialResult":"ip-limit"}"#)
        XCTAssertTrue(s.limitBy == "cost" && s.resetAt == 1_793_318_400_000 && s.trialResult == "ip-limit")
        let old = try decodeStatus(statusJSON)
        XCTAssertTrue(old.limitBy == nil && old.resetAt == nil && old.trialResult == nil)
    }

    /// The backend's trialResult beats what this Mac remembers; a cost cap past its reset time does not block.
    func testStatesUseServerTrialResultAndCostCap() {
        var s = makeStatus(plan: "none", granted: false, reason: "trial-closed")
        s.trialResult = "closed"
        XCTAssertEqual(MemberState.of(s, available: true, failed: false, trialResult: "existing"), .trialClosed(.full))
        var c = makeStatus(plan: "trial", left: 10)
        c.reason = "daily-limit"
        c.canUse = false
        c.limitBy = "cost"
        c.resetAt = Date().addingTimeInterval(600).timeIntervalSince1970 * 1000
        XCTAssertEqual(MemberState.of(c, available: true, failed: false, trialResult: nil).blockCode, "daily-limit")
        c.resetAt = Date().addingTimeInterval(-60).timeIntervalSince1970 * 1000
        XCTAssertEqual(MemberState.of(c, available: true, failed: false, trialResult: nil), .trial(left: 10, total: 300))
    }

    func testStates() {
        let later = Date().addingTimeInterval(20 * 86400)
        func state(_ s: MemberStatus?, trialResult: String? = nil, available: Bool = true, failed: Bool = false, registered: Bool = true) -> MemberState {
            MemberState.of(s, available: available, failed: failed, trialResult: trialResult, registered: registered)
        }
        XCTAssertEqual(state(nil, available: false), .unavailable)
        XCTAssertEqual(state(nil), .connecting)
        XCTAssertEqual(state(nil, failed: true), .offline)
        // Not registered: the first AI card registers, even after a failed try.
        XCTAssertEqual(state(nil, registered: false), .notClaimed)
        XCTAssertEqual(state(nil, failed: true, registered: false), .notClaimed)
        XCTAssertFalse(MemberState.notClaimed.blocked)
        XCTAssertFalse(MemberState.offline.blocked)
        XCTAssertEqual(state(makeStatus(plan: "trial", left: 297)), .trial(left: 297, total: 300))
        XCTAssertEqual(state(makeStatus(plan: "none", reason: "trial-used-up")), .trialUsedUp)
        XCTAssertEqual(state(makeStatus(plan: "none", granted: false, reason: "trial-closed"), trialResult: "closed"), .trialClosed(.full))
        XCTAssertEqual(state(makeStatus(plan: "none", granted: false, reason: "trial-closed"), trialResult: "ip-limit"), .trialClosed(.network))
        XCTAssertEqual(state(makeStatus(plan: "none", granted: false, reason: "trial-closed"), trialResult: "daily-limit"), .trialClosed(.dayFull))
        XCTAssertEqual(state(makeStatus(plan: "none", granted: false, reason: "trial-closed")), .trialClosed(.unknown))
        XCTAssertEqual(state(makeStatus(plan: "none", granted: false, reason: "trial-closed"), trialResult: "existing"), .trialClosed(.unknown))
        XCTAssertEqual(state(makeStatus(plan: "none", reason: "sub-ended")), .ended)
        XCTAssertEqual(state(makeStatus(plan: "none", reason: "payment-failed")), .paymentFailed)
        let member = state(makeStatus(plan: "member", until: later, autoRenew: true, todayLeft: 488, subscription: "active"))
        guard case let .member(until, autoRenew, _, pastDue, left, limit) = member else {
            return XCTFail("should be a member: \(member)")
        }
        XCTAssertLessThan(abs((until ?? .distantPast).timeIntervalSince(later)), 1)
        XCTAssertTrue(autoRenew && !pastDue && left == 488 && limit == 500)
        XCTAssertFalse(member.blocked)
        // Today's limit: blocked until the reset; past midnight UTC (status not refreshed yet) it is not.
        XCTAssertEqual(state(makeStatus(plan: "member", reason: "daily-limit", until: later, todayLeft: 0, resetAt: Date().addingTimeInterval(3600))).blockCode, "daily-limit")
        XCTAssertFalse(state(makeStatus(plan: "member", reason: "daily-limit", until: later, todayLeft: 0, resetAt: Date().addingTimeInterval(-60))).blocked)
        XCTAssertFalse(state(makeStatus(plan: "member", until: later, todayLeft: 3, subscription: "past_due")).blocked)
        for (s, code) in [(makeStatus(plan: "none", reason: "trial-used-up"), "trial-used-up"),
                          (makeStatus(plan: "none", granted: false, reason: "trial-closed"), "trial-closed"),
                          (makeStatus(plan: "none", reason: "sub-ended"), "sub-ended"),
                          (makeStatus(plan: "none", reason: "payment-failed"), "payment-failed")]
        {
            XCTAssertTrue(state(s).blocked, code)
            XCTAssertEqual(state(s).blockCode, code)
        }
    }

    /// Renewing shows the next charge (end of the period), not the access date with its extra day.
    func testAutoRenewShowsPeriodEnd() {
        let periodEnd = Date().addingTimeInterval(30 * 86400)
        var s = makeStatus(plan: "member", until: periodEnd.addingTimeInterval(86400), autoRenew: true, todayLeft: 500, subscription: "active")
        s.subscription?.periodEnd = periodEnd.timeIntervalSince1970 * 1000
        guard case let .member(until, _, _, _, _, _) = MemberState.of(s, available: true, failed: false, trialResult: nil) else {
            return XCTFail("should be a member")
        }
        XCTAssertLessThan(abs((until ?? .distantPast).timeIntervalSince(periodEnd)), 1)
        s.autoRenew = false
        guard case let .member(until2, _, _, _, _, _) = MemberState.of(s, available: true, failed: false, trialResult: nil) else {
            return XCTFail("should be a member")
        }
        XCTAssertLessThan(abs((until2 ?? .distantPast).timeIntervalSince(periodEnd.addingTimeInterval(86400))), 1)
    }
}

final class TypeRightMemberErrorTests: XCTestCase {
    func testReadsCodeMessageAndReset() {
        let body = #"{"error":{"code":"daily-limit","message":"今天的 500 次用完了","resetAt":1793318400000}}"#
        let e = MemberError.from(status: 429, body: Data(body.utf8), headers: ["retry-after": "120"])
        XCTAssertEqual(e.code, "daily-limit")
        XCTAssertEqual(e.message, "今天的 500 次用完了")
        XCTAssertEqual(e.status, 429)
        XCTAssertEqual(e.resetAt, Date(timeIntervalSince1970: 1_793_318_400))
        XCTAssertEqual(e.retryAfter, 120)
        XCTAssertTrue(e.changesStatus && !e.isRetryable)
        XCTAssertTrue(MemberText.detail(e).contains(Date(timeIntervalSince1970: 1_793_318_400).formatted(date: .omitted, time: .shortened)))
        XCTAssertEqual(MemberError.from(status: 502, body: Data("<html>".utf8)).code, "http")
    }

    func testWhatToRetry() {
        XCTAssertTrue(MemberError(code: "upstream", status: 503).isRetryable)
        XCTAssertTrue(MemberError(code: "rate", status: 429).isRetryable)
        XCTAssertTrue(MemberError(code: "http", status: 502).isRetryable)
        XCTAssertFalse(MemberError(code: "busy", status: 503).isRetryable)
        XCTAssertFalse(MemberError(code: "trial-used-up", status: 402).isRetryable)
        XCTAssertFalse(MemberError(code: "use-limit", status: 429).isRetryable)
        XCTAssertFalse(MemberError.network.isRetryable)
    }

    /// The kinds the coach gets: used up, today's limit, offline and a rejected token each have their own.
    func testKindsForTheCoach() {
        let kinds: [(String, Int, MemberError.Kind)] = [
            ("trial-used-up", 402, .usedUp), ("trial-closed", 402, .usedUp), ("sub-ended", 402, .usedUp),
            ("payment-failed", 402, .paymentFailed), ("daily-limit", 429, .dailyLimit),
            ("network", 0, .offline), ("bad-device", 401, .tokenExpired), ("re-register-limit", 429, .tokenExpired),
            ("upstream", 503, .busy), ("busy", 503, .busy), ("rate", 429, .busy), ("too-fast", 429, .busy),
            ("use-limit", 429, .busy), ("use-expired", 409, .busy), ("http", 502, .busy),
            ("unavailable", 0, .unavailable), ("bad-request", 400, .other), ("http", 404, .other),
        ]
        for (code, status, kind) in kinds {
            XCTAssertEqual(MemberError(code: code, status: status).kind, kind, "\(code) \(status)")
        }
    }

    /// Every code has its own words; only unknown codes fall back to the backend's message.
    func testEveryCodeHasWords() {
        let codes = ["trial-used-up", "trial-closed", "sub-ended", "payment-failed", "daily-limit", "use-limit", "use-expired",
                     "busy", "upstream", "rate", "network", "unavailable", "bad-device", "bad-code", "too-many-devices",
                     "already-subscribed", "pass-active", "already-paid", "payment-pending", "not-ready", "portal-not-ready",
                     "portal-upstream", "pay-upstream", "no-customer"]
        let generic = MemberText.title(MemberError(code: "zzz"))
        for code in codes {
            let e = MemberError(code: code)
            XCTAssertNotEqual(MemberText.title(e), generic, code)
            XCTAssertFalse(MemberText.detail(e).isEmpty, code)
            XCTAssertFalse(MemberText.detail(e).contains("Key 不对"), code)
        }
        XCTAssertEqual(MemberText.detail(MemberError(code: "zzz", message: "后台原话")), "后台原话")
        XCTAssertEqual(MemberText.detail(MemberError(code: "re-register-limit", message: "约 3 小时后再试")), "约 3 小时后再试")
        XCTAssertTrue(MemberText.detail(MemberError(code: "bad-code")).contains("TR-"))
        // The coach's error says the same words.
        XCTAssertEqual(CoachAIError.member(MemberError(code: "trial-used-up")).errorDescription, MemberText.detail(MemberError(code: "trial-used-up")))
    }

    /// The AI behind the backend answering 400: only the sentence inside its JSON is kept.
    func testUpstreamRejectionIsReadable() {
        let raw = #"{"error":{"code":"bad-request","message":"{\"error\":{\"message\":\"Content Exists Risk\",\"type\":\"invalid_request_error\"}}"}}"#
        let e = MemberError.from(status: 400, body: Data(raw.utf8))
        XCTAssertTrue(e.code == "bad-request" && e.message == "Content Exists Risk")
        XCTAssertTrue(e.isContentRisk)
        XCTAssertFalse(MemberText.detail(e).contains("Risk"))
        XCTAssertEqual(MemberError.from(status: 400, body: Data(#"{"error":{"code":"bad-json","message":"请求体不是 JSON"}}"#.utf8)).message, "请求体不是 JSON")
    }

    func testPrices() {
        XCTAssertEqual(MemberText.price(990, "cny"), "¥9.9")
        XCTAssertEqual(MemberText.price(9900, "cny"), "¥99")
        XCTAssertEqual(MemberText.price(199, "usd"), "$1.99")
        XCTAssertEqual(MemberText.price(1990, "usd"), "$19.90")
    }
}

final class TypeRightMemberSetupTests: XCTestCase {
    func testPlanDefaults() {
        // Never chosen: a key filled in stays on it; a new Mac starts on the trial.
        XCTAssertEqual(AIPlan.resolve(stored: nil, hasOwnKey: true), .own)
        XCTAssertEqual(AIPlan.resolve(stored: nil, hasOwnKey: false), .member)
        XCTAssertEqual(AIPlan.resolve(stored: "local", hasOwnKey: true), .local)
        XCTAssertEqual(AIPlan.resolve(stored: "member", hasOwnKey: true), .member)
        XCTAssertEqual(AIPlan.resolve(stored: "own", hasOwnKey: false), .own)
        XCTAssertEqual(AIPlan.resolve(stored: "zzz", hasOwnKey: false), .member)
    }

    func testDeviceFingerprint() throws {
        XCTAssertEqual(MemberDevice.fingerprint(hardwareUUID: "00000000-0000-4000-8000-000000000001"),
                       "1dec140d83326774831839a7f9a97ba76860aea1ad93f9bbe7b2c408dfd329fd")
        let mine = try XCTUnwrap(MemberDevice.hardwareUUID())
        XCTAssertEqual(MemberDevice.fingerprint(hardwareUUID: mine).count, 64)
    }

    func testAPIBase() throws {
        let suite = "TypeRightTests.api.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        func base(_ env: [String: String] = [:], debug: Bool) -> String? {
            MemberAPI.base(environment: env, defaults: d, isDebug: debug)?.absoluteString
        }
        // Release: always production, whatever is set.
        XCTAssertEqual(base(debug: false), "https://api.us-cloud.uk")
        XCTAssertEqual(base(["TYPERIGHT_API": "http://127.0.0.1:8820"], debug: false), "https://api.us-cloud.uk")
        // Debug: nothing unless pointed somewhere; the environment wins over defaults.
        XCTAssertNil(base(debug: true))
        XCTAssertEqual(base(["TYPERIGHT_API": "http://127.0.0.1:8820/"], debug: true), "http://127.0.0.1:8820")
        d.set("http://localhost:9000", forKey: MemberAPI.defaultsKey)
        XCTAssertEqual(base(debug: true), "http://localhost:9000")
        XCTAssertEqual(base(["TYPERIGHT_API": "http://127.0.0.1:8820"], debug: true), "http://127.0.0.1:8820")
        XCTAssertNil(base(["TYPERIGHT_API": "ftp://x"], debug: true))
        // Unit tests never connect, in any build.
        XCTAssertNil(base(["XCTestConfigurationFilePath": "/x", "TYPERIGHT_API": "http://127.0.0.1:8820"], debug: true))
        XCTAssertNil(base(["XCTestConfigurationFilePath": "/x"], debug: false))
    }

    /// The test run (inside the app) talks to no backend at all.
    @MainActor func testTestsDontTalkToAnyBackend() {
        XCTAssertNil(MemberAPI.current)
        XCTAssertNil(MemberService.shared.api)
        XCTAssertEqual(MemberService.shared.state, .unavailable)
        XCTAssertNil(UsagePing.shared.endpoint)
    }

    /// Through the backend every card gets a new use number; off states give no route.
    func testRoutes() {
        XCTAssertEqual(CoachAIStatus.own(.deepseek).route(), .own(.deepseek))
        guard case let .member(a)? = CoachAIStatus.member.route(), case let .member(b)? = CoachAIStatus.member.route() else {
            return XCTFail("member should route through the backend")
        }
        XCTAssertNotEqual(a, b)
        for off in [CoachAIStatus.localOnly, .noKey, .memberBlocked(.trialUsedUp), .memberBlocked(.unavailable)] {
            XCTAssertNil(off.route(), "\(off)")
            XCTAssertFalse(off.isOn)
        }
    }

    /// Through the backend the model and thinking are the backend's; with an own key the provider's settings go along.
    func testRequestBodies() throws {
        let member = CoachAI.requestBody("Task: check.", maxTokens: 500, via: .member(use: UUID()))
        XCTAssertEqual(member["model"] as? String, "deepseek-flash")
        XCTAssertNil(member["thinking"])
        XCTAssertNil(member["reasoning_effort"])
        XCTAssertEqual(member["max_tokens"] as? Int, 500)
        XCTAssertEqual((member["response_format"] as? [String: String])?["type"], "json_object")
        XCTAssertEqual((member["messages"] as? [[String: String]])?.last?["content"], "Task: check.")
        let deepseek = CoachAI.requestBody("x", maxTokens: 300, via: .own(.deepseek))
        XCTAssertEqual(deepseek["model"] as? String, CoachSettings.model(for: .deepseek))
        XCTAssertEqual((deepseek["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertEqual(CoachAI.requestBody("x", maxTokens: 300, via: .own(.openai))["reasoning_effort"] as? String, "low")
    }

    func testReplyContent() throws {
        let reply = #"{"id":"t","choices":[{"index":0,"message":{"role":"assistant","content":"```json\n{\"english\":\"book\"}\n```"}}]}"#
        XCTAssertEqual(String(decoding: try CoachAI.content(of: Data(reply.utf8)), as: UTF8.self), #"{"english":"book"}"#)
        XCTAssertThrowsError(try CoachAI.content(of: Data("<html>".utf8)))
    }

    /// A card on the member route goes through MemberService; in the test run that has no backend,
    /// so the card gets the member error and no request leaves.
    func testCardThroughTheBackendNeedsOne() async {
        let error = await caught { _ = try await CoachAI.translate(fragment: "预约", in: "I want to 预约 a room", via: .member(use: UUID())) }
        guard case let .member(e)? = error as? CoachAIError else { return XCTFail("expected a member error, got \(String(describing: error))") }
        XCTAssertEqual(e.kind, .unavailable)
    }
}

// MARK: - A fake backend

/// Records every request and answers by path; replies queue up per path (the n-th call gets the n-th, the last one repeats).
final class FakeTypeRightBackend: @unchecked Sendable {
    struct Reply {
        var status = 200
        var body = ""
        var headers: [String: String] = [:]
        var error: URLError?
    }

    private let lock = NSLock()
    private var queues: [String: [Reply]] = [:]
    private(set) var requests: [URLRequest] = []

    func on(_ method: String, _ path: String, _ replies: Reply...) {
        lock.withLock { queues["\(method) \(path)", default: []] += replies }
    }

    var paths: [String] { lock.withLock { requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } } }

    func requests(to path: String) -> [URLRequest] { lock.withLock { requests.filter { $0.url?.path == path } } }

    func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
        let key = "\(request.httpMethod ?? "") \(request.url?.path ?? "")"
        let reply: Reply = lock.withLock {
            requests.append(request)
            guard var q = queues[key], let first = q.first else {
                return Reply(status: 404, body: #"{"error":{"code":"not-found","message":"假后台没配"}}"#)
            }
            if q.count > 1 { q.removeFirst() }
            queues[key] = q
            return first
        }
        if let error = reply.error { throw error }
        guard let url = request.url,
              let http = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                         headerFields: reply.headers.merging(["Content-Type": "application/json"]) { a, _ in a })
        else { throw URLError(.badURL) }
        return (Data(reply.body.utf8), http)
    }
}

private func registration(token: String = "trd_one", trial: String = "granted", left: Int = 300) -> String {
    #"{"token":"\#(token)","trial":"\#(trial)","trialUses":{"granted":true,"total":300,"used":\#(300 - left),"left":\#(left)},"plan":"trial","canUse":true}"#
}

private func trialStatus(left: Int) -> String {
    #"{"plan":"\#(left > 0 ? "trial" : "none")","trial":{"granted":true,"total":300,"used":\#(300 - left),"left":\#(left)},"canUse":\#(left > 0),"reason":\#(left > 0 ? "null" : "\"trial-used-up\""),"prices":{"month":{"cny":990,"usd":199},"year":{"cny":9900,"usd":1990}}}"#
}

/// A member: today's uses left, a reason, the reset time.
private func memberBody(todayLeft: Int = 500, reason: String? = nil, resetAt: Date = Date().addingTimeInterval(3600)) -> String {
    let reset = Int(resetAt.timeIntervalSince1970 * 1000)
    return #"{"plan":"member","code":"TR-AAAA-BBBB-CCCC","trialOnly":false,"trial":{"granted":true,"total":300,"used":3,"left":297},"subscription":{"status":"active","plan":"month","currency":"cny","amount":990,"periodEnd":1795824000000,"cancelAtPeriodEnd":false,"accessUntil":1795910400000},"memberUntil":1795910400000,"autoRenew":true,"today":{"limit":500,"used":\#(500 - todayLeft),"left":\#(todayLeft),"resetAt":\#(reset)},"canUse":\#(reason == nil),"reason":\#(reason.map { "\"\($0)\"" } ?? "null")}"#
}

private let paidReply = #"{"status":"paid",\#(memberBody().dropFirst())"#
private let chatOK = #"{"id":"t","choices":[{"index":0,"message":{"role":"assistant","content":"{\"english\":\"book\",\"ipa\":\"/bʊk/\",\"note\":\"\"}"},"finish_reason":"stop"}]}"#

/// The member service against the fake backend, with its own UserDefaults suite and a token kept in memory.
@MainActor
class TypeRightMemberTestCase: XCTestCase {
    var server = FakeTypeRightBackend()
    var opened: [URL] = []
    var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        server = FakeTypeRightBackend()
        opened = []
        suite = "TypeRightTests.member.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func make(api: URL? = URL(string: "http://127.0.0.1:9"), token: String? = nil, plan: AIPlan? = .member,
              ownKey: CoachProvider? = nil) -> MemberService
    {
        let server = server
        let m = MemberService(api: api, defaults: defaults, tokens: .memory(token), device: { String(repeating: "ab", count: 32) },
                              openURL: { [weak self] in self?.opened.append($0) }, send: { try server.handle($0) },
                              lines: CoachNet.lines(from: { try server.handle($0) }))
        m.ownKey = { ownKey }
        if let plan { m.plan = plan }
        m.pollInterval = .milliseconds(10)
        m.retryDelays = [0, 0]
        return m
    }

    func wait(until done: @escaping () -> Bool) async throws {
        var tries = 0
        while !done(), tries < 300 {
            tries += 1
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

final class TypeRightMemberServiceTests: TypeRightMemberTestCase {
    /// Not registered: status, start and coming back to the front never register (no trial taken for
    /// someone who has not used the membership); claiming does, once.
    func testRegistersOnlyWhenClaimed() async throws {
        server.on("POST", "/v1/typeright/device", .init(body: registration()))
        server.on("GET", "/v1/typeright/status", .init(body: trialStatus(left: 300)))
        let m = make()
        m.start()
        await m.refresh()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertEqual(m.state, .notClaimed)
        XCTAssertFalse(m.registered)

        await m.claimTrial()
        XCTAssertEqual(server.paths, ["POST /v1/typeright/device"])
        let register = try XCTUnwrap(server.requests.first)
        XCTAssertNil(register.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: register.httpBody ?? Data()) as? [String: String])
        XCTAssertEqual(body["device"], String(repeating: "ab", count: 32))
        XCTAssertEqual(body["platform"], "darwin")
        XCTAssertTrue(["arm64", "x64"].contains(body["arch"] ?? ""))
        XCTAssertNotNil(body["version"])
        XCTAssertTrue(m.registered && m.trialResult == "granted")
        XCTAssertEqual(m.state, .trial(left: 300, total: 300))

        // Registered: the status carries the token, 20 s timeout; within a minute it is not asked again.
        await m.refresh()
        XCTAssertEqual(server.paths.last, "GET /v1/typeright/status")
        XCTAssertEqual(server.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer trd_one")
        XCTAssertEqual(server.requests[1].timeoutInterval, 20)
        await m.refresh(maxAge: 60)
        XCTAssertEqual(server.requests.count, 2)
        await m.claimTrial()
        XCTAssertEqual(server.paths.filter { $0.hasSuffix("/device") }.count, 1)
    }

    /// Own key or on-device only, registered before: launch asks nothing. Member and registered: one status.
    func testStartOnlyAsksForMembers() async throws {
        server.on("GET", "/v1/typeright/status", .init(body: trialStatus(left: 5)))
        make(token: "trd_one", plan: .own).start()
        make(token: "trd_one", plan: .local).start()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(server.requests.isEmpty)
        make(token: "trd_one").start()
        try await wait { !self.server.requests.isEmpty }
        XCTAssertEqual(server.paths, ["GET /v1/typeright/status"])
    }

    /// Own key, on-device only, and a debug build without a backend send nothing at all.
    func testOwnKeyLocalAndDebugBuildsStayQuiet() async throws {
        for plan in [AIPlan.own, .local] {
            let m = make(plan: plan, ownKey: .deepseek)
            m.start()
            await m.refresh()
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(server.requests.isEmpty)
        let dev = make(api: nil)
        await dev.refresh()
        await dev.claimTrial()
        XCTAssertEqual(dev.state, .unavailable)
        XCTAssertEqual(dev.aiStatus, .memberBlocked(.unavailable))
        let error = await caught { _ = try await dev.chatData(Data(), use: UUID(), timeout: 15) }
        XCTAssertEqual(error as? MemberError, .unavailable)
        XCTAssertTrue(server.requests.isEmpty)
    }

    /// No trial: the reason comes from the first registration and survives registering again (existing).
    func testTrialMissSurvivesReRegistering() async throws {
        server.on("POST", "/v1/typeright/device",
                  .init(body: #"{"token":"trd_one","trial":"ip-limit","trialUses":{"granted":false,"total":0,"used":0,"left":0},"plan":"none","canUse":false,"reason":"trial-closed"}"#),
                  .init(body: #"{"token":"trd_two","trial":"existing","trialUses":{"granted":false,"total":0,"used":0,"left":0},"plan":"none","canUse":false,"reason":"trial-closed"}"#))
        let m = make()
        await m.claimTrial()
        XCTAssertEqual(m.state, .trialClosed(.network))
        let renewed = await m.renewToken("trd_one")
        XCTAssertTrue(renewed)
        XCTAssertEqual(m.trialResult, "ip-limit")
        XCTAssertEqual(m.state, .trialClosed(.network))
        XCTAssertEqual(m.aiStatus, .memberBlocked(.trialClosed(.network)))
        let e = m.explain(MemberError(code: "trial-closed", message: "免费试用名额已经发完了。", status: 402))
        XCTAssertEqual(e.miss, .network)
        XCTAssertNotEqual(MemberText.detail(e), MemberText.detail(MemberError(code: "trial-closed", miss: .full)))
    }

    /// Last time's status shows at launch, for the backend it came from only.
    func testRemembersLastStatus() async throws {
        server.on("GET", "/v1/typeright/status", .init(body: trialStatus(left: 12)))
        await make(token: "trd_one").refresh()
        XCTAssertEqual(make(token: "trd_one").status?.trial.left, 12)
        XCTAssertNil(make(api: URL(string: "http://127.0.0.1:10"), token: "trd_one").status)
    }

    /// A rejected token (backend reset, a backup from another Mac): register again once and resend.
    func testBadDeviceRegistersAgain() async throws {
        server.on("GET", "/v1/typeright/status", .init(status: 401, body: #"{"error":{"code":"bad-device","message":"设备令牌无效"}}"#),
                  .init(body: trialStatus(left: 20)))
        server.on("POST", "/v1/typeright/device", .init(body: registration(token: "trd_two", trial: "existing", left: 20)))
        let m = make(token: "trd_old")
        await m.refresh()
        XCTAssertEqual(server.paths, ["GET /v1/typeright/status", "POST /v1/typeright/device", "GET /v1/typeright/status"])
        XCTAssertEqual(server.requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer trd_two")
        XCTAssertEqual(m.state, .trial(left: 20, total: 300))
        XCTAssertNil(m.lastError)
    }

    func testOfflineKeepsOldStatus() async throws {
        server.on("GET", "/v1/typeright/status", .init(body: trialStatus(left: 9)))
        await make(token: "trd_one").refresh()
        let failing = MemberService(api: URL(string: "http://127.0.0.1:9"), defaults: defaults, tokens: .memory("trd_one"),
                                    send: { _ in throw URLError(.notConnectedToInternet) })
        failing.ownKey = { nil }
        await failing.refresh()
        XCTAssertEqual(failing.lastError, .network)
        XCTAssertEqual(failing.state, .trial(left: 9, total: 300))
    }

    /// Checkout: the browser opens the page, the app asks until paid, then it is a member.
    func testBuyPollsUntilPaid() async throws {
        server.on("POST", "/v1/typeright/checkout", .init(body: #"{"url":"https://checkout.stripe.test/cs_1","claim":"trc_1"}"#))
        server.on("GET", "/v1/typeright/checkout/trc_1", .init(body: #"{"status":"pending"}"#), .init(body: #"{"status":"pending"}"#),
                  .init(body: paidReply))
        let m = make(token: "trd_one")
        try await m.buy(plan: "year", currency: "usd", mode: "sub")
        XCTAssertEqual(opened.map(\.absoluteString), ["https://checkout.stripe.test/cs_1"])
        XCTAssertEqual(m.purchase?.claim, "trc_1")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: server.requests[0].httpBody ?? Data()) as? [String: String])
        XCTAssertEqual(body, ["plan": "year", "currency": "usd", "mode": "sub"])
        try await wait { m.purchase == nil }
        XCTAssertNil(m.purchase)
        XCTAssertTrue(m.justPaid && m.isMember)
        XCTAssertEqual(m.status?.code, "TR-AAAA-BBBB-CCCC")
        XCTAssertEqual(server.paths.filter { $0.hasSuffix("/checkout/trc_1") }.count, 3)
    }

    func testBuyExpiredStops() async throws {
        server.on("POST", "/v1/typeright/checkout", .init(body: #"{"url":"https://checkout.stripe.test/cs_2","claim":"trc_2"}"#))
        server.on("GET", "/v1/typeright/checkout/trc_2", .init(body: #"{"status":"expired"}"#))
        let m = make(token: "trd_one")
        try await m.buy(plan: "month", currency: "cny", mode: "pass")
        try await wait { m.purchase == nil }
        XCTAssertTrue(m.purchase == nil && !m.justPaid)
    }

    /// Already renewing: the backend's 409 comes through, so the page can offer 管理订阅.
    func testBuyAlreadySubscribed() async throws {
        server.on("POST", "/v1/typeright/checkout", .init(status: 409, body: #"{"error":{"code":"already-subscribed","message":"已经是会员了"}}"#))
        let m = make(token: "trd_one")
        let error = await caught { try await m.buy(plan: "month", currency: "cny", mode: "sub") }
        XCTAssertEqual(error as? MemberError, MemberError(code: "already-subscribed", message: "已经是会员了", status: 409))
        XCTAssertTrue(opened.isEmpty && m.purchase == nil)
    }

    /// The earlier page was paid after all (409 already-paid): a member counts as paid, no new page.
    func testBuyAlreadyPaidCountsAsPaid() async throws {
        server.on("POST", "/v1/typeright/checkout", .init(status: 409, body: #"{"error":{"code":"already-paid","message":"上一个付款页已经付好了"}}"#))
        server.on("GET", "/v1/typeright/status", .init(body: memberBody()))
        let m = make(token: "trd_one")
        try await m.buy(plan: "year", currency: "cny", mode: "sub")
        XCTAssertTrue(m.justPaid && m.isMember)
        XCTAssertTrue(opened.isEmpty && m.purchase == nil)
    }

    /// "不等了" and the same choice again within the hour: the same page reopens, no second order.
    func testCancelledCheckoutIsReopened() async throws {
        server.on("POST", "/v1/typeright/checkout", .init(body: #"{"url":"https://checkout.stripe.test/cs_3","claim":"trc_3"}"#),
                  .init(body: #"{"url":"https://checkout.stripe.test/cs_4","claim":"trc_4"}"#))
        server.on("GET", "/v1/typeright/checkout/trc_3", .init(body: #"{"status":"pending"}"#))
        let m = make(token: "trd_one")
        m.pollInterval = .seconds(60)
        let cs3 = "https://checkout.stripe.test/cs_3"
        try await m.buy(plan: "month", currency: "cny", mode: "sub")
        m.cancelPurchase()
        XCTAssertNil(m.purchase)
        try await m.buy(plan: "month", currency: "cny", mode: "sub")
        XCTAssertEqual(server.paths.filter { $0 == "POST /v1/typeright/checkout" }.count, 1)
        XCTAssertTrue(server.paths.contains("GET /v1/typeright/checkout/trc_3"))
        XCTAssertEqual(opened.map(\.absoluteString), [cs3, cs3])
        XCTAssertEqual(m.purchase?.claim, "trc_3")
        // Yearly is another order.
        m.cancelPurchase()
        try await m.buy(plan: "year", currency: "cny", mode: "sub")
        XCTAssertEqual(server.paths.filter { $0 == "POST /v1/typeright/checkout" }.count, 2)
        XCTAssertEqual(opened.last?.absoluteString, "https://checkout.stripe.test/cs_4")
        m.cancelPurchase()
    }

    /// Paid in the browser after "不等了": the same choice asks about that order first; paid means member, expired means a new order.
    func testReopenChecksTheOldCheckoutFirst() async throws {
        server.on("POST", "/v1/typeright/checkout", .init(body: #"{"url":"https://checkout.stripe.test/cs_5","claim":"trc_5"}"#),
                  .init(body: #"{"url":"https://checkout.stripe.test/cs_6","claim":"trc_6"}"#))
        server.on("GET", "/v1/typeright/checkout/trc_5", .init(body: paidReply))
        server.on("GET", "/v1/typeright/checkout/trc_6", .init(body: #"{"status":"expired"}"#))
        let m = make(token: "trd_one")
        m.pollInterval = .seconds(60)
        try await m.buy(plan: "year", currency: "usd", mode: "sub")
        m.cancelPurchase()
        try await m.buy(plan: "year", currency: "usd", mode: "sub")
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(m.justPaid && m.isMember && m.purchase == nil)

        try await m.buy(plan: "month", currency: "cny", mode: "pass")
        m.cancelPurchase()
        try await m.buy(plan: "month", currency: "cny", mode: "pass")
        XCTAssertEqual(server.paths.filter { $0 == "POST /v1/typeright/checkout" }.count, 3)
        m.cancelPurchase()
    }

    /// The portal or the payment page not opening says so, not "购买还没开通" or "会员 AI 连不上".
    func testPortalAndCheckoutErrorsSayWhatBroke() async throws {
        server.on("POST", "/v1/typeright/portal", .init(status: 503, body: #"{"error":{"code":"not-ready","message":"门户还没配好"}}"#))
        server.on("POST", "/v1/typeright/checkout", .init(status: 503, body: #"{"error":{"code":"upstream","message":"付款服务暂时连不上，稍后再试"}}"#))
        let m = make(token: "trd_one")
        let portal = await caught { try await m.openPortal() }
        XCTAssertEqual(portal as? MemberError, MemberError(code: "portal-not-ready", message: "门户还没配好", status: 503))
        let pay = await caught { try await m.buy(plan: "month", currency: "cny", mode: "sub") }
        XCTAssertEqual(pay as? MemberError, MemberError(code: "pay-upstream", message: "付款服务暂时连不上，稍后再试", status: 503))
        XCTAssertNotEqual(MemberText.title(MemberError(code: "portal-not-ready")), MemberText.title(MemberError(code: "not-ready")))
        XCTAssertNotEqual(MemberText.title(MemberError(code: "pay-upstream")), MemberText.title(MemberError(code: "upstream")))
        XCTAssertTrue(opened.isEmpty && m.purchase == nil)
    }

    func testPortalOpensBrowser() async throws {
        server.on("POST", "/v1/typeright/portal", .init(body: #"{"url":"https://billing.stripe.test/p/1"}"#))
        let m = make(token: "trd_one")
        try await m.openPortal()
        XCTAssertEqual(opened.map(\.absoluteString), ["https://billing.stripe.test/p/1"])
    }

    func testActivateAndUnbind() async throws {
        server.on("POST", "/v1/typeright/license/activate", .init(status: 404, body: #"{"error":{"code":"bad-code","message":"不是 TypeRight 的授权码"}}"#),
                  .init(body: memberBody()))
        server.on("POST", "/v1/typeright/license/unbind", .init(body: trialStatus(left: 297)))
        let m = make(token: "trd_one")
        let bad = await caught { try await m.activate(code: "GW-1234-5678-ABCD") }
        XCTAssertEqual((bad as? MemberError)?.code, "bad-code")
        try await m.activate(code: "tr-aaaa-bbbb-cccc")
        XCTAssertTrue(m.isMember)
        XCTAssertEqual(m.status?.code, "TR-AAAA-BBBB-CCCC")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: server.requests[1].httpBody ?? Data()) as? [String: String])
        XCTAssertEqual(body["code"], "tr-aaaa-bbbb-cccc")
        try await m.unbind()
        XCTAssertEqual(m.state, .trial(left: 297, total: 300))
    }

    /// The backend's trialResult explains a missing trial even when this Mac forgot.
    func testServerTrialResultExplainsMiss() async throws {
        server.on("GET", "/v1/typeright/status",
                  .init(body: #"{"plan":"none","trial":{"granted":false,"total":0,"used":0,"left":0},"canUse":false,"reason":"trial-closed","trialResult":"closed"}"#))
        let m = make(token: "trd_one")
        await m.refresh()
        XCTAssertNil(m.trialResult)
        XCTAssertEqual(m.state, .trialClosed(.full))
        XCTAssertEqual(m.explain(MemberError(code: "trial-closed", status: 402)).miss, .full)
    }

    /// The cost cap (limitBy cost) blocks a trial too and says "用量到上限"; a used-up count says "次数用完".
    func testCostCapFromStatus() async throws {
        let reset = Int(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        server.on("GET", "/v1/typeright/status",
                  .init(body: #"{"plan":"trial","trial":{"granted":true,"total":300,"used":5,"left":295},"canUse":false,"reason":"daily-limit","limitBy":"cost","resetAt":\#(reset)}"#))
        let m = make(token: "trd_one")
        await m.refresh()
        guard case let .dailyLimit(at) = m.state else { return XCTFail("a trial's cost cap blocks too: \(m.state)") }
        XCTAssertEqual(at.map { Int($0.timeIntervalSince1970 * 1000) }, reset)
        XCTAssertEqual(m.aiStatus, .memberBlocked(m.state))
        let e = m.explain(MemberError(code: "daily-limit", status: 429))
        XCTAssertTrue(e.costCap)
        XCTAssertEqual(MemberText.title(e), "今天的用量到上限了")
    }

    func testUsesLimitIsNotCostCap() async throws {
        server.on("GET", "/v1/typeright/status", .init(body: memberBody(todayLeft: 0, reason: "daily-limit")
                .replacingOccurrences(of: #""reason":"daily-limit""#, with: #""reason":"daily-limit","limitBy":"uses""#)))
        let m = make(token: "trd_one")
        await m.refresh()
        let e = m.explain(MemberError(code: "daily-limit", status: 429))
        XCTAssertFalse(e.costCap)
        XCTAssertEqual(MemberText.title(e), "今天的次数用完了")
    }

    /// Before showing an error: a cost cap with uses left is not "次数用完"; a pass not over yet gives its date.
    func testExplainFillsTheRealReason() async throws {
        server.on("GET", "/v1/typeright/status", .init(body: memberBody(todayLeft: 150)))
        let m = make(token: "trd_one")
        await m.refresh()
        let reset = Date().addingTimeInterval(3600)
        let cap = m.explain(MemberError(code: "daily-limit", message: "今天的用量到上限了", status: 429, resetAt: reset))
        XCTAssertTrue(cap.costCap)
        XCTAssertTrue(MemberText.detail(cap).contains(reset.formatted(date: .omitted, time: .shortened)))
        let until = Date(timeIntervalSince1970: 1_795_910_400)
        let pass = m.explain(MemberError(code: "pass-active", message: "一次买的会员用到2026年11月28日（北京时间）", status: 409))
        XCTAssertEqual(pass.until, until)
        XCTAssertTrue(MemberText.detail(pass).contains(MemberText.day(until)))
        m.noteResponse(headers: ["X-Uses-Kind": "sub", "X-Uses-Left": "0"], error: nil)
        XCTAssertFalse(m.explain(MemberError(code: "daily-limit", status: 429)).costCap)
    }

    /// The uses left come with every card: the count follows at once; 0 is used up.
    func testUsageHeadersUpdateCounts() async throws {
        server.on("GET", "/v1/typeright/status", .init(body: trialStatus(left: 2)))
        let m = make(token: "trd_one")
        await m.refresh()
        m.noteResponse(headers: ["x-uses-kind": "trial", "X-Uses-Left": "1", "X-Use-Charged": "1"], error: nil)
        XCTAssertEqual(m.state, .trial(left: 1, total: 300))
        m.noteResponse(headers: ["X-Uses-Kind": "trial", "X-Uses-Left": "0"], error: nil)
        XCTAssertEqual(m.state, .trialUsedUp)
        XCTAssertEqual(m.aiStatus, .memberBlocked(.trialUsedUp))
    }

    /// Used up yesterday, first card today works: "used up" goes; 0 again is used up with tonight's reset.
    func testNewDayClearsDailyLimit() async throws {
        server.on("GET", "/v1/typeright/status", .init(body: memberBody(todayLeft: 0, reason: "daily-limit", resetAt: Date().addingTimeInterval(-60))))
        let m = make(token: "trd_one")
        await m.refresh()
        let tonight = Date().addingTimeInterval(20 * 3600)
        let tonightMs = String(Int(tonight.timeIntervalSince1970 * 1000))
        m.noteResponse(headers: ["X-Uses-Kind": "sub", "X-Uses-Left": "499", "X-Uses-Reset": tonightMs], error: nil)
        guard case let .member(_, _, _, _, left, _) = m.state else { return XCTFail("should be a member: \(m.state)") }
        XCTAssertEqual(left, 499)
        XCTAssertTrue(m.status?.reason == nil && m.status?.canUse == true)
        m.noteResponse(headers: ["X-Uses-Kind": "sub", "X-Uses-Left": "0", "X-Uses-Reset": tonightMs], error: nil)
        guard case let .dailyLimit(reset) = m.state else { return XCTFail("should be used up today: \(m.state)") }
        XCTAssertLessThan(abs((reset ?? .distantPast).timeIntervalSince(tonight)), 1)
    }

    /// The plan the page binds to: never chosen follows the key; a choice sticks and tells the page.
    func testPlanAndAIStatus() throws {
        let fresh = make(plan: nil)
        XCTAssertEqual(fresh.plan, .member)
        XCTAssertEqual(fresh.aiStatus, .member) // not registered yet: the first card claims the trial
        XCTAssertNil(defaults.string(forKey: AIPlan.key)) // reading never writes

        let keyed = make(plan: nil, ownKey: .deepseek)
        XCTAssertEqual(keyed.plan, .own)
        XCTAssertEqual(keyed.aiStatus, .own(.deepseek))

        var changes = 0
        let watch = keyed.objectWillChange.sink { changes += 1 }
        keyed.plan = .local
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(defaults.string(forKey: AIPlan.key), "local")
        XCTAssertEqual(keyed.aiStatus, .localOnly)
        watch.cancel()

        let noKey = make(plan: .own)
        XCTAssertEqual(noKey.aiStatus, .noKey)
    }
}

// MARK: - AI cards through the backend

final class TypeRightMemberChatTests: TypeRightMemberTestCase {
    private func body(_ use: UUID) throws -> Data {
        try JSONSerialization.data(withJSONObject: CoachAI.requestBody("Task: translate.", maxTokens: 300, via: .member(use: use)))
    }

    private func useIDs() -> [String] {
        server.requests(to: "/v1/typeright/chat/completions").map { $0.value(forHTTPHeaderField: "X-Use-Id") ?? "" }
    }

    /// To our backend, with the device token and the card's use number; the uses left go into the status.
    func testCardGoesToOurServer() async throws {
        server.on("GET", "/v1/typeright/status", .init(body: trialStatus(left: 300)))
        server.on("POST", "/v1/typeright/chat/completions",
                  .init(body: chatOK, headers: ["X-Use-Charged": "1", "X-Uses-Kind": "trial", "X-Uses-Left": "299"]))
        let m = make(token: "trd_one")
        await m.refresh()
        let use = UUID()
        let data = try await m.chatData(body(use), use: use, timeout: 15)
        XCTAssertEqual(try JSONDecoder().decode(CoachTranslation.self, from: CoachAI.content(of: data)).english, "book")
        let sent = try XCTUnwrap(server.requests(to: "/v1/typeright/chat/completions").first)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer trd_one")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-Use-Id"), use.uuidString.lowercased())
        XCTAssertEqual(sent.timeoutInterval, 15)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: sent.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "deepseek-flash")
        XCTAssertNil(json["thinking"])
        XCTAssertEqual(json["max_tokens"] as? Int, 300)
        XCTAssertEqual(m.state, .trial(left: 299, total: 300))
    }

    /// The first card on the member plan registers this Mac (and claims the trial).
    func testFirstCardRegisters() async throws {
        server.on("POST", "/v1/typeright/device", .init(body: registration(token: "trd_new")))
        server.on("POST", "/v1/typeright/chat/completions", .init(body: chatOK))
        let m = make()
        let use = UUID()
        _ = try await m.chatData(body(use), use: use, timeout: 15)
        XCTAssertEqual(server.paths, ["POST /v1/typeright/device", "POST /v1/typeright/chat/completions"])
        XCTAssertEqual(server.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer trd_new")
        XCTAssertTrue(m.registered)
    }

    /// The AI behind the backend away for a moment: the card is sent again with the same use number, so it counts once.
    func testRetriesShareTheCardsUseNumber() async throws {
        server.on("POST", "/v1/typeright/chat/completions",
                  .init(status: 503, body: #"{"error":{"code":"upstream","message":"会员 AI 服务暂时不可用"}}"#), .init(body: chatOK))
        let m = make(token: "trd_one")
        let use = UUID()
        _ = try await m.chatData(body(use), use: use, timeout: 15)
        XCTAssertEqual(useIDs(), [use.uuidString.lowercased(), use.uuidString.lowercased()])
    }

    /// Never more than 3 requests for one card, however often it fails.
    func testAtMostThreeRequestsPerCard() async throws {
        server.on("POST", "/v1/typeright/chat/completions", .init(status: 503, body: #"{"error":{"code":"upstream","message":"x"}}"#))
        let m = make(token: "trd_one")
        let use = UUID()
        let error = await caught { _ = try await m.chatData(body(use), use: use, timeout: 15) }
        XCTAssertEqual((error as? MemberError)?.code, "upstream")
        XCTAssertEqual((error as? MemberError)?.kind, .busy)
        XCTAssertEqual(useIDs(), Array(repeating: use.uuidString.lowercased(), count: 3))
    }

    /// A rejected device token: register again and send the same card (same use number) with the new token.
    func testBadDeviceRenewsTokenForTheSameCard() async throws {
        server.on("POST", "/v1/typeright/chat/completions",
                  .init(status: 401, body: #"{"error":{"code":"bad-device","message":"设备令牌无效"}}"#), .init(body: chatOK))
        server.on("POST", "/v1/typeright/device", .init(body: registration(token: "trd_two", trial: "existing")))
        let m = make(token: "trd_one")
        let use = UUID()
        _ = try await m.chatData(body(use), use: use, timeout: 15)
        XCTAssertEqual(server.paths, ["POST /v1/typeright/chat/completions", "POST /v1/typeright/device", "POST /v1/typeright/chat/completions"])
        XCTAssertEqual(server.requests(to: "/v1/typeright/chat/completions").map { $0.value(forHTTPHeaderField: "Authorization") ?? "" },
                       ["Bearer trd_one", "Bearer trd_two"])
        XCTAssertEqual(Set(useIDs()), [use.uuidString.lowercased()])
    }

    /// The token rejected and registering again refused: the card comes back with that refusal (tokenExpired).
    func testTokenThatCannotBeRenewed() async throws {
        server.on("POST", "/v1/typeright/chat/completions", .init(status: 401, body: #"{"error":{"code":"bad-device","message":"设备令牌无效"}}"#))
        server.on("POST", "/v1/typeright/device", .init(status: 429, body: #"{"error":{"code":"re-register-limit","message":"约 3 小时后再试","resetAt":1793318400000}}"#))
        let m = make(token: "trd_one")
        let use = UUID()
        let error = await caught { _ = try await m.chatData(body(use), use: use, timeout: 15) }
        XCTAssertEqual((error as? MemberError)?.code, "re-register-limit")
        XCTAssertEqual((error as? MemberError)?.kind, .tokenExpired)
        XCTAssertEqual(server.paths, ["POST /v1/typeright/chat/completions", "POST /v1/typeright/device"])
    }

    /// Trial used up: one request, no retry, the status is asked for, and the next card is not tried.
    func testUsedUpComesBackAtOnce() async throws {
        server.on("POST", "/v1/typeright/chat/completions", .init(status: 402, body: #"{"error":{"code":"trial-used-up","message":"300 次的免费试用用完了"}}"#))
        server.on("GET", "/v1/typeright/status", .init(body: trialStatus(left: 0)))
        let m = make(token: "trd_one")
        let use = UUID()
        let error = await caught { _ = try await m.chatData(body(use), use: use, timeout: 15) }
        XCTAssertEqual((error as? MemberError)?.kind, .usedUp)
        XCTAssertEqual(server.paths, ["POST /v1/typeright/chat/completions", "GET /v1/typeright/status"])
        XCTAssertEqual(m.aiStatus, .memberBlocked(.trialUsedUp))
    }

    /// Today's 500 used: one request, the reset time comes along.
    func testDailyLimitCarriesResetTime() async throws {
        server.on("POST", "/v1/typeright/chat/completions",
                  .init(status: 429, body: #"{"error":{"code":"daily-limit","message":"今天的 500 次用完了","resetAt":1793318400000}}"#, headers: ["Retry-After": "3600"]))
        server.on("GET", "/v1/typeright/status", .init(body: memberBody(todayLeft: 0, reason: "daily-limit")))
        let m = make(token: "trd_one")
        let use = UUID()
        let error = await caught { _ = try await m.chatData(body(use), use: use, timeout: 15) }
        let e = try XCTUnwrap(error as? MemberError)
        XCTAssertEqual(e.kind, .dailyLimit)
        XCTAssertEqual(e.resetAt, Date(timeIntervalSince1970: 1_793_318_400))
        XCTAssertEqual(server.requests(to: "/v1/typeright/chat/completions").count, 1)
        guard case .memberBlocked(.dailyLimit) = m.aiStatus else { return XCTFail("today's limit should block: \(m.aiStatus)") }
    }

    /// No network: one try, offline, no retry.
    func testOfflineIsNotRetried() async throws {
        server.on("POST", "/v1/typeright/chat/completions", .init(error: URLError(.notConnectedToInternet)))
        let m = make(token: "trd_one")
        let use = UUID()
        let error = await caught { _ = try await m.chatData(body(use), use: use, timeout: 15) }
        XCTAssertEqual((error as? MemberError)?.kind, .offline)
        XCTAssertEqual(server.requests.count, 1)
    }

    /// Too many requests with a long Retry-After: the card gives up rather than arrive late.
    func testLongRetryAfterIsNotWaited() async throws {
        server.on("POST", "/v1/typeright/chat/completions",
                  .init(status: 429, body: #"{"error":{"code":"rate","message":"请求太频繁"}}"#, headers: ["Retry-After": "30"]))
        let m = make(token: "trd_one")
        let use = UUID()
        let started = Date()
        let error = await caught { _ = try await m.chatData(body(use), use: use, timeout: 15) }
        XCTAssertEqual((error as? MemberError)?.kind, .busy)
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    /// Two cards are two uses: different use numbers.
    func testEachCardIsItsOwnUse() async throws {
        server.on("POST", "/v1/typeright/chat/completions", .init(body: chatOK))
        let m = make(token: "trd_one")
        for _ in 0 ..< 2 {
            guard case let .member(use)? = m.aiStatus.route() else { return XCTFail("member should route through the backend") }
            _ = try await m.chatData(body(use), use: use, timeout: 15)
        }
        XCTAssertEqual(Set(useIDs()).count, 2)
    }
}

extension MemberService {
    /// A card's whole reply at once, for tests that look at it in one piece.
    func chatData(_ body: Data, use: UUID, timeout: TimeInterval) async throws -> Data {
        await CoachNet.body(of: try await chat(body, use: use, timeout: timeout))
    }
}
