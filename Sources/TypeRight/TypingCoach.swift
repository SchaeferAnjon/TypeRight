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
import KeyboardShortcuts

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
    /// A longer pause: a sentence without . ? ! (chat style) is checked as finished.
    private var lingerTimer: Timer?
    private var aiTask: Task<Void, Never>?
    private var waitingPinyin: (range: Range<Int>, word: String)?

    /// Things the user said no to (Esc), so they are not offered again.
    private var declined = Set<String>()
    /// Sentences already sent for a check.
    private var checkedSentences = Set<String>()

    private init() {
        #if DEBUG
            Self.importDevKey()
        #endif
        PinyinDetector.warmUp()
        KeyboardShortcuts.onKeyUp(for: .typeRightTranslate) { [weak self] in self?.translateWholeSentence() }
        keyTap.onKey = { [weak self] key in self?.handleKey(key) ?? false }
        panel.onClickOutside = { [weak self] in
            self?.dismiss(remember: false)
            self?.schedulePauseCheck(after: 0.4)
        }
    }

    #if DEBUG
        /// Development builds can be handed a DeepSeek key through a one-time file
        /// (`open --env TYPERIGHT_DEV_KEY_FILE=…`); the app stores it in its own keychain item and deletes the file.
        private static func importDevKey() {
            guard let path = ProcessInfo.processInfo.environment["TYPERIGHT_DEV_KEY_FILE"],
                  let key = try? String(contentsOfFile: path, encoding: .utf8)
            else { return }
            try? FileManager.default.removeItem(atPath: path)
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            CoachKeychain.setKey(trimmed, for: .deepseek)
            CoachSettings.provider = .deepseek
            Logger.info("TypeRight: development key imported", category: Logger.llm)
        }
    #endif

    // MARK: - Input from the analysis

    /// Called after every analysis of the focused field.
    func analysisDidUpdate(text: String, errors: [GrammarErrorModel]) {
        guard CoachSettings.cardsEnabled, host != nil else { return }
        latestText = text
        latestErrors = errors

        if let active, !stillMatches(active) { dismiss(remember: false) }

        if active == nil, let (error, word) = justFinishedSpellingError(in: text, errors: errors) {
            if CoachSettings.isAIReady, CoachSettings.pinyinEnabled, PinyinDetector.isLikelyPinyin(word) {
                waitingPinyin = (error.start ..< error.end, word)
            } else {
                showSpelling(error, word: word, text: text)
            }
        }

        schedulePauseCheck(after: CoachSettings.pauseSeconds)
    }

    private func schedulePauseCheck(after seconds: Double) {
        pauseTimer?.invalidate()
        lingerTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.userPaused() }
        }
    }

    /// The monitored field went away (focus moved, app switched, monitoring stopped).
    func reset() {
        pauseTimer?.invalidate()
        lingerTimer?.invalidate()
        aiTask?.cancel()
        waitingPinyin = nil
        dismiss(remember: false)
    }

    /// The translate shortcut: the Chinese sentence at the caret becomes English.
    func translateWholeSentence() {
        guard host != nil else { return }
        let text = latestText
        let scalars = Array(text.unicodeScalars)
        let caret = min(host?.coachCaret(in: text) ?? scalars.count, scalars.count)
        var end = caret
        while end > 0, CharacterSet.whitespacesAndNewlines.contains(scalars[end - 1]) {
            end -= 1
        }
        var range = sentenceRange(endingNear: end, in: scalars)
        if range.isEmpty, end > 0 { range = sentenceRange(endingNear: end - 1, in: scalars).lowerBound ..< end }
        guard !range.isEmpty,
              !ChineseText.hanRuns(in: scalars, from: range.lowerBound, to: range.upperBound).isEmpty else { return }
        guard CoachSettings.isAIReady else {
            present(Active(content: .failed("整句翻译要用 AI：先在设置 › AI 服务商里选一家、填 Key。"), range: range,
                           analyzedText: text, harperError: nil, memoryKey: ""))
            return
        }
        dismiss(remember: false)
        translate(fragmentRange: range, sentence: range, scalars: scalars, text: text)
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
        // Chinese is handled by the translate card, never as a misspelling.
        guard !word.unicodeScalars.contains(where: ChineseText.isHan),
              word.unicodeScalars.contains(where: { ("a" ... "z").contains($0) || ("A" ... "Z").contains($0) }),
              !declined.contains(spellingKey(word, error)) else { return nil }
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
        guard active == nil || isThinking else { return }
        let text = latestText
        let scalars = Array(text.unicodeScalars)
        let caret = min(host?.coachCaret(in: text) ?? scalars.count, scalars.count)
        let sentence = sentenceRange(endingNear: caret, in: scalars)

        guard CoachSettings.isAIReady else {
            countWithoutAI(caret: caret, scalars: scalars)
            return
        }

        // Chinese inside an English sentence.
        if CoachSettings.autoTranslateMixed,
           ChineseText.latinWordCount(in: scalars, from: sentence.lowerBound, to: sentence.upperBound) >= 1,
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
            checkIfNew(finished, scalars: scalars, text: text, unfinished: false)
            return
        }

        // No . ? ! yet: chat messages often go out without one, so after a longer pause
        // check what is there as if it were finished.
        lingerTimer?.invalidate()
        lingerTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.userLingered() }
        }
    }

    private func userLingered() {
        guard active == nil, CoachSettings.isAIReady else { return }
        let text = latestText
        let scalars = Array(text.unicodeScalars)
        let caret = min(host?.coachCaret(in: text) ?? scalars.count, scalars.count)
        // Only when the caret sits at the end of what was typed.
        guard scalars[caret...].allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) else { return }
        var range = sentenceRange(endingNear: caret, in: scalars)
        while range.upperBound > range.lowerBound, CharacterSet.whitespaces.contains(scalars[range.upperBound - 1]) {
            range = range.lowerBound ..< range.upperBound - 1
        }
        guard ChineseText.latinWordCount(in: scalars, from: range.lowerBound, to: range.upperBound) >= 4 else { return }
        checkIfNew(range, scalars: scalars, text: text, unfinished: true)
    }

    private func checkIfNew(_ range: Range<Int>, scalars: [Unicode.Scalar], text: String, unfinished: Bool) {
        let key = Self.sentenceKey(substring(scalars, range))
        guard !checkedSentences.contains(key), !declined.contains("sentence:\(key)"),
              ChineseText.hanRuns(in: scalars, from: range.lowerBound, to: range.upperBound).isEmpty,
              ChineseText.latinWordCount(in: scalars, from: range.lowerBound, to: range.upperBound) >= 3
        else { return }
        checkedSentences.insert(key)
        check(sentenceRange: range, scalars: scalars, text: text, unfinished: unfinished)
    }

    /// The same sentence with or without its final . ? ! counts once.
    nonisolated static func sentenceKey(_ sentence: String) -> String {
        sentence.trimmingCharacters(in: CharacterSet(charactersIn: ".?!").union(.whitespacesAndNewlines)).lowercased()
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

    private func check(sentenceRange: Range<Int>, scalars: [Unicode.Scalar], text: String, unfinished: Bool) {
        let sentenceText = substring(scalars, sentenceRange)
        let lastWord = lastWordRange(in: scalars, within: sentenceRange)
        showThinking(at: lastWord, text: text)
        aiTask?.cancel()
        aiTask = Task { [weak self] in
            do {
                let result = try await CoachAI.check(sentence: sentenceText, mayBeUnfinished: unfinished)
                guard let self, !Task.isCancelled else { return }
                let clean = result.ok || result.corrected.isEmpty || result.corrected == sentenceText
                CoachNotebook.shared.noteSentence(clean: clean)
                if clean { CoachNotebook.shared.noteCorrectUse(in: sentenceText) }
                guard !clean,
                      self.latestTextStill(has: sentenceText, at: sentenceRange)
                else {
                    if self.isThinking { self.dismiss(remember: false) }
                    return
                }
                let anchor = self.firstChangeRange(result, in: scalars, within: sentenceRange) ?? lastWord
                var card = Active(content: .sentence(original: sentenceText, check: result), range: sentenceRange,
                                  analyzedText: self.latestText, harperError: nil,
                                  memoryKey: "sentence:\(Self.sentenceKey(sentenceText))")
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
            // Whatever was waiting behind this card (Chinese after a misspelling) comes next.
            schedulePauseCheck(after: 0.4)
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
            if ok {
                let context = Self.context(of: card, after: replacement)
                CoachNotebook.shared.record(card.content, app: appName, context: context)
            }
        }
    }

    /// The sentence around the fix as it reads afterwards.
    private static func context(of card: Active, after replacement: String) -> String {
        if case let .sentence(_, check) = card.content { return check.corrected }
        let scalars = Array(card.analyzedText.unicodeScalars)
        guard card.range.upperBound <= scalars.count else { return "" }
        var start = card.range.lowerBound
        while start > 0, !sentenceEnds.contains(scalars[start - 1]) {
            start -= 1
        }
        var end = card.range.upperBound
        while end < scalars.count, !sentenceEnds.contains(scalars[end]) {
            end += 1
        }
        let before = String(String.UnicodeScalarView(scalars[start ..< card.range.lowerBound]))
        let after = String(String.UnicodeScalarView(scalars[card.range.upperBound ..< end]))
        return (before + replacement + after).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Without an AI the sentence count comes from the spell checker: a finished sentence
    /// it found nothing in counts as right the first time.
    private func countWithoutAI(caret: Int, scalars: [Unicode.Scalar]) {
        guard let finished = finishedSentence(before: caret, in: scalars) else { return }
        let sentenceText = substring(scalars, finished)
        let key = Self.sentenceKey(sentenceText)
        guard !checkedSentences.contains(key),
              ChineseText.latinWordCount(in: scalars, from: finished.lowerBound, to: finished.upperBound) >= 3 else { return }
        checkedSentences.insert(key)
        let clean = !latestErrors.contains { $0.start < finished.upperBound && $0.end > finished.lowerBound }
        CoachNotebook.shared.noteSentence(clean: clean)
        if clean { CoachNotebook.shared.noteCorrectUse(in: sentenceText) }
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
