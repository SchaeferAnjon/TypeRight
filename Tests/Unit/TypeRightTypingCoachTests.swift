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
    /// Words the system spell checker marks, with its guesses.
    var misspellings: [String: [String]] = [:]
    private(set) var writes: [(range: Range<Int>, replacement: String)] = []
    /// Where the caret is; nil means at the end of the text.
    var caret: Int?
    var canMoveCaret = true
    private(set) var caretMoves: [Int] = []
    /// Characters per line: past this the next character sits on the line below (for the card following the typing).
    var lineLength = Int.max

    func coachAnchor(for range: Range<Int>, in _: String) -> CGRect? {
        let line = range.lowerBound / lineLength
        let column = range.lowerBound - line * (lineLength == .max ? 0 : lineLength)
        return CGRect(x: 100 + CGFloat(column) * 10, y: 500 - CGFloat(line) * 20, width: CGFloat(range.count) * 10, height: 16)
    }

    func coachFallbackAnchor() -> CGRect? { CGRect(x: 10, y: 10, width: 30, height: 30) }
    func coachCaret(in text: String) -> Int? { min(caret ?? text.unicodeScalars.count, text.unicodeScalars.count) }
    func coachReadText() -> String? { readable ? text : nil }
    var coachCanMoveCaret: Bool { canMoveCaret }

    func coachSetCaret(_ offset: Int, in _: String) -> Bool {
        guard canMoveCaret else { return false }
        caretMoves.append(offset)
        caret = offset
        return true
    }

    /// Types `characters` where the caret is, the way a key reaches the field.
    func typeAtCaret(_ characters: String) {
        let at = coachCaret(in: text) ?? 0
        text = CoachText.replacing(at ..< at, in: text, with: characters)
        caret = at + characters.unicodeScalars.count
    }

    /// One Backspace where the caret is.
    func deleteBack() {
        guard let at = coachCaret(in: text), at > 0 else { return }
        text = CoachText.replacing(at - 1 ..< at, in: text, with: "")
        caret = at - 1
    }

    func coachMisspelling(in word: String) -> CoachMisspelling? {
        misspellings[word].map { CoachMisspelling(range: 0 ..< word.unicodeScalars.count, guesses: $0) }
    }

    var coachReadsOnKeys: Bool { true }

    func coachReplace(range: Range<Int>, with replacement: String, analyzedText _: String) async -> CoachWriteResult {
        writes.append((range, replacement))
        switch write {
        case .writes:
            text = CoachText.replacing(range, in: text, with: replacement)
            // Like the AX write: the caret right after what was written.
            caret = range.lowerBound + replacement.unicodeScalars.count
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
    /// nil plays an app that does not say (Chrome); `composing` is what an app that does say says.
    var reportsMarkedText = true
    var lettersCompose = false
    var coachMarkedText: Bool? { reportsMarkedText ? composing : nil }
    var coachInputMethodComposesLetters: Bool { lettersCompose }
}

@MainActor
final class FakeCardDisplay: CoachCardDisplay {
    var onClickOutside: (() -> Void)?
    var onNoticeAction: ((CoachNotice.Action) -> Void)?
    private(set) var shown: [(content: CoachCardContent, keys: CoachCardKeys, anchor: CGRect)] = []
    private(set) var visible: CoachCardContent?
    /// False plays a card window that never makes it onto the screen (the 0 × 0 window of 2026-11-11).
    var reachesScreen = true

    func show(_ content: CoachCardContent, keys: CoachCardKeys, anchor: CGRect) -> Bool {
        shown.append((content, keys, anchor))
        visible = reachesScreen ? content : nil
        return reachesScreen
    }

    private(set) var updates: [CoachCardContent] = []

    func update(_ content: CoachCardContent, keys _: CoachCardKeys) -> Bool {
        guard visible != nil else { return false }
        updates.append(content)
        visible = content
        return true
    }

    /// The card's typing-along state as last shown, and every place it moved to.
    private(set) var follow: CoachFollow?
    private(set) var moves: [CGRect] = []
    private(set) var allWords = false

    func follow(_ state: CoachFollow?, anchor: CGRect?) -> Bool {
        guard visible != nil else { return false }
        follow = state
        if let anchor { moves.append(anchor) }
        return true
    }

    func showAllWords(_ shown: Bool) { allWords = shown }

    func hide() {
        visible = nil
        follow = nil
        allWords = false
    }
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
    /// Answers given one by one for each sentence (in the order asked), before `checkResult`.
    var checkResults: [String: CoachSentenceCheck] = [:]
    /// What streams in before the whole answer: each is handed to the card, then the request waits for `release()`.
    var translationParts: [CoachTranslation] = []
    var checkParts: [CoachSentenceCheck] = []
    private(set) var translateCalls: [(fragment: String, route: CoachAIRoute)] = []
    private(set) var checkCalls: [(sentence: String, route: CoachAIRoute)] = []
    private(set) var warmed = 0
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

    /// Lets the requests waiting now go one step further.
    func step() {
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }

    var service: CoachAIService {
        CoachAIService(
            status: { [unowned self] in self.status },
            blocked: {},
            warm: { [unowned self] in self.warmed += 1 },
            translate: { [unowned self] fragment, sentence, route, partial in try await self.translate(fragment, sentence, route, partial) },
            check: { [unowned self] sentence, unfinished, route, partial in try await self.check(sentence, unfinished, route, partial) }
        )
    }

    private func waitIfHeld() async {
        if hold { await withCheckedContinuation { held.append($0) } }
    }

    private func translate(_ fragment: String, _: String, _ route: CoachAIRoute, _ partial: CoachAI.Partial<CoachTranslation>) async throws -> CoachTranslation {
        translateCalls.append((fragment, route))
        await waitIfHeld()
        for part in translationParts {
            partial(part)
            await withCheckedContinuation { held.append($0) }
        }
        return try translation.get()
    }

    private func check(_ sentence: String, _: Bool, _ route: CoachAIRoute, _ partial: CoachAI.Partial<CoachSentenceCheck>) async throws -> CoachSentenceCheck {
        checkCalls.append((sentence, route))
        await waitIfHeld()
        for part in checkParts {
            partial(part)
            await withCheckedContinuation { held.append($0) }
        }
        if let answer = checkResults[sentence] { return answer }
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
        // The field gets focus empty.
        coach.textDidChange("")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The user typed until the field read `text`, and the analysis ran. A long stretch arrives as
    /// typing does: all but its last characters, then the rest.
    func type(_ text: String, errors: [GrammarErrorModel] = []) {
        clock.lastKeyAt = clock.now
        host.caret = nil
        let scalars = Array(text.unicodeScalars)
        for error in errors where error.category == "Spelling" && error.end <= scalars.count {
            host.misspellings[CoachText.substring(scalars, error.start ..< error.end)] = error.suggestions
        }
        if text.hasPrefix(host.text), scalars.count - host.text.unicodeScalars.count > 8 {
            host.text = CoachText.substring(scalars, 0 ..< scalars.count - 8)
            coach.textDidChange(host.text)
        }
        host.text = text
        coach.textDidChange(text)
        coach.analysisDidUpdate(text: text, errors: errors)
    }

    /// Types `text` after what is there, one character every `every` seconds, like a person.
    func typeOn(_ text: String, every: TimeInterval = 0.1) {
        host.caret = nil
        for character in text {
            clock.advance(every)
            clock.lastKeyAt = clock.now
            host.text += String(character)
            coach.textDidChange(host.text)
        }
    }

    /// Time passes without typing; every AI request it started has answered.
    func wait(_ seconds: TimeInterval = 1) async {
        clock.advance(seconds)
        await answers()
    }

    /// The field is new or was left and came back: it gets focus empty.
    func focusEmptyField() {
        host.caret = nil
        host.text = ""
        coach.textDidChange("")
    }

    /// Lets requests that were just asked for reach the AI.
    func untilAsked(_ count: Int) async {
        for _ in 0 ..< 50 where ai.translateCalls.count + ai.checkCalls.count < count {
            await Task.yield()
        }
    }

    func answers() async {
        while let task = coach.runningAI.first {
            await task.value
        }
    }

    /// Tab Tab: with Tab set to type along (the default) the first takes the original out and the
    /// second fills in the fix, which is the old replace; set to replace at once, one Tab writes it.
    /// A first write that failed leaves no card to type along with, and no second Tab.
    func tab() async {
        keys.press(.tab)
        await coach.writeTask?.value
        guard behavior.tabFollows, display.follow != nil else { return }
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
        case .notice: "notice"
        case .pill: "pill"
        case nil: nil
        }
    }

    var failedMessage: String? {
        if case let .failed(message, _) = display.visible { return message }
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
            focusEmptyField()
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
        keys.press(.typed)
        keys.press(.typed)
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

    func testSpellingTypedPastRightAfterTheWordComesBackOnceAtTheNextStop() async throws {
        ai.status = .localOnly
        let first = "a meeting room tomorow "
        type(first, errors: [try misspelling("tomorow", in: first, fixes: ["tomorrow"])])
        XCTAssertEqual(visibleKind, "spelling")
        keys.press(.typed)
        keys.press(.typed)
        XCTAssertNil(display.visible)
        let next = "a meeting room tomorow at"
        type(next, errors: [try misspelling("tomorow", in: next, fixes: ["tomorrow"])])
        XCTAssertNil(display.visible, "not while typing")
        clock.advance(TypingCoach.settleSeconds)
        XCTAssertEqual(visibleKind, "spelling", "back at the stop")
        keys.press(.typed)
        keys.press(.typed)
        type("a meeting room tomorow at no")
        clock.advance(3)
        XCTAssertNil(display.visible, "typed past after a stop: gone")
        XCTAssertEqual(display.shown.filter { if case .spelling = $0.content { return true }; return false }.count, 2)
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
        await answers()
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
        await answers()
        XCTAssertNil(display.visible)
    }

    func testTypingTwoCharactersClosesThinkingAndTheCardWaitsForTheNextStop() async {
        ai.hold = true
        type("I want to 预约")
        clock.advance(1)
        type("I want to 预约 ")
        XCTAssertEqual(visibleKind, "thinking", "one character is not enough")
        type("I want to 预约 a")
        XCTAssertNil(display.visible)
        ai.release()
        await answers()
        XCTAssertNil(display.visible, "the answer waits while the user types")
        XCTAssertEqual(ai.translateCalls.count, 1, "the request went on")
        clock.advance(TypingCoach.settleSeconds)
        XCTAssertEqual(visibleKind, "translate")
    }

    func testClickingThinkingAwayCancelsItsCard() async {
        ai.hold = true
        type("I want to 预约")
        clock.advance(1)
        await untilAsked(1)
        XCTAssertEqual(visibleKind, "thinking")
        display.onClickOutside?()
        ai.release()
        await answers()
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
        focusEmptyField()
        type("I want to 预约")
        await wait()
        XCTAssertEqual(ai.translateCalls.count, 2)
    }

    func testResetForgetsTheField() async {
        type("I want to 预约")
        await wait()
        keys.press(.escape)
        coach.reset()
        focusEmptyField()
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
        XCTAssertTrue(keys.press(.tab), "Tab Tab is the old replace")
        await coach.writeTask?.value
        XCTAssertEqual(host.text, "I want to book")
        XCTAssertEqual(notebook.words.first?.to, "book")
        XCTAssertEqual(notebook.words.first?.how, .replaced)
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
            focusEmptyField()
            let word = text.split(whereSeparator: { " /@-".contains($0) })[1]
            type(text, errors: [try misspelling(String(word), in: text, fixes: ["x"])])
            XCTAssertNil(display.visible, text)
        }
        coach.reset()
        focusEmptyField()
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

    // 2026-11-11 walkthrough: every card window was 0 × 0, yet the coach took Tab and Esc for it
    // and kept the spot, so the sentence typed next was never checked.

    func testCardThatNeverReachedTheScreenTakesNoKey() async throws {
        display.reachesScreen = false
        let text = "I will send it tomorow "
        type(text, errors: [try misspelling("tomorow", in: text, fixes: ["tomorrow"])])
        XCTAssertEqual(display.shown.count, 1, "the spelling card was tried")
        XCTAssertNil(keys.policy, "no key is taken for a card nobody can see")
        await waitForTabGrace()
        XCTAssertFalse(keys.press(.tab), "Tab goes to the app")
        XCTAssertFalse(keys.press(.escape), "Esc goes to the app")
        await coach.writeTask?.value
        XCTAssertTrue(host.writes.isEmpty, "nothing in the field changed")
    }

    func testCardThatNeverReachedTheScreenHoldsNoPlace() async throws {
        display.reachesScreen = false
        let first = "I will send it tomorow "
        type(first, errors: [try misspelling("tomorow", in: first, fixes: ["tomorrow"])])
        display.reachesScreen = true
        let sentence = "I will send it tomorow because I has a question."
        type(sentence, errors: [try misspelling("tomorow", in: sentence, fixes: ["tomorrow"])])
        await wait()
        XCTAssertEqual(ai.checkCalls.map(\.sentence), [sentence], "the sentence is checked as if no card had come up")
    }

    func testAIRequestGoesOnWhenTheCardInFrontOfItNeverReachedTheScreen() async throws {
        ai.hold = true
        type("I want to 预约 tomorow")
        clock.advance(1)
        XCTAssertEqual(visibleKind, "thinking")
        display.reachesScreen = false
        let text = "I want to 预约 tomorow "
        type(text, errors: [try misspelling("tomorow", in: text, fixes: ["tomorrow"])])
        XCTAssertNil(keys.policy)
        display.reachesScreen = true
        ai.release()
        await answers()
        XCTAssertNil(display.visible, "it waits while the user types")
        clock.advance(TypingCoach.settleSeconds)
        XCTAssertEqual(visibleKind, "translate", "the translation still comes")
        XCTAssertEqual(ai.translateCalls.count, 1)
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
        await answers()
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
        focusEmptyField()
        let again = "I recieve it "
        type(again, errors: [try misspelling("recieve", in: again, fixes: ["receive"])])
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
        await answers()
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
        await answers()
    }
}

// MARK: - Which keys make a card go

/// 2026-11-12, from the user's own use: F1 for a screenshot closed the card, and so did the key
/// pressed to type on after a translation card in Notes. Keys that leave the text alone keep the
/// card up and are not counted; keys that move the caret or delete close it; typing makes the card
/// step aside at the second character, a space included.
final class TypeRightCardKeyTests: TypeRightCoachTestCase {
    private typealias Press = (name: String, code: Int64, flags: CGEventFlags)

    private let letterA: Int64 = 0
    private let space: Int64 = 49

    /// The key as the key tap reads it.
    private func key(_ code: Int64, _ flags: CGEventFlags = []) -> CoachKey {
        CoachKey.of(keyCode: code, flags: flags)
    }

    private func showSpellingCard() throws {
        coach.reset()
        focusEmptyField()
        let text = "a meeting room tomorow "
        type(text, errors: [try misspelling("tomorow", in: text, fixes: ["tomorrow"])])
        XCTAssertEqual(visibleKind, "spelling")
    }

    /// Each key leaves a spelling card up; one letter after it still does and the second makes it
    /// go, so the key was not counted as typing.
    private func assertLeavesTheCardUp(_ presses: [Press], file: StaticString = #filePath, line: UInt = #line) throws {
        for press in presses {
            try showSpellingCard()
            keys.press(key(press.code, press.flags))
            XCTAssertEqual(visibleKind, "spelling", "\(press.name) closed the card", file: file, line: line)
            keys.press(key(letterA))
            XCTAssertEqual(visibleKind, "spelling", "\(press.name) counted as typing", file: file, line: line)
            keys.press(key(letterA))
            XCTAssertNil(display.visible, "two letters after \(press.name)", file: file, line: line)
        }
    }

    func testFunctionKeysLeaveTheCardUp() throws {
        let codes: [Int64] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        try assertLeavesTheCardUp(codes.enumerated().map { ("F\($0.offset + 1)", $0.element, []) })
        // As the keyboard sends them: with fn, or with Shift.
        try assertLeavesTheCardUp([("F1 with fn", 122, .maskSecondaryFn), ("⇧F5", 96, .maskShift)])
    }

    func testShortcutsLeaveTheCardUp() throws {
        try assertLeavesTheCardUp([
            ("⌘⇧3", 20, [.maskCommand, .maskShift]), ("⌘⇧4", 21, [.maskCommand, .maskShift]), ("⌘⇧5", 23, [.maskCommand, .maskShift]),
            ("⌘C", 8, .maskCommand), ("⌘Space", 49, .maskCommand), ("⌃⌘Space", 49, [.maskControl, .maskCommand]),
            ("⌃Space, previous input source", 49, .maskControl), ("⌃⌥Space, next input source", 49, [.maskControl, .maskAlternate]),
            ("⌥A", letterA, .maskAlternate), ("⌘Tab", 48, .maskCommand), ("⌃Tab", 48, .maskControl), ("⌥⌘Esc", 53, [.maskCommand, .maskAlternate]),
            ("⇧Esc", 53, .maskShift),
        ])
    }

    func testModifierAndInputModeKeysLeaveTheCardUp() throws {
        try assertLeavesTheCardUp([
            ("Command", 55, .maskCommand), ("right Command", 54, .maskCommand), ("Shift", 56, .maskShift), ("right Shift", 60, .maskShift),
            ("Option", 58, .maskAlternate), ("Control", 59, .maskControl), ("fn", 63, .maskSecondaryFn), ("Caps Lock", 57, .maskAlphaShift),
            ("英数", 102, []), ("かな", 104, []), ("volume up", 72, []), ("volume down", 73, []), ("mute", 74, []), ("Help", 114, []),
            ("Mission Control key", 160, []), ("Globe key", 179, .maskSecondaryFn),
        ])
    }

    /// A shortcut that does change the text closes the card only when the text it points at changed.
    func testAShortcutThatChangesTheTextGoesByTheText() throws {
        try showSpellingCard()
        keys.press(key(6, .maskCommand)) // ⌘Z
        XCTAssertEqual(visibleKind, "spelling", "the key itself")
        host.text = "a meeting room "
        coach.textDidChange(host.text)
        XCTAssertNil(display.visible, "the undo took the word away")

        try showSpellingCard()
        keys.press(key(9, .maskCommand)) // ⌘V
        host.text += "see you there"
        coach.textDidChange(host.text)
        XCTAssertEqual(visibleKind, "spelling", "a paste after the word leaves the word where it was")
    }

    func testKeysThatMoveTheCaretOrDeleteCloseTheCard() throws {
        let presses: [Press] = [
            ("Return", 36, []), ("Enter", 76, []), ("←", 123, []), ("→", 124, []), ("↓", 125, []), ("↑", 126, []),
            ("← as the keyboard sends it", 123, [.maskNumericPad, .maskSecondaryFn]), ("Page Up", 116, []), ("Page Down", 121, []),
            ("Home", 115, []), ("End", 119, []), ("Delete", 51, []), ("Forward Delete", 117, []),
            ("⌘←", 123, .maskCommand), ("⌥←", 123, .maskAlternate), ("⇧→", 124, .maskShift), ("⌘Return", 36, .maskCommand),
            ("⌥Delete", 51, .maskAlternate), ("⇧Tab", 48, .maskShift),
        ]
        for press in presses {
            try showSpellingCard()
            keys.press(key(press.code, press.flags))
            XCTAssertNil(display.visible, press.name)
        }
    }

    func testASpaceIsOneCharacterTyped() throws {
        try showSpellingCard()
        keys.press(key(space))
        XCTAssertEqual(visibleKind, "spelling", "one space")
        keys.press(key(space, .maskShift))
        XCTAssertNil(display.visible, "two characters")
    }

    func testTabAndEscWorkAsBefore() async throws {
        try showSpellingCard()
        clock.advance(TypingCoach.tabGrace + 0.05)
        XCTAssertTrue(keys.press(key(48)), "Tab types along")
        await coach.writeTask?.value
        XCTAssertTrue(keys.press(key(48)), "Tab again fills in the fix")
        await coach.writeTask?.value
        XCTAssertEqual(host.text, "a meeting room tomorrow ")

        try showSpellingCard()
        XCTAssertTrue(keys.press(key(53)), "Esc keeps the text")
        XCTAssertNil(display.visible)
        XCTAssertEqual(host.text, "a meeting room tomorow ")
    }

    // The user's own sentence (2026-11-12, Notes): English, then 风雪交加 from the Pinyin input
    // method at the end of it, a stop, and the translation card.

    private let usersCard = CoachCardContent.translate(source: "风雪交加", result: CoachTranslation(english: "a mix of wind and snow", ipa: "", note: ""))

    private func showTheUsersTranslationCard() async {
        ai.translation = .success(CoachTranslation(english: "a mix of wind and snow", ipa: "", note: ""))
        typeOn("Who is Jason Huang, the outside is ")
        host.composing = true
        typeOn("fengxuejiaojia")
        host.composing = false
        clock.advance(0.1)
        clock.lastKeyAt = clock.now
        host.text = "Who is Jason Huang, the outside is 风雪交加"
        coach.textDidChange(host.text)
        coach.analysisDidUpdate(text: host.text, errors: [])
        await wait()
        XCTAssertEqual(display.visible, usersCard)
    }

    /// Types `character` the way it reaches TypeRight: the key, the field's change, the read after a
    /// word-ending key, the analysis.
    private func typeKey(_ code: Int64, _ character: String) {
        keys.press(key(code))
        typeOn(character)
        if let scalar = character.unicodeScalars.first, CoachText.wordEnds.contains(scalar) { coach.wordEndKeyPressed() }
        clock.advance(0.2)
        coach.analysisDidUpdate(text: host.text, errors: [])
    }

    func testOneSpaceAfterTheUsersTranslationCardLeavesItUp() async {
        await showTheUsersTranslationCard()
        typeKey(space, " ")
        XCTAssertEqual(display.visible, usersCard, "one space is one character")
        await wait(2)
        XCTAssertEqual(display.visible, usersCard, "and the card stays while the user stops")
        XCTAssertEqual(ai.translateCalls.count, 1, "the space does not ask again")
        typeKey(letterA, "a")
        XCTAssertNil(display.visible, "the second character makes it step aside")
    }

    /// On the user's Mac ⌃Space switches between ABC and Pinyin: switching to English to type on is
    /// not typing.
    func testSwitchingToEnglishAfterTheUsersTranslationCardLeavesItUp() async {
        await showTheUsersTranslationCard()
        keys.press(key(space, .maskControl))
        XCTAssertEqual(display.visible, usersCard, "⌃Space")
        typeKey(space, " ")
        XCTAssertEqual(display.visible, usersCard, "then one space")
        typeKey(letterA, "a")
        XCTAssertNil(display.visible, "the second character")
    }
}
