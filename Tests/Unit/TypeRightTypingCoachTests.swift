//
//  TypeRightTypingCoachTests.swift
//  TypeRight
//
//  When a card pops up, what it shows, what the keys do and what is remembered afterwards,
//  with a fake field, a fake AI, a hand-driven clock and no window or key tap. The notebook
//  writes into a temporary folder.
//

@testable import TextWarden
import XCTest

// MARK: - Fakes

@MainActor
final class FakeCoachHost: TypingCoachHost {
    enum Write { case writes, ignores, insertsAtEnd }

    var text = ""
    var fieldID: String? = "com.example.chat#1"
    var appID: String? = "com.example.chat"
    var watching = true
    var composing = false
    var readable = true
    var write: Write = .writes
    private(set) var writes: [(range: Range<Int>, replacement: String)] = []

    func coachAnchor(for range: Range<Int>, in _: String) -> CGRect? {
        CGRect(x: 100 + CGFloat(range.lowerBound) * 10, y: 500, width: CGFloat(range.count) * 10, height: 16)
    }

    func coachFallbackAnchor() -> CGRect? { CGRect(x: 10, y: 10, width: 30, height: 30) }
    func coachCaret(in text: String) -> Int? { text.unicodeScalars.count }
    func coachReadText() -> String? { readable ? text : nil }

    func coachReplace(range: Range<Int>, with replacement: String, analyzedText _: String, harperError _: GrammarErrorModel?) async -> CoachWriteResult {
        writes.append((range, replacement))
        switch write {
        case .writes:
            text = CoachText.replacing(range, in: text, with: replacement)
            return .written(text: text, at: range.lowerBound ..< range.lowerBound + replacement.unicodeScalars.count)
        case .ignores:
            return .notWritten
        case .insertsAtEnd:
            text += replacement
            return .wrongResult
        }
    }

    var coachAppName: String { "Chat" }
    var coachAppID: String? { appID }
    var coachFieldID: String? { fieldID }
    var coachIsWatching: Bool { watching }
    var coachIsComposing: Bool { composing }
}

@MainActor
final class FakeCardDisplay: CoachCardDisplay {
    var onClickOutside: (() -> Void)?
    private(set) var shown: [(content: CoachCardContent, keys: CoachCardKeys, anchor: CGRect)] = []
    private(set) var visible: CoachCardContent?

    func show(_ content: CoachCardContent, keys: CoachCardKeys, anchor: CGRect) {
        shown.append((content, keys, anchor))
        visible = content
    }

    func hide() { visible = nil }
}

@MainActor
final class FakeClock: CoachClock {
    final class Timer: CoachTimer {
        let due: TimeInterval
        let action: @MainActor () -> Void
        var cancelled = false

        init(due: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.due = due
            self.action = action
        }

        func cancel() { cancelled = true }
    }

    var now: TimeInterval = 1000
    var lastKeyAt: TimeInterval = 0
    var secondsSinceLastKey: TimeInterval { now - lastKeyAt }
    private var timers: [Timer] = []

    func after(_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> CoachTimer {
        let timer = Timer(due: now + seconds, action: action)
        timers.append(timer)
        return timer
    }

    func advance(_ seconds: TimeInterval) {
        let end = now + seconds
        while let next = timers.filter({ !$0.cancelled && $0.due <= end }).min(by: { $0.due < $1.due }) {
            now = next.due
            next.cancelled = true
            next.action()
        }
        now = end
        timers.removeAll { $0.cancelled }
    }
}

/// Decides like the tap thread (the same CoachKeyGate), then tells the coach.
@MainActor
final class FakeKeyInput: CoachKeyInput {
    var onKey: ((CoachKey, Bool) -> Void)?
    var canIntercept = true
    var inputMethod = false
    let clock: FakeClock
    private var gate = CoachKeyGate()

    init(clock: FakeClock) {
        self.clock = clock
    }

    var policy: CoachKeyPolicy? { gate.policy }

    func set(_ policy: CoachKeyPolicy?) { gate.reset(policy, inputMethod: inputMethod) }

    /// True when the key was taken from the app.
    @discardableResult
    func press(_ key: CoachKey) -> Bool {
        guard gate.policy != nil else { return false }
        let swallowed = gate.swallows(key, at: clock.now)
        onKey?(key, swallowed)
        return swallowed
    }
}

struct FakeAIFailure: Error {}

@MainActor
final class FakeCoachAI {
    var status: CoachAIStatus = .own(.deepseek)
    var translation: Result<CoachTranslation, Error> = .success(CoachTranslation(english: "book", ipa: "/bʊk/", note: ""))
    var checkResult: Result<CoachSentenceCheck, Error> = .success(CoachSentenceCheck(ok: true, corrected: "", changes: []))
    private(set) var translateCalls: [(fragment: String, route: CoachAIRoute)] = []
    private(set) var checkCalls: [(sentence: String, route: CoachAIRoute)] = []
    /// Requests wait until `release()`.
    var hold = false
    private var held: [CheckedContinuation<Void, Never>] = []

    /// Lets every request answer, including ones that have not started yet.
    func release() {
        hold = false
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }

    var service: CoachAIService {
        CoachAIService(
            status: { [unowned self] in self.status },
            blocked: {},
            translate: { [unowned self] fragment, sentence, route in try await self.translate(fragment, sentence, route) },
            check: { [unowned self] sentence, unfinished, route in try await self.check(sentence, unfinished, route) }
        )
    }

    private func translate(_ fragment: String, _: String, _ route: CoachAIRoute) async throws -> CoachTranslation {
        translateCalls.append((fragment, route))
        if hold { await withCheckedContinuation { held.append($0) } }
        return try translation.get()
    }

    private func check(_ sentence: String, _: Bool, _ route: CoachAIRoute) async throws -> CoachSentenceCheck {
        checkCalls.append((sentence, route))
        if hold { await withCheckedContinuation { held.append($0) } }
        return try checkResult.get()
    }
}

// MARK: - Base

@MainActor
class TypeRightCoachTestCase: XCTestCase {
    var host: FakeCoachHost!
    var display: FakeCardDisplay!
    var clock: FakeClock!
    var keys: FakeKeyInput!
    var ai: FakeCoachAI!
    var notebook: CoachNotebook!
    var behavior = CoachBehavior()
    var copied: [String] = []
    var coach: TypingCoach!
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("TypeRightCoachTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        notebook = CoachNotebook(fileURL: folder.appendingPathComponent("notebook.json"))
        host = FakeCoachHost()
        display = FakeCardDisplay()
        clock = FakeClock()
        keys = FakeKeyInput(clock: clock)
        ai = FakeCoachAI()
        behavior = CoachBehavior()
        copied = []
        coach = TypingCoach(ai: ai.service, notebook: notebook, display: display, keys: keys, clock: clock,
                            behavior: { [unowned self] in self.behavior }, copy: { [unowned self] in self.copied.append($0) })
        coach.host = host
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The user typed until the field read `text`, and the analysis ran.
    func type(_ text: String, errors: [GrammarErrorModel] = []) {
        clock.lastKeyAt = clock.now
        host.text = text
        coach.analysisDidUpdate(text: text, errors: errors)
    }

    /// Time passes without typing; any AI request it started has answered.
    func wait(_ seconds: TimeInterval = 1) async {
        clock.advance(seconds)
        await coach.aiTask?.value
    }

    func tab() async {
        keys.press(.tab)
        await coach.writeTask?.value
    }

    func misspelling(_ word: String, in text: String, fixes: [String]) throws -> GrammarErrorModel {
        let found = try XCTUnwrap(text.range(of: word))
        let start = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: found.lowerBound)
        return GrammarErrorModel(start: start, end: start + word.unicodeScalars.count, message: "", severity: .error,
                                 category: "Spelling", lintId: "SpellCheck", suggestions: fixes)
    }

    var visibleKind: String? {
        switch display.visible {
        case .spelling: "spelling"
        case .translate: "translate"
        case .sentence: "sentence"
        case .thinking: "thinking"
        case .failed: "failed"
        case nil: nil
        }
    }

    var failedMessage: String? {
        if case let .failed(message) = display.visible { return message }
        return nil
    }
}

// MARK: - When a card pops up

final class TypeRightTypingCoachTests: TypeRightCoachTestCase {
    // Item 2: which mixed sentences translate by themselves.

    func testMostlyEnglishSentenceTranslatesChineseAfterAPause() async {
        type("I want to 预约")
        await wait()
        XCTAssertEqual(ai.translateCalls.map(\.fragment), ["预约"])
        XCTAssertEqual(display.visible, .translate(source: "预约", result: CoachTranslation(english: "book", ipa: "/bʊk/", note: "")))
    }

    func testChineseChatWithAnEnglishWordDoesNotPopUp() async {
        for text in ["明天 meeting 改到下午", "OK，我明天到", "我想 book 一个 meeting room"] {
            coach.reset()
            type(text)
            await wait(3)
        }
        XCTAssertTrue(ai.translateCalls.isEmpty)
        XCTAssertNil(display.visible)
    }

    // Item 1: a fragment is sent to the AI once, whatever happens to its card.

    func testTranslationClosedWithEscIsNotAskedAgain() async {
        type("I want to 预约")
        await wait()
        await waitForTabGrace()
        XCTAssertTrue(keys.press(.escape))
        await wait(3)
        type("I want to 预约 a")
        await wait(3)
        XCTAssertEqual(ai.translateCalls.count, 1)
    }

    func testTranslationTypedPastIsNotAskedAgain() async {
        type("I want to 预约")
        await wait()
        keys.press(.other(printable: true))
        keys.press(.other(printable: true))
        XCTAssertNil(display.visible)
        type("I want to 预约 a ")
        await wait(3)
        XCTAssertEqual(ai.translateCalls.count, 1)
    }

    func testTranslationClickedAwayIsNotAskedAgain() async {
        type("I want to 预约")
        await wait()
        display.onClickOutside?()
        await wait(3)
        XCTAssertEqual(ai.translateCalls.count, 1)
    }

    func testFailedTranslationIsNotRetriedAfterEsc() async {
        ai.translation = .failure(CoachAIError.offline)
        type("I want to 预约")
        await wait()
        XCTAssertEqual(failedMessage, CoachAIError.offline.errorDescription)
        keys.press(.escape)
        await wait(5)
        XCTAssertEqual(ai.translateCalls.count, 1)
    }

    func testKeyTurnedDownSaysSoOnTheCard() async {
        ai.translation = .failure(CoachAIError.http(401))
        type("I want to 预约")
        await wait()
        XCTAssertEqual(failedMessage, "AI 的 Key 不对或已经失效，去设置 › AI 服务商换一个。")
        XCTAssertFalse(failedMessage?.contains("401") ?? true)
        await wait(5)
        XCTAssertNil(display.visible, "a failed card goes after 4 seconds")
    }

    func testFragmentTypedAgainAfterDeletingIsAskedAgain() async {
        type("I want to 预约")
        await wait()
        keys.press(.escape)
        type("I want to ")
        type("I want to 预约")
        await wait()
        XCTAssertEqual(ai.translateCalls.count, 2)
    }

    func testEditBeforeAnOfferedFragmentKeepsItOffered() async {
        type("I want to 预约")
        await wait()
        keys.press(.escape)
        type("I really want to 预约")
        await wait(3)
        XCTAssertEqual(ai.translateCalls.count, 1)
    }

    func testPinyinIsAskedOnce() async throws {
        let text = "I want to yuyue "
        type(text, errors: [try misspelling("yuyue", in: text, fixes: ["yule", "yue"])])
        XCTAssertNil(display.visible, "pinyin waits for the pause instead of a spelling card")
        await wait()
        XCTAssertEqual(ai.translateCalls.map(\.fragment), ["yuyue"])
        keys.press(.escape)
        let more = "I want to yuyue a"
        type(more, errors: [try misspelling("yuyue", in: more, fixes: ["yule", "yue"])])
        await wait(3)
        XCTAssertEqual(ai.translateCalls.count, 1)
    }

    // Requirement 2: through the membership one text costs one use, and each card has its own use number.

    func testMemberUsesOneUsePerFragmentAndOneNumberPerCard() async {
        ai.status = .member
        ai.translation = .failure(CoachAIError.member(MemberError(code: "upstream", status: 503)))
        type("I want to 预约")
        await wait()
        XCTAssertNil(display.visible, "member errors show no card for now")
        await wait(3)
        type("I want to 预约 a 会议室")
        await wait(3)
        XCTAssertEqual(ai.translateCalls.map(\.fragment), ["预约", "会议室"])
        let uses = ai.translateCalls.compactMap { call -> UUID? in
            if case let .member(use) = call.route { return use }
            return nil
        }
        XCTAssertEqual(Set(uses).count, 2)
    }

    // Item 3: a misspelling typed past stays away in this field.

    func testSpellingTypedPastDoesNotComeBack() async throws {
        let first = "a meeting room tomorow "
        type(first, errors: [try misspelling("tomorow", in: first, fixes: ["tomorrow"])])
        XCTAssertEqual(visibleKind, "spelling")
        keys.press(.other(printable: true))
        keys.press(.other(printable: true))
        XCTAssertNil(display.visible)
        let next = "a meeting room tomorow at"
        type(next, errors: [try misspelling("tomorow", in: next, fixes: ["tomorrow"])])
        XCTAssertNil(display.visible)
        XCTAssertEqual(display.shown.count, 1)
    }

    // Item 7: the "想一下" capsule does not hold the spot; an AI card waits for the card in front.

    func testSpellingShowsWhileAIThinksAndTranslationWaitsBehindIt() async throws {
        ai.hold = true
        type("I want to 预约 tomorow")
        clock.advance(1)
        XCTAssertEqual(visibleKind, "thinking")
        let text = "I want to 预约 tomorow "
        type(text, errors: [try misspelling("tomorow", in: text, fixes: ["tomorrow"])])
        XCTAssertEqual(visibleKind, "spelling")
        ai.release()
        await coach.aiTask?.value
        XCTAssertEqual(visibleKind, "spelling", "the translation waits")
        keys.press(.escape)
        XCTAssertEqual(visibleKind, "translate")
    }

    // Item 8: the capsule never sticks, and closing it ends the request.

    func testThinkingGoesWhenTheChineseIsEdited() async {
        ai.hold = true
        type("I want to 预约")
        clock.advance(1)
        XCTAssertEqual(visibleKind, "thinking")
        type("I want to 预")
        XCTAssertNil(display.visible)
        ai.release()
        await coach.aiTask?.value
        XCTAssertNil(display.visible)
    }

    func testTypingTwoCharactersClosesThinkingAndNoCardFollows() async {
        ai.hold = true
        type("I want to 预约")
        clock.advance(1)
        type("I want to 预约 ")
        XCTAssertEqual(visibleKind, "thinking", "one character is not enough")
        type("I want to 预约 a")
        XCTAssertNil(display.visible)
        ai.release()
        await coach.aiTask?.value
        XCTAssertNil(display.visible)
    }

    func testClickingThinkingAwayCancelsItsCard() async {
        ai.hold = true
        type("I want to 预约")
        clock.advance(1)
        display.onClickOutside?()
        ai.release()
        await coach.aiTask?.value
        await wait(3)
        XCTAssertNil(display.visible)
        XCTAssertEqual(ai.translateCalls.count, 1)
    }

    // Item 9: what TypeRight changed is not counted as right the first time, and is not checked again.

    func testTakenSentenceIsNotCheckedAgain() async {
        ai.checkResult = .success(CoachSentenceCheck(ok: false, corrected: "Because I have a question.",
                                                     changes: [.init(from: "has", to: "have", why: "主语是 I", type: "agreement")]))
        type("Because I has a question.")
        await wait()
        XCTAssertEqual(visibleKind, "sentence")
        await waitForTabGrace()
        await tab()
        XCTAssertEqual(host.text, "Because I have a question.")
        ai.checkResult = .success(CoachSentenceCheck(ok: true, corrected: "", changes: []))
        coach.analysisDidUpdate(text: host.text, errors: [])
        await wait(3)
        XCTAssertEqual(ai.checkCalls.count, 1)
        XCTAssertEqual(notebook.days.last?.sentences, 1)
        XCTAssertEqual(notebook.days.last?.clean, 0)
    }

    func testSentenceWithASpellingFixIsNotRightFirstTime() async throws {
        notebook.record(.spelling(wrong: "tomorow", fixes: ["tomorrow"]), app: "Chat", context: "see you tomorrow")
        let text = "See you tomorow "
        type(text, errors: [try misspelling("tomorow", in: text, fixes: ["tomorrow"])])
        await waitForTabGrace()
        await tab()
        XCTAssertEqual(host.text, "See you tomorrow ")
        type("See you tomorrow at noon.")
        await wait()
        XCTAssertEqual(ai.checkCalls.map(\.sentence), ["See you tomorrow at noon."])
        XCTAssertEqual(notebook.days.last?.clean, 0)
        XCTAssertEqual(notebook.mistakes.first?.correctUses, 0, "a fix TypeRight made is not a use without help")
    }

    func testWithoutAIASentenceWithAFixIsNotClean() async throws {
        ai.status = .localOnly
        let text = "See you tomorow "
        type(text, errors: [try misspelling("tomorow", in: text, fixes: ["tomorrow"])])
        await waitForTabGrace()
        await tab()
        type("See you tomorrow at noon.")
        await wait()
        XCTAssertEqual(notebook.days.last?.sentences, 1)
        XCTAssertEqual(notebook.days.last?.clean, 0)
        type("See you tomorrow at noon. Thanks a lot for that.")
        await wait()
        XCTAssertEqual(notebook.days.last?.sentences, 2)
        XCTAssertEqual(notebook.days.last?.clean, 1)
    }

    // Item 10: what the coach remembers belongs to one field.

    func testAnotherFieldStartsFresh() async {
        type("I want to 预约")
        await wait()
        keys.press(.escape)
        host.fieldID = "com.example.mail#2"
        type("I want to 预约")
        await wait()
        XCTAssertEqual(ai.translateCalls.count, 2)
    }

    func testResetForgetsTheField() async {
        type("I want to 预约")
        await wait()
        keys.press(.escape)
        coach.reset()
        type("I want to 预约")
        await wait()
        XCTAssertEqual(ai.translateCalls.count, 2)
    }

    // Item 11: Tab and Esc are only taken when they are meant for the card.

    func testCardAfterAWaitLetsAnEarlyTabThrough() async {
        type("I want to 预约")
        await wait()
        XCTAssertFalse(keys.press(.tab), "a Tab right as the card appears goes to the app")
        XCTAssertNil(display.visible)
        XCTAssertTrue(host.writes.isEmpty)
    }

    func testCardTakesTabAfterAMoment() async {
        type("I want to 预约")
        await wait()
        await waitForTabGrace()
        XCTAssertTrue(keys.press(.tab))
        await coach.writeTask?.value
        XCTAssertEqual(host.text, "I want to book")
        XCTAssertEqual(notebook.words.first?.to, "book")
    }

    func testSpellingCardRightAfterTypingLetsAnEarlyTabThrough() async throws {
        let text = "a meeting room tomorow "
        type(text, errors: [try misspelling("tomorow", in: text, fixes: ["tomorrow"])])
        XCTAssertFalse(keys.press(.tab))
        XCTAssertTrue(host.writes.isEmpty)
    }

    func testWordEndsOnlyAtSpaceOrPunctuation() async throws {
        for text in ["cd srcc/", "mail me@exmaple", "see tomorow-"] {
            coach.reset()
            let word = text.split(whereSeparator: { " /@-".contains($0) })[1]
            type(text, errors: [try misspelling(String(word), in: text, fixes: ["x"])])
            XCTAssertNil(display.visible, text)
        }
        coach.reset()
        let text = "see you tomorow,"
        type(text, errors: [try misspelling("tomorow", in: text, fixes: ["tomorrow"])])
        XCTAssertEqual(visibleKind, "spelling")
    }

    func testFailedCardLetsEscThrough() async {
        ai.translation = .failure(CoachAIError.timedOut)
        type("I want to 预约")
        await wait()
        XCTAssertNotNil(failedMessage)
        XCTAssertFalse(keys.press(.escape))
        XCTAssertNil(display.visible)
    }

    func testWithoutAKeyTapTheCardIsReadOnlyAndLeavesByItself() async throws {
        keys.canIntercept = false
        let text = "a meeting room tomorow "
        type(text, errors: [try misspelling("tomorow", in: text, fixes: ["tomorrow"])])
        XCTAssertEqual(display.shown.last?.keys, .readOnly)
        XCTAssertNil(keys.policy)
        clock.advance(TypingCoach.readOnlySeconds + 0.1)
        XCTAssertNil(display.visible)
    }

    // Item 15: the translate key.

    func testTranslateKeyDoesNothingWhilePaused() {
        host.watching = false
        host.text = "明天下午开会可以吗"
        coach.translateWholeSentence()
        XCTAssertTrue(ai.translateCalls.isEmpty)
        XCTAssertNil(display.visible)
    }

    func testTranslateKeyDoesNothingWithCardsOff() {
        behavior.cardsEnabled = false
        host.text = "明天下午开会可以吗"
        coach.translateWholeSentence()
        XCTAssertTrue(ai.translateCalls.isEmpty)
    }

    func testTranslateKeyReadsTheFieldNow() async {
        type("明天下午")
        host.text = "明天下午开会可以吗"
        coach.translateWholeSentence()
        await coach.aiTask?.value
        XCTAssertEqual(ai.translateCalls.map(\.fragment), ["明天下午开会可以吗"])
    }

    func testTranslateKeyAfterResetDoesNotUseTheOldField() {
        type("明天下午开会可以吗")
        coach.reset()
        host.readable = false
        coach.translateWholeSentence()
        XCTAssertTrue(ai.translateCalls.isEmpty)
    }

    // Item 17 and 6: a write that did not happen, or came out wrong.

    func testWriteThatChangedNothingSaysSoAndRecordsNothing() async throws {
        host.write = .ignores
        let text = "a meeting room tomorow "
        type(text, errors: [try misspelling("tomorow", in: text, fixes: ["tomorrow"])])
        await waitForTabGrace()
        await tab()
        XCTAssertEqual(failedMessage, "没改成：这个输入框里的字没变，自己改一下吧。")
        XCTAssertTrue(notebook.entries.isEmpty)
        XCTAssertNil(notebook.days.last?.fixes)
    }

    func testWrongWriteCopiesAndTabCopiesInThatAppAfterwards() async throws {
        host.write = .insertsAtEnd
        let text = "a meeting room tomorow "
        type(text, errors: [try misspelling("tomorow", in: text, fixes: ["tomorrow"])])
        await waitForTabGrace()
        await tab()
        XCTAssertEqual(copied, ["tomorrow"])
        XCTAssertTrue(failedMessage?.contains("已复制") ?? false)
        XCTAssertTrue(notebook.entries.isEmpty)

        coach.reset()
        host.text = "I recieve it "
        type(host.text, errors: [try misspelling("recieve", in: host.text, fixes: ["receive"])])
        XCTAssertEqual(display.shown.last?.keys, .copy)
        await waitForTabGrace()
        await tab()
        XCTAssertEqual(copied, ["tomorrow", "receive"])
        XCTAssertEqual(host.writes.count, 1, "no second write in that app")
    }

    // Item 21: English written over Chinese that touches letters gets spaces.

    func testTranslationTouchingLettersIsSpaced() async {
        type("I want to预约a room")
        await wait()
        await waitForTabGrace()
        await tab()
        XCTAssertEqual(host.text, "I want to book a room")
    }

    // Item 27: failure cards close by themselves and point at where the text is now.

    func testTranslateKeyWithoutAIShowsAFailedCardThatCloses() {
        ai.status = .noKey
        host.text = "明天下午开会可以吗"
        coach.translateWholeSentence()
        XCTAssertNotNil(failedMessage)
        clock.advance(TypingCoach.failureSeconds + 0.1)
        XCTAssertNil(display.visible)
    }

    func testFailedCardPointsAtTheFragmentWhereItIsNow() async throws {
        ai.hold = true
        ai.translation = .failure(CoachAIError.timedOut)
        type("I want to 预约 tomorow")
        clock.advance(1)
        XCTAssertEqual(visibleKind, "thinking")
        let text = "I want to 预约 tomorow "
        type(text, errors: [try misspelling("tomorow", in: text, fixes: ["tomorrow"])])
        XCTAssertEqual(visibleKind, "spelling", "the spelling card covers the capsule; the request goes on")
        type("Hi, I want to 预约 tomorow ")
        ai.release()
        await coach.aiTask?.value
        XCTAssertNotNil(failedMessage)
        XCTAssertEqual(display.shown.last?.anchor.minX, 100 + 14 * 10, "预约 moved from 10 to 14")
    }

    // U2: nothing pops up and no key is taken while an input method composes.

    func testNothingPopsUpWhileComposing() async throws {
        host.composing = true
        let text = "I want to ni hao "
        type(text, errors: [try misspelling("ni", in: text, fixes: ["no"])])
        await wait(3)
        XCTAssertNil(display.visible)
        XCTAssertNil(keys.policy)
    }

    // Helpers

    private func waitForTabGrace() async {
        clock.advance(TypingCoach.tabGrace + 0.05)
        await coach.aiTask?.value
    }
}
