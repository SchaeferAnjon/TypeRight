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
//  What was offered is remembered per field (app and text field), by text and position: a piece
//  offered once (taken, turned down, typed past, clicked away, or failed) is not offered or sent
//  to the AI again until the text at that spot changes.
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
    /// The field's text read now, the way the analysis reads it (the analysis may lag behind typing).
    func coachReadText() -> String?
    /// Writes `replacement` over `range` of the text the analysis saw, then reads the field back.
    func coachReplace(range: Range<Int>, with replacement: String, analyzedText: String, harperError: GrammarErrorModel?) async -> CoachWriteResult
    /// Name of the app being typed in, for the notebook.
    var coachAppName: String { get }
    var coachAppID: String? { get }
    /// The app and text field being typed in; what the coach remembers belongs to one field.
    var coachFieldID: String? { get }
    /// A field is monitored in an app that is not paused.
    var coachIsWatching: Bool { get }
    /// An input method is composing in the field (marked text not yet committed).
    var coachIsComposing: Bool { get }
}

/// What reading the field back after a write showed.
enum CoachWriteResult: Equatable {
    /// The field reads `text`; the fix sits at `at` in it.
    case written(text: String, at: Range<Int>)
    /// The text did not change (or could not be read back).
    case notWritten
    /// The text changed, but not into the fix (`tomorow tomorrow`).
    case wrongResult
}

/// The AI behind the cards (a fake in unit tests).
struct CoachAIService {
    var status: @MainActor () -> CoachAIStatus
    /// The member plan is blocked: ask the backend again now and then.
    var blocked: @MainActor () -> Void
    var translate: @Sendable (_ fragment: String, _ sentence: String, _ route: CoachAIRoute) async throws -> CoachTranslation
    var check: @Sendable (_ sentence: String, _ mayBeUnfinished: Bool, _ route: CoachAIRoute) async throws -> CoachSentenceCheck

    static let live = CoachAIService(
        status: { MemberService.shared.aiStatus },
        blocked: { MemberService.shared.recheckWhileBlocked() },
        translate: { try await CoachAI.translate(fragment: $0, in: $1, via: $2) },
        check: { try await CoachAI.check(sentence: $0, mayBeUnfinished: $1, via: $2) }
    )
}

/// The settings the coach goes by.
struct CoachBehavior: Equatable {
    var cardsEnabled = true
    var autoTranslateMixed = true
    var pinyinEnabled = true
    var pauseSeconds = 0.8

    static var current: CoachBehavior {
        CoachBehavior(cardsEnabled: CoachSettings.cardsEnabled, autoTranslateMixed: CoachSettings.autoTranslateMixed,
                      pinyinEnabled: CoachSettings.pinyinEnabled, pauseSeconds: CoachSettings.pauseSeconds)
    }
}

protocol CoachTimer: AnyObject {
    func cancel()
}

extension DispatchWorkItem: CoachTimer {}

/// Time for the coach (a fake in unit tests). `now` is system uptime, the clock the key tap uses.
@MainActor
protocol CoachClock: AnyObject {
    var now: TimeInterval { get }
    var secondsSinceLastKey: TimeInterval { get }
    func after(_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> CoachTimer
}

@MainActor
final class CoachSystemClock: CoachClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    var secondsSinceLastKey: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
    }

    func after(_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> CoachTimer {
        let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }
}

/// A piece of text that was offered at a position.
struct CoachMark: Equatable {
    var text: String
    var range: Range<Int>
}

@MainActor
final class TypingCoach {
    static let shared: TypingCoach = {
        let coach = TypingCoach(ai: .live, notebook: .shared, display: CoachCardPanel(), keys: CoachKeyTap(),
                                clock: CoachSystemClock(), behavior: { .current },
                                copy: { text in
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(text, forType: .string)
                                })
        coach.startLive()
        return coach
    }()

    /// A failed card stays this long.
    static let failureSeconds: TimeInterval = 4
    /// A card without keys (no tap, Secure Event Input) stays this long.
    static let readOnlySeconds: TimeInterval = 5
    /// A card that came up while the user was typing, or after a wait for the AI, ignores Tab this long.
    static let tabGrace: TimeInterval = 0.3
    /// Without . ? ! a sentence is checked as finished after this much longer pause.
    static let lingerSeconds: TimeInterval = 1.2
    /// After a card is handled, what waited behind it comes this soon.
    static let nextCardSeconds: TimeInterval = 0.4
    /// Typing this many characters while the "想一下" capsule or a card without keys is up makes it go.
    static let typedAway = 2

    weak var host: TypingCoachHost?

    private let ai: CoachAIService
    private let notebook: CoachNotebook
    private let display: CoachCardDisplay
    private let keys: CoachKeyInput
    private let clock: CoachClock
    private let behavior: () -> CoachBehavior
    private let copy: (String) -> Void

    private struct Card {
        let id = UUID()
        var content: CoachCardContent
        var range: Range<Int>
        /// The text at `range` when the card was made.
        var piece: String
        var analyzedText: String
        var harperError: GrammarErrorModel?
        /// Where the card points when that differs from the range it replaces (sentence cards).
        var anchorOverride: Range<Int>?
        var keys: CoachCardKeys = .normal
        var keysSinceShown = 0

        var isThinking: Bool { content == .thinking }

        var isFailure: Bool {
            if case .failed = content { return true }
            return false
        }
    }

    private struct Request {
        var task: Task<Void, Never>
        /// Where the fragment or sentence sent to the AI is now.
        var range: Range<Int>
    }

    /// What the coach knows about the field being typed in.
    private struct FieldMemory {
        static let limit = 300
        /// Pieces already offered: not again while the text there stays the same.
        var offered: [CoachMark] = []
        /// Ranges TypeRight wrote: a sentence with one of them was not right the first time.
        var fixed: [Range<Int>] = []
        /// Sentences sent for a check or taken from a sentence card.
        var checked = CappedSet<String>(limit: limit)

        func wasOffered(_ mark: CoachMark) -> Bool { offered.contains(mark) }

        mutating func offer(_ mark: CoachMark) {
            offered.append(mark)
            if offered.count > Self.limit { offered.removeFirst(offered.count - Self.limit) }
        }

        mutating func fix(_ range: Range<Int>) {
            fixed.append(range)
            if fixed.count > Self.limit { fixed.removeFirst(fixed.count - Self.limit) }
        }

        func wasFixed(within range: Range<Int>) -> Bool { fixed.contains { $0.overlaps(range) } }

        mutating func apply(_ edit: CoachText.Edit) {
            offered = offered.compactMap { mark in edit.shift(mark.range).map { CoachMark(text: mark.text, range: $0) } }
            fixed = fixed.compactMap { edit.shift($0) }
        }
    }

    private var active: Card?
    /// An AI card that came back while another card was up: it comes once that one is handled.
    private var pending: Card?
    private var request: Request?
    private var latestText = ""
    private var latestErrors: [GrammarErrorModel] = []
    private var fieldID: String?
    private var memory = FieldMemory()
    private var waitingPinyin: CoachMark?
    private var pauseTimer: CoachTimer?
    private var lingerTimer: CoachTimer?
    private var closeTimer: CoachTimer?
    /// Apps where a write came out wrong: there Tab copies the fix instead (until TypeRight quits).
    private var copyOnlyApps = Set<String>()

    /// The latest AI request and Tab write, so tests can wait for them.
    private(set) var aiTask: Task<Void, Never>?
    private(set) var writeTask: Task<Void, Never>?

    init(ai: CoachAIService, notebook: CoachNotebook, display: CoachCardDisplay, keys: CoachKeyInput,
         clock: CoachClock, behavior: @escaping () -> CoachBehavior, copy: @escaping (String) -> Void)
    {
        self.ai = ai
        self.notebook = notebook
        self.display = display
        self.keys = keys
        self.clock = clock
        self.behavior = behavior
        self.copy = copy
        keys.onKey = { [weak self] key, swallowed in self?.keyArrived(key, swallowed: swallowed) }
        display.onClickOutside = { [weak self] in self?.clickedOutside() }
    }

    private func startLive() {
        #if DEBUG
            Self.importDevKey()
        #endif
        PinyinDetector.warmUp()
        MemberService.shared.start()
        UsagePing.shared.start()
        KeyboardShortcuts.onKeyUp(for: .typeRightTranslate) { [weak self] in self?.translateWholeSentence() }
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
            guard !trimmed.isEmpty, CoachKeyStore.shared.save(trimmed, for: .deepseek) else { return }
            CoachSettings.provider = .deepseek
            Logger.info("TypeRight: development key imported", category: Logger.llm)
        }
    #endif

    // MARK: - Input from the analysis

    /// Called after every analysis of the focused field.
    func analysisDidUpdate(text: String, errors: [GrammarErrorModel]) {
        let behavior = behavior()
        guard behavior.cardsEnabled, let host else {
            Logger.trace("TypeRight: analysis ignored (cards \(behavior.cardsEnabled), host \(host != nil))", category: Logger.ui)
            return
        }
        let field = host.coachFieldID
        if field != fieldID {
            forgetField()
            fieldID = field
        }
        take(text)
        latestErrors = errors

        if host.coachIsComposing {
            // An input method is composing: nothing pops up and no key is taken until it commits.
            if let card = active, !card.isThinking { close(.typedOn) }
            return
        }
        if let card = active { recheck(card) }

        if active?.isThinking ?? true, let (error, word) = justFinishedSpellingError(in: text, errors: errors) {
            if behavior.pinyinEnabled, ai.status().isOn,
               PinyinDetector.treatAsPinyin(word, firstSuggestion: error.suggestions.first)
            {
                waitingPinyin = CoachMark(text: word, range: error.start ..< error.end)
            } else {
                showSpelling(error, word: word, text: text)
            }
        }

        schedulePauseCheck(after: behavior.pauseSeconds)
    }

    /// The field went away (focus moved, app switched, monitoring stopped).
    func reset() {
        forgetField()
        fieldID = nil
    }

    private func forgetField() {
        pauseTimer?.cancel()
        lingerTimer?.cancel()
        cancelRequest()
        close(.gone)
        pending = nil
        waitingPinyin = nil
        latestText = ""
        latestErrors = []
        memory = FieldMemory()
    }

    /// The field now reads `text`: everything remembered by position moves with the edit, and
    /// whatever the edit touched is forgotten.
    private func take(_ text: String) {
        guard let edit = CoachText.edit(from: latestText, to: text) else { return }
        latestText = text
        memory.apply(edit)
        if let current = request {
            if let moved = edit.shift(current.range) {
                request?.range = moved
            } else {
                Logger.info("TypeRight: the text sent to the AI was edited, request dropped", category: Logger.llm)
                cancelRequest()
                if active?.isThinking == true { close(.textChanged) }
            }
        }
        if var card = pending {
            if let moved = edit.shift(card.range) {
                card.range = moved
                card.anchorOverride = card.anchorOverride.flatMap { edit.shift($0) }
                pending = card
            } else {
                pending = nil
            }
        }
        if let pinyin = waitingPinyin {
            waitingPinyin = edit.shift(pinyin.range).map { CoachMark(text: pinyin.text, range: $0) }
        }
    }

    /// Whether the card on screen still fits what is typed now.
    private func recheck(_ card: Card) {
        let typed = CoachText.edit(from: card.analyzedText, to: latestText)?.size ?? 0
        if card.isThinking {
            if typed >= Self.typedAway { close(.typedOn) }
            return
        }
        if !card.isFailure, !latestTextStill(has: card.piece, at: card.range) {
            close(.textChanged)
        } else if card.keys == .readOnly, typed >= Self.typedAway {
            close(.typedOn)
        }
    }

    private func schedulePauseCheck(after seconds: Double) {
        pauseTimer?.cancel()
        lingerTimer?.cancel()
        pauseTimer = clock.after(seconds) { [weak self] in self?.userPaused() }
    }

    /// The translate shortcut: the Chinese sentence at the caret becomes English.
    func translateWholeSentence() {
        guard behavior().cardsEnabled, let host, host.coachIsWatching else {
            Logger.info("TypeRight: translate key ignored (cards off, paused or no field)", category: Logger.ui)
            return
        }
        if host.coachFieldID != fieldID {
            forgetField()
            fieldID = host.coachFieldID
        }
        // Some apps are analysed a second after typing stops: read what is there now.
        if let fresh = host.coachReadText() { take(fresh) }
        let scalars = Array(latestText.unicodeScalars)
        let caret = min(host.coachCaret(in: latestText) ?? scalars.count, scalars.count)
        var end = caret
        while end > 0, CharacterSet.whitespacesAndNewlines.contains(scalars[end - 1]) {
            end -= 1
        }
        var range = CoachText.sentenceRange(endingNear: end, in: scalars)
        if range.isEmpty, end > 0 { range = CoachText.sentenceRange(endingNear: end - 1, in: scalars).lowerBound ..< end }
        guard !range.isEmpty,
              !ChineseText.hanRuns(in: scalars, from: range.lowerBound, to: range.upperBound).isEmpty else { return }
        let status = ai.status()
        guard status.isOn else {
            // Trial used up, today's limit and the like: no card until the account page is designed.
            if case let .memberBlocked(state) = status {
                Logger.info("TypeRight: translate shortcut without AI, member \(state)", category: Logger.llm)
                ai.blocked()
                return
            }
            showFailed("整句翻译要用 AI：先在设置 › AI 服务商里选一家、填 Key。", at: range)
            return
        }
        cancelRequest()
        close(.gone)
        pending = nil
        let sentence = CoachText.substring(scalars, range)
        translate(CoachMark(text: sentence, range: range), sentence: sentence)
    }

    // MARK: - Spelling

    private func justFinishedSpellingError(in text: String, errors: [GrammarErrorModel]) -> (GrammarErrorModel, String)? {
        let scalars = Array(text.unicodeScalars)
        let caret = min(host?.coachCaret(in: text) ?? scalars.count, scalars.count)
        let candidates = errors.filter { ($0.category == "Spelling" || $0.category == "Typo") && $0.end <= caret }
        guard let error = candidates.max(by: { $0.end < $1.end }), error.start < error.end, error.end <= scalars.count else { return nil }

        // The word counts as finished when a space or punctuation follows it and at most
        // a few letters of the next word have been typed since.
        let after = scalars[error.end ..< caret]
        guard let first = after.first, CoachText.wordEnds.contains(first), after.count <= 4 else { return nil }

        let word = CoachText.substring(scalars, error.start ..< error.end)
        // Chinese is handled by the translate card, never as a misspelling.
        guard !word.unicodeScalars.contains(where: ChineseText.isHan),
              word.unicodeScalars.contains(where: CoachText.isLatinLetter),
              !memory.wasOffered(CoachMark(text: word, range: error.start ..< error.end)) else { return nil }
        Logger.info("TypeRight: finished misspelling at \(error.start)-\(error.end), caret \(caret), \(error.suggestions.count) suggestions", category: Logger.ui)
        return (error, word)
    }

    private func showSpelling(_ error: GrammarErrorModel, word: String, text: String) {
        guard !error.suggestions.isEmpty else { return }
        let mark = CoachMark(text: word, range: error.start ..< error.end)
        memory.offer(mark)
        present(Card(content: .spelling(wrong: word, fixes: Array(error.suggestions.prefix(4))), range: mark.range,
                     piece: word, analyzedText: text, harperError: error), async: false)
    }

    // MARK: - After a pause: Chinese, pinyin, finished sentences

    private func userPaused() {
        guard let host, active == nil, request == nil, !host.coachIsComposing else { return }
        if let card = pending {
            pending = nil
            if latestTextStill(has: card.piece, at: card.range) {
                present(card, async: true)
                return
            }
        }
        let status = ai.status()
        let text = latestText
        let scalars = Array(text.unicodeScalars)
        let caret = min(host.coachCaret(in: text) ?? scalars.count, scalars.count)
        let sentence = CoachText.sentenceRange(endingNear: caret, in: scalars)
        // With the trial used up, today's limit reached and the like, this line is all there is for now:
        // no AI card until the account page is designed.
        Logger.info("TypeRight: pause check (AI \(status), pinyin waiting \(waitingPinyin != nil))", category: Logger.ui)

        guard status.isOn else {
            if case .memberBlocked = status { ai.blocked() }
            countWithoutAI(caret: caret, scalars: scalars)
            return
        }

        // Chinese inside an English sentence.
        if behavior().autoTranslateMixed, CoachText.shouldAutoTranslate(scalars, in: sentence),
           let run = ChineseText.hanRuns(in: scalars, from: sentence.lowerBound, to: sentence.upperBound)
           .first(where: { !memory.wasOffered(CoachMark(text: CoachText.substring(scalars, $0), range: $0)) })
        {
            translate(CoachMark(text: CoachText.substring(scalars, run), range: run), sentence: CoachText.substring(scalars, sentence))
            return
        }

        // Pinyin the spell checker rejected.
        if let pinyin = waitingPinyin {
            waitingPinyin = nil
            if latestTextStill(has: pinyin.text, at: pinyin.range), !memory.wasOffered(pinyin) {
                translate(pinyin, sentence: CoachText.substring(scalars, sentence))
                return
            }
        }

        // A sentence that was just finished.
        if let finished = CoachText.finishedSentence(before: caret, in: scalars) {
            checkIfNew(finished, scalars: scalars, unfinished: false)
            return
        }

        // No . ? ! yet: chat messages often go out without one, so after a longer pause
        // check what is there as if it were finished.
        lingerTimer?.cancel()
        lingerTimer = clock.after(Self.lingerSeconds) { [weak self] in self?.userLingered() }
    }

    private func userLingered() {
        guard let host, active == nil, request == nil, ai.status().isOn else { return }
        let scalars = Array(latestText.unicodeScalars)
        let caret = min(host.coachCaret(in: latestText) ?? scalars.count, scalars.count)
        // Only when the caret sits at the end of what was typed.
        guard scalars[caret...].allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) else { return }
        var range = CoachText.sentenceRange(endingNear: caret, in: scalars)
        while range.upperBound > range.lowerBound, CharacterSet.whitespaces.contains(scalars[range.upperBound - 1]) {
            range = range.lowerBound ..< range.upperBound - 1
        }
        guard ChineseText.latinWordCount(in: scalars, from: range.lowerBound, to: range.upperBound) >= 4 else { return }
        checkIfNew(range, scalars: scalars, unfinished: true)
    }

    private func checkIfNew(_ range: Range<Int>, scalars: [Unicode.Scalar], unfinished: Bool) {
        let key = Self.sentenceKey(CoachText.substring(scalars, range))
        guard !memory.checked.contains(key),
              ChineseText.hanRuns(in: scalars, from: range.lowerBound, to: range.upperBound).isEmpty,
              ChineseText.latinWordCount(in: scalars, from: range.lowerBound, to: range.upperBound) >= 3
        else { return }
        memory.checked.insert(key)
        check(sentenceRange: range, scalars: scalars, unfinished: unfinished)
    }

    /// The same sentence with or without its final . ? ! counts once.
    nonisolated static func sentenceKey(_ sentence: String) -> String {
        sentence.trimmingCharacters(in: CharacterSet(charactersIn: ".?!").union(.whitespacesAndNewlines)).lowercased()
    }

    /// Where a new card's AI request goes. Through our backend each card is one use: it gets its own
    /// use number, which its retries share.
    private func newCardRoute() -> CoachAIRoute? {
        let status = ai.status()
        guard let route = status.route() else {
            Logger.info("TypeRight: no AI for this card (\(status))", category: Logger.llm)
            return nil
        }
        return route
    }

    /// Asks for the English of a fragment once: the fragment counts as offered from now on, whatever
    /// comes back, so a failure or a closed card never sends the same text again by itself.
    private func translate(_ mark: CoachMark, sentence: String) {
        guard let route = newCardRoute() else { return }
        memory.offer(mark)
        showThinking(at: mark.range)
        let translate = ai.translate
        let task = Task { [weak self] in
            do {
                let result = try await translate(mark.text, sentence, route)
                guard let self, !Task.isCancelled, let range = self.finishRequest() else { return }
                guard self.latestTextStill(has: mark.text, at: range) else {
                    self.dropThinking()
                    return
                }
                self.deliver(Card(content: .translate(source: mark.text, result: result), range: range, piece: mark.text,
                                  analyzedText: self.latestText))
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.requestFailed(error)
            }
        }
        request = Request(task: task, range: mark.range)
        aiTask = task
    }

    private func check(sentenceRange: Range<Int>, scalars: [Unicode.Scalar], unfinished: Bool) {
        guard let route = newCardRoute() else { return }
        let sentenceText = CoachText.substring(scalars, sentenceRange)
        // A sentence TypeRight already changed was not right the first time, whatever the AI says now.
        let assisted = memory.wasFixed(within: sentenceRange)
        showThinking(at: CoachText.lastWordRange(in: scalars, within: sentenceRange))
        let check = ai.check
        let notebook = notebook
        let task = Task { [weak self] in
            do {
                let result = try await check(sentenceText, unfinished, route)
                guard let self, !Task.isCancelled, let range = self.finishRequest() else { return }
                let clean = result.ok || result.corrected.isEmpty || result.corrected == sentenceText
                notebook.noteSentence(clean: clean && !assisted)
                if clean, !assisted { notebook.noteCorrectUse(in: sentenceText) }
                guard !clean, self.latestTextStill(has: sentenceText, at: range) else {
                    self.dropThinking()
                    return
                }
                let now = Array(self.latestText.unicodeScalars)
                let anchor = CoachText.firstChangeRange(result, in: now, within: range) ?? CoachText.lastWordRange(in: now, within: range)
                self.deliver(Card(content: .sentence(original: sentenceText, check: result), range: range, piece: sentenceText,
                                  analyzedText: self.latestText, anchorOverride: anchor))
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.requestFailed(error)
            }
        }
        request = Request(task: task, range: sentenceRange)
        aiTask = task
    }

    /// The request is over; where its text is now.
    private func finishRequest() -> Range<Int>? {
        defer { request = nil }
        return request?.range
    }

    private func cancelRequest() {
        request?.task.cancel()
        request = nil
    }

    private func requestFailed(_ error: Error) {
        let range = finishRequest()
        if case let CoachAIError.member(memberError) = error {
            // Through our backend the trial or membership could not be used (used up, today's limit,
            // offline, device token …). For now that is one info line and no card; the account page is being designed.
            Logger.info("TypeRight: member AI gave no card: \(memberError.kind) (\(memberError.code), HTTP \(memberError.status))", category: Logger.llm)
            dropThinking()
            return
        }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        Logger.warning("TypeRight: AI request failed: \(message)", category: Logger.llm)
        showFailed(message, at: range)
    }

    // MARK: - Showing and taking cards

    private enum CloseReason {
        case accepted, declined, typedOn, clickedOutside, textChanged, timeUp, gone
    }

    private func showThinking(at range: Range<Int>) {
        present(Card(content: .thinking, range: range, piece: CoachText.substring(Array(latestText.unicodeScalars), range),
                     analyzedText: latestText), async: false)
    }

    /// The capsule goes when its request ends without a card.
    private func dropThinking() {
        if active?.isThinking == true { close(.gone) }
    }

    /// A failed card, at the range's place in the current text (or the field's corner).
    private func showFailed(_ message: String, at range: Range<Int>?) {
        let scalars = Array(latestText.unicodeScalars)
        let range = range.flatMap { $0.upperBound <= scalars.count ? $0 : nil } ?? 0 ..< 0
        deliver(Card(content: .failed(message), range: range, piece: CoachText.substring(scalars, range), analyzedText: latestText))
    }

    /// An AI card or a failure: shown now unless another card is up, then it waits for that one.
    private func deliver(_ card: Card) {
        if active?.isThinking ?? true {
            present(card, async: true)
        } else {
            pending = card
        }
    }

    private func present(_ card: Card, async: Bool) {
        guard let host else { return }
        var card = card
        let scalarCount = card.analyzedText.unicodeScalars.count
        let anchorRange = card.anchorOverride ?? card.range
        let wordAnchor = anchorRange.isEmpty || anchorRange.upperBound > scalarCount ? nil : host.coachAnchor(for: anchorRange, in: card.analyzedText)
        guard let anchor = wordAnchor ?? host.coachFallbackAnchor() else {
            Logger.info("TypeRight: no anchor for card, not showing", category: Logger.ui)
            return
        }
        closeTimer?.cancel()
        let interactive = card.isThinking || keys.canIntercept
        if !interactive {
            card.keys = .readOnly
        } else if card.content.acceptText != nil, let app = host.coachAppID, copyOnlyApps.contains(app) {
            card.keys = .copy
        }
        Logger.info("TypeRight: card \(Self.kind(card.content)) at \(Int(anchor.minX)),\(Int(anchor.minY)) \(wordAnchor == nil ? "(fallback)" : "(word)")\(card.keys == .readOnly ? " read-only" : "")", category: Logger.ui)
        active = card
        display.show(card.content, keys: card.keys, anchor: anchor)
        keys.set(policy(for: card, async: async))
        let id = card.id
        if card.isFailure || (card.keys == .readOnly && !card.isThinking) {
            closeTimer = clock.after(card.isFailure ? Self.failureSeconds : Self.readOnlySeconds) { [weak self] in
                guard let self, self.active?.id == id else { return }
                self.close(.timeUp)
                self.schedulePauseCheck(after: Self.nextCardSeconds)
            }
        }
    }

    /// Which keys the card takes. A card that came after a wait, or while the user was still typing,
    /// ignores Tab for a moment: that Tab was meant for the app (next form field, completion).
    /// A failed card takes no key; keys are only watched so typing or Esc closes it.
    private func policy(for card: Card, async: Bool) -> CoachKeyPolicy? {
        if card.isThinking || card.keys == .readOnly { return nil }
        if card.isFailure { return CoachKeyPolicy(tab: false, tabFrom: 0, esc: false) }
        let typing = clock.secondsSinceLastKey < Self.tabGrace
        let tabFrom = async || typing ? clock.now + Self.tabGrace : clock.now
        return CoachKeyPolicy(tab: card.content.acceptText != nil, tabFrom: tabFrom, esc: true)
    }

    private static func kind(_ content: CoachCardContent) -> String {
        switch content {
        case .spelling: "spelling"
        case .translate: "translate"
        case .sentence: "sentence"
        case .thinking: "thinking"
        case .failed: "failed"
        }
    }

    private func close(_ reason: CloseReason) {
        guard let card = active else { return }
        active = nil
        closeTimer?.cancel()
        display.hide()
        keys.set(nil)
        // Closing the capsule ends its request: no card turns up after the user moved on.
        if card.isThinking { cancelRequest() }
        Logger.debug("TypeRight: card \(Self.kind(card.content)) closed (\(reason))", category: Logger.ui)
    }

    /// After Tab, Esc or a click outside: what waited behind the card comes now.
    private func showNext() {
        if let card = pending {
            pending = nil
            if latestTextStill(has: card.piece, at: card.range) {
                var card = card
                card.analyzedText = latestText
                present(card, async: true)
                return
            }
        }
        schedulePauseCheck(after: Self.nextCardSeconds)
    }

    private func clickedOutside() {
        guard active != nil else { return }
        close(.clickedOutside)
        showNext()
    }

    private func keyArrived(_ key: CoachKey, swallowed: Bool) {
        guard var card = active else {
            keys.set(nil)
            return
        }
        switch key {
        case .tab where swallowed:
            accept(card)
        case .escape:
            close(.declined)
            showNext()
        case .other(printable: true):
            card.keysSinceShown += 1
            if card.keysSinceShown >= Self.typedAway {
                close(.typedOn)
            } else {
                active = card
            }
        default:
            // A Tab that went to the app, arrows, return, shortcuts.
            close(.typedOn)
        }
    }

    private func accept(_ card: Card) {
        close(.accepted)
        guard let host, let accepted = card.content.acceptText else { return }
        let replacement: String = if case .translate = card.content {
            CoachText.spaced(accepted, replacing: card.range, in: Array(card.analyzedText.unicodeScalars))
        } else {
            accepted
        }
        let app = host.coachAppID ?? ""
        if card.keys == .copy {
            copy(replacement)
            showFailed("已复制「\(replacement)」：这个 App 里 TypeRight 不直接改字，粘贴替换一下就好。", at: card.range)
            return
        }
        let appName = host.coachAppName
        writeTask = Task { [weak self] in
            let result = await host.coachReplace(range: card.range, with: replacement, analyzedText: card.analyzedText,
                                                 harperError: card.harperError)
            self?.finishWrite(card, replacement: replacement, result: result, app: app, appName: appName)
        }
    }

    private func finishWrite(_ card: Card, replacement: String, result: CoachWriteResult, app: String, appName: String) {
        switch result {
        case let .written(text, at):
            take(text)
            memory.fix(at)
            if case let .sentence(_, check) = card.content { memory.checked.insert(Self.sentenceKey(check.corrected)) }
            notebook.record(card.content, app: appName, context: Self.context(of: card, after: replacement))
            showNext()
        case .notWritten:
            Logger.warning("TypeRight: write-back left the text unchanged in \(app)", category: Logger.analysis)
            showFailed("没改成：这个输入框里的字没变，自己改一下吧。", at: card.range)
        case .wrongResult:
            Logger.warning("TypeRight: write-back gave the wrong text in \(app); Tab copies there from now on", category: Logger.analysis)
            copyOnlyApps.insert(app)
            copy(replacement)
            showFailed("这个 App 里没改对。改法「\(replacement)」已复制，粘贴替换一下；之后在这里按 Tab 只复制，不直接改。", at: nil)
        }
    }

    /// The sentence around the fix as it reads afterwards.
    private static func context(of card: Card, after replacement: String) -> String {
        if case let .sentence(_, check) = card.content { return check.corrected }
        let scalars = Array(card.analyzedText.unicodeScalars)
        guard card.range.upperBound <= scalars.count else { return "" }
        var start = card.range.lowerBound
        while start > 0, !CoachText.sentenceEnds.contains(scalars[start - 1]) {
            start -= 1
        }
        var end = card.range.upperBound
        while end < scalars.count, !CoachText.sentenceEnds.contains(scalars[end]) {
            end += 1
        }
        let before = CoachText.substring(scalars, start ..< card.range.lowerBound)
        let after = CoachText.substring(scalars, card.range.upperBound ..< end)
        return (before + replacement + after).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Without an AI the sentence count comes from the spell checker: a finished sentence
    /// it found nothing in, and TypeRight did not change, counts as right the first time.
    private func countWithoutAI(caret: Int, scalars: [Unicode.Scalar]) {
        guard let finished = CoachText.finishedSentence(before: caret, in: scalars) else { return }
        let sentenceText = CoachText.substring(scalars, finished)
        let key = Self.sentenceKey(sentenceText)
        guard !memory.checked.contains(key),
              ChineseText.latinWordCount(in: scalars, from: finished.lowerBound, to: finished.upperBound) >= 3 else { return }
        memory.checked.insert(key)
        let clean = !latestErrors.contains { $0.start < finished.upperBound && $0.end > finished.lowerBound }
            && !memory.wasFixed(within: finished)
        notebook.noteSentence(clean: clean)
        if clean { notebook.noteCorrectUse(in: sentenceText) }
    }

    // MARK: - Text helpers

    private func latestTextStill(has piece: String, at range: Range<Int>) -> Bool {
        let scalars = Array(latestText.unicodeScalars)
        return range.upperBound <= scalars.count && CoachText.substring(scalars, range) == piece
    }
}
