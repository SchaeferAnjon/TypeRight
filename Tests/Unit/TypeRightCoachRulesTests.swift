//
//  TypeRightCoachRulesTests.swift
//  TypeRight
//
//  The rules behind the cards that need no field: which sentences translate by themselves,
//  where words are, what counts as pinyin, which keys a card takes, how a write is checked,
//  what each AI provider is sent and how its errors read. No keychain, no network, no defaults.
//

@testable import TextWarden
import XCTest

final class TypeRightCoachRulesTests: XCTestCase {
    private func scalars(_ text: String) -> [Unicode.Scalar] { Array(text.unicodeScalars) }

    // MARK: Item 2: automatic translation only in mostly English sentences

    func testAutoTranslateOnlyInMostlyEnglishSentences() {
        let yes = ["I want to 预约", "I want to 预约一个会议室 tomorrow", "I want to 预约 a 会议室"]
        let no = ["明天 meeting 改到下午", "OK，我明天到", "我想 book 一个 meeting room", "I 预约", "Hi 你好 我 是 Tom"]
        for text in yes {
            XCTAssertTrue(CoachText.shouldAutoTranslate(scalars(text), in: 0 ..< scalars(text).count), text)
        }
        for text in no {
            XCTAssertFalse(CoachText.shouldAutoTranslate(scalars(text), in: 0 ..< scalars(text).count), text)
        }
    }

    // MARK: Positions that follow edits (items 1, 3, 9, 27)

    func testEditMovesRangesAfterItAndDropsTouchedOnes() throws {
        let edit = try XCTUnwrap(CoachText.edit(from: "I want to 预约", to: "Hi, I want to 预约"))
        XCTAssertEqual(edit, CoachText.Edit(start: 0, removed: 0, inserted: 4))
        XCTAssertEqual(edit.shift(10 ..< 12), 14 ..< 16)

        let typedAfter = try XCTUnwrap(CoachText.edit(from: "I want to 预约", to: "I want to 预约 a"))
        XCTAssertEqual(typedAfter.shift(10 ..< 12), 10 ..< 12)
        XCTAssertEqual(typedAfter.size, 2)

        let deleted = try XCTUnwrap(CoachText.edit(from: "I want to 预约", to: "I want to 预"))
        XCTAssertNil(deleted.shift(10 ..< 12))
        XCTAssertNil(CoachText.edit(from: "same", to: "same"))
    }

    // MARK: Item 21: spaces around English written over Chinese

    func testTranslationTouchingLettersGetsSpaces() {
        let text = scalars("to预约a")
        XCTAssertEqual(CoachText.spaced("book", replacing: 2 ..< 4, in: text), " book ")
        let spaced = scalars("to 预约 a")
        XCTAssertEqual(CoachText.spaced("book", replacing: 3 ..< 5, in: spaced), "book")
        let digits = scalars("3预约")
        XCTAssertEqual(CoachText.spaced("rooms", replacing: 1 ..< 3, in: digits), " rooms")
        XCTAssertEqual(CoachText.replacing(2 ..< 4, in: "to预约a", with: " book "), "to book a")
    }

    // MARK: Item 22: whole words, in the order of the changes

    func testChangeIsFoundAsAWholeWordNotInsideAnother() throws {
        let sentence = "I have question about a plan"
        let found = try XCTUnwrap(CoachText.wordRange(of: "a", in: sentence))
        XCTAssertEqual(sentence[found.lowerBound...].prefix(6), "a plan")
        XCTAssertNil(CoachText.wordRange(of: "ave", in: sentence))
    }

    func testChangesAreFoundInOrder() {
        let corrected = "I have a cat and a dog"
        let ranges = CoachText.orderedWordRanges(of: ["a", "a"], in: corrected)
        let offsets = ranges.map { $0.map { corrected.distance(from: corrected.startIndex, to: $0.lowerBound) } }
        XCTAssertEqual(offsets, [7, 17])
    }

    func testSentenceCardPointsAtTheFirstChangedWord() {
        let text = scalars("Yesterday I have a cat")
        let check = CoachSentenceCheck(ok: false, corrected: "Yesterday I had a cat",
                                       changes: [.init(from: "have", to: "had", why: "")])
        XCTAssertEqual(CoachText.firstChangeRange(check, in: text, within: 0 ..< text.count), 12 ..< 16)
        let article = CoachSentenceCheck(ok: false, corrected: "I have the cat", changes: [.init(from: "a", to: "the", why: "")])
        let s = scalars("I have a cat")
        XCTAssertEqual(CoachText.firstChangeRange(article, in: s, within: 0 ..< s.count), 7 ..< 8)
    }

    // MARK: Item 16: misspellings are not pinyin, pinyin still is

    /// Harper's first suggestion for each word (recorded from the bundled Harper, 2026-11-11).
    private let harperFirst = [
        "hapen": "happen", "anme": "anime", "tehm": "team", "namee": "name", "meen": "mean", "hehe": "heme", "emmm": "emam",
        "yuyue": "yule", "nihao": "niha", "xiexie": "pixie", "pengyou": "pengyun", "keyi": "key", "huiyi": "haidi",
        "suanfa": "stanfa", "zhongwen": "zhong", "shangban": "shanghai", "mingtian": "minasian",
    ]

    func testCommonMisspellingsAreTreatedAsSpelling() {
        for word in ["hapen", "anme", "tehm", "namee", "meen", "hehe", "emmm"] {
            XCTAssertFalse(PinyinDetector.treatAsPinyin(word, firstSuggestion: harperFirst[word]), word)
        }
        for word in ["namee", "emmm", "hahaha", "hehe"] {
            XCTAssertFalse(PinyinDetector.isLikelyPinyin(word), word)
        }
    }

    func testPinyinStaysPinyinEvenWithACloseSuggestion() {
        for word in ["yuyue", "nihao", "xiexie", "pengyou", "keyi", "huiyi", "suanfa", "zhongwen", "shangban", "mingtian"] {
            XCTAssertTrue(PinyinDetector.treatAsPinyin(word, firstSuggestion: harperFirst[word]), word)
        }
        XCTAssertTrue(PinyinDetector.treatAsPinyin("yuyue", firstSuggestion: nil))
    }

    func testEditDistanceCountsASwapAsOne() {
        XCTAssertEqual(PinyinDetector.editDistance("tehm", "them"), 1)
        XCTAssertEqual(PinyinDetector.editDistance("hapen", "happen"), 1)
        XCTAssertEqual(PinyinDetector.editDistance("yuyue", "yule"), 2)
    }

    // MARK: Item 11 and 12: which keys a card takes, decided without the main thread

    func testTabOnlyAfterTheGraceTime() {
        var gate = CoachKeyGate()
        gate.reset(CoachKeyPolicy(tab: true, tabFrom: 10.3, esc: true), inputMethod: false)
        XCTAssertFalse(gate.swallows(.tab, at: 10.1))
        XCTAssertTrue(gate.swallows(.tab, at: 10.3))
        XCTAssertTrue(gate.swallows(.escape, at: 10.1))
        XCTAssertFalse(gate.swallows(.typed, at: 10.4))
    }

    func testFailedCardTakesNoKeyAndNoPolicyTakesNothing() {
        var gate = CoachKeyGate()
        gate.reset(CoachKeyPolicy(tab: false, tabFrom: 0, esc: false), inputMethod: false)
        XCTAssertFalse(gate.swallows(.tab, at: 99))
        XCTAssertFalse(gate.swallows(.escape, at: 99))
        gate.reset(nil, inputMethod: false)
        XCTAssertFalse(gate.swallows(.escape, at: 99))
    }

    /// U2: typing with an input method after the card came up: Tab and Esc may be the candidate window's.
    func testInputMethodTypingLeavesTabAndEscToIt() {
        var gate = CoachKeyGate()
        gate.reset(CoachKeyPolicy(tab: true, tabFrom: 0, esc: true), inputMethod: true)
        XCTAssertTrue(gate.swallows(.escape, at: 1), "nothing typed yet: the Esc is for the card")
        gate.reset(CoachKeyPolicy(tab: true, tabFrom: 0, esc: true), inputMethod: true)
        XCTAssertFalse(gate.swallows(.typed, at: 1))
        XCTAssertFalse(gate.swallows(.escape, at: 1))
        XCTAssertFalse(gate.swallows(.tab, at: 1))
    }

    /// A function key, switching the input source or a shortcut is not typing: with an input method
    /// on, Tab and Esc stay the card's.
    func testKeysThatLeaveTheTextAloneDoNotCountAsTyping() {
        var gate = CoachKeyGate()
        gate.reset(CoachKeyPolicy(tab: true, tabFrom: 0, esc: true), inputMethod: true)
        for key in [CoachKey.of(keyCode: 122, flags: []), CoachKey.of(keyCode: 49, flags: .maskControl), CoachKey.of(keyCode: 8, flags: .maskCommand)] {
            XCTAssertFalse(gate.swallows(key, at: 1))
        }
        XCTAssertTrue(gate.swallows(.escape, at: 1))
    }

    // MARK: Items 6 and 17: reading the field back after a write

    func testWriteCheckTellsDoneUnchangedAndWrong() {
        let before = "a meeting room tomorow "
        let expected = "a meeting room tomorrow "
        XCTAssertEqual(AnalysisCoordinator.writeCheck(before: before, expected: expected, after: expected), .done)
        XCTAssertEqual(AnalysisCoordinator.writeCheck(before: before, expected: expected, after: expected + "at noon"), .done)
        XCTAssertEqual(AnalysisCoordinator.writeCheck(before: before, expected: expected, after: "a meeting room\u{00A0}tomorrow"), .done)
        XCTAssertEqual(AnalysisCoordinator.writeCheck(before: before, expected: expected, after: before), .unchanged)
        XCTAssertEqual(AnalysisCoordinator.writeCheck(before: before, expected: expected, after: "a meeting room tomorow tomorrow"), .wrong)
        XCTAssertEqual(AnalysisCoordinator.writeCheck(before: "see the the", expected: "see the", after: "see the the"), .unchanged)
    }

    // MARK: Item 20: the caret after an upstream replacement

    func testCaretAfterReplacementCountsUTF16() throws {
        let text = "😂 I want to 预约 a room"
        let scalarStart = 12 // 预约
        let utf16 = try XCTUnwrap(TextIndexConverter.scalarRangeToUTF16CFRange(start: scalarStart, end: scalarStart + 2, in: text))
        let caret = AnalysisCoordinator.caretAfterReplacement(at: utf16.location, with: "book")
        let after = "😂 I want to book a room"
        let book = try XCTUnwrap(after.range(of: "book"))
        XCTAssertEqual(caret, after.utf16.distance(from: after.utf16.startIndex, to: book.upperBound))
        XCTAssertNotEqual(caret, scalarStart + "book".count, "the old sum put the caret inside book")
    }

    // MARK: U3: caret offsets

    func testCaretOffsetFromUTF16() {
        XCTAssertEqual(AnalysisCoordinator.scalarOffset(utf16: 3, in: "😂 a"), 2)
        XCTAssertEqual(AnalysisCoordinator.scalarOffset(utf16: 99, in: "ab"), 2)
    }

    // MARK: Item 10 and 24: memory that stays bounded

    func testCappedSetForgetsTheOldest() {
        var set = CappedSet<Int>(limit: 3)
        for i in 1 ... 5 {
            set.insert(i)
        }
        XCTAssertEqual(set.count, 3)
        XCTAssertFalse(set.contains(1))
        XCTAssertTrue(set.contains(5))
    }

    // MARK: Item 25: keys

    func testKeychainReadKeepsMissingApartFromFailed() {
        XCTAssertEqual(CoachKeychain.readResult(status: errSecSuccess, data: Data("sk-1".utf8)), .found("sk-1"))
        XCTAssertEqual(CoachKeychain.readResult(status: errSecItemNotFound, data: nil), .missing)
        XCTAssertEqual(CoachKeychain.readResult(status: errSecInteractionNotAllowed, data: nil), .failed(errSecInteractionNotAllowed))
    }

    func testKeyPresenceIsCachedAndUpdatedOnSave() {
        let store = MemoryKeychain(["deepseek_api_key": "sk-1"])
        let keys = store.keyStore
        XCTAssertTrue(keys.hasKey(.deepseek))
        XCTAssertTrue(keys.hasKey(.deepseek))
        XCTAssertFalse(keys.hasKey(.openai))
        XCTAssertEqual(store.reads, 2, "one read per provider, then memory")
        XCTAssertTrue(keys.save("sk-2", for: .openai))
        XCTAssertTrue(keys.hasKey(.openai))
        XCTAssertEqual(store.reads, 2)
        XCTAssertTrue(keys.save("", for: .deepseek))
        XCTAssertFalse(keys.hasKey(.deepseek))
    }

    func testFailedReadIsNotCachedAsNoKey() {
        let store = MemoryKeychain(["deepseek_api_key": "sk-1"])
        store.failing = true
        let keys = store.keyStore
        XCTAssertEqual(keys.key(for: .deepseek), .failed(errSecInteractionNotAllowed))
        XCTAssertFalse(keys.hasKey(.deepseek))
        store.failing = false
        XCTAssertTrue(keys.hasKey(.deepseek), "asked again once the keychain answers")
    }

    func testRejectedKeyStaysMarkedUntilANewOneIsSaved() {
        let keys = MemoryKeychain(["deepseek_api_key": "sk-1"]).keyStore
        keys.markRejected(.deepseek)
        XCTAssertTrue(keys.isRejected(.deepseek))
        keys.save("sk-2", for: .deepseek)
        XCTAssertFalse(keys.isRejected(.deepseek))
    }

    // MARK: Items 1, 25 and 26: what a provider's answer does

    func testProviderTurningTheKeyDownMarksItAndCardSaysSo() async throws {
        let keys = MemoryKeychain(["deepseek_api_key": "sk-1"]).keyStore
        let error = await failure {
            _ = try await CoachAI.stream("x", maxTokens: 10, via: .own(.deepseek), keys: keys,
                                         lines: CoachNet.lines(from: Self.reply(status: 401, body: #"{"error":{"message":"Authentication Fails, your api key sk-1 is invalid"}}"#)))
        }
        let coachError = try XCTUnwrap(error as? CoachAIError)
        XCTAssertTrue(keys.isRejected(.deepseek))
        XCTAssertFalse(coachError.errorDescription?.contains("Authentication") ?? true, "the provider's words stay in the log")
    }

    func testErrorsReadAsPlainChinese() {
        XCTAssertEqual(CoachAIError.http(403).errorDescription, CoachAIError.http(401).errorDescription)
        XCTAssertEqual(CoachAIError.http(402).errorDescription, "AI 账户的余额不够了，充值后再用。")
        XCTAssertEqual(CoachAIError.http(429).errorDescription, "AI 服务商限流了，过一会儿再试。")
        XCTAssertEqual(CoachAIError.http(503).errorDescription, "AI 服务商那边出错了（503），过一会儿再试。")
        XCTAssertEqual(CoachAIError.timedOut.errorDescription, "AI 超过 15 秒没回，这次先跳过。")
        XCTAssertTrue(CoachAIError.from(URLError(.timedOut)) is CoachAIError)
        XCTAssertEqual((CoachAIError.from(URLError(.notConnectedToInternet)) as? CoachAIError)?.errorDescription,
                       CoachAIError.offline.errorDescription)
        XCTAssertTrue(CoachAIError.from(URLError(.cancelled)) is CancellationError)
    }

    func testNoNetworkBecomesOffline() async {
        let keys = MemoryKeychain(["deepseek_api_key": "sk-1"]).keyStore
        let error = await failure {
            _ = try await CoachAI.stream("x", maxTokens: 10, via: .own(.deepseek), keys: keys,
                                         lines: CoachNet.lines(from: { _ in throw URLError(.notConnectedToInternet) }))
        }
        XCTAssertEqual((error as? CoachAIError)?.errorDescription, CoachAIError.offline.errorDescription)
        XCTAssertFalse(keys.isRejected(.deepseek))
    }

    // MARK: U1: each provider gets what its documentation accepts

    private func body(_ provider: CoachProvider, model: String? = nil) -> [String: Any] {
        CoachAI.requestBody("x", maxTokens: 300, via: .own(provider), model: model ?? provider.defaultModel)
    }

    private func jsonMode(_ body: [String: Any]) -> String? { (body["response_format"] as? [String: String])?["type"] }

    func testDeepSeekAndDoubaoTurnThinkingOff() {
        for provider in [CoachProvider.deepseek, .doubao] {
            let b = body(provider)
            XCTAssertEqual((b["thinking"] as? [String: String])?["type"], "disabled")
            XCTAssertEqual(b["max_tokens"] as? Int, 300)
            XCTAssertEqual(b["temperature"] as? Double, 0.2)
            XCTAssertEqual(jsonMode(b), "json_object")
        }
    }

    func testZhipuOnlyTurnsThinkingOffWhereItCan() {
        let flash = body(.zhipu)
        XCTAssertNil(flash["thinking"], "GLM-5.3 always thinks")
        XCTAssertEqual(flash["max_tokens"] as? Int, 300 + CoachAI.thinkingRoom)
        let older = body(.zhipu, model: "glm-5.2")
        XCTAssertEqual((older["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertEqual(older["max_tokens"] as? Int, 300)
    }

    func testQwenTurnsThinkingOff() {
        XCTAssertEqual(body(.qwen)["enable_thinking"] as? Bool, false)
    }

    func testOpenAIUsesMaxCompletionTokensAndNoTemperature() {
        let b = body(.openai)
        XCTAssertNil(b["max_tokens"])
        XCTAssertNil(b["temperature"])
        XCTAssertEqual(b["max_completion_tokens"] as? Int, 300 + CoachAI.thinkingRoom)
        XCTAssertEqual(b["reasoning_effort"] as? String, "low")
        XCTAssertEqual(jsonMode(b), "json_object")
    }

    func testKimiAsksForLowEffortWithoutTemperature() {
        let b = body(.kimi)
        XCTAssertNil(b["temperature"])
        XCTAssertNil(b["max_tokens"])
        XCTAssertEqual(b["reasoning_effort"] as? String, "low")
        XCTAssertEqual(b["max_completion_tokens"] as? Int, 300 + CoachAI.thinkingRoom)
    }

    func testClaudeGetsNoJSONModeNoTemperatureNoEffort() {
        let b = body(.claude)
        XCTAssertNil(b["response_format"], "json_object is a 400 on Claude's compatibility layer")
        XCTAssertNil(b["temperature"])
        XCTAssertNil(b["reasoning_effort"])
        XCTAssertNil(b["thinking"])
        XCTAssertEqual(b["max_tokens"] as? Int, 300 + CoachAI.thinkingRoom)
    }

    func testGeminiUsesMinimalEffortWithoutJSONModeOrTemperature() {
        let b = body(.gemini)
        XCTAssertEqual(b["reasoning_effort"] as? String, "minimal")
        XCTAssertNil(b["response_format"])
        XCTAssertNil(b["temperature"])
    }

    func testOpenRouterUsesItsReasoningObject() {
        let b = body(.openrouter)
        XCTAssertEqual((b["reasoning"] as? [String: String])?["effort"], "low")
        XCTAssertNil(b["reasoning_effort"])
        XCTAssertNil(b["temperature"])
    }

    func testMemberBodyIsUnchanged() {
        let b = CoachAI.requestBody("x", maxTokens: 300, via: .member(use: UUID()))
        XCTAssertEqual(b["model"] as? String, MemberAPI.model)
        XCTAssertEqual(b["max_tokens"] as? Int, 300)
        XCTAssertEqual(b["temperature"] as? Double, 0.2)
        XCTAssertEqual(jsonMode(b), "json_object")
        XCTAssertNil(b["thinking"])
    }

    // MARK: Helpers

    private static func reply(status: Int, body: String) -> CoachNet.Send {
        { request in
            let url = request.url ?? URL(fileURLWithPath: "/")
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }

    private func failure(_ work: () async throws -> Void) async -> Error? {
        do {
            try await work()
            return nil
        } catch {
            return error
        }
    }
}

/// A keychain in memory.
final class MemoryKeychain: @unchecked Sendable {
    private var items: [String: String]
    private(set) var reads = 0
    var failing = false

    init(_ items: [String: String]) {
        self.items = items
    }

    var keyStore: CoachKeyStore {
        CoachKeyStore(read: { [self] account in
            reads += 1
            if failing { return .failed(errSecInteractionNotAllowed) }
            return items[account].map { .found($0) } ?? .missing
        }, write: { [self] value, account in
            items[account] = value.isEmpty ? nil : value
            return true
        })
    }
}

/// Item 1: a turned-down key switches the own-key AI off without moving the plan to the membership.
final class TypeRightRejectedKeyTests: TypeRightMemberTestCase {
    func testRejectedKeyTurnsOwnAIOffButKeepsThePlan() {
        let m = make(plan: nil, ownKey: .deepseek)
        XCTAssertEqual(m.aiStatus, .own(.deepseek))
        m.keyRejected = { $0 == .deepseek }
        XCTAssertEqual(m.plan, .own)
        XCTAssertEqual(m.aiStatus, .noKey)
        XCTAssertTrue(server.requests.isEmpty)
    }
}
