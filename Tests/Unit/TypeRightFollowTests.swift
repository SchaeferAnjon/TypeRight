//
//  TypeRightFollowTests.swift
//  TypeRight
//
//  Tab types along (2026-11-13, direction B): the original goes out of the field, the card stays,
//  and what the user types in the field lights the card's English up character by character. Tab
//  again fills in the rest, Esc or Backspace at the start puts the original back, return or an
//  arrow ends it and keeps what was typed. With the same fake field, AI, clock and keys as the
//  other coach tests.
//

@testable import TextWarden
import XCTest

final class TypeRightFollowTests: TypeRightCoachTestCase {
    private let sentence = "Who is Jason Huang, the outside is 风雪交加"
    private let english = "a mix of wind and snow"
    private let space: Int64 = 49

    // MARK: Helpers

    private func showTranslation() async {
        ai.translation = .success(CoachTranslation(english: english, ipa: "", note: ""))
        type(sentence)
        await wait()
        XCTAssertEqual(visibleKind, "translate")
        await afterTabGrace()
    }

    private func afterTabGrace() async {
        clock.advance(TypingCoach.tabGrace + 0.05)
        await answers()
    }

    /// One Tab, and the write it started.
    @discardableResult
    private func pressTab() async -> Bool {
        let taken = keys.press(.tab)
        await coach.writeTask?.value
        return taken
    }

    @discardableResult
    private func pressEsc() async -> Bool {
        let taken = keys.press(.escape)
        await coach.writeTask?.value
        return taken
    }

    /// Types where the caret is, one key at a time: the key, then the field's change.
    private func typeAlong(_ characters: String) {
        for character in characters {
            keys.press(.typed)
            clock.advance(0.1)
            clock.lastKeyAt = clock.now
            host.typeAtCaret(String(character))
            coach.textDidChange(host.text)
        }
    }

    /// Backspace: the card takes it at the start, otherwise the field deletes a character.
    @discardableResult
    private func backspace() async -> Bool {
        let taken = keys.press(.deleteBack)
        if taken {
            await coach.writeTask?.value
        } else {
            host.deleteBack()
            coach.textDidChange(host.text)
        }
        return taken
    }

    private var follow: CoachFollow? { display.follow }

    // MARK: Translation card

    func testTabTakesTheChineseOutAndTheCardStays() async {
        await showTranslation()
        XCTAssertEqual(display.shown.last?.keys, .normal)
        let taken = await pressTab()
        XCTAssertTrue(taken)
        XCTAssertEqual(host.text, "Who is Jason Huang, the outside is ")
        XCTAssertEqual(host.caret, host.text.unicodeScalars.count, "the caret stays where the Chinese started")
        XCTAssertEqual(visibleKind, "translate", "the card stays")
        XCTAssertEqual(follow, CoachFollow(target: english))
        XCTAssertNotNil(keys.policy?.follow)
    }

    func testEachCharacterTypedRightLightsUpAndASpaceKeepsTheCard() async {
        await showTranslation()
        await pressTab()
        typeAlong("a mix ")
        XCTAssertEqual(follow?.right, 6)
        XCTAssertNil(follow?.wrongAt)
        XCTAssertEqual(visibleKind, "translate", "typing along, a space included, does not close the card")
        clock.advance(3)
        XCTAssertEqual(visibleKind, "translate", "nor does a stop")
        XCTAssertTrue(ai.checkCalls.isEmpty && ai.translateCalls.count == 1, "what is typed along is not sent anywhere")
    }

    func testTypedToTheEndIsRecordedAsTypedAndTheCardGoesAfterAMoment() async {
        await showTranslation()
        await pressTab()
        typeAlong(english)
        XCTAssertEqual(host.text, "Who is Jason Huang, the outside is a mix of wind and snow")
        XCTAssertEqual(follow?.phase, .done(filled: false))
        XCTAssertEqual(notebook.words.first?.to, english)
        XCTAssertEqual(notebook.words.first?.how, .typed)
        XCTAssertEqual(host.writes.count, 1, "TypeRight wrote nothing but taking the Chinese out")
        clock.advance(TypingCoach.doneSeconds - 0.1)
        XCTAssertEqual(visibleKind, "translate", "says what was recorded for a moment")
        clock.advance(0.2)
        XCTAssertNil(display.visible)
    }

    func testTypingOnAfterTheEndClosesTheCardAtOnce() async {
        await showTranslation()
        await pressTab()
        typeAlong(english)
        keys.press(.typed)
        XCTAssertNil(display.visible)
    }

    func testAWrongCharacterIsMarkedAndBackspaceTakesItBack() async {
        await showTranslation()
        await pressTab()
        typeAlong("a mo")
        XCTAssertEqual(follow?.right, 3)
        XCTAssertEqual(follow?.wrongAt, 3)
        XCTAssertEqual(visibleKind, "translate")
        let taken = await backspace()
        XCTAssertFalse(taken, "Backspace after something typed goes to the field")
        XCTAssertNil(follow?.wrongAt)
        typeAlong("ix")
        XCTAssertEqual(follow?.right, 5)
    }

    func testOneSpaceTooManyIsWrong() async {
        await showTranslation()
        await pressTab()
        typeAlong("a  ")
        XCTAssertEqual(follow?.wrongAt, 2)
    }

    func testTabAgainFillsInTheRestAndCountsAsReplaced() async {
        await showTranslation()
        await pressTab()
        typeAlong("a mi")
        let taken = await pressTab()
        XCTAssertTrue(taken)
        XCTAssertEqual(host.text, "Who is Jason Huang, the outside is a mix of wind and snow")
        XCTAssertEqual(follow?.phase, .done(filled: true))
        XCTAssertEqual(notebook.words.first?.how, .replaced)
    }

    func testTabAgainFixesAWrongCharacterToo() async {
        await showTranslation()
        await pressTab()
        typeAlong("a mox")
        await pressTab()
        XCTAssertEqual(host.text, "Who is Jason Huang, the outside is a mix of wind and snow")
    }

    func testTabTabIsTheOldReplace() async {
        await showTranslation()
        await pressTab()
        await pressTab()
        XCTAssertEqual(host.text, "Who is Jason Huang, the outside is a mix of wind and snow")
        XCTAssertEqual(notebook.words.first?.how, .replaced)
        XCTAssertEqual(host.writes.count, 2, "the Chinese goes, then the English comes")
    }

    /// The second Tab of a quick Tab Tab arrives while the first write is still under way.
    func testASecondTabDuringTheFirstWriteFillsIn() async {
        await showTranslation()
        XCTAssertTrue(keys.press(.tab))
        XCTAssertTrue(keys.press(.tab))
        await coach.writeTask?.value
        await coach.writeTask?.value
        XCTAssertEqual(host.text, "Who is Jason Huang, the outside is a mix of wind and snow")
    }

    func testEscPutsTheChineseBackAndItIsNotAskedAgain() async {
        await showTranslation()
        await pressTab()
        typeAlong("a m")
        let taken = await pressEsc()
        XCTAssertTrue(taken)
        XCTAssertEqual(host.text, sentence)
        XCTAssertEqual(host.caret, sentence.unicodeScalars.count, "the caret back where it was")
        XCTAssertNil(display.visible)
        XCTAssertTrue(notebook.entries.isEmpty, "Esc records nothing")
        typeOn(" ")
        await wait(3)
        XCTAssertEqual(ai.translateCalls.count, 1, "put back as it was: not offered again")
        XCTAssertNil(display.visible)
    }

    func testBackspaceAtTheStartIsLikeEsc() async {
        await showTranslation()
        await pressTab()
        typeAlong("a")
        let first = await backspace()
        XCTAssertFalse(first, "the a goes")
        let second = await backspace()
        XCTAssertTrue(second, "at the start Backspace is the card's")
        XCTAssertEqual(host.text, sentence)
        XCTAssertNil(display.visible)
    }

    func testFunctionKeysShortcutsAndModifiersDoNotEndTypingAlong() async {
        await showTranslation()
        await pressTab()
        typeAlong("a")
        for key in [CoachKey.of(keyCode: 122, flags: []), CoachKey.of(keyCode: 8, flags: .maskCommand), CoachKey.of(keyCode: 49, flags: .maskControl),
                    .modifiers(.option), .modifiers(.none)]
        {
            XCTAssertFalse(keys.press(key))
        }
        XCTAssertEqual(visibleKind, "translate")
        typeAlong(" mix")
        XCTAssertEqual(follow?.right, 5)
    }

    func testReturnOrAnArrowEndsTypingAlongAndKeepsWhatWasTyped() async {
        for key in [CoachKey.of(keyCode: 36, flags: []), CoachKey.of(keyCode: 123, flags: [])] {
            coach.reset()
            focusEmptyField()
            await showTranslation()
            await pressTab()
            typeAlong("a mix")
            let writes = host.writes.count
            XCTAssertFalse(keys.press(key), "\(key) goes to the app")
            XCTAssertNil(display.visible)
            XCTAssertEqual(host.text, "Who is Jason Huang, the outside is a mix")
            await wait(3)
            XCTAssertEqual(host.writes.count, writes, "nothing more is written")
        }
        XCTAssertTrue(notebook.entries.isEmpty, "left half way: nothing recorded")
    }

    func testAClickOutsideOrAnEditElsewhereEndsTypingAlong() async {
        await showTranslation()
        await pressTab()
        typeAlong("a")
        display.onClickOutside?()
        XCTAssertNil(display.visible)

        coach.reset()
        focusEmptyField()
        ai.translation = .success(CoachTranslation(english: english, ipa: "", note: ""))
        type("Hi Jason, the outside is 风雪交加")
        await wait()
        await afterTabGrace()
        await pressTab()
        host.text = "Oh, " + host.text
        coach.textDidChange(host.text)
        XCTAssertNil(display.visible, "the field changed outside the part typed along")
    }

    func testTheCardFollowsTheTypingToTheNextLine() async {
        host.lineLength = 40
        await showTranslation()
        await pressTab()
        let start = display.moves.count
        typeAlong("a mi")
        XCTAssertEqual(display.moves.count, start, "the card stays put along the line")
        typeAlong("x of")
        XCTAssertEqual(display.moves.count, start + 1, "the typing reached the next line")
        XCTAssertEqual(display.moves.last?.minY, 480)
    }

    func testTabSetToReplaceWritesAtOnce() async {
        behavior.tabFollows = false
        await showTranslation()
        XCTAssertEqual(display.shown.last?.keys, .direct)
        let taken = await pressTab()
        XCTAssertTrue(taken)
        XCTAssertEqual(host.text, "Who is Jason Huang, the outside is a mix of wind and snow")
        XCTAssertNil(display.visible)
        XCTAssertEqual(notebook.words.first?.how, .replaced)
    }

    func testChineseTouchingLettersGetsItsSpacesAndTypingStartsAtTheFirstLetter() async {
        ai.translation = .success(CoachTranslation(english: "book", ipa: "", note: ""))
        type("I want to预约a room")
        await wait()
        await afterTabGrace()
        await pressTab()
        XCTAssertEqual(host.text, "I want to  a room")
        XCTAssertEqual(host.caret, 10, "between the two spaces")
        typeAlong("book")
        XCTAssertEqual(host.text, "I want to book a room")
        XCTAssertEqual(follow?.phase, .done(filled: false))
    }

    /// The translate key turned the whole field: a space holds its place.
    func testAWholeFieldTranslationKeepsAPlaceToTypeIn() async {
        ai.translation = .success(CoachTranslation(english: "Can we meet tomorrow?", ipa: "", note: ""))
        host.text = "明天能见面吗"
        coach.translateWholeSentence()
        await answers()
        XCTAssertEqual(visibleKind, "translate")
        await afterTabGrace()
        await pressTab()
        XCTAssertEqual(host.text, " ")
        XCTAssertEqual(host.caret, 0)
        await pressEsc()
        XCTAssertEqual(host.text, "明天能见面吗")
    }

    func testInputMethodLettersDoNotCountAndItKeepsTabAndEsc() async {
        await showTranslation()
        await pressTab()
        host.composing = true
        typeAlong("mi")
        XCTAssertEqual(follow?.composing, true)
        XCTAssertNil(follow?.wrongAt, "letters the input method has not committed are not typed yet")
        XCTAssertFalse(keys.press(.tab), "Tab picks a candidate")
        XCTAssertFalse(keys.press(.escape), "Esc cancels the letters")
        XCTAssertEqual(visibleKind, "translate")
        host.composing = false
        host.text = "Who is Jason Huang, the outside is a"
        host.caret = nil
        coach.textDidChange(host.text)
        XCTAssertEqual(follow?.composing, false)
        XCTAssertEqual(follow?.right, 1)
    }

    /// Chrome and other apps that do not report composing, with a Chinese input method on: the
    /// letters count (it may be in its English mode), the card reminds that pinyin only counts once
    /// committed, and Tab and Esc stay the card's.
    func testInputMethodOnInAnAppThatDoesNotSayKeepsTheKeys() async {
        await showTranslation()
        await pressTab()
        host.reportsMarkedText = false
        host.lettersCompose = true
        coach.letterKeyPressed()
        typeAlong("a")
        XCTAssertEqual(follow?.composing, false)
        XCTAssertEqual(follow?.inputMethodOn, true)
        XCTAssertEqual(follow?.right, 1, "the letter counts")
        coach.wordEndKeyPressed()
        typeAlong(" ")
        XCTAssertEqual(follow?.inputMethodOn, false, "a space typed by a key ends the syllables")
        coach.letterKeyPressed()
        typeAlong("m")
        XCTAssertEqual(follow?.inputMethodOn, true)
        XCTAssertTrue(keys.press(.tab), "Tab still fills in")
    }

    /// Copying the card is not remembering the word: it gets the 自己打的 tag, not a use without help.
    func testTypingAlongIsNotAUseWithoutHelp() async {
        ai.translation = .success(CoachTranslation(english: "book", ipa: "", note: ""))
        type("I want to 预约")
        await wait()
        await afterTabGrace()
        await pressTab()
        typeAlong("book")
        clock.advance(TypingCoach.doneSeconds + 0.1)
        ai.checkResult = .success(CoachSentenceCheck(ok: true, corrected: "", changes: []))
        typeOn(" a room.")
        await wait()
        XCTAssertEqual(ai.checkCalls.map(\.sentence), ["I want to book a room."])
        XCTAssertEqual(notebook.words.first?.correctUses, 0)
        XCTAssertEqual(notebook.days.last?.clean, 0, "a sentence TypeRight helped with is not right the first time")
    }

    // MARK: Spelling card

    func testSpellingTypedAlongPutsTheCaretBackAfterTheSpace() async throws {
        ai.status = .localOnly
        let text = "I will send it tomorow "
        type(text, errors: [try misspelling("tomorow", in: text, fixes: ["tomorrow"])])
        XCTAssertEqual(visibleKind, "spelling")
        await afterTabGrace()
        await pressTab()
        XCTAssertEqual(host.text, "I will send it  ")
        XCTAssertEqual(host.caret, 15)
        typeAlong("tomorrow")
        XCTAssertEqual(host.text, "I will send it tomorrow ")
        XCTAssertEqual(host.caret, host.text.unicodeScalars.count, "back after the space, where the user was typing")
        XCTAssertEqual(notebook.mistakes.first?.to, "tomorrow")
        XCTAssertEqual(notebook.mistakes.first?.how, .typed)
    }

    func testSpellingEscPutsTheMisspelledWordBack() async throws {
        ai.status = .localOnly
        let text = "I will send it tomorow "
        type(text, errors: [try misspelling("tomorow", in: text, fixes: ["tomorrow"])])
        await afterTabGrace()
        await pressTab()
        typeAlong("tom")
        await pressEsc()
        XCTAssertEqual(host.text, text)
        XCTAssertNil(display.visible)
    }

    // MARK: Sentence card

    private let original = "Yesterday I go to the office because I has a question."
    private let corrected = "Yesterday I went to the office because I had a question."

    private func showSentence() async {
        ai.checkResult = .success(CoachSentenceCheck(ok: false, corrected: corrected, changes: [
            .init(from: "go", to: "went", why: "过去的事用过去式", type: "tense"),
            .init(from: "has", to: "had", why: "", type: "tense"),
        ]))
        type(original)
        await wait()
        XCTAssertEqual(visibleKind, "sentence")
        await afterTabGrace()
    }

    func testSentenceCardTypesOnlyTheChangedWordsOneAfterTheOther() async {
        await showSentence()
        XCTAssertEqual(display.shown.last?.keys, .normal)
        await pressTab()
        XCTAssertEqual(host.text, "Yesterday I  to the office because I has a question.")
        XCTAssertEqual(host.caret, 12, "the caret on the first change")
        XCTAssertEqual(follow, CoachFollow(target: "went", step: 0))
        typeAlong("went")
        await coach.writeTask?.value
        XCTAssertEqual(host.text, "Yesterday I went to the office because I  a question.")
        XCTAssertEqual(host.caret, 41, "the caret jumped to the next change")
        XCTAssertEqual(follow, CoachFollow(target: "had", step: 1))
        XCTAssertTrue(display.moves.isEmpty, "the sentence card stays where it came up")
        typeAlong("had")
        XCTAssertEqual(host.text, corrected)
        XCTAssertEqual(host.caret, corrected.unicodeScalars.count, "back at the end of the sentence")
        XCTAssertEqual(follow?.phase, .done(filled: false))
        XCTAssertEqual(notebook.mistakes.map(\.how), [.typed, .typed])
        await wait(3)
        XCTAssertEqual(ai.checkCalls.count, 1, "the corrected sentence is not checked again")
    }

    func testSentenceTabHalfWayWritesTheWholeCorrection() async {
        await showSentence()
        await pressTab()
        typeAlong("we")
        await pressTab()
        XCTAssertEqual(host.text, corrected)
        XCTAssertEqual(notebook.mistakes.map(\.how), [.replaced, .replaced])
    }

    func testSentenceEscPutsTheOriginalSentenceBack() async {
        await showSentence()
        await pressTab()
        typeAlong("went")
        await coach.writeTask?.value
        typeAlong("h")
        await pressEsc()
        XCTAssertEqual(host.text, original)
        XCTAssertTrue(notebook.entries.isEmpty)
        await wait(3)
        XCTAssertEqual(ai.checkCalls.count, 1, "the original sentence is not checked again")
    }

    func testAChangeThatOnlyTakesWordsOutIsDoneByTypeRight() async {
        ai.checkResult = .success(CoachSentenceCheck(ok: false, corrected: "I like apples a lot.", changes: [
            .init(from: "very", to: "", why: ""), .init(from: "much", to: "a lot", why: ""),
        ]))
        type("I very like apples much.")
        await wait()
        await afterTabGrace()
        await pressTab()
        await coach.writeTask?.value
        XCTAssertEqual(host.text, "I like apples .")
        XCTAssertEqual(follow?.target, "a lot")
        typeAlong("a lot")
        XCTAssertEqual(host.text, "I like apples a lot.")
    }

    func testWhereTheCaretCannotBePutTheSentenceCardOnlyReplaces() async {
        host.canMoveCaret = false
        await showSentence()
        XCTAssertEqual(display.shown.last?.keys, .direct)
        await pressTab()
        XCTAssertEqual(host.text, corrected)
    }

    // MARK: Holding ⌥

    func testHoldingOptionAloneListsTheWordsUntilItIsLetGo() async {
        await showTranslation()
        keys.press(.modifiers(.option))
        clock.advance(TypingCoach.holdSeconds - 0.1)
        XCTAssertFalse(display.allWords)
        clock.advance(0.15)
        XCTAssertTrue(display.allWords)
        XCTAssertEqual(visibleKind, "translate", "holding ⌥ keeps the card")
        keys.press(.modifiers(.none))
        XCTAssertFalse(display.allWords)
        XCTAssertEqual(visibleKind, "translate")
    }

    func testAnotherKeyWhileHoldingIsAShortcutNotALook() async {
        await showTranslation()
        keys.press(.modifiers(.option))
        clock.advance(0.2)
        keys.press(CoachKey.of(keyCode: 0, flags: .maskAlternate))
        clock.advance(1)
        XCTAssertFalse(display.allWords)
        keys.press(.modifiers(.other))
        clock.advance(1)
        XCTAssertFalse(display.allWords, "⌥ with ⇧ is not ⌥ alone")
    }

    func testTheListKeyFollowsTheSettingAndTypingAlongGoesOn() async {
        behavior.allWordsKey = .control
        await showTranslation()
        keys.press(.modifiers(.option))
        clock.advance(1)
        XCTAssertFalse(display.allWords)
        await pressTab()
        keys.press(.modifiers(.control))
        clock.advance(1)
        XCTAssertTrue(display.allWords)
        keys.press(.modifiers(.none))
        typeAlong("a")
        XCTAssertEqual(follow?.right, 1, "typing along goes on")
        behavior.allWordsKey = .off
        keys.press(.modifiers(.control))
        clock.advance(1)
        XCTAssertFalse(display.allWords)
    }
}

// MARK: - The key gate while typing along

final class TypeRightFollowKeyGateTests: XCTestCase {
    private func gate(typed: Int, composing: Bool = false) -> CoachKeyGate {
        var gate = CoachKeyGate()
        gate.reset(CoachKeyPolicy(tab: true, tabFrom: 100, esc: true, follow: CoachFollowKeys(typed: typed, composing: composing)),
                   inputMethod: true)
        return gate
    }

    func testTabAndEscAreTheCardsAtOnceEvenWithAnInputMethod() {
        var gate = gate(typed: 0)
        XCTAssertTrue(gate.swallows(.tab, at: 0), "no grace time while typing along")
        XCTAssertFalse(gate.swallows(.typed, at: 0))
        XCTAssertTrue(gate.swallows(.tab, at: 0), "letters typed with Pinyin's English mode keep Tab the card's")
        XCTAssertTrue(gate.swallows(.escape, at: 0))
    }

    func testBackspaceIsTheCardsOnlyAtTheStart() {
        var gate = gate(typed: 2)
        XCTAssertFalse(gate.swallows(.deleteBack, at: 0))
        XCTAssertFalse(gate.swallows(.deleteBack, at: 0))
        XCTAssertTrue(gate.swallows(.deleteBack, at: 0), "a quick run of Backspaces stops at the start")
        XCTAssertFalse(gate.swallows(.typed, at: 0))
        XCTAssertFalse(gate.swallows(.deleteBack, at: 0))
    }

    func testWhileComposingTheInputMethodGetsTabEscAndBackspace() {
        var gate = gate(typed: 0, composing: true)
        XCTAssertFalse(gate.swallows(.tab, at: 0))
        XCTAssertFalse(gate.swallows(.escape, at: 0))
        XCTAssertFalse(gate.swallows(.deleteBack, at: 0))
    }

    func testKeysAreReadTheSameWay() {
        XCTAssertEqual(CoachKey.of(keyCode: 51, flags: []), .deleteBack)
        XCTAssertEqual(CoachKey.of(keyCode: 51, flags: .maskShift), .deleteBack)
        XCTAssertEqual(CoachKey.of(keyCode: 51, flags: .maskAlternate), .moves, "⌥⌫ deletes a word")
        XCTAssertEqual(CoachKey.of(keyCode: 51, flags: .maskCommand), .moves)
        XCTAssertEqual(CoachKey.of(keyCode: 117, flags: []), .moves, "Forward Delete")
        XCTAssertEqual(CoachModifiers(.maskAlternate), .option)
        XCTAssertEqual(CoachModifiers([.maskAlternate, .maskNonCoalesced]), .option)
        XCTAssertEqual(CoachModifiers([.maskAlternate, .maskShift]), .other)
        XCTAssertEqual(CoachModifiers(.maskControl), .control)
        XCTAssertEqual(CoachModifiers([]), .none)
        XCTAssertEqual(CoachModifiers(.maskAlphaShift), .none, "Caps Lock on is not a key held")
    }
}
