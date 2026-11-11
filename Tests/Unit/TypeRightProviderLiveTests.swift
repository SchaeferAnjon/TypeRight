//
//  TypeRightProviderLiveTests.swift
//  TypeRight
//
//  Sends the real request bodies to a provider. Runs only when a key is handed in through the
//  environment (xcodebuild: TEST_RUNNER_DEEPSEEK_API_KEY=…); never reads the keychain.
//

@testable import TextWarden
import XCTest

final class TypeRightProviderLiveTests: XCTestCase {
    private func keys(_ provider: CoachProvider, env: String) throws -> CoachKeyStore {
        guard let key = ProcessInfo.processInfo.environment[env], !key.isEmpty else {
            throw XCTSkip("set \(env) to talk to \(provider.displayName)")
        }
        return CoachKeyStore(read: { _ in .found(key) }, write: { _, _ in false })
    }

    func testDeepSeekTranslatesAndChecks() async throws {
        let keys = try keys(.deepseek, env: "DEEPSEEK_API_KEY")
        let started = Date()
        let translation = try await CoachAI.translate(fragment: "预约", in: "I want to 预约 a meeting room", via: .own(.deepseek), keys: keys)
        let translateSeconds = Date().timeIntervalSince(started)
        XCTAssertFalse(translation.english.isEmpty)
        let checkStarted = Date()
        let check = try await CoachAI.check(sentence: "Because I has a question.", via: .own(.deepseek), keys: keys)
        let checkSeconds = Date().timeIntervalSince(checkStarted)
        XCTAssertFalse(check.ok)
        XCTAssertTrue(check.corrected.contains("have"), check.corrected)
        print("TYPERIGHT-LIVE deepseek model \(CoachSettings.model(for: .deepseek)): 预约 → \(translation.english) \(translation.ipa) in \(String(format: "%.1f", translateSeconds))s; check → \(check.corrected) in \(String(format: "%.1f", checkSeconds))s")
    }
}
