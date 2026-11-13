//
//  TypeRightSpeedTests.swift
//  TypeRight
//
//  Cards that come without waiting: spelling at the word end, sentences at their . ? !, Chinese
//  as soon as the user types on, answers that stream in and wait while the user types, and the
//  rules that keep it from costing more (one request per text, one use number per card, two
//  requests at a time). Same fakes as TypeRightTypingCoachTests.
//

@testable import TextWarden
import XCTest

// MARK: - Answers that are still arriving

@MainActor
final class TypeRightStreamTests: XCTestCase {
    func testPartialJSONLeavesOutWhatIsStillBeingWritten() throws {
        let partial = try XCTUnwrap(PartialJSON.parse(#"```json\n{"english": "bo"#))
        XCTAssertNil(partial["english"], "a string still open is left out")
        XCTAssertFalse(partial.isClosed)

        let english = try XCTUnwrap(PartialJSON.parse(#"{"english": "book", "ipa": "/bʊ"#))
        XCTAssertEqual(english["english"]?.string, "book")
        XCTAssertNil(english["ipa"])

        let escaped = try XCTUnwrap(PartialJSON.parse(#"{"why": "用 \"have\"\n😀 主😀", "n": 12}"#))
        XCTAssertEqual(escaped["why"]?.string, "用 \"have\"\n😀 主😀")
        XCTAssertEqual(escaped["n"], .number(12))
        XCTAssertTrue(escaped.isClosed)
        XCTAssertNil(PartialJSON.parse(#"{"n": 12"#)?["n"], "a number at the very end may still grow")
    }

    func testSentenceCheckShowsOnceEveryEditIsInAndReasonsFillInAfter() throws {
        let original = "because I has a question."
        let edits = #"{"ok": false, "edits": [{"from": "because", "to": "Because"}, {"from": "has", "to": "have"}"#
        XCTAssertNil(PartialJSON.parse(edits).flatMap { CoachSentenceCheck.partial($0, original: original) }, "the edits are not all in yet")
        let closed = edits + #"], "notes": [{"why": "句首大写", "type": "capitalization"}, {"why": "主语是"#
        let check = try XCTUnwrap(PartialJSON.parse(closed).flatMap { CoachSentenceCheck.partial($0, original: original) })
        XCTAssertEqual(check.corrected, "Because I have a question.")
        XCTAssertEqual(check.changes.map(\.why), ["句首大写", ""], "the second reason is still being written")
        XCTAssertEqual(check.changes.first?.type, "capitalization")
    }

    func testEditsGoIntoTheSentenceWhereTheyBelong() {
        func apply(_ edits: [(String, String)], _ original: String) -> String {
            CoachText.applying(edits.map { (from: $0.0, to: $0.1) }, to: original).text
        }
        // Whole words only, exact case first: the change of `i` is not the i inside `this`.
        XCTAssertEqual(apply([("i", "I"), ("dont", "don't"), ("now", "know")], "i dont now this ."), "I don't know this .")
        // The same word twice: each edit takes the next one.
        XCTAssertEqual(apply([("has", "have"), ("has", "have")], "I has it and she has it"), "I have it and she have it")
        // Out of order still lands; a word taken out takes one space with it.
        XCTAssertEqual(apply([("question", "problem"), ("very", "")], "I very have a question"), "I have a problem")
        // Case only differs: found anyway.
        XCTAssertEqual(apply([("Because", "because")], "so BECAUSE of that"), "so because of that")
        let missing = CoachText.applying([(from: "zebra", to: "horse"), (from: "has", to: "have")], to: "I has it")
        XCTAssertEqual(missing.text, "I have it")
        XCTAssertEqual(missing.placed, [1], "an edit that is not in the sentence is left out")
    }

    func testTheUsersRunOnTextIsThreeSentences() {
        let text = "i dont now this .this is vertical, bro. Hope you're doing good."
        let scalars = Array(text.unicodeScalars)
        let sentences = CoachText.sentences(in: scalars).map { CoachText.substring(scalars, $0.range) }
        XCTAssertEqual(sentences, ["i dont now this .", "this is vertical, bro.", "Hope you're doing good."])

        func split(_ s: String) -> [String] {
            let scalars = Array(s.unicodeScalars)
            return CoachText.sentences(in: scalars).map { CoachText.substring(scalars, $0.range) }
        }
        XCTAssertEqual(split("Open README.md and wait 3.5 s on example.com now."), ["Open README.md and wait 3.5 s on example.com now."])
        XCTAssertEqual(split("He said \"hi.\" Then he left"), ["He said \"hi.\"", "Then he left"])
        XCTAssertEqual(split("Really?yes. I see.Thanks"), ["Really?", "yes.", "I see.", "Thanks"])
        XCTAssertEqual(CoachText.sentences(in: Array("a b c\nd e".unicodeScalars)).map(\.finished), [false, false])
    }

    func testStreamedTranslationGivesTheEnglishFirst() async throws {
        let keys = MemoryKeychain(["deepseek_api_key": "sk-1"]).keyStore
        let pieces = [#"{\"english\": \"bo"#, #"ok\", \"ipa\": \"/bʊk/\""#, #", \"note\": \"订会议室用 book\"}"#]
        let body = pieces.map { #"data: {"choices":[{"delta":{"content":""# + $0 + #""}}]}"# }.joined(separator: "\n\n")
            + "\n\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":90,\"completion_tokens\":20}}\n\ndata: [DONE]\n"
        let seen = Seen()
        let result = try await CoachAI.translate(fragment: "预约", in: "I want to 预约", via: .own(.deepseek), keys: keys,
                                                 lines: CoachNet.lines(from: Self.reply(body))) { seen.items.append($0) }
        XCTAssertEqual(seen.items.map(\.english), ["book", "book"])
        XCTAssertEqual(seen.items.map(\.ipa), ["/bʊk/", "/bʊk/"])
        XCTAssertEqual(seen.items.first?.note, "", "the card went up before the note arrived")
        XCTAssertEqual(result, CoachTranslation(english: "book", ipa: "/bʊk/", note: "订会议室用 book"))
    }

    func testAnAnswerThatIsNotStreamedStillWorks() async throws {
        let keys = MemoryKeychain(["deepseek_api_key": "sk-1"]).keyStore
        let body = #"{"choices":[{"message":{"content":"{\"ok\": true}"}}]}"#
        let check = try await CoachAI.check(sentence: "I have a question.", via: .own(.deepseek), keys: keys, lines: CoachNet.lines(from: Self.reply(body)))
        XCTAssertTrue(check.ok)
    }

    func testRequestAsksForAStream() throws {
        let body = CoachAI.requestBody("x", maxTokens: 300, via: .own(.deepseek), stream: true)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["stream_options"] as? [String: Bool])?["include_usage"], true)
        XCTAssertEqual(CoachAI.requestBody("x", maxTokens: 300, via: .member(use: UUID()), stream: true)["stream"] as? Bool, true)
        XCTAssertNil(CoachAI.requestBody("x", maxTokens: 300, via: .own(.claude), stream: true)["stream_options"], "only where documented")
    }

    @MainActor
    final class Seen {
        var items: [CoachTranslation] = []
    }

    private static func reply(_ body: String) -> CoachNet.Send {
        { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }
}

// MARK: - When the cards come

final class TypeRightSpeedTests: TypeRightCoachTestCase {
    private func sentenceCard(_ corrected: String, _ changes: [CoachSentenceCheck.Change]) -> CoachSentenceCheck {
        CoachSentenceCheck(ok: false, corrected: corrected, changes: changes)
    }

    func testSpellingCardComesAtTheWordEndWithoutTheAnalysis() {
        host.misspellings["tomorow"] = ["tomorrow"]
        typeOn("I will send it tomorow")
        XCTAssertNil(display.visible, "not before the word is finished")
        typeOn(" ")
        XCTAssertEqual(display.visible, .spelling(wrong: "tomorow", fixes: ["tomorrow"]), "no analysis has run")
    }

    func testAnalysisThatFlagsNothingThereWithdrawsTheSpellingCard() {
        host.misspellings["kubectl"] = ["subject"]
        typeOn("run kubectl ")
        XCTAssertEqual(visibleKind, "spelling")
        coach.analysisDidUpdate(text: host.text, errors: [])
        XCTAssertNil(display.visible)
        clock.advance(3)
        XCTAssertNil(display.visible, "and it does not come back")
    }

    func testAKeyReadsTheFieldWhenTheAppSaysNothing() {
        host.misspellings["tomorow"] = ["tomorrow"]
        typeOn("I will send it tomorow")
        host.text += " " // the app never says this changed
        coach.wordEndKeyPressed()
        XCTAssertNil(display.visible)
        clock.advance(0.02)
        XCTAssertEqual(visibleKind, "spelling")
    }

    func testQuestionMarkSendsTheSentenceAtOnce() async {
        typeOn("can I has a question?")
        await untilAsked(1)
        XCTAssertEqual(ai.checkCalls.map(\.sentence), ["can I has a question?"], "no pause waited for")
    }

    func testPeriodSendsTheSentenceAfterABriefStopNotAfterThePause() async {
        ai.hold = true
        typeOn("because I has a question.")
        clock.advance(TypingCoach.quickSeconds + 0.01)
        XCTAssertLessThan(TypingCoach.quickSeconds + 0.11, behavior.pauseSeconds)
        await untilAsked(1)
        XCTAssertEqual(ai.checkCalls.map(\.sentence), ["because I has a question."])
        XCTAssertEqual(visibleKind, "thinking", "想一下 within 0.3 s of the period")
        ai.release()
        await answers()
    }

    func testSentenceWithoutAPeriodShowsThinkingAsSoonAsItIsSent() async {
        ai.hold = true
        typeOn("I goes to the office every day")
        clock.advance(behavior.pauseSeconds + TypingCoach.lingerSeconds + 0.01)
        await untilAsked(1)
        XCTAssertEqual(ai.checkCalls.map(\.sentence), ["I goes to the office every day"])
        XCTAssertEqual(visibleKind, "thinking")
        ai.release()
        await answers()
    }

    func testPeriodOfAFileNameIsNotASentenceEnd() async {
        typeOn("please open the README.md file")
        await wait(TypingCoach.quickSeconds + 0.05)
        XCTAssertTrue(ai.checkCalls.isEmpty)
    }

    func testChineseFollowedByASpaceIsTranslatedAtOnce() async {
        typeOn("I want to ")
        clock.lastKeyAt = clock.now
        host.text += "预约"
        coach.textDidChange(host.text)
        await untilAsked(1)
        XCTAssertTrue(ai.translateCalls.isEmpty, "the Chinese is the last thing typed: it waits for the pause")
        typeOn(" ")
        await untilAsked(1)
        XCTAssertEqual(ai.translateCalls.map(\.fragment), ["预约"])
    }

    func testStreamingFillsTheCardInPlace() async {
        ai.translationParts = [CoachTranslation(english: "book", ipa: "", note: ""), CoachTranslation(english: "book", ipa: "/bʊk/", note: "")]
        ai.translation = .success(CoachTranslation(english: "book", ipa: "/bʊk/", note: "订会议室用 book"))
        type("I want to 预约")
        clock.advance(1)
        await untilAsked(1)
        for _ in 0 ..< 5 { await Task.yield() }
        XCTAssertEqual(display.visible, .translate(source: "预约", result: CoachTranslation(english: "book", ipa: "", note: "")),
                       "the English is on screen before the rest")
        ai.step()
        for _ in 0 ..< 5 { await Task.yield() }
        ai.step()
        await answers()
        XCTAssertEqual(display.visible, .translate(source: "预约", result: CoachTranslation(english: "book", ipa: "/bʊk/", note: "订会议室用 book")))
        XCTAssertEqual(display.shown.filter { if case .translate = $0.content { return true }; return false }.count, 1, "shown once, then filled in")
        XCTAssertEqual(display.updates.count, 2)
    }

    func testRunOnSentencesAreEachCheckedOnceAndComeInOrder() async {
        // Tab set to replace at once: each card writes its whole sentence.
        behavior.tabFollows = false
        let first = "i dont now this ."
        let second = "this is vertical, bro."
        let third = "Hope you're doing good."
        ai.checkResults = [
            first: sentenceCard("I don't know this .", [.init(from: "i", to: "I", why: "I 大写"), .init(from: "dont", to: "don't", why: "缩写"),
                                                       .init(from: "now", to: "know", why: "know 是知道")]),
            second: sentenceCard("This is virtual, bro.", [.init(from: "vertical", to: "virtual", why: "意思是虚拟")]),
            third: sentenceCard("Hope you're doing well.", [.init(from: "good", to: "well", why: "副词用 well")]),
        ]
        typeOn(first + second + " " + third)
        await wait(1)
        // The first two go out together, the third once one of them is back; cards still come in order.
        XCTAssertEqual(Set(ai.checkCalls.map(\.sentence)), [first, second, third])
        XCTAssertEqual(ai.checkCalls.last?.sentence, third)
        for (sentence, card) in [(first, "I don't know this ."), (second, "This is virtual, bro."), (third, "Hope you're doing well.")] {
            guard case let .sentence(original, check)? = display.visible else { return XCTFail("no card for \(sentence)") }
            XCTAssertEqual(original, sentence)
            XCTAssertEqual(check.corrected, card)
            await waitForTabGrace()
            await tab()
            XCTAssertEqual(host.writes.last?.range.count, sentence.unicodeScalars.count, "the whole sentence and only it")
        }
        XCTAssertEqual(host.text, "I don't know this .This is virtual, bro. Hope you're doing well.")
        XCTAssertEqual(ai.checkCalls.count, 3, "nothing asked twice")
    }

    func testASentenceIsAskedOnceEvenWhenItsCardWasDroppedForAnEdit() async {
        ai.checkResult = .success(sentenceCard("Because I have a question.", [.init(from: "has", to: "have", why: "主语是 I")]))
        ai.hold = true
        typeOn("because I has a question.")
        typeOn(" I")
        await untilAsked(1)
        ai.release()
        await answers()
        XCTAssertNil(display.visible, "held while typing")
        // The user fixes it, changes their mind and puts it back.
        host.text = "because I had a question. I"
        coach.textDidChange(host.text)
        host.text = "because I has a question. I"
        coach.textDidChange(host.text)
        XCTAssertNil(display.visible)
        await wait(3)
        XCTAssertEqual(ai.checkCalls.map(\.sentence), ["because I has a question."], "the text that was sent is not sent again")
        XCTAssertNil(display.visible, "the dropped card does not come back")
    }

    func testAtMostTwoRequestsAtATime() async {
        ai.hold = true
        typeOn("I has one question? She go home? He don't care?")
        await untilAsked(3)
        XCTAssertEqual(ai.checkCalls.count, 2)
        ai.release()
        await answers()
        XCTAssertEqual(ai.checkCalls.count, 3)
    }

    func testEachMemberCardHasItsOwnUseNumber() async {
        ai.status = .member
        typeOn("I has one question? She go to ")
        clock.lastKeyAt = clock.now
        host.text += "学校"
        coach.textDidChange(host.text)
        typeOn(" every day. He don't care?")
        await wait(1)
        let uses = (ai.checkCalls.map(\.route) + ai.translateCalls.map(\.route)).compactMap { route -> UUID? in
            if case let .member(use) = route { return use }
            return nil
        }
        XCTAssertEqual(uses.count, 3)
        XCTAssertEqual(Set(uses).count, 3, "one use number per card")
    }

    func testMisspellingSkippedWhileACardWasUpIsCoveredByItsSentenceCard() async {
        host.misspellings = ["recieve": ["receive"], "tomorow": ["tomorrow"]]
        ai.hold = true
        typeOn("I recieve ")
        XCTAssertEqual(display.visible, .spelling(wrong: "recieve", fixes: ["receive"]))
        typeOn("it tomorow again.")
        XCTAssertEqual(display.visible, .spelling(wrong: "recieve", fixes: ["receive"]), "the card in front stays")
        clock.advance(1)
        keys.press(.escape)
        XCTAssertEqual(visibleKind, "thinking", "the sentence is being checked: tomorow waits for it")
        ai.checkResult = .success(sentenceCard("I receive it tomorrow again.", [.init(from: "tomorow", to: "tomorrow", why: "拼写")]))
        ai.release()
        await answers()
        XCTAssertEqual(visibleKind, "sentence")
        keys.press(.escape)
        clock.advance(3)
        XCTAssertNil(display.visible, "the sentence card covered tomorow")
    }

    func testMisspellingSkippedComesNextWhenNoSentenceCardCovers() {
        host.misspellings = ["recieve": ["receive"], "tomorow": ["tomorrow"]]
        ai.status = .localOnly
        typeOn("I recieve ")
        typeOn("it tomorow ")
        XCTAssertEqual(display.visible, .spelling(wrong: "recieve", fixes: ["receive"]))
        keys.press(.escape)
        XCTAssertEqual(display.visible, .spelling(wrong: "tomorow", fixes: ["tomorrow"]), "right after the card in front")
    }

    func testTextThatWasThereAtFocusIsLeftAlone() async {
        coach.reset()
        host.text = "because I has a question. She go home."
        coach.textDidChange(host.text)
        await wait(3)
        XCTAssertTrue(ai.checkCalls.isEmpty)
        typeOn(" He don't care.")
        await wait(3)
        XCTAssertEqual(ai.checkCalls.map(\.sentence), ["He don't care."], "only what was typed now")
    }

    private func waitForTabGrace() async {
        clock.advance(TypingCoach.tabGrace + 0.05)
        await answers()
    }
}
