//
//  TypeRightUsagePingTests.swift
//  TypeRight
//
//  The anonymous check-in: not one request before the user agrees, once a day after, only the agreed
//  fields, a failure does not count as reported. Nothing leaves this Mac: every request goes to a recorder.
//  Ported from GetNewWord's UsagePingTests.swift.
//

@testable import TextWarden
import XCTest

@MainActor
final class TypeRightUsagePingTests: XCTestCase {
    /// Records what would be sent and answers with `status`.
    final class Recorder: @unchecked Sendable {
        var requests: [URLRequest] = []
        var status = 204
        var error: Error?
    }

    private var dir: URL!
    private var defaults: UserDefaults!
    private var suite = ""
    private var recorder = Recorder()

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("TypeRightPingTests-\(UUID().uuidString)", isDirectory: true)
        suite = "TypeRightTests.ping.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        recorder = Recorder()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suite)
    }

    private func makePing(endpoint: URL? = URL(string: "http://127.0.0.1:9/v1/ping"), day: @escaping () -> Date = Date.init) -> UsagePing {
        let recorder = recorder
        let ping = UsagePing(file: dir.appendingPathComponent("usage-ping.json"), endpoint: endpoint, defaults: defaults,
                             plan: { .member }, now: day, send: { request in
                                 recorder.requests.append(request)
                                 if let error = recorder.error { throw error }
                                 return recorder.status
                             })
        ping.firstLook = .milliseconds(10)
        ping.interval = .milliseconds(10)
        return ping
    }

    /// Never asked and "no" send nothing: not on a look, not from the hourly loop; not even the random id is made.
    func testNothingGoesOutBeforeConsent() async throws {
        let ping = makePing()
        XCTAssertEqual(ping.consent, .unasked)
        let outcome = await ping.tick()
        XCTAssertEqual(outcome, .off)
        ping.start()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ping.file.path))

        ping.answer(false)
        XCTAssertEqual(ping.consent, .no)
        XCTAssertEqual(defaults.object(forKey: UsageConsent.key) as? Bool, false)
        try await Task.sleep(for: .milliseconds(100))
        let afterNo = await ping.tick()
        XCTAssertEqual(afterNo, .off)
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ping.file.path))

        // Agreeing reports today at once, and only once.
        ping.answer(true)
        for _ in 0 ..< 100 where recorder.requests.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(defaults.object(forKey: UsageConsent.key) as? Bool, true)
        let again = await ping.tick()
        XCTAssertEqual(again, .done)
    }

    /// A Mac that said no earlier stays quiet after a restart.
    func testNoStaysNoAcrossLaunches() async throws {
        defaults.set(false, forKey: UsageConsent.key)
        let ping = makePing()
        XCTAssertEqual(ping.consent, .no)
        ping.start()
        try await Task.sleep(for: .milliseconds(100))
        let outcome = await ping.tick()
        XCTAssertEqual(outcome, .off)
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    /// The consent lives on the key the privacy toggle always used: missing = never asked.
    func testConsentKey() {
        XCTAssertEqual(UsageConsent.load(from: defaults), .unasked)
        defaults.set(true, forKey: "typeright.anonymousReport")
        XCTAssertEqual(UsageConsent.load(from: defaults), .yes)
        defaults.set(false, forKey: "typeright.anonymousReport")
        XCTAssertEqual(UsageConsent.load(from: defaults), .no)
    }

    func testSendsOnlyTheAgreedFieldsOncePerDay() async throws {
        defaults.set(true, forKey: UsageConsent.key)
        let ping = makePing()
        let sent = await ping.tick()
        XCTAssertEqual(sent, .sent)
        let done = await ping.tick()
        XCTAssertEqual(done, .done)
        XCTAssertEqual(recorder.requests.count, 1)

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:9/v1/ping")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 10)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
        XCTAssertEqual(Set(body.keys), ["id", "version", "platform", "arch", "plan", "lang", "product"])
        XCTAssertNotNil(UUID(uuidString: body["id"] ?? ""))
        XCTAssertEqual(body["platform"], "darwin")
        XCTAssertTrue(["arm64", "x64"].contains(body["arch"] ?? ""))
        XCTAssertEqual(body["plan"], "member")
        XCTAssertEqual(body["product"], "typeright")
        XCTAssertFalse((body["lang"] ?? "").contains("-"))
        XCTAssertEqual(body["version"], Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        // The id is kept for the next days.
        let saved = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: ping.file)) as? [String: String])
        XCTAssertEqual(saved["id"], body["id"])
    }

    /// Offline and server errors do not count as reported; the next day reports again with the same id.
    func testFailureRetriesAndNextDaySendsAgain() async throws {
        defaults.set(true, forKey: UsageConsent.key)
        var today = Date(timeIntervalSince1970: 1_790_000_000)
        let ping = makePing(day: { today })

        recorder.error = URLError(.timedOut)
        var outcome = await ping.tick()
        XCTAssertEqual(outcome, .failed)
        recorder.error = nil
        recorder.status = 500
        outcome = await ping.tick()
        XCTAssertEqual(outcome, .failed)
        recorder.status = 204
        outcome = await ping.tick()
        XCTAssertEqual(outcome, .sent)
        today = today.addingTimeInterval(86400)
        outcome = await ping.tick()
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(recorder.requests.count, 4)
        let ids = try recorder.requests.map { try JSONDecoder().decode(UsagePing.Body.self, from: $0.httpBody ?? Data()).id }
        XCTAssertEqual(Set(ids).count, 1)
    }

    /// Without somewhere to report to (debug build not pointed at a backend, unit tests) nothing runs.
    func testNoEndpointNoReport() async throws {
        defaults.set(true, forKey: UsageConsent.key)
        let ping = makePing(endpoint: nil)
        ping.start()
        let outcome = await ping.tick()
        XCTAssertEqual(outcome, .off)
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertNil(UsagePing.shared.endpoint)
    }
}
