//
//  TypeRightNoticeTests.swift
//  TypeRight
//
//  Typing on the member plan while it cannot be used (design/membership/redesign, «一件事只说一次»):
//  the first Chinese word gets a notice card, later ones a capsule that goes by itself; the notice
//  takes no Tab, Esc closes it, its buttons open the right window; no network is told after two
//  failed requests in a row and not again until an answer came. And Chinese input methods in apps
//  that do not report composing (Chrome): pinyin syllables are not taken for misspellings.
//

@testable import TextWarden
import XCTest

final class TypeRightNoticeTests: TypeRightCoachTestCase {
    private var ledger: CoachNoticeLedger!
    private var acted: [CoachNotice.Action] = []

    override func setUp() async throws {
        try await super.setUp()
        ledger = .memory()
        acted = []
        remake()
    }

    /// A coach with this test's notice ledger and a record of what the notice buttons opened.
    private func remake() {
        var service = ai.service
        service.act = { [unowned self] in self.acted.append($0) }
        coach = TypingCoach(ai: service, notebook: notebook, display: display, keys: keys, clock: clock,
                            behavior: { [unowned self] in self.behavior }, copy: { _ in }, notices: ledger)
        coach.host = host
        focusEmptyField()
    }

    private var notice: CoachNotice? {
        if case let .notice(n) = display.visible { return n }
        return nil
    }

    private var pill: String? {
        if case let .pill(text) = display.visible { return text }
        return nil
    }

    // MARK: No membership

    func testNoMembershipIsToldOnceThenACapsule() async {
        ai.status = .memberBlocked(.noMember)
        type("I want to 预约")
        await wait()
        XCTAssertTrue(ai.translateCalls.isEmpty, "nothing goes to the AI")
        XCTAssertEqual(notice?.issue, .noMember)
        XCTAssertTrue(notice?.body.hasPrefix("「预约」这次没翻成英文") ?? false)
        clock.advance(TypingCoach.tabGrace + 0.05)
        XCTAssertEqual(keys.policy?.tab, false, "a notice has nothing to write: Tab stays with the app")
        XCTAssertTrue(keys.press(.escape))
        XCTAssertNil(display.visible)

        type("I want to 预约 a 会议室")
        await wait()
        XCTAssertEqual(pill, "没翻：还没开会员")
        XCTAssertNil(keys.policy, "the capsule takes no key")
        clock.advance(TypingCoach.pillSeconds + 0.1)
        XCTAssertNil(display.visible, "the capsule goes by itself")
        XCTAssertTrue(ai.translateCalls.isEmpty)
    }

    /// Told once on this Mac: a new coach (TypeRight started again) with the same ledger shows the capsule.
    func testToldStaysToldAfterARestart() async {
        ai.status = .memberBlocked(.noMember)
        type("I want to 预约")
        await wait()
        XCTAssertEqual(notice?.issue, .noMember)
        remake()
        type("I want to 预约")
        await wait()
        XCTAssertEqual(pill, "没翻：还没开会员")
    }

    func testSameChineseIsNotToldTwice() async {
        ai.status = .memberBlocked(.noMember)
        type("I want to 预约")
        await wait()
        keys.press(.escape)
        let shown = display.shown.count
        await wait(3)
        type("I want to 预约 ")
        await wait(3)
        XCTAssertEqual(display.shown.count, shown, "the same word at the same place says nothing more")
    }

    func testNoticeButtonsOpenTheirWindow() async {
        ai.status = .memberBlocked(.noMember)
        type("I want to 预约")
        await wait()
        XCTAssertNotNil(notice)
        display.onNoticeAction?(.pricing)
        XCTAssertEqual(acted, [.pricing])
        XCTAssertNil(display.visible, "the card goes once a button was clicked")
    }

    /// Spelling is checked on this Mac whatever the membership.
    func testSpellingGoesOnWithoutMembership() throws {
        ai.status = .memberBlocked(.noMember)
        let text = "a meeting room tomorow "
        type(text, errors: [try misspelling("tomorow", in: text, fixes: ["tomorrow"])])
        XCTAssertEqual(visibleKind, "spelling")
    }

    /// Today's limit: once a day, and no buttons (a member is not sold anything).
    func testDailyLimitIsToldOncePerDay() async {
        ai.status = .memberBlocked(.dailyLimit(reset: nil))
        type("I want to 预约")
        await wait()
        XCTAssertEqual(notice?.issue, .dailyLimit)
        XCTAssertEqual(notice?.links, [])
        keys.press(.escape)
        type("I want to 预约 a 会议室")
        await wait()
        XCTAssertEqual(pill, "没翻：明天恢复")
    }

    /// On-device only and an own key without one: Chinese gets nothing (no notice, no capsule).
    func testOtherPlansSayNothingAboutTheMembership() async {
        for status in [CoachAIStatus.localOnly, .noKey, .memberBlocked(.unavailable)] {
            ai.status = status
            focusEmptyField()
            type("I want to 预约")
            await wait()
            XCTAssertNil(display.visible, "\(status)")
        }
    }

    // MARK: Through the backend

    /// The backend says no membership for a card that went out (a refund, another Mac): the same notice.
    func testBackendRefusalIsToldLikeABlockedState() async {
        ai.status = .member
        ai.translation = .failure(CoachAIError.member(MemberError(code: "trial-closed", status: 402)))
        type("I want to 预约")
        await wait()
        XCTAssertEqual(ai.translateCalls.count, 1)
        XCTAssertEqual(notice?.issue, .noMember)
    }

    /// No network: a blip is not news; the second failure in a row is told, the third gets the capsule;
    /// once an answer came, the next stretch without network is told again.
    func testOfflineIsToldAfterTwoFailuresInARow() async {
        ai.status = .member
        ai.translation = .failure(CoachAIError.member(.network))
        type("I want to 预约")
        await wait()
        XCTAssertNil(display.visible, "one failure says nothing")
        type("I want to 预约 a 会议室")
        await wait()
        XCTAssertEqual(notice?.issue, .offline)
        keys.press(.escape)
        type("I want to 预约 a 会议室 at 三点")
        await wait()
        XCTAssertEqual(pill, "没翻：没网")
        clock.advance(TypingCoach.pillSeconds + 0.1)

        ai.translation = .success(CoachTranslation(english: "book", ipa: "", note: ""))
        focusEmptyField()
        type("I want to 改期")
        await wait()
        XCTAssertEqual(visibleKind, "translate", "the network is back: cards as usual, nothing said about it")
        keys.press(.escape)
        ai.translation = .failure(CoachAIError.member(.network))
        for word in ["取消", "推迟"] {
            focusEmptyField()
            type("I want to \(word)")
            await wait()
        }
        XCTAssertEqual(notice?.issue, .offline, "a new stretch without network is told again")
    }

    /// A busy backend or a token being renewed passes by itself: no notice, no capsule.
    func testPassingTroubleSaysNothing() async {
        ai.status = .member
        ai.translation = .failure(CoachAIError.member(MemberError(code: "upstream", status: 503)))
        type("I want to 预约")
        await wait()
        XCTAssertNil(display.visible)
    }

    // MARK: Chinese input methods in apps that do not say (Chrome)

    /// Types `letters` as an input method shows them: each a letter key, the field shows the
    /// composition (with the input method's own syllable break, no space key pressed).
    private func compose(_ composition: String, after prefix: String) {
        for count in 1 ... composition.count {
            coach.letterKeyPressed()
            clock.advance(0.1)
            clock.lastKeyAt = clock.now
            host.caret = nil
            host.text = prefix + String(composition.prefix(count))
            coach.textDidChange(host.text)
        }
    }

    /// Types `text` key by key in English: letters are letter keys, spaces are space keys.
    private func typeKeys(_ text: String, after prefix: String) {
        for count in 1 ... text.count {
            let character = text[text.index(text.startIndex, offsetBy: count - 1)]
            if character == " " { coach.wordEndKeyPressed() } else { coach.letterKeyPressed() }
            clock.advance(0.1)
            clock.lastKeyAt = clock.now
            host.caret = nil
            host.text = prefix + String(text.prefix(count))
            coach.textDidChange(host.text)
        }
    }

    func testPinyinSyllablesInChromeAreNotMisspellings() async {
        host.reportsMarkedText = false
        host.lettersCompose = true
        host.misspellings = ["yu": ["you"], "yue": ["you"], "yuyue": ["yuyu"]]
        type("I want to ")
        coach.wordEndKeyPressed()
        compose("yu yue", after: "I want to ")
        await wait()
        XCTAssertNil(display.visible, "no spelling card for the input method's syllables")
        XCTAssertTrue(ai.translateCalls.isEmpty && ai.checkCalls.isEmpty, "nothing half-composed goes to the AI")
        // Space picks 预约: the letters turn into Chinese.
        coach.wordEndKeyPressed()
        type("I want to 预约")
        await wait()
        XCTAssertEqual(ai.translateCalls.map(\.fragment), ["预约"])
        XCTAssertEqual(visibleKind, "translate")
    }

    /// The same input method in its English mode: the space is a key, the word is checked as usual.
    func testEnglishTypedWithTheInputMethodOnIsStillChecked() throws {
        host.reportsMarkedText = false
        host.lettersCompose = true
        let text = "a meeting room tomorow"
        host.misspellings = ["tomorow": ["tomorrow"]]
        typeKeys(text, after: "")
        XCTAssertNil(display.visible)
        coach.wordEndKeyPressed()
        type(text + " ", errors: [try misspelling("tomorow", in: text + " ", fixes: ["tomorrow"])])
        XCTAssertEqual(visibleKind, "spelling")
    }

    /// Without a Chinese input method nothing is guessed: pinyin typed in ABC is offered as English.
    func testPlainKeyboardIsNotGuessedAt() async throws {
        host.reportsMarkedText = false
        host.lettersCompose = false
        host.misspellings = ["yuyue": ["yuyu"]]
        type("I want to ")
        compose("yuyue", after: "I want to ")
        coach.wordEndKeyPressed()
        type("I want to yuyue ")
        await wait()
        XCTAssertEqual(ai.translateCalls.map(\.fragment), ["yuyue"])
    }

    func testCompositionGuess() {
        let text = Array("I want to yu'yue".unicodeScalars)
        XCTAssertEqual(CoachComposition.state(marked: true, lettersCompose: false, lettersSinceWordEnd: false, scalars: text, caret: text.count), .yes)
        XCTAssertEqual(CoachComposition.state(marked: false, lettersCompose: true, lettersSinceWordEnd: true, scalars: text, caret: text.count), .no,
                       "an app that says so is believed")
        XCTAssertEqual(CoachComposition.state(marked: nil, lettersCompose: true, lettersSinceWordEnd: true, scalars: text, caret: text.count), .maybe)
        XCTAssertEqual(CoachComposition.state(marked: nil, lettersCompose: true, lettersSinceWordEnd: false, scalars: text, caret: text.count), .no,
                       "a space key came after the letters")
        XCTAssertEqual(CoachComposition.state(marked: nil, lettersCompose: false, lettersSinceWordEnd: true, scalars: text, caret: text.count), .no)
        let han = Array("I want to 预约".unicodeScalars)
        XCTAssertEqual(CoachComposition.state(marked: nil, lettersCompose: true, lettersSinceWordEnd: true, scalars: han, caret: han.count), .no,
                       "committed Chinese is not composing")
    }

    func testWhichInputSourcesComposeLetters() {
        let wetype = CoachInputSource(id: "com.tencent.inputmethod.wetype.pinyin", mode: "com.tencent.inputmethod.wetype.pinyin",
                                      isInputMethod: true, languages: ["zh-Hans"])
        XCTAssertTrue(wetype.composesLetters)
        XCTAssertTrue(CoachInputSource(id: "com.apple.inputmethod.SCIM.ITABC", mode: "com.apple.inputmethod.SCIM.ITABC",
                                       isInputMethod: true, languages: ["zh-Hans"]).composesLetters)
        XCTAssertFalse(CoachInputSource(id: "com.apple.keylayout.ABC", mode: nil, isInputMethod: false, languages: ["en"]).composesLetters)
        XCTAssertFalse(CoachInputSource(id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Roman", mode: "com.apple.inputmethod.Japanese.Roman",
                                        isInputMethod: true, languages: ["ja"]).composesLetters)
        XCTAssertFalse(CoachInputSource(id: "com.apple.inputmethod.Korean.2SetKorean", mode: "com.apple.inputmethod.Korean.2SetKorean",
                                        isInputMethod: true, languages: ["ko"]).composesLetters, "Korean composes Hangul, not Latin letters")
    }
}
