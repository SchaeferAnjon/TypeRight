//
//  CoachLocalGrammar.swift
//  TypeRight
//
//  The sentence card without AI (on-device checks only, no usable membership, no network, a key
//  the provider turned down). The analysis that already looks for misspellings (Harper, on this
//  Mac) finds some grammar mistakes as well. Only the kinds in `Rule` get a card: on 170 sentences
//  with typical learners' mistakes and 800 right ones (2026-11-13) they fixed what they found and
//  almost never fired on a right sentence. The card says in one line of Chinese what kind of
//  mistake it is; Harper's English message is not shown. A finding of another kind, one without a
//  fix, or one that overlaps another finding gets no card: no card is better than a wrong one.
//  Misspellings have their own card.
//

import Foundation

enum CoachLocalGrammar {
    /// The kinds of Harper findings that get a card, told apart by the analysis' lint id
    /// (`Category::first_eight_words_of_the_message`, GrammarEngine/src/analyzer.rs).
    enum Rule: CaseIterable {
        /// I has, he don't, we goes (Harper's PronounVerbAgreement).
        case pronounAgreement
        /// they was, he were (PronounInflectionBe).
        case beAgreement
        /// a apple, an teacher (AnA).
        case article
        /// didn't went, did you finished (DidPast).
        case didBase
        /// have went, has broke (SimplePastToPastParticiple, after have only).
        case participle
        /// more taller, most best (AdjectiveDoubleDegree).
        case doubleComparative
        /// could of (ModalOf).
        case modalOf
        /// advices, informations (MassNouns).
        case massNoun
        /// discuss about (Discuss).
        case discussAbout
        /// its a nice day (ItsContraction).
        case itsContraction
        /// their going (TheirToTheyre).
        case theirContraction

        init?(lintID: String) {
            guard let rule = Self.allCases.first(where: { $0.matches(lintID) }) else { return nil }
            self = rule
        }

        private func matches(_ id: String) -> Bool {
            switch self {
            case .pronounAgreement: id == "Agreement::the_form_of_the_verb_must_agree_in"
            case .beAgreement: id == "Agreement::make_the_verb_agree_with_its_subject"
            case .article: id == "Miscellaneous::incorrect_indefinite_article"
            case .didBase: id == "Grammar::use_the_base_form_of_the_verb_with"
            // The message names the words: `Use the past participle gone instead of went …`.
            case .participle: id.hasPrefix("Grammar::use_the_past_participle_")
            case .doubleComparative:
                id.hasPrefix("Redundancy::") && (id.contains("_is_already_in_the_comparative_form") || id.contains("_is_already_in_the_superlative_form"))
            case .modalOf: id == "WordChoice::use_have_rather_than_of_here"
            case .massNoun: id.hasPrefix("Grammar::the_word_") && id.hasSuffix("_is_a_mass_noun_and")
            case .discussAbout: id == "Usage::about_is_redundant"
            case .itsContraction: id == "Punctuation::use_it_s_short_for_it_has_or"
            case .theirContraction: id == "Grammar::did_you_mean_they_re"
            }
        }

        /// The kind of mistake in the notebook (the words MistakeCategory reads).
        var type: String {
            switch self {
            case .pronounAgreement, .beAgreement: "agreement"
            case .article: "article"
            case .didBase, .participle: "tense"
            case .massNoun: "plural"
            case .discussAbout: "preposition"
            case .modalOf, .itsContraction, .theirContraction: "word-choice"
            case .doubleComparative: "other"
            }
        }

        /// One line of Chinese on what is wrong, with the words of the sentence; nil when the
        /// finding gets no card (the sentence lacks what the line needs, or Harper is known to be
        /// wrong there).
        func why(from: String, to: String, before: [String], after: String?) -> String? {
            let subject = before.last.flatMap { Self.subjects.contains($0.lowercased()) ? $0 : nil }
            switch self {
            case .pronounAgreement:
                // `I suggest (that) he go`: after suggest, insist … the verb stays as it is.
                let lower = before.map { $0.lowercased() }
                if Self.mandative(lower.dropLast().last == "that" ? lower.dropLast(2).last : lower.dropLast().last) { return nil }
                guard let subject else { return "动词要和主语的单复数对上：这里用 \(to)，不用 \(from)。" }
                return ["he", "she", "it"].contains(subject.lowercased())
                    ? "主语是 \(subject)，第三人称单数，动词用 \(to)，不用 \(from)。"
                    : "主语是 \(subject)，动词用 \(to)；\(from) 只跟 he、she、it 这类第三人称单数。"
            case .beAgreement:
                guard let subject else { return "be 动词要和主语对上：这里用 \(to)，不用 \(from)。" }
                return "主语是 \(subject)，be 动词用 \(to)，不用 \(from)。"
            case .article:
                guard let after else { return nil }
                switch to.lowercased() {
                case "an": return "\(after) 的读音以元音开头，前面用 an，不用 a。"
                case "a": return "\(after) 的读音以辅音开头，前面用 a，不用 an。"
                default: return nil
                }
            case .didBase:
                return "did 和 didn't 后面的动词用原形：用 \(to)，不用 \(from)。"
            case .participle:
                // Harper also takes `is broke` (has no money) for a passive: only after have.
                guard Self.afterHave(before) else { return nil }
                return "have、has、had 后面跟过去分词：用 \(to)，不用过去式 \(from)。"
            case .doubleComparative:
                switch from.split(separator: " ").first?.lowercased() {
                case "more": return "\(to) 本身就是比较级，前面不用再加 more。"
                case "most": return "\(to) 本身就是最高级，前面不用再加 most。"
                default: return nil
                }
            case .modalOf:
                guard let modal = from.split(separator: " ").first else { return nil }
                return "\(modal) 后面要写 have，不是 of：\(modal)'ve 读起来像 of。"
            case .massNoun:
                return "\(to) 是不可数名词，不加 s。"
            case .discussAbout:
                return "\(to) 后面直接跟要讨论的事，不加 about。"
            case .itsContraction:
                return "这里是 it is 或 it has 的缩写，要写 it's；its 是「它的」。"
            case .theirContraction:
                return "这里是 they are 的缩写，要写 they're；their 是「他们的」。"
            }
        }

        private static let subjects: Set<String> = ["i", "you", "he", "she", "it", "we", "they"]

        private static func mandative(_ word: String?) -> Bool {
            guard let word else { return false }
            return ["suggest", "insist", "recommend", "demand", "propos", "request", "requir", "urg", "ask"].contains { word.hasPrefix($0) }
        }

        /// The word before (or before an adverb like already) is have, has, had or 've.
        private static func afterHave(_ before: [String]) -> Bool {
            let words = before.suffix(2).map { $0.lowercased().replacingOccurrences(of: "’", with: "'") }
            func have(_ word: String) -> Bool {
                ["have", "has", "had", "having", "haven't", "hasn't", "hadn't"].contains(word) || word.hasSuffix("'ve")
            }
            guard let last = words.last else { return false }
            if have(last) { return true }
            let adverbs: Set<String> = ["already", "just", "never", "ever", "not", "also", "recently", "finally", "still", "always"]
            return words.count == 2 && adverbs.contains(last) && have(words[0])
        }
    }

    /// The card for the sentence at `range` of `scalars`, from the analysis of that text; nil when
    /// nothing in it gets a card.
    static func check(_ range: Range<Int>, in scalars: [Unicode.Scalar], errors: [GrammarErrorModel]) -> CoachSentenceCheck? {
        guard range.upperBound <= scalars.count else { return nil }
        let sentence = CoachText.substring(scalars, range)
        let sentenceScalars = Array(sentence.unicodeScalars)
        let words = CoachWords.words(in: sentence)
        var found: [(range: Range<Int>, to: String, why: String, type: String)] = []
        for error in errors.sorted(by: { $0.start < $1.start })
            where error.start >= range.lowerBound && error.end <= range.upperBound && error.start < error.end
        {
            guard let rule = Rule(lintID: error.lintId), let fix = error.suggestions.first,
                  !errors.contains(where: { $0 !== error && $0.start < error.end && $0.end > error.start })
            else { continue }
            let at = error.start - range.lowerBound ..< error.end - range.lowerBound
            let from = CoachText.substring(sentenceScalars, at)
            let to = matchCase(fix, like: from)
            let before = words.filter { $0.offset + $0.text.unicodeScalars.count <= at.lowerBound }.map(\.text)
            let after = words.first { $0.offset >= at.upperBound }?.text
            guard to != from, let why = rule.why(from: from, to: to, before: before, after: after) else { continue }
            found.append((at, to, why, rule.type))
        }
        guard !found.isEmpty else { return nil }

        // The card places each change by looking for its words after the change before it
        // (CoachText.placements): a change is widened by whole words until that lands where Harper found it.
        var changes: [CoachSentenceCheck.Change] = []
        var placed: [Range<Int>] = []
        for item in found {
            guard let spot = widened(item.range, to: item.to, in: sentence, words: words, after: placed.last?.upperBound ?? 0) else { return nil }
            changes.append(.init(from: spot.from, to: spot.to, why: item.why, type: item.type))
            placed.append(spot.range)
        }
        guard CoachText.placements(of: changes, in: sentence).map(\.range) == placed else { return nil }
        let corrected = CoachText.applying(changes.map { (from: $0.from, to: $0.to) }, to: sentence).text
        return CoachSentenceCheck(ok: false, corrected: corrected, changes: changes, local: true)
    }

    /// Harper's fix written the way the user wrote the words it replaces: `A apple` becomes
    /// `An apple`, not `AN apple`; `its` stays lower case.
    static func matchCase(_ fix: String, like original: String) -> String {
        let originalLetters = original.filter(\.isLetter)
        if originalLetters.count > 1, originalLetters.allSatisfy(\.isUppercase) { return fix.uppercased() }
        let fixLetters = fix.filter(\.isLetter)
        var out = fixLetters.count > 1 && fixLetters.allSatisfy(\.isUppercase) ? fix.lowercased() : fix
        guard let first = original.first(where: \.isLetter), let index = out.firstIndex(where: \.isLetter) else { return out }
        let pronounI = out == "I" || out.hasPrefix("I ") || out.hasPrefix("I'") || out.hasPrefix("I’")
        let head = first.isUppercase || pronounI ? String(out[index]).uppercased() : String(out[index]).lowercased()
        out.replaceSubrange(index ... index, with: head)
        return out
    }

    /// `at` and its fix, widened by the next (or else the previous) whole word until the words of
    /// `at` first appear as whole words at or after `cursor` right at `at`.
    private static func widened(_ at: Range<Int>, to: String, in sentence: String, words: [CoachWords.Piece],
                                after cursor: Int) -> (from: String, to: String, range: Range<Int>)?
    {
        let scalars = Array(sentence.unicodeScalars)
        let view = sentence.unicodeScalars
        var range = at
        var fix = to
        for _ in 0 ..< 6 {
            let from = CoachText.substring(scalars, range)
            let start = view.index(view.startIndex, offsetBy: cursor)
            if let hit = CoachText.wordRange(of: from, in: sentence, from: start), view.distance(from: view.startIndex, to: hit.lowerBound) == range.lowerBound {
                return (from, fix, range)
            }
            if let next = words.first(where: { $0.offset >= range.upperBound }) {
                let end = next.offset + next.text.unicodeScalars.count
                fix += CoachText.substring(scalars, range.upperBound ..< end)
                range = range.lowerBound ..< end
            } else if let previous = words.last(where: { $0.offset + $0.text.unicodeScalars.count <= range.lowerBound && $0.offset >= cursor }) {
                fix = CoachText.substring(scalars, previous.offset ..< range.lowerBound) + fix
                range = previous.offset ..< range.upperBound
            } else {
                return nil
            }
        }
        return nil
    }
}
