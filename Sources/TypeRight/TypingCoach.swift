//
//  TypingCoach.swift
//  TypeRight
//
//  Decides when a card pops up while the user types English:
//  1. a word was just finished and the spell checker rejected it  -> spelling card, right away
//  2. the user typed Chinese (or pinyin) inside an English sentence -> English for it, after a pause
//  3. a sentence was just finished (. ? !)                          -> whole-sentence check, after a pause
//  One card at a time. Tab takes the card's fix, Esc keeps the text, typing on makes it step aside.
//

import AppKit

/// What TypingCoach needs from the app-monitoring side (AnalysisCoordinator).
@MainActor
protocol TypingCoachHost: AnyObject {
    /// Screen bounds (Cocoa coordinates) of a scalar range of `text`, or nil when unknown.
    func coachAnchor(for range: Range<Int>, in text: String) -> CGRect?
    /// A place near the text field to fall back on when a word's bounds are unknown.
    func coachFallbackAnchor() -> CGRect?
    /// The caret as a scalar offset into `text`, or nil when the app does not say.
    func coachCaret(in text: String) -> Int?
    /// Writes `replacement` over `range` of the text the analysis saw.
    func coachReplace(range: Range<Int>, with replacement: String, analyzedText: String, harperError: GrammarErrorModel?) async -> Bool
    /// Name of the app being typed in, for the notebook.
    var coachAppName: String { get }
}

@MainActor
final class TypingCoach {
    static let shared = TypingCoach()

    weak var host: TypingCoachHost?

    private let panel = CoachCardPanel()
    private let keyTap = CoachKeyTap()

    private struct Active {
        var content: CoachCardContent
        var range: Range<Int>
        var analyzedText: String
        var harperError: GrammarErrorModel?
        var memoryKey: String
        var keysSinceShown = 0
        /// Where the card points when that differs from the range it replaces (sentence cards).
        var anchorOverride: Range<Int>?
    }

    private var active: Active?
    private var latestText = ""
    private var latestErrors: [GrammarErrorModel] = []
    private var pauseTimer: Timer?
    private var aiTask: Task<Void, Never>?
    private var waitingPinyin: (range: Range<Int>, word: String)?

    /// Things the user said no to (Esc), so they are not offered again.
    private var declined = Set<String>()
    /// Sentences already sent for a check.
    private var checkedSentences = Set<String>()

    private init() {
        PinyinDetector.warmUp()
        keyTap.onKey = { [weak self] key in self?.handleKey(key) ?? false }
        panel.onClickOutside = { [weak self] in self?.dismiss(remember: false) }
    }

    // MARK: - Input from the analysis

    /// Called after every analysis of the focused field.
    func analysisDidUpdate(text: String, errors: [GrammarErrorModel]) {
        guard CoachSettings.cardsEnabled, host != nil else { return }
        latestText = text
        latestErrors = errors

        if let active, !stillMatches(active) { dismiss(remember: false) }

        if active == nil, let (error, word) = justFinishedSpellingError(in: text, errors: errors) {
            if CoachSettings.isAIReady, PinyinDetector.isLikelyPinyin(word) {
                waitingPinyin = (error.start ..< error.end, word)
            } else {
                showSpelling(error, word: word, text: text)
            }
        }

        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: CoachSettings.pauseSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.userPaused() }
        }
    }

    /// The monitored field went away (focus moved, app switched, monitoring stopped).
    func reset() {
        pauseTimer?.invalidate()
        aiTask?.cancel()
        waitingPinyin = nil
        dismiss(remember: false)
    }

    // MARK: - Spelling

    private func justFinishedSpellingError(in text: String, errors: [GrammarErrorModel]) -> (GrammarErrorModel, String)? {
        let scalars = Array(text.unicodeScalars)
        let caret = min(host?.coachCaret(in: text) ?? scalars.count, scalars.count)
        let candidates = errors.filter { ($0.category == "Spelling" || $0.category == "Typo") && $0.end <= caret }
        guard let error = candidates.max(by: { $0.end < $1.end }), error.end <= scalars.count else { return nil }

        // The word counts as finished when a space or punctuation follows it and at most
        // a few letters of the next word have been typed since.
        let after = scalars[error.end ..< caret]
        guard let first = after.first, !CharacterSet.letters.contains(first), after.count <= 4 else { return nil }

        let word = String(String.UnicodeScalarView(scalars[error.start ..< error.end]))
        guard !declined.contains(spellingKey(word, error)) else { return nil }
        return (error, word)
    }

    private func spellingKey(_ word: String, _ error: GrammarErrorModel) -> String {
        "spell:\(word.lowercased()):\(error.start)"
    }

    private func showSpelling(_ error: GrammarErrorModel, word: String, text: String) {
        guard !error.suggestions.isEmpty else { return }
        let content = CoachCardContent.spelling(wrong: word, fixes: Array(error.suggestions.prefix(4)))
        present(Active(content: content, range: error.start ..< error.end, analyzedText: text,
                       harperError: error, memoryKey: spellingKey(word, error)))
    }

    // MARK: - After a pause: Chinese, pinyin, finished sentences

    private func userPaused() {
        guard active == nil || isThinking, CoachSettings.isAIReady else { return }
        let text = latestText
        let scalars = Array(text.unicodeScalars)
        let caret = min(host?.coachCaret(in: text) ?? scalars.count, scalars.count)
        let sentence = sentenceRange(endingNear: caret, in: scalars)

        // Chinese inside an English sentence.
        if ChineseText.latinWordCount(in: scalars, from: sentence.lowerBound, to: sentence.upperBound) >= 1,
           let run = ChineseText.hanRuns(in: scalars, from: sentence.lowerBound, to: sentence.upperBound)
           .first(where: { !declined.contains("han:\(substring(scalars, $0))") })
        {
            translate(fragmentRange: run, sentence: sentence, scalars: scalars, text: text)
            return
        }

        // Pinyin the spell checker rejected.
        if let pinyin = waitingPinyin {
            waitingPinyin = nil
            if pinyin.range.upperBound <= scalars.count, substring(scalars, pinyin.range) == pinyin.word {
                translate(fragmentRange: pinyin.range, sentence: sentence, scalars: scalars, text: text)
                return
            }
        }

        // A sentence that was just finished.
        if let finished = finishedSentence(before: caret, in: scalars) {
            let sentenceText = substring(scalars, finished)
            guard !checkedSentences.contains(sentenceText),
                  ChineseText.hanRuns(in: scalars, from: finished.lowerBound, to: finished.upperBound).isEmpty,
                  ChineseText.latinWordCount(in: scalars, from: finished.lowerBound, to: finished.upperBound) >= 3
            else { return }
            checkedSentences.insert(sentenceText)
            check(sentenceRange: finished, scalars: scalars, text: text)
        }
    }

    private func translate(fragmentRange: Range<Int>, sentence: Range<Int>, scalars: [Unicode.Scalar], text: String) {
        let fragment = substring(scalars, fragmentRange)
        let sentenceText = substring(scalars, sentence)
        showThinking(at: fragmentRange, text: text)
        aiTask?.cancel()
        aiTask = Task { [weak self] in
            do {
                let result = try await CoachAI.translate(fragment: fragment, in: sentenceText)
                guard let self, !Task.isCancelled, self.latestTextStill(has: fragment, at: fragmentRange) else { return }
                self.present(Active(content: .translate(source: fragment, result: result), range: fragmentRange,
                                    analyzedText: self.latestText, harperError: nil, memoryKey: "han:\(fragment)"))
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.showFailure(error, at: fragmentRange, text: text)
            }
        }
    }

    private func check(sentenceRange: Range<Int>, scalars: [Unicode.Scalar], text: String) {
        let sentenceText = substring(scalars, sentenceRange)
        let lastWord = lastWordRange(in: scalars, within: sentenceRange)
        showThinking(at: lastWord, text: text)
        aiTask?.cancel()
        aiTask = Task { [weak self] in
            do {
                let result = try await CoachAI.check(sentence: sentenceText)
                guard let self, !Task.isCancelled else { return }
                guard !result.ok, !result.corrected.isEmpty, result.corrected != sentenceText,
                      self.latestTextStill(has: sentenceText, at: sentenceRange)
                else {
                    if self.isThinking { self.dismiss(remember: false) }
                    return
                }
                let anchor = self.firstChangeRange(result, in: scalars, within: sentenceRange) ?? lastWord
                var card = Active(content: .sentence(original: sentenceText, check: result), range: sentenceRange,
                                  analyzedText: self.latestText, harperError: nil, memoryKey: "sentence:\(sentenceText)")
                card.anchorOverride = anchor
                self.present(card)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.showFailure(error, at: lastWord, text: text)
            }
        }
    }

    // MARK: - Showing and taking cards

    private var isThinking: Bool {
        if case .thinking = active?.content { return true }
        return false
    }

    private func showThinking(at range: Range<Int>, text: String) {
        present(Active(content: .thinking, range: range, analyzedText: text, harperError: nil, memoryKey: ""))
    }

    private func showFailure(_ error: Error, at range: Range<Int>, text: String) {
        let message = "AI 没回上来：" + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        Logger.warning("TypeRight: AI request failed: \(message.prefix(200))", category: Logger.llm)
        present(Active(content: .failed(message), range: range, analyzedText: text, harperError: nil, memoryKey: ""))
        let shown = active?.content
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            MainActor.assumeIsolated {
                if let self, self.active?.content == shown { self.dismiss(remember: false) }
            }
        }
    }

    private func present(_ card: Active) {
        guard let host else { return }
        let anchorRange = card.anchorOverride ?? card.range
        guard let anchor = host.coachAnchor(for: anchorRange, in: card.analyzedText) ?? host.coachFallbackAnchor() else {
            Logger.debug("TypeRight: no anchor for card, not showing", category: Logger.ui)
            return
        }
        active = card
        panel.show(card.content, anchor: anchor)
        if card.content.acceptText != nil || isFailure(card.content) { keyTap.turnOn() } else { keyTap.turnOff() }
    }

    private func isFailure(_ content: CoachCardContent) -> Bool {
        if case .failed = content { return true }
        return false
    }

    private func dismiss(remember: Bool) {
        if remember, let key = active?.memoryKey, !key.isEmpty { declined.insert(key) }
        active = nil
        panel.hide()
        keyTap.turnOff()
    }

    private func handleKey(_ key: CoachKeyTap.Key) -> Bool {
        guard var card = active else {
            keyTap.turnOff()
            return false
        }
        switch key {
        case .tab:
            guard let replacement = card.content.acceptText else { return false }
            accept(card, replacement: replacement)
            return true
        case .escape:
            dismiss(remember: true)
            return true
        case let .other(printable):
            card.keysSinceShown += 1
            active = card
            if !printable || card.keysSinceShown >= 2 { dismiss(remember: false) }
            return false
        }
    }

    private func accept(_ card: Active, replacement: String) {
        dismiss(remember: false)
        let appName = host?.coachAppName ?? ""
        Task { [weak self] in
            guard let host = self?.host else { return }
            let ok = await host.coachReplace(range: card.range, with: replacement,
                                             analyzedText: card.analyzedText, harperError: card.harperError)
            if ok { CoachNotebook.shared.record(card.content, app: appName) }
        }
    }

    // MARK: - Text helpers

    private func stillMatches(_ card: Active) -> Bool {
        if case .thinking = card.content { return true }
        let original = substring(Array(card.analyzedText.unicodeScalars), card.range)
        return latestTextStill(has: original, at: card.range)
    }

    private func latestTextStill(has piece: String, at range: Range<Int>) -> Bool {
        let scalars = Array(latestText.unicodeScalars)
        return range.upperBound <= scalars.count && substring(scalars, range) == piece
    }

    private func substring(_ scalars: [Unicode.Scalar], _ range: Range<Int>) -> String {
        let clamped = range.clamped(to: 0 ..< scalars.count)
        return String(String.UnicodeScalarView(scalars[clamped]))
    }

    private static let sentenceEnds: Set<Unicode.Scalar> = [".", "?", "!", "\n", "。", "？", "！"]

    /// From just after the previous sentence end up to `end`.
    private func sentenceRange(endingNear end: Int, in scalars: [Unicode.Scalar]) -> Range<Int> {
        var start = end
        while start > 0, !Self.sentenceEnds.contains(scalars[start - 1]) {
            start -= 1
        }
        while start < end, scalars[start] == " " || scalars[start] == "\t" {
            start += 1
        }
        return start ..< end
    }

    /// The sentence whose . ? ! sits right before the caret (spaces allowed in between).
    private func finishedSentence(before caret: Int, in scalars: [Unicode.Scalar]) -> Range<Int>? {
        var end = caret
        while end > 0, scalars[end - 1] == " " {
            end -= 1
        }
        guard end > 0, [".", "?", "!"].contains(scalars[end - 1]) else { return nil }
        let range = sentenceRange(endingNear: end - 1, in: scalars)
        return range.lowerBound < end - 1 ? range.lowerBound ..< end : nil
    }

    private func lastWordRange(in scalars: [Unicode.Scalar], within range: Range<Int>) -> Range<Int> {
        var end = range.upperBound
        while end > range.lowerBound, !CharacterSet.letters.contains(scalars[end - 1]) {
            end -= 1
        }
        var start = end
        while start > range.lowerBound, CharacterSet.letters.contains(scalars[start - 1]) {
            start -= 1
        }
        return start < end ? start ..< end : range
    }

    private func firstChangeRange(_ check: CoachSentenceCheck, in scalars: [Unicode.Scalar], within range: Range<Int>) -> Range<Int>? {
        let sentence = substring(scalars, range)
        for change in check.changes where !change.from.isEmpty {
            if let found = sentence.range(of: change.from) {
                let start = sentence.unicodeScalars.distance(from: sentence.unicodeScalars.startIndex, to: found.lowerBound)
                let length = change.from.unicodeScalars.count
                return range.lowerBound + start ..< range.lowerBound + start + length
            }
        }
        return nil
    }
}
