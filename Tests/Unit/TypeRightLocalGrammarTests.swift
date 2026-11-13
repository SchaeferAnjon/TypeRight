//
//  TypeRightLocalGrammarTests.swift
//  TypeRight
//
//  The sentence card without AI. CoachLocalGrammar on made-up analyses (which findings get a card
//  and what it says), the coach with the fakes of TypeRightTypingCoachTests (when the card comes,
//  Tab, Esc, the notebook, never next to an AI card for the same sentence), and the real Harper on
//  typical learners' sentences and on right ones.
//

@testable import TextWarden
import XCTest

/// The lint ids the analysis gives Harper's rules (Category::first eight words of the message).
private enum LintID {
    static let agreement = "Agreement::the_form_of_the_verb_must_agree_in"
    static let be = "Agreement::make_the_verb_agree_with_its_subject"
    static let article = "Miscellaneous::incorrect_indefinite_article"
    static let didBase = "Grammar::use_the_base_form_of_the_verb_with"
    static let gone = "Grammar::use_the_past_participle_gone_instead_of_went"
    static let broken = "Grammar::use_the_past_participle_broken_instead_of_broke"
    static let taller = "Redundancy::taller_is_already_in_the_comparative_form_the"
    static let best = "Redundancy::best_is_already_in_the_superlative_form_the"
    static let modalOf = "WordChoice::use_have_rather_than_of_here"
    static let advice = "Grammar::the_word_advice_is_a_mass_noun_and"
    static let discuss = "Usage::about_is_redundant"
    static let its = "Punctuation::use_it_s_short_for_it_has_or"
    static let their = "Grammar::did_you_mean_they_re"
}

/// Harper's finding of `words` in `text`: the first time they appear as whole words, or the
/// `nth` time.
private func finding(_ words: String, in text: String, nth: Int = 1, id: String, fix: [String]) -> GrammarErrorModel {
    var start = text.startIndex
    var found = text.startIndex ..< text.startIndex
    for _ in 0 ..< nth {
        guard let hit = CoachText.wordRange(of: words, in: text, from: start) else { preconditionFailure("\(words) not in \(text)") }
        found = hit
        start = hit.upperBound
    }
    let scalars = text.unicodeScalars
    let lower = scalars.distance(from: scalars.startIndex, to: found.lowerBound)
    let upper = scalars.distance(from: scalars.startIndex, to: found.upperBound)
    let category = String(id.prefix { $0 != ":" })
    return GrammarErrorModel(start: lower, end: upper, message: "Harper's English", severity: .warning, category: category, lintId: id, suggestions: fix)
}

// MARK: - What gets a card, and what it says

final class TypeRightLocalGrammarTests: XCTestCase {
    private func card(_ text: String, _ errors: [GrammarErrorModel]) -> CoachSentenceCheck? {
        let scalars = Array(text.unicodeScalars)
        return CoachLocalGrammar.check(0 ..< scalars.count, in: scalars, errors: errors)
    }

    func testIHasGetsHaveAndOneLineOfChinese() throws {
        let text = "I has a question."
        let check = card(text, [finding("has", in: text, id: LintID.agreement, fix: ["have"])])
        XCTAssertEqual(check, CoachSentenceCheck(ok: false, corrected: "I have a question.", changes: [
            .init(from: "has", to: "have", why: "主语是 I，动词用 have；has 只跟 he、she、it 这类第三人称单数。", type: "agreement"),
        ], local: true))
    }

    func testEachKindSaysWhatIsWrongInChinese() throws {
        let cases: [(text: String, words: String, id: String, fix: String, corrected: String, why: String, kind: MistakeCategory)] = [
            ("He don't like apples.", "don't", LintID.agreement, "doesn't", "He doesn't like apples.",
             "主语是 He，第三人称单数，动词用 doesn't，不用 don't。", .agreement),
            ("They was late.", "was", LintID.be, "were", "They were late.", "主语是 They，be 动词用 were，不用 was。", .agreement),
            ("It is a apple.", "a", LintID.article, "an", "It is an apple.", "apple 的读音以元音开头，前面用 an，不用 a。", .article),
            ("She is an teacher.", "an", LintID.article, "a", "She is a teacher.", "teacher 的读音以辅音开头，前面用 a，不用 an。", .article),
            ("I didn't went home.", "went", LintID.didBase, "go", "I didn't go home.", "did 和 didn't 后面的动词用原形：用 go，不用 went。", .tense),
            ("I have went there.", "went", LintID.gone, "gone", "I have gone there.", "have、has、had 后面跟过去分词：用 gone，不用过去式 went。", .tense),
            ("She is more taller than me.", "more taller", LintID.taller, "taller", "She is taller than me.", "taller 本身就是比较级，前面不用再加 more。", .other),
            ("This is the most best day.", "most best", LintID.best, "best", "This is the best day.", "best 本身就是最高级，前面不用再加 most。", .other),
            ("I could of done better.", "could of", LintID.modalOf, "could have", "I could have done better.",
             "could 后面要写 have，不是 of：could've 读起来像 of。", .wordChoice),
            ("He gave me some advices.", "advices", LintID.advice, "advice", "He gave me some advice.", "advice 是不可数名词，不加 s。", .plural),
            ("We discussed about the problem.", "discussed about", LintID.discuss, "discussed", "We discussed the problem.",
             "discussed 后面直接跟要讨论的事，不加 about。", .preposition),
            ("Its a nice day.", "Its", LintID.its, "It's", "It's a nice day.", "这里是 it is 或 it has 的缩写，要写 it's；its 是「它的」。", .wordChoice),
            ("Their going to the party.", "Their", LintID.their, "They're", "They're going to the party.",
             "这里是 they are 的缩写，要写 they're；their 是「他们的」。", .wordChoice),
        ]
        var kinds = Set<CoachLocalGrammar.Rule>()
        for c in cases {
            let check = try XCTUnwrap(card(c.text, [finding(c.words, in: c.text, id: c.id, fix: [c.fix])]), c.text)
            XCTAssertTrue(check.local, c.text)
            XCTAssertEqual(check.corrected, c.corrected, c.text)
            XCTAssertEqual(check.changes.map(\.why), [c.why], c.text)
            XCTAssertEqual(check.changes.map { MistakeCategory(aiType: $0.type) }, [c.kind], c.text)
            XCTAssertFalse(check.changes.contains { $0.why.contains("Harper") }, "Harper's English stays off the card")
            kinds.insert(try XCTUnwrap(CoachLocalGrammar.Rule(lintID: c.id)))
        }
        XCTAssertEqual(kinds.count, CoachLocalGrammar.Rule.allCases.count, "every kind has its line")
    }

    func testFindingsTheCardCannotExplainGetNone() {
        let text = "Let's go to there."
        // Harper's ToTwoToo would write `too there`; a kind not in the list gets no card.
        XCTAssertNil(card(text, [finding("to", in: text, id: "WordChoice::use_too_here_to_mean_also_or_an", fix: ["too"])]))
        let noFix = "He are my best friend."
        XCTAssertNil(card(noFix, [finding("are", in: noFix, id: LintID.agreement, fix: [])]), "no fix, no card")
        let spelled = "I have a questoin."
        XCTAssertNil(card(spelled, [finding("questoin", in: spelled, id: "Spelling::did_you_mean_question", fix: ["question"])]),
                     "misspellings have their own card")
        XCTAssertNil(card(text, []))
    }

    func testOverlappingFindingsGetNoCard() {
        let text = "I need a advice."
        XCTAssertNil(card(text, [
            finding("a", in: text, id: LintID.article, fix: ["an"]),
            finding("a advice", in: text, id: "Agreement::advice_is_a_mass_noun", fix: ["a tip", "advice"]),
        ]), "`an advice` would be wrong as well")
    }

    func testPastParticipleOnlyAfterHave() {
        // `is broke` means has no money; Harper takes it for a passive.
        let broke = "He is broke."
        XCTAssertNil(card(broke, [finding("broke", in: broke, id: LintID.broken, fix: ["broken"])]))
        for text in ["He has broke the window.", "He has already broke the window.", "We've broke the window."] {
            XCTAssertEqual(card(text, [finding("broke", in: text, id: LintID.broken, fix: ["broken"])])?.corrected,
                           text.replacingOccurrences(of: "broke", with: "broken"), text)
        }
    }

    func testTheVerbAfterSuggestStays() {
        for text in ["I suggest he go now.", "I suggest that he go now.", "They insisted she stay."] {
            let verb = text.contains("stay") ? "stay" : "go"
            XCTAssertNil(card(text, [finding(verb, in: text, id: LintID.agreement, fix: [verb + "s"])]), text)
        }
    }

    func testTheFixIsWrittenTheWayTheUserWrites() {
        let text = "A apple a day keeps the doctor away."
        XCTAssertEqual(card(text, [finding("A", in: text, id: LintID.article, fix: ["AN"])])?.corrected, "An apple a day keeps the doctor away.")
        XCTAssertEqual(CoachLocalGrammar.matchCase("an", like: "A"), "An")
        XCTAssertEqual(CoachLocalGrammar.matchCase("It's", like: "its"), "it's")
        XCTAssertEqual(CoachLocalGrammar.matchCase("doesn't", like: "DON'T"), "DOESN'T")
        XCTAssertEqual(CoachLocalGrammar.matchCase("I have", like: "i has"), "I have")
    }

    func testAWordThatComesTwiceIsChangedWhereHarperFoundIt() throws {
        let text = "I have a dog and a apple."
        let check = try XCTUnwrap(card(text, [finding("a", in: text, nth: 2, id: LintID.article, fix: ["an"])]))
        XCTAssertEqual(check.corrected, "I have a dog and an apple.")
        XCTAssertEqual(check.changes.map(\.from), ["a apple"])
        XCTAssertEqual(CoachText.placements(of: check.changes, in: text).map(\.range), [17 ..< 24])
    }

    func testSeveralFindingsInOneSentenceGoInTheOrderOfTheText() throws {
        let text = "He don't like a apple."
        let check = try XCTUnwrap(card(text, [
            finding("a", in: text, id: LintID.article, fix: ["an"]),
            finding("don't", in: text, id: LintID.agreement, fix: ["doesn't"]),
        ]))
        XCTAssertEqual(check.corrected, "He doesn't like an apple.")
        XCTAssertEqual(CoachText.placements(of: check.changes, in: text).map(\.to), ["doesn't", "an"])
    }

    func testOnlyTheSentenceAsked() throws {
        let text = "I has a question. She go home."
        let errors = [finding("has", in: text, id: LintID.agreement, fix: ["have"]), finding("go", in: text, id: LintID.agreement, fix: ["goes"])]
        let scalars = Array(text.unicodeScalars)
        let second = try XCTUnwrap(CoachLocalGrammar.check(18 ..< scalars.count, in: scalars, errors: errors))
        XCTAssertEqual(second.corrected, "She goes home.")
    }
}

// MARK: - The coach without AI

final class TypeRightLocalGrammarCoachTests: TypeRightCoachTestCase {
    private let text = "I has a question."
    private var harper: [GrammarErrorModel] { [finding("has", in: text, id: LintID.agreement, fix: ["have"])] }

    /// The card on screen when it is the one Harper found.
    private var localCard: CoachSentenceCheck? {
        if case let .sentence(_, check) = display.visible, check.local { return check }
        return nil
    }

    private var sentenceCardsShown: Int {
        display.shown.count(where: { if case .sentence = $0.content { true } else { false } })
    }

    private func afterTabGrace() async {
        clock.advance(TypingCoach.tabGrace + 0.05)
        await answers()
    }

    private func typeAlong(_ characters: String) {
        for character in characters {
            keys.press(.typed)
            clock.advance(0.1)
            clock.lastKeyAt = clock.now
            host.typeAtCaret(String(character))
            coach.textDidChange(host.text)
        }
    }

    func testWithoutAIAFinishedSentenceGetsTheCardFromThisMac() async {
        let off: [CoachAIStatus] = [.localOnly, .noKey, .memberBlocked(.noMember), .memberBlocked(.ended), .memberBlocked(.paymentFailed),
                                    .memberBlocked(.dailyLimit(reset: nil))]
        for (index, status) in off.enumerated() {
            ai.status = status
            host.fieldID = "com.example.chat#\(index + 10)"
            focusEmptyField()
            type(text, errors: harper)
            await wait()
            XCTAssertEqual(localCard?.corrected, "I have a question.", "\(status)")
            XCTAssertEqual(display.shown.last?.keys, .normal, "\(status)")
            keys.press(.escape)
        }
        XCTAssertTrue(ai.checkCalls.isEmpty, "nothing goes to the AI")
    }

    func testTabTypesAlongAndTheNotebookGetsTheKindInChinese() async throws {
        ai.status = .localOnly
        type(text, errors: harper)
        await wait()
        await afterTabGrace()
        keys.press(.tab)
        await coach.writeTask?.value
        XCTAssertEqual(host.text, "I  a question.")
        XCTAssertEqual(display.follow?.target, "have")
        typeAlong("have")
        XCTAssertEqual(host.text, "I have a question.")
        XCTAssertEqual(display.follow?.phase, .done(filled: false))
        let entry = try XCTUnwrap(notebook.mistakes.first)
        XCTAssertEqual(entry.category, .agreement)
        XCTAssertEqual(entry.category.title, "主谓一致")
        XCTAssertEqual([entry.from, entry.to, entry.why], ["has", "have", "主语是 I，动词用 have；has 只跟 he、she、it 这类第三人称单数。"])
        XCTAssertEqual(entry.how, .typed)
        await wait(3)
        XCTAssertEqual(sentenceCardsShown, 1, "the corrected sentence is not checked again")
    }

    func testTabTabFillsInAndEscPutsTheSentenceBack() async {
        ai.status = .localOnly
        type(text, errors: harper)
        await wait()
        await afterTabGrace()
        await tab()
        XCTAssertEqual(host.text, "I have a question.")
        XCTAssertEqual(notebook.mistakes.map(\.how), [.replaced])

        host.fieldID = "com.example.chat#2"
        focusEmptyField()
        notebook.clearAll()
        type(text, errors: harper)
        await wait()
        await afterTabGrace()
        keys.press(.tab)
        await coach.writeTask?.value
        typeAlong("h")
        keys.press(.escape)
        await coach.writeTask?.value
        XCTAssertEqual(host.text, text)
        XCTAssertNil(display.visible)
        XCTAssertTrue(notebook.entries.isEmpty)
    }

    /// The AI gets sentences of three words or more.
    private let longer = "Today I has a question."
    private var harperLonger: [GrammarErrorModel] { [finding("has", in: longer, id: LintID.agreement, fix: ["have"])] }

    func testWithAIOnlyTheAIChecksTheSentence() async {
        ai.status = .own(.deepseek)
        ai.checkResult = .success(CoachSentenceCheck(ok: false, corrected: "Today I have a question.",
                                                     changes: [.init(from: "has", to: "have", why: "主语是 I", type: "agreement")]))
        type(longer, errors: harperLonger)
        await wait()
        XCTAssertEqual(visibleKind, "sentence")
        XCTAssertNil(localCard)
        keys.press(.escape)
        await wait(3)
        XCTAssertEqual(sentenceCardsShown, 1, "one card for one sentence")

        // The AI finds it fine: Harper's finding brings no card of its own.
        host.fieldID = "com.example.chat#2"
        focusEmptyField()
        ai.checkResult = .success(CoachSentenceCheck(ok: true, corrected: "", changes: []))
        type(longer, errors: harperLonger)
        await wait(3)
        XCTAssertNil(display.visible)
        XCTAssertEqual(ai.checkCalls.count, 2)
    }

    func testMembershipOfflineTheSentenceIsCheckedHere() async {
        ai.status = .member
        ai.checkResult = .failure(CoachAIError.member(.network))
        type(longer, errors: harperLonger)
        await wait()
        XCTAssertEqual(ai.checkCalls.count, 1)
        XCTAssertEqual(localCard?.corrected, "Today I have a question.")
        XCTAssertNil(failedMessage)
    }

    func testRejectedKeyTheSentenceIsCheckedHereAndTheFailureShowsOnlyWithoutAFinding() async {
        ai.checkResult = .failure(CoachAIError.http(401))
        type(longer, errors: harperLonger)
        await wait()
        XCTAssertEqual(ai.checkCalls.count, 1)
        XCTAssertEqual(localCard?.corrected, "Today I have a question.", "the card from this Mac instead of the failure")
        keys.press(.escape)

        host.fieldID = "com.example.chat#2"
        focusEmptyField()
        type("Today I have a question.", errors: [])
        await wait()
        guard case let .failed(_, keyRejected) = display.visible else { return XCTFail("the failure, when this Mac finds nothing either") }
        XCTAssertTrue(keyRejected)
    }

    func testTheCardWaitsForAnAnalysisOfTheTextAsItReads() async {
        ai.status = .localOnly
        typeOn("I has a question. ")
        coach.analysisDidUpdate(text: "I has a question.", errors: harper)
        await wait()
        XCTAssertNil(display.visible, "an analysis of an older text is not used")
        coach.analysisDidUpdate(text: "I has a question. ", errors: harper)
        XCTAssertEqual(localCard?.corrected, "I have a question.")
    }

    func testTheCardWaitsForAStopLikeAnAIAnswer() async {
        ai.status = .localOnly
        typeOn("I has a question. ")
        clock.lastKeyAt = clock.now
        coach.analysisDidUpdate(text: host.text, errors: harper)
        XCTAssertNil(display.visible, "not under the words being typed")
        clock.advance(TypingCoach.settleSeconds)
        XCTAssertEqual(localCard?.corrected, "I have a question.")
    }

    func testAMisspellingKeepsItsOwnCardFirst() async throws {
        ai.status = .localOnly
        let typo = "I has a questoin."
        type(typo, errors: [finding("has", in: typo, id: LintID.agreement, fix: ["have"]),
                            try misspelling("questoin", in: typo, fixes: ["question"])])
        XCTAssertEqual(visibleKind, "spelling")
        await wait()
        XCTAssertEqual(visibleKind, "spelling", "the sentence card waits its turn")
        keys.press(.escape)
        XCTAssertEqual(localCard?.corrected, "I have a questoin.", "the card changes only the grammar")
    }

    func testAFindingWithoutAnExplanationCountsButShowsNothing() async {
        ai.status = .localOnly
        let future = "I will going to call you."
        type(future, errors: [finding("will going", in: future, id: "Grammar::will_and_shall_should_be_followed_by_a", fix: ["will go"])])
        await wait()
        XCTAssertNil(display.visible)
        XCTAssertEqual(notebook.days.last?.sentences, 1)
        XCTAssertEqual(notebook.days.last?.clean, 0)
    }

    func testAChatMessageWithoutAPeriodIsCheckedAfterALongerPause() async {
        ai.status = .localOnly
        let chat = "He don't like apples"
        type(chat, errors: [finding("don't", in: chat, id: LintID.agreement, fix: ["doesn't"])])
        await wait(behavior.pauseSeconds + 0.1)
        XCTAssertNil(display.visible)
        await wait(TypingCoach.lingerSeconds)
        XCTAssertEqual(localCard?.corrected, "He doesn't like apples")
    }
}

// MARK: - The real Harper

/// The analysis this Mac runs (all word lists on, American English), then CoachLocalGrammar. The
/// sentences are the ones the rules were picked with (2026-11-13).
final class TypeRightLocalGrammarEngineTests: XCTestCase {
    private static func card(_ sentence: String) -> (check: CoachSentenceCheck?, rules: [CoachLocalGrammar.Rule]) {
        let errors = GrammarEngine.shared.analyzeText(sentence).errors
        let scalars = Array(sentence.unicodeScalars)
        guard let check = CoachLocalGrammar.check(0 ..< scalars.count, in: scalars, errors: errors) else { return (nil, []) }
        let placed = CoachText.placements(of: check.changes, in: sentence).map(\.range)
        let rules = errors.compactMap { error in
            placed.contains { $0.lowerBound <= error.start && error.end <= $0.upperBound } ? CoachLocalGrammar.Rule(lintID: error.lintId) : nil
        }
        return (check, rules)
    }

    func testLearnersSentencesAndRightOnes() {
        var hits: [String: Int] = [:]
        for (sentence, expected) in Self.wrong {
            let found = Self.card(sentence)
            XCTAssertEqual(found.check?.corrected, expected, sentence)
            for rule in found.rules {
                hits["\(rule)", default: 0] += 1
            }
        }
        for sentence in Self.right {
            XCTAssertNil(Self.card(sentence).check, sentence)
        }
        let cards = Self.wrong.count(where: { $0.card != nil })
        print("TypeRight local grammar: \(Self.wrong.count) wrong sentences, \(cards) with a card; \(Self.right.count) right sentences; per kind: "
            + hits.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    }

    /// Typical learners' sentences and what the card makes of them; nil: no card (Harper does not
    /// flag it, has no fix, or the kind is not one CoachLocalGrammar explains).
    static let wrong: [(sentence: String, card: String?)] = [
        ("I has a question.", "I have a question."),
        ("She go to school every day.", "She goes to school every day."),
        ("He don't like apples.", "He doesn't like apples."),
        ("I am agree with you.", nil),
        ("It is a apple.", "It is an apple."),
        ("My mother cook dinner every night.", nil),
        ("The weather are very good today.", nil),
        ("He have two brothers.", "He has two brothers."),
        ("She don't know the answer.", "She doesn't know the answer."),
        ("It make me happy.", nil),
        ("My friend live in Beijing.", nil),
        ("They was late for the meeting.", "They were late for the meeting."),
        ("There is many people in the room.", nil),
        ("Everyone have their own opinion.", nil),
        ("He are my best friend.", nil),
        ("I is a student.", nil),
        ("This book are interesting.", nil),
        ("I am very like this movie.", nil),
        ("We are discuss the plan now.", nil),
        ("He is work in a bank.", nil),
        ("I want to buy a umbrella.", "I want to buy an umbrella."),
        ("She is an teacher.", "She is a teacher."),
        ("He is a honest man.", "He is an honest man."),
        ("I waited for a hour.", "I waited for an hour."),
        ("This is an useful tool.", "This is a useful tool."),
        ("Yesterday I go to the park.", nil),
        ("I have went there before.", "I have gone there before."),
        ("He has broke the window.", "He has broken the window."),
        ("I didn't went to work yesterday.", "I didn't go to work yesterday."),
        ("Did you finished your homework?", "Did you finish your homework?"),
        ("She doesn't likes coffee.", nil),
        ("He can speaks English.", nil),
        ("I will going to call you.", nil),
        ("You should to rest more.", nil),
        ("I have many homeworks.", nil),
        ("He gave me some advices.", "He gave me some advice."),
        ("I bought two book.", nil),
        ("There are three apple on the table.", nil),
        ("I need some informations.", "I need some information."),
        ("Many peoples like it.", nil),
        ("I am married with her.", nil),
        ("We discussed about the problem.", "We discussed the problem."),
        ("Please contact with me.", nil),
        ("He arrived to Beijing yesterday.", nil),
        ("I look forward to hear from you.", nil),
        ("Although it rained, but we went out.", nil),
        ("Because I was tired, so I went to bed.", nil),
        ("I very like it.", nil),
        ("She is more taller than me.", "She is taller than me."),
        ("This is the most best day.", "This is the best day."),
        ("He said me that he was busy.", nil),
        ("I can't able to come.", nil),
        ("Me and him went to the store.", nil),
        ("Let's go to there.", nil),
        ("Could you borrow me your pen?", nil),
        ("Their going to the party.", "They're going to the party."),
        ("Your welcome.", nil),
        ("Its a nice day.", "It's a nice day."),
        ("I could of done better.", "I could have done better."),
        ("He is more better now.", "He is better now."),
        ("I didn't knew that.", "I didn't know that."),
        ("She can't drives.", nil),
        ("I want to learning English.", nil),
        ("I enjoy to swim.", nil),
        ("Every students like him.", nil),
        ("I have a lot of works.", nil),
        ("He go to work by bus.", "He goes to work by bus."),
        ("She have a cat.", "She has a cat."),
        ("My father work in a hospital.", nil),
        ("The meeting are at 3 pm.", nil),
        ("We was happy to see you.", "We were happy to see you."),
        ("I has finished the report.", "I have finished the report."),
        ("It have been a long day.", nil),
        ("He doesn't has time.", nil),
        ("Does she knows you?", nil),
        ("I am study English now.", nil),
        ("I wants to go home.", "I want to go home."),
        ("They goes to the gym.", "They go to the gym."),
        ("This are my friends.", nil),
        ("These is my books.", nil),
        ("I has two cats and a dog.", "I have two cats and a dog."),
        ("He don't want to go.", "He doesn't want to go."),
        ("There is a apple on the table.", "There is an apple on the table."),
        ("I need a advice.", nil),
        ("It is an big problem.", "It is a big problem."),
        ("Can you tell me what is your name?", nil),
        ("I don't know what should I do.", nil),
        ("I am interesting in music.", nil),
        ("She explained me the rule.", nil),
        ("I think so that he is right.", nil),
        ("i has a question", "i have a question"),
        ("she go to work at 9.", "she goes to work at 9."),
        ("he dont like it.", nil),
        ("My boss have a meeting today.", nil),
        ("He like playing football.", nil),
        ("She want to talk to you.", "She wants to talk to you."),
        ("It look good to me.", nil),
        ("He need more time.", nil),
        ("She say it is fine.", "She says it is fine."),
        ("He know the answer.", "He knows the answer."),
        ("It work on my machine.", nil),
        ("They is coming tomorrow.", nil),
        ("You was right.", "You were right."),
        ("I were there yesterday.", nil),
        ("He were busy.", "He was busy."),
        ("She have been there twice.", "She has been there twice."),
        ("We has a problem.", "We have a problem."),
        ("He haven't finished yet.", "He hasn't finished yet."),
        ("She don't have time today.", "She doesn't have time today."),
        ("It don't work.", "It doesn't work."),
        ("Does he likes it?", nil),
        ("I didn't saw him.", "I didn't see him."),
        ("Did she went home?", "Did she go home?"),
        ("He didn't came yesterday.", "He didn't come yesterday."),
        ("They have went home.", "They have gone home."),
        ("She has wrote the email.", "She has written the email."),
        ("I have ate lunch.", "I have eaten lunch."),
        ("We have took the train.", "We have taken the train."),
        ("He has drank too much.", "He has drunk too much."),
        ("It is a interesting idea.", "It is an interesting idea."),
        ("I have a idea.", "I have an idea."),
        ("She is a engineer.", "She is an engineer."),
        ("He is an good man.", "He is a good man."),
        ("It takes a hour.", "It takes an hour."),
        ("I bought an new phone.", "I bought a new phone."),
        ("This is more easier.", "This is easier."),
        ("It is the most biggest city.", "It is the biggest city."),
        ("You are more smarter than him.", "You are smarter than him."),
        ("You should of told me.", "You should have told me."),
        ("We would of won.", "We would have won."),
        ("Thanks for your advices.", "Thanks for your advice."),
        ("I have some feedbacks.", "I have some feedback."),
        ("We bought new furnitures.", "We bought new furniture."),
        ("Its very cold today.", nil),
        ("Their coming later.", nil),
        ("We need to discuss about this.", "We need to discuss this."),
        ("Its going to rain.", nil),
        ("Its been a while.", "It's been a while."),
        ("Its time to go.", nil),
        ("I think its broken.", "I think it's broken."),
        ("Their not here.", "They're not here."),
        ("Their late again.", nil),
        ("I think their right.", nil),
        ("He go home early every day.", "He goes home early every day."),
        ("It seem fine to me.", nil),
        ("She play the piano.", "She plays the piano."),
        ("We goes there every week.", "We go there every week."),
        ("You has a nice car.", "You have a nice car."),
        ("He have to leave now.", "He has to leave now."),
        ("She don't want it.", "She doesn't want it."),
        ("It don't matter.", "It doesn't matter."),
        ("They was here.", "They were here."),
        ("I has to go now.", "I have to go now."),
        ("He didn't went home.", "He didn't go home."),
        ("I didn't heard you.", "I didn't hear you."),
        ("We have spoke about it.", "We have spoken about it."),
        ("He has gave me a book.", "He has given me a book."),
        ("It is a easy question.", "It is an easy question."),
        ("He is an nice person.", "He is a nice person."),
        ("This one is more cheaper.", "This one is cheaper."),
        ("That is the most fastest car.", "That is the fastest car."),
        ("I would of called you.", "I would have called you."),
        ("Thanks for the informations.", "Thanks for the information."),
        ("We discussed about it yesterday.", "We discussed it yesterday."),
        ("He don’t like apples.", nil),
        ("I didn’t went there.", "I didn’t go there."),
        ("She haven’t seen it.", nil),
        ("A apple a day keeps the doctor away.", "An apple a day keeps the doctor away."),
        ("Yesterday I go to the office because I has a question.", nil),
        ("He don't like a apple.", "He doesn't like an apple."),
        ("The window was broke.", nil),
        ("I had went home.", "I had gone home."),
        ("We've went there.", "We've gone there."),
        ("I have a dog and a apple.", "I have a dog and an apple."),
    ]

    /// Right sentences: none of them gets a card.
    static let right: [String] = [
        "I have a question.",
        "She goes to school every day.",
        "He doesn't like apples.",
        "I agree with you.",
        "It is an apple.",
        "I want to buy an umbrella.",
        "She is a teacher.",
        "He is an honest man.",
        "I waited for an hour.",
        "This is a useful tool.",
        "Yesterday I went to the park.",
        "I have been there before.",
        "He has broken the window.",
        "I didn't go to work yesterday.",
        "Did you finish your homework?",
        "She doesn't like coffee.",
        "He can speak English.",
        "I will call you tomorrow.",
        "You should rest more.",
        "He gave me some advice.",
        "There are three apples on the table.",
        "I look forward to hearing from you.",
        "She is taller than me.",
        "They were late for the meeting.",
        "There are many people in the room.",
        "Everyone has their own opinion.",
        "My mother cooks dinner every night.",
        "The weather is very good today.",
        "Could you lend me your pen?",
        "They're going to the party.",
        "You're welcome.",
        "It's a nice day.",
        "I could have done better.",
        "Let me know if you have any questions.",
        "We discussed the problem yesterday.",
        "Please contact me when you are free.",
        "Thanks for your help, I really appreciate it.",
        "Can we move the meeting to Friday?",
        "I'm not sure what you mean.",
        "The data is stored in a database.",
        "Our team uses GitHub for code review.",
        "I think this is a good idea.",
        "He has lived here for ten years.",
        "Sorry for the late reply.",
        "I will send you the report by tomorrow.",
        "My sister and I went to the store.",
        "Each student has a book.",
        "The children are playing outside.",
        "If I were you, I would wait.",
        "What time does the train leave?",
        "She has been working here since 2019.",
        "The news was surprising.",
        "I'd like a cup of coffee.",
        "These are my friends' bikes.",
        "Have you ever been to Japan?",
        "I am looking forward to the weekend.",
        "Neither of them was ready.",
        "This one is the best.",
        "Please let me know your thoughts.",
        "The meeting has been moved to 3 pm.",
        "ok I'll check it later",
        "lol that's funny",
        "Can you send me the link?",
        "I usually go to the gym after work.",
        "The API returns a JSON object.",
        "We need to fix the bug before Friday.",
        "Run npm install first.",
        "The function returns nil when the key is missing.",
        "I pushed the commit to main.",
        "He was a university student.",
        "It was a one-time thing.",
        "She wants an MBA.",
        "I have a European friend.",
        "We had an hour-long call.",
        "What does he do for a living?",
        "Does she know you?",
        "I was told to wait here.",
        "The kids have gone to bed.",
        "My parents live in Shanghai.",
        "Everybody loves him.",
        "The team is working on it.",
        "The police are coming.",
        "Do you want to grab lunch?",
        "Hope you're doing well.",
        "I'll be there in five minutes.",
        "Let's meet at the station.",
        "I can't make it today, sorry.",
        "Did he call you back?",
        "Where do you work?",
        "That makes sense.",
        "I don't think so.",
        "We should go now.",
        "This is the one I like.",
        "Have a nice weekend!",
        "He and I are old friends.",
        "Two of my friends are coming.",
        "It depends on the weather.",
        "What do you think about it?",
        "I've already sent the email.",
        "Could you please review my PR?",
        "The build failed on CI again.",
        "I am going to the store.",
        "They have been married for years.",
        "She has a lot of work to do.",
        "There is a cat on the roof.",
        "There are a lot of reasons.",
        "I like it very much.",
        "He told me that he was busy.",
        "Let him go.",
        "Make it work.",
        "Did she go home?",
        "Does he have time?",
        "I heard her sing.",
        "Help me find it.",
        "She and I have a dog.",
        "He and his wife live here.",
        "What do they want?",
        "I saw him leave.",
        "Can it run on Linux?",
        "Let it be.",
        "It doesn't matter.",
        "Thank you so much.",
        "Was it you?",
        "Were they there?",
        "Who was it?",
        "You were right.",
        "I was there yesterday.",
        "We were busy.",
        "I need a user name.",
        "We use an LLM for this.",
        "Paste a URL here.",
        "Write an SQL query.",
        "It has a UI.",
        "Call an API.",
        "It is an honor.",
        "We worked an 8-hour day.",
        "It was a 1-hour call.",
        "He had an X-ray.",
        "It runs on a Unix server.",
        "Did you know that?",
        "I did it.",
        "What did you say?",
        "He did his homework.",
        "She didn't want to go.",
        "Didn't you see it?",
        "I have a car that went fast.",
        "He has a friend who broke his leg.",
        "I have seen it.",
        "She has written a book.",
        "They had gone home.",
        "I had a dog that ran away.",
        "We have a team that wrote the code.",
        "He has a sister who sang at the party.",
        "There are more tall trees here.",
        "I want more and better tools.",
        "It is easier than I thought.",
        "I could, of course, wait.",
        "Its color is red.",
        "The dog wagged its tail.",
        "Its price is too high.",
        "Their house is big.",
        "Their going-away party was fun.",
        "Their car is new.",
        "She researches climate change.",
        "He advises me every week.",
        "Two coffees, please.",
        "We talked about it.",
        "The discussion about money took hours.",
        "Let's discuss it tomorrow.",
        "He works hard.",
        "The works of Shakespeare are great.",
        "She has two jobs.",
        "People say it is fine.",
        "Most people like it.",
        "The people here are nice.",
        "My friends live in Beijing.",
        "My friend lives in Beijing.",
        "One of my friends lives in Beijing.",
        "Neither he nor she knows.",
        "The number of users has grown.",
        "A lot of people have asked.",
        "I will go to the office tomorrow.",
        "I am going to call you.",
        "I think he is right.",
        "I'm going to be late.",
        "It's been a long day.",
        "It has been a long day.",
        "He has had enough.",
        "She had had a long day.",
        "What have you done?",
        "He's gone.",
        "I've been busy lately.",
        "We've got a problem.",
        "Have you eaten?",
        "I'd have done it.",
        "Is it OK if I come later?",
        "If it rains, we will stay home.",
        "When he arrives, call me.",
        "Whatever you want.",
        "We should have left earlier.",
        "He might have forgotten.",
        "They could have called.",
        "I really like it.",
        "She speaks English very well.",
        "He is an hour late.",
        "It is a European company.",
        "We visited a university.",
        "That was a one-off.",
        "He has an MBA.",
        "What a day!",
        "Thanks a lot!",
        "I love you.",
        "Do you have a minute?",
        "Let me check.",
        "Can you help me with this?",
        "I just sent it.",
        "See you tomorrow.",
        "Good morning everyone.",
        "The bug is fixed now.",
        "Please review the PR when you have time.",
        "The tests pass on my machine.",
        "We should merge it today.",
        "He doesn't know yet.",
        "She does a great job.",
        "It does work.",
        "He did go.",
        "Did it work?",
        "They have gone.",
        "I have done it.",
        "It was broken.",
        "The window was broken.",
        "He broke the window.",
        "I went there before.",
        "My mother cooks dinner.",
        "The weather is nice.",
        "They are late.",
        "We are happy.",
        "I am a student.",
        "He is my friend.",
        "This book is interesting.",
        "These are my books.",
        "This is my friend.",
        "The company and its employees agree.",
        "Its main feature is speed.",
        "Their plan worked.",
        "I like their idea.",
        "Let them know.",
        "Make him stop.",
        "Have them call me.",
        "She made me do it.",
        "We saw it happen.",
        "Did they say it?",
        "Do you think he knows?",
        "I wonder if he knows.",
        "Should she go?",
        "Would he come?",
        "Has he left?",
        "Is it done?",
        "Are they ready?",
        "Here it is.",
        "So do I.",
        "Neither do they.",
        "Me too.",
        "It seems fine.",
        "He seems tired.",
        "I suggest he go now.",
        "It is important that she be on time.",
        "Watch him play.",
        "Let us know what you think.",
        "I want you to come.",
        "They want me to stay.",
        "Who wants coffee?",
        "Everyone wants a raise.",
        "Nobody knows.",
        "Something is wrong.",
        "He said they were coming.",
        "They said he was coming.",
        "You and I are friends.",
        "Either you or he is wrong.",
        "I'll let you know.",
        "Hope it helps!",
        "Thank you for your patience.",
        "I have an idea.",
        "That is an easy question.",
        "This one is cheaper.",
        "That is the fastest car.",
        "I would have called you.",
        "Thanks for the information.",
        "We discussed it yesterday.",
        "He didn't go home.",
        "I didn't hear you.",
        "We have spoken about it.",
        "He has given me a book.",
        "They were here.",
        "I have to go now.",
        "It seems fine to me.",
        "She plays the piano.",
        "We go there every week.",
        "You have a nice car.",
        "He has to leave now.",
        "She doesn't want it.",
        "They're not here.",
        "They're late again.",
        "It's going to rain.",
        "It's been a while.",
        "It's time to go.",
        "I think it's broken.",
        "The more, the merrier.",
        "The more you practice, the better you get.",
        "Of course you could.",
        "He works more than me.",
        "The more expensive one is better.",
        "It got more interesting.",
        "I did my best.",
        "Did I say that?",
        "He did say so.",
        "Why did you leave?",
        "How did it go?",
        "We had it done.",
        "He had them sent over.",
        "I have them ready.",
        "He doesn’t like apples.",
        "I didn’t go there.",
        "It’s been a while.",
        "He is broke.",
        "We are broke this month.",
        "I was broke last year.",
        "The car is broke down.",
        "It is important that she be on time.",
        "I insist that he leave now.",
    ]
}
