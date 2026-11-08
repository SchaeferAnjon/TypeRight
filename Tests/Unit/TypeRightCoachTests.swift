//
//  TypeRightCoachTests.swift
//  TypeRight
//
//  The parts of the typing coach that do not need a real app or the network.
//

@testable import TextWarden
import XCTest

final class TypeRightCoachTests: XCTestCase {
    // MARK: Pinyin

    func testPinyinWordsAreRecognised() {
        for word in ["yuyue", "suanfa", "nihao", "xiexie", "zhongwen", "shangban", "huiyi"] {
            XCTAssertTrue(PinyinDetector.isLikelyPinyin(word), word)
        }
    }

    func testMisspelledEnglishIsNotPinyin() {
        for word in ["tomorow", "becaus", "recieve", "seperate", "definately", "adress", "wich"] {
            XCTAssertFalse(PinyinDetector.isLikelyPinyin(word), word)
        }
    }

    func testShortOrMixedTokensAreNotPinyin() {
        XCTAssertFalse(PinyinDetector.isLikelyPinyin("ma"))
        XCTAssertFalse(PinyinDetector.isLikelyPinyin("nihao2"))
        XCTAssertFalse(PinyinDetector.isLikelyPinyin("Ni-hao"))
    }

    // MARK: Chinese inside English

    func testHanRunsAndLatinWords() {
        let scalars = Array("I want to 预约 a meeting room".unicodeScalars)
        let runs = ChineseText.hanRuns(in: scalars, from: 0, to: scalars.count)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(String(String.UnicodeScalarView(scalars[runs[0]])), "预约")
        XCTAssertEqual(ChineseText.latinWordCount(in: scalars, from: 0, to: scalars.count), 4)
    }

    func testPureChineseHasNoLatinWords() {
        let scalars = Array("明天下午三点开会可以吗".unicodeScalars)
        XCTAssertEqual(ChineseText.latinWordCount(in: scalars, from: 0, to: scalars.count), 0)
    }

    func testMixedChatSentence() {
        let scalars = Array("i wannna 预约 a table".unicodeScalars)
        let runs = ChineseText.hanRuns(in: scalars, from: 0, to: scalars.count)
        XCTAssertEqual(runs, [9 ..< 11])
        XCTAssertEqual(ChineseText.latinWordCount(in: scalars, from: 0, to: scalars.count), 2) // "i" is one letter
    }

    func testSentenceKeyIgnoresFinalPunctuation() {
        XCTAssertEqual(TypingCoach.sentenceKey("I has a question"), TypingCoach.sentenceKey("I has a question. "))
        XCTAssertNotEqual(TypingCoach.sentenceKey("I has a question"), TypingCoach.sentenceKey("I have a question"))
    }

    // MARK: AI replies

    func testCodeFenceAndChatterAreStripped() {
        let raw = "```json\n{\"ok\": true}\n```"
        XCTAssertEqual(CoachAI.stripCodeFence(raw), "{\"ok\": true}")
        XCTAssertEqual(CoachAI.stripCodeFence("Sure! {\"english\":\"book\"} hope it helps"), "{\"english\":\"book\"}")
    }

    func testSentenceCheckDecodesWithMissingFields() throws {
        let ok = try JSONDecoder().decode(CoachSentenceCheck.self, from: Data(#"{"ok": true}"#.utf8))
        XCTAssertTrue(ok.ok)
        XCTAssertTrue(ok.changes.isEmpty)

        let fix = try JSONDecoder().decode(CoachSentenceCheck.self, from: Data(#"""
        {"ok": false, "corrected": "I have a question.", "changes": [{"from": "I has", "to": "I have", "why": "主语是 I，用 have"}]}
        """#.utf8))
        XCTAssertFalse(fix.ok)
        XCTAssertEqual(fix.corrected, "I have a question.")
        XCTAssertEqual(fix.changes.first?.to, "I have")
    }

    func testTranslationNeedsEnglish() throws {
        let t = try JSONDecoder().decode(CoachTranslation.self, from: Data(#"{"english": "book"}"#.utf8))
        XCTAssertEqual(t.english, "book")
        XCTAssertEqual(t.ipa, "")
    }

    // MARK: Card actions

    func testCardAcceptText() {
        XCTAssertEqual(CoachCardContent.spelling(wrong: "tomorow", fixes: ["tomorrow"]).acceptText, "tomorrow")
        let check = CoachSentenceCheck(ok: true, corrected: "", changes: [])
        XCTAssertNil(CoachCardContent.sentence(original: "Fine.", check: check).acceptText)
        XCTAssertNil(CoachCardContent.thinking.acceptText)
    }
}
