//
//  TypingCoach.swift
//  TypeRight
//
//  Decides when a card pops up while the user types English:
//  1. a word was just finished and the system spell checker marks it  -> spelling card, at once
//  2. Chinese (or pinyin) inside an English sentence                   -> its English: at once when the
//     user typed on after the Chinese, after a pause when the Chinese is the last thing typed
//  3. a sentence was finished (. ? !)                                  -> whole-sentence check, at once;
//     at a pause, every other sentence typed or edited in this field that is finished and not checked
//  The coach reads every change of the field as it happens (and right after a space or punctuation
//  key, in case the app does not say), not only after the analysis.
//
//  Cards come one at a time, in the order of the text. An AI answer that arrives while the user is
//  typing waits for a short stop, so nothing pops up under the words being typed; answers stream in
//  and the card shows the first useful part. Esc keeps the text, the second character typed makes
//  it step aside, return, an arrow or a delete key closes it; keys that type nothing (function keys,
//  shortcuts, switching the input source, a modifier held on its own) leave it. A spelling card
//  typed past right after the word comes back once at the next stop, unless a sentence card covers
//  its sentence.
//
//  Tab types along (设置 › 快捷键 › 按 Tab, the default): the Chinese or the misspelled word goes,
//  the card stays, and each character the user types right lights up on it; a sentence card goes
//  through its changed words one by one. Tab again fills in the rest (so Tab Tab is the old
//  replace), Esc or Backspace at the start puts the original back, return, an arrow, a click or
//  another field ends it and keeps what was typed. Set to 直接换, Tab writes the fix at once.
//
//  What was offered is remembered per field (app and text field), by text and position: a piece
//  offered (taken, turned down, clicked away, failed, or typed past after a stop) is not offered or
//  sent to the AI again until the text at that spot changes. Only what the user typed or edited
//  since the field got focus is looked at.
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
    /// The field's text read now, the way the analysis reads it.
    func coachReadText() -> String?
    /// Writes `replacement` over `range` of the text the card was made for, then reads the field back.
    func coachReplace(range: Range<Int>, with replacement: String, analyzedText: String) async -> CoachWriteResult
    /// The misspelled part of `word` and what to write instead, when the system spell checker marks it
    /// (the red underline the user sees) and none of the word lists TypeRight goes by knows it.
    func coachMisspelling(in word: String) -> CoachMisspelling?
    /// Name of the app being typed in, for the notebook.
    var coachAppName: String { get }
    var coachAppID: String? { get }
    /// The app and text field being typed in; what the coach remembers belongs to one field.
    var coachFieldID: String? { get }
    /// A field is monitored in an app that is not paused.
    var coachIsWatching: Bool { get }
    /// An input method is composing in the field (marked text not yet committed).
    var coachIsComposing: Bool { get }
    /// Reading the field right after a key does not slow this app down.
    var coachReadsOnKeys: Bool { get }
    /// The caret can be put somewhere in the field (a sentence card is typed along only then).
    var coachCanMoveCaret: Bool { get }
    /// Puts the caret at a scalar offset of `text`; false when the app did not take it.
    func coachSetCaret(_ offset: Int, in text: String) -> Bool
}

struct CoachMisspelling: Equatable {
    /// Scalar offsets inside the word that was asked about.
    var range: Range<Int>
    var guesses: [String]
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

/// The AI behind the cards (a fake in unit tests). `partial` gets each more complete version of the answer.
struct CoachAIService {
    var status: @MainActor () -> CoachAIStatus
    /// The member plan is blocked: ask the backend again now and then.
    var blocked: @MainActor () -> Void
    /// The user is typing: open the connection the next request will use.
    var warm: @MainActor () -> Void
    var translate: @Sendable (_ fragment: String, _ sentence: String, _ route: CoachAIRoute,
                              _ partial: @escaping CoachAI.Partial<CoachTranslation>) async throws -> CoachTranslation
    var check: @Sendable (_ sentence: String, _ mayBeUnfinished: Bool, _ route: CoachAIRoute,
                          _ partial: @escaping CoachAI.Partial<CoachSentenceCheck>) async throws -> CoachSentenceCheck

    static let live = CoachAIService(
        status: { MemberService.shared.aiStatus },
        blocked: { MemberService.shared.recheckWhileBlocked() },
        warm: {
            switch MemberService.shared.aiStatus {
            case let .own(provider): if let url = URL(string: provider.endpoint) { CoachNet.warm(url) }
            case .member: if let api = MemberAPI.current { CoachNet.warm(api) }
            case .localOnly, .noKey, .memberBlocked: break
            }
        },
        translate: { try await CoachAI.translate(fragment: $0, in: $1, via: $2, partial: $3) },
        check: { try await CoachAI.check(sentence: $0, mayBeUnfinished: $1, via: $2, partial: $3) }
    )
}

/// The settings the coach goes by.
struct CoachBehavior: Equatable {
    var cardsEnabled = true
    var autoTranslateMixed = true
    var pinyinEnabled = true
    var pauseSeconds = 0.5
    /// Tab types along first (false: Tab replaces at once).
    var tabFollows = true
    var allWordsKey = CoachHeldKey.option

    static var current: CoachBehavior {
        CoachBehavior(cardsEnabled: CoachSettings.cardsEnabled, autoTranslateMixed: CoachSettings.autoTranslateMixed,
                      pinyinEnabled: CoachSettings.pinyinEnabled, pauseSeconds: CoachSettings.pauseSeconds,
                      tabFollows: CoachSettings.tabFollows, allWordsKey: CoachSettings.allWordsKey)
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
    static let lingerSeconds: TimeInterval = 0.8
    /// Typing this many characters while the "想一下" capsule or a card without keys is up makes it go.
    static let typedAway = 2
    /// The user stopped this long: answers that waited come now, one at a time.
    static let settleSeconds: TimeInterval = 0.35
    /// The user stopped this long after typing a period at the end: it ends a sentence (and is not
    /// the dot of `README.md` still being typed), and the "想一下" capsule may show.
    static let quickSeconds: TimeInterval = 0.2
    /// At most this many AI requests at the same time; the others wait their turn.
    static let maxRequests = 2
    /// An insertion up to this long counts as typing; a longer one (a paste) only touches its last sentence.
    static let typedChunk = 16
    /// After a space or punctuation key, the field is read at these delays until the change shows,
    /// so a card does not wait on an app that is slow to say its text changed.
    static let keyReadDelays: [TimeInterval] = [0.015, 0.045, 0.12]
    /// A card typed along to the end says what was recorded this long.
    static let doneSeconds: TimeInterval = 1.6
    /// The modifier for the card's word list is held alone this long before the list shows.
    static let holdSeconds: TimeInterval = 0.4

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
        /// Where the card points when that differs from the range it replaces (sentence cards).
        var anchorOverride: Range<Int>?
        var keys: CoachCardKeys = .normal
        var keysSinceShown = 0
        /// The AI request whose answer this is; the card fills in as the answer streams.
        var job: UUID?
        /// A spelling card shown right after its word: typed past, it comes back once at the next stop.
        var whileTyping = false
        /// When the change that led to the card was seen, and how long before that the key was pressed.
        var seenAt: TimeInterval?
        var keyLatency: TimeInterval?
        /// When its AI request was asked for and sent (for the timing line).
        var askedAt: TimeInterval?
        var sentAt: TimeInterval?
        /// A check of a sentence without . ? ! (it stays as long as its text does).
        var unfinished = false

        var isThinking: Bool { content == .thinking }

        var isFailure: Bool {
            if case .failed = content { return true }
            return false
        }

        var isSentence: Bool {
            if case .sentence = content { return true }
            return false
        }
    }

    /// An AI request, waiting for its turn or running.
    private struct Job {
        enum Kind {
            case translate(fragment: String, sentence: String)
            case check(sentence: String, unfinished: Bool, assisted: Bool)
        }

        let id = UUID()
        var kind: Kind
        /// Where the fragment or sentence sent to the AI is now.
        var range: Range<Int>
        var piece: String
        /// Where "想一下" points.
        var capsuleAt: Range<Int>
        var task: Task<Void, Never>?
        var queuedAt: TimeInterval
        var startedAt: TimeInterval?
        var firstContentAt: TimeInterval?
        /// Its "想一下" was typed past: it stays away; the answer waits for a stop.
        var capsuleTypedAway = false
        /// Asked for with the translate key: the capsule and the card come at once.
        var explicit = false
        var gotCard = false

        var isCheck: Bool {
            if case .check = kind { return true }
            return false
        }

        var isUnfinishedCheck: Bool {
            if case let .check(_, unfinished, _) = kind { return unfinished }
            return false
        }
    }

    /// A misspelling that got no card of its own yet (the user typed on, another card was up), or
    /// whose card was typed past right after the word.
    private struct Skipped {
        var mark: CoachMark
        var fixes: [String]
    }

    /// What the coach knows about the field being typed in.
    private struct FieldMemory {
        static let limit = 300
        /// Pieces already offered: not again while the text there stays the same.
        var offered: [CoachMark] = []
        /// Ranges TypeRight wrote: a sentence with one of them was not right the first time.
        var fixed: [Range<Int>] = []
        /// Sentences sent for a check, counted without AI, or taken from a sentence card.
        var checked = CappedSet<String>(limit: limit)
        /// What the user typed or edited since the field got focus; text that was there before is left alone.
        var touched: [Range<Int>] = []

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

        func isTouched(_ range: Range<Int>) -> Bool { touched.contains { $0.overlaps(range) } }

        mutating func apply(_ edit: CoachText.Edit, typed: Bool) {
            offered = offered.compactMap { mark in edit.shift(mark.range).map { CoachMark(text: mark.text, range: $0) } }
            fixed = fixed.compactMap { edit.shift($0) }
            // A paste touches only where it ends, so a pasted page is not checked sentence by sentence.
            let end = edit.start + edit.inserted
            var region = typed || edit.inserted == 0 ? edit.start ..< max(end, edit.start + 1) : max(end - 1, edit.start) ..< max(end, edit.start + 1)
            var kept: [Range<Int>] = []
            let delta = edit.inserted - edit.removed
            for range in touched {
                if let moved = edit.shift(range) {
                    kept.append(moved)
                } else if typed {
                    // Touched before and edited now: the whole stretch stays touched.
                    region = min(region.lowerBound, range.lowerBound) ..< max(region.upperBound, range.upperBound + delta)
                }
            }
            kept.append(region)
            kept.sort { $0.lowerBound < $1.lowerBound }
            var merged: [Range<Int>] = []
            for range in kept {
                if let last = merged.last, range.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
                } else {
                    merged.append(range)
                }
            }
            touched = Array(merged.suffix(Self.limit))
        }
    }

    /// Typing along with the card on screen.
    private struct Follow {
        enum Phase: Equatable {
            /// TypeRight is writing into the field (taking the original out, filling in, putting it back).
            case writing
            case typing
            /// Recorded; the card says so for a moment.
            case done
        }

        /// What a key asked for while the write that starts typing along was under way.
        enum Asked { case fill, putBack }

        var card: Card
        var phase = Phase.writing
        /// The English to type: one for a translation or spelling card, each changed word of a sentence card.
        var steps: [CoachText.Placement]
        var step = 0
        /// The field reads `before` + what was typed + `after` while the user types along.
        var before: [Unicode.Scalar] = []
        var after: [Unicode.Scalar] = []
        var typed: [Unicode.Scalar] = []
        var composing = false
        /// The stretch TypeRight works in lies between `head` scalars at the start of the field and
        /// `tail` at its end: Esc writes `original` over it, Tab writes `filled` over it.
        var head: Int
        var tail: Int
        var original: String
        var filled: String
        /// A space TypeRight puts before or after the English (`to预约a` → `to book a`).
        var lead = ""
        var trail = ""
        /// Where the caret was when Tab was pressed, counted from the end of the field: it goes back there.
        var caretFromEnd: Int
        /// Where the card sits (the line being typed on).
        var anchor: CGRect?
        var asked: Asked?
        /// Finished with Tab rather than typed to the end.
        var filledIn = false

        var target: String { steps.indices.contains(step) ? steps[step].to : "" }

        var isSentence: Bool { card.isSentence }

        /// How much of the target was typed right, and where it went wrong.
        func progress() -> (right: Int, wrongAt: Int?) {
            let goal = Array(target.unicodeScalars)
            let typed = typed.map { $0 == "\u{00A0}" ? " " : $0 }
            var right = 0
            while right < typed.count, right < goal.count, typed[right] == goal[right] {
                right += 1
            }
            return (right, right < typed.count ? right : nil)
        }
    }

    private var follow: Follow?
    private var heldTimer: CoachTimer?
    private var allWordsShown = false

    private var active: Card?
    /// Cards that came while another card was up or the user was typing, in the order of the text.
    private var pending: [Card] = []
    private var jobs: [Job] = []
    private var skipped: [Skipped] = []
    private var latestText = ""
    /// The last texts the field read, to tell an analysis of an older text from one of a newer text.
    private var recentTexts: [String] = []
    /// The text the next change starts from is what the field had when it got focus.
    private var awaitingFirstText = true
    private var latestAnalysis: (text: String, errors: [GrammarErrorModel])?
    private var fieldID: String?
    private var memory = FieldMemory()
    private var waitingPinyin: CoachMark?
    /// A sentence ended by a period at the very end: checked once something follows or the user stops.
    private var unconfirmed: [Range<Int>] = []
    private var lastChangeAt: TimeInterval = -.infinity
    private var quickTimer: CoachTimer?
    private var settleTimer: CoachTimer?
    private var pauseTimer: CoachTimer?
    private var lingerTimer: CoachTimer?
    private var closeTimer: CoachTimer?
    private var keyReads: [CoachTimer] = []
    private var keyWatch: Any?
    /// Apps where a write came out wrong: there Tab copies the fix instead (until TypeRight quits).
    private var copyOnlyApps = Set<String>()

    /// The latest Tab write, so tests can wait for it.
    private(set) var writeTask: Task<Void, Never>?

    /// Every AI request now running (tests wait for them).
    var runningAI: [Task<Void, Never>] { jobs.compactMap(\.task) }

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
        CoachDictionary.shared.warmUp()
        MemberService.shared.start()
        UsagePing.shared.start()
        KeyboardShortcuts.onKeyUp(for: .typeRightTranslate) { [weak self] in self?.translateWholeSentence() }
        // Only whether a key ends a word is looked at; no key is kept. Secure Event Input (password
        // fields) sends nothing here.
        keyWatch = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let ends = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
                && (event.characters?.unicodeScalars.first.map { CoachText.wordEnds.contains($0) } ?? false)
            guard ends else { return }
            MainActor.assumeIsolated { self?.wordEndKeyPressed() }
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
            guard !trimmed.isEmpty, CoachKeyStore.shared.save(trimmed, for: .deepseek) else { return }
            CoachSettings.provider = .deepseek
            Logger.info("TypeRight: development key imported", category: Logger.llm)
        }
    #endif

    // MARK: - Input

    /// Where a change of the field was seen.
    enum ChangeSource: String {
        /// The app said its text changed.
        case app
        /// Read right after a space or punctuation key.
        case key
        /// Came with an analysis no change had announced.
        case analysis
    }

    /// The field reads `text` now. Called on every change the app reports, before the analysis.
    func textDidChange(_ text: String, source: ChangeSource = .app) {
        let behavior = behavior()
        guard behavior.cardsEnabled, let host else { return }
        let seenAt = clock.now
        let keyLatency = clock.secondsSinceLastKey
        if host.coachFieldID != fieldID {
            forgetField()
            fieldID = host.coachFieldID
        }
        if awaitingFirstText {
            awaitingFirstText = false
            latestText = text
            remember(text)
            return
        }
        guard let edit = take(text) else { return }
        remember(text)
        lastChangeAt = seenAt
        cancelKeyReads()
        if ai.status().isOn { ai.warm() }

        if follow?.phase == .done {
            // Typing on after the end: the card goes, and the text is looked at as usual.
            close(.typedOn)
        }
        if follow != nil {
            followTextChanged(text)
            return
        }
        if host.coachIsComposing {
            // An input method is composing: nothing pops up and no key is taken until it commits.
            if let card = active, !card.isThinking { close(.typedOn) }
            scheduleTimers(behavior)
            return
        }
        if let card = active { recheck(card) }
        let scalars = Array(text.unicodeScalars)
        spelling(after: edit, in: scalars, behavior: behavior, seenAt: seenAt, keyLatency: keyLatency, source: source)
        aiTriggers(after: edit, in: scalars, behavior: behavior)
        scheduleTimers(behavior)
    }

    /// Called after every analysis of the focused field.
    func analysisDidUpdate(text: String, errors: [GrammarErrorModel]) {
        guard behavior().cardsEnabled, let host else {
            Logger.trace("TypeRight: analysis ignored (cards off or no host)", category: Logger.ui)
            return
        }
        if host.coachFieldID != fieldID || (text != latestText && !recentTexts.contains(text)) {
            textDidChange(text, source: .analysis)
        }
        latestAnalysis = (text, errors)
        guard follow == nil, text == latestText, let card = active, case .spelling = card.content else { return }
        // The analysis found nothing at the word the system spell checker marked (code, a link, a word
        // the app's own rules allow): the card goes and does not come back.
        let flagged = errors.contains { ($0.category == "Spelling" || $0.category == "Typo") && $0.start < card.range.upperBound && $0.end > card.range.lowerBound }
        if !flagged {
            Logger.info("TypeRight: the analysis does not flag \(card.range), spelling card withdrawn", category: Logger.ui)
            close(.textChanged)
        }
    }

    /// A space or punctuation key went down somewhere: read the field shortly, in case the app is
    /// late to say (or never says) its text changed.
    func wordEndKeyPressed() {
        guard behavior().cardsEnabled, let host, host.coachIsWatching else { return }
        readSoon()
    }

    /// Reads the field shortly after a key (an app may be late to say its text changed).
    private func readSoon() {
        guard let host, host.coachReadsOnKeys else { return }
        cancelKeyReads()
        let before = latestText
        keyReads = Self.keyReadDelays.map { delay in
            clock.after(delay) { [weak self] in self?.readAfterKey(since: before) }
        }
    }

    private func readAfterKey(since before: String) {
        // A change the app reported got here first.
        guard latestText == before, let host, let text = host.coachReadText(), text != before else { return }
        cancelKeyReads()
        textDidChange(text, source: .key)
    }

    private func cancelKeyReads() {
        keyReads.forEach { $0.cancel() }
        keyReads = []
    }

    /// The field went away (focus moved, app switched, monitoring stopped).
    func reset() {
        forgetField()
        fieldID = nil
    }

    private func forgetField() {
        // Typing along ends with the field, and nothing more is written into it.
        follow = nil
        quickTimer?.cancel()
        settleTimer?.cancel()
        pauseTimer?.cancel()
        lingerTimer?.cancel()
        cancelKeyReads()
        for job in jobs {
            job.task?.cancel()
        }
        jobs = []
        close(.gone)
        pending = []
        skipped = []
        waitingPinyin = nil
        unconfirmed = []
        latestText = ""
        recentTexts = []
        latestAnalysis = nil
        awaitingFirstText = true
        memory = FieldMemory()
    }

    private func remember(_ text: String) {
        recentTexts.append(text)
        if recentTexts.count > 12 { recentTexts.removeFirst(recentTexts.count - 12) }
    }

    /// The field now reads `text`: everything remembered by position moves with the edit, and
    /// whatever the edit touched is forgotten. Nil when nothing changed.
    private func take(_ text: String) -> CoachText.Edit? {
        guard let edit = CoachText.edit(from: latestText, to: text) else { return nil }
        latestText = text
        memory.apply(edit, typed: edit.inserted <= Self.typedChunk)
        // A finished sentence stays one while its . ? ! still ends a sentence (not `README.` + `md`).
        let scalars = Array(text.unicodeScalars)
        let ends = Set(CoachText.sentences(in: scalars).filter(\.finished).map(\.range.upperBound))
        for job in jobs {
            guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { continue }
            if let moved = edit.shift(job.range), !job.isCheck || job.isUnfinishedCheck || ends.contains(moved.upperBound) {
                jobs[index].range = moved
                jobs[index].capsuleAt = edit.shift(job.capsuleAt) ?? moved
            } else {
                Logger.info("TypeRight: the text sent to the AI was edited, request dropped", category: Logger.llm)
                cancel(job.id)
            }
        }
        pending = pending.compactMap { card in
            guard let moved = edit.shift(card.range) else { return nil }
            if card.isSentence, !card.unfinished, !ends.contains(moved.upperBound) { return nil }
            var card = card
            card.range = moved
            card.anchorOverride = card.anchorOverride.flatMap { edit.shift($0) }
            return card
        }
        skipped = skipped.compactMap { item in
            edit.shift(item.mark.range).map { Skipped(mark: CoachMark(text: item.mark.text, range: $0), fixes: item.fixes) }
        }
        if let pinyin = waitingPinyin {
            waitingPinyin = edit.shift(pinyin.range).map { CoachMark(text: pinyin.text, range: $0) }
        }
        unconfirmed = unconfirmed.compactMap { edit.shift($0) }
        return edit
    }

    private func jobFor(_ id: UUID) -> Job? { jobs.first { $0.id == id } }

    /// Whether the card on screen still fits what is typed now.
    private func recheck(_ card: Card) {
        let typed = CoachText.edit(from: card.analyzedText, to: latestText)?.size ?? 0
        if card.isThinking {
            if typed >= Self.typedAway {
                // The request goes on; its answer waits for the user to stop.
                if let job = card.job, let index = jobs.firstIndex(where: { $0.id == job }) { jobs[index].capsuleTypedAway = true }
                close(.typedOn)
            }
            return
        }
        if !card.isFailure, !latestTextStill(has: card.piece, at: card.range) {
            close(.textChanged)
        } else if card.keys == .readOnly, typed >= Self.typedAway {
            close(.typedOn)
        }
    }

    private func scheduleTimers(_ behavior: CoachBehavior) {
        quickTimer?.cancel()
        settleTimer?.cancel()
        pauseTimer?.cancel()
        lingerTimer?.cancel()
        quickTimer = clock.after(Self.quickSeconds) { [weak self] in self?.userStoppedBriefly() }
        settleTimer = clock.after(Self.settleSeconds) { [weak self] in self?.showNext() }
        pauseTimer = clock.after(behavior.pauseSeconds) { [weak self] in self?.userPaused() }
    }

    private var userIsTyping: Bool {
        clock.now - lastChangeAt < Self.settleSeconds || clock.secondsSinceLastKey < Self.settleSeconds
    }

    /// The translate shortcut: the Chinese sentence at the caret becomes English.
    func translateWholeSentence() {
        guard behavior().cardsEnabled, let host, host.coachIsWatching, follow == nil else {
            Logger.info("TypeRight: translate key ignored (cards off, paused, no field or typing along)", category: Logger.ui)
            return
        }
        if host.coachFieldID != fieldID {
            forgetField()
            fieldID = host.coachFieldID
        }
        // Some apps say late that their text changed: read what is there now.
        if let fresh = host.coachReadText() {
            if awaitingFirstText {
                awaitingFirstText = false
                latestText = fresh
            } else {
                _ = take(fresh)
            }
        }
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
        close(.gone)
        let sentence = CoachText.substring(scalars, range)
        translate(CoachMark(text: sentence, range: range), sentence: sentence, explicit: true)
    }

    // MARK: - Spelling

    /// Checks the words this edit finished with the system spell checker. The word next to the caret
    /// gets its card now; others (several finished at once, or another card up) wait for the next stop.
    private func spelling(after edit: CoachText.Edit, in scalars: [Unicode.Scalar], behavior: CoachBehavior,
                          seenAt: TimeInterval, keyLatency: TimeInterval, source: ChangeSource)
    {
        guard edit.inserted > 0, edit.inserted <= Self.typedChunk, follow == nil, let host else { return }
        var found: [(mark: CoachMark, fixes: [String])] = []
        for range in CoachText.finishedWords(in: scalars, by: edit) {
            let word = CoachText.substring(scalars, range)
            guard !memory.wasOffered(CoachMark(text: word, range: range)), let miss = host.coachMisspelling(in: word) else { continue }
            let wrongRange = range.lowerBound + miss.range.lowerBound ..< range.lowerBound + miss.range.upperBound
            let mark = CoachMark(text: CoachText.substring(scalars, wrongRange), range: wrongRange)
            guard !memory.wasOffered(mark), !skipped.contains(where: { $0.mark == mark }) else { continue }
            if behavior.pinyinEnabled, ai.status().isOn, PinyinDetector.treatAsPinyin(mark.text, firstSuggestion: miss.guesses.first) {
                waitingPinyin = mark
                continue
            }
            guard !miss.guesses.isEmpty else { continue }
            found.append((mark, Array(miss.guesses.prefix(4))))
        }
        guard let last = found.last else { return }
        skipped += found.dropLast().map { Skipped(mark: $0.mark, fixes: $0.fixes) }
        guard active?.isThinking ?? true else {
            skipped.append(Skipped(mark: last.mark, fixes: last.fixes))
            return
        }
        Logger.info("TypeRight: finished misspelling at \(last.mark.range.lowerBound)-\(last.mark.range.upperBound) (\(source.rawValue)), \(last.fixes.count) suggestions", category: Logger.ui)
        memory.offer(last.mark)
        var card = Card(content: .spelling(wrong: last.mark.text, fixes: last.fixes), range: last.mark.range, piece: last.mark.text,
                        analyzedText: latestText, whileTyping: true)
        card.seenAt = seenAt
        card.keyLatency = keyLatency
        present(card, async: false)
    }

    // MARK: - AI: when to ask

    /// What this edit ended: a sentence (its . ? ! or the character right after it was typed) or a
    /// Chinese run (something was typed right after it). Those go to the AI now.
    private func aiTriggers(after edit: CoachText.Edit, in scalars: [Unicode.Scalar], behavior: CoachBehavior) {
        guard ai.status().isOn, follow == nil else { return }
        let typedEnd = edit.start + edit.inserted
        let sentences = CoachText.sentences(in: scalars)
        if behavior.autoTranslateMixed, edit.inserted > 0 {
            for sentence in sentences where memory.isTouched(sentence.range) && CoachText.shouldAutoTranslate(scalars, in: sentence.range) {
                for run in ChineseText.hanRuns(in: scalars, from: sentence.range.lowerBound, to: sentence.range.upperBound)
                    where run.upperBound < scalars.count && run.upperBound >= edit.start && run.upperBound < typedEnd
                {
                    translate(CoachMark(text: CoachText.substring(scalars, run), range: run), sentence: CoachText.substring(scalars, sentence.range))
                }
            }
        }
        for sentence in sentences where sentence.finished {
            let tail = Self.terminatorStart(of: sentence.range, in: scalars)
            guard edit.start <= sentence.range.upperBound, typedEnd >= tail else { continue }
            if sentence.range.upperBound == scalars.count, scalars[sentence.range.upperBound - 1] == "." {
                if !unconfirmed.contains(sentence.range) { unconfirmed.append(sentence.range) }
            } else {
                check(sentence.range, scalars: scalars, unfinished: false)
            }
        }
    }

    /// Where the . ? ! (and closing quotes) at the end of a sentence start.
    private static func terminatorStart(of range: Range<Int>, in scalars: [Unicode.Scalar]) -> Int {
        var start = range.upperBound
        while start > range.lowerBound, CoachText.terminators.contains(scalars[start - 1]) || CoachText.closers.contains(scalars[start - 1]) {
            start -= 1
        }
        return start
    }

    /// The user stopped for a moment: a period at the end ends its sentence; "想一下" may show.
    private func userStoppedBriefly() {
        guard let host, !host.coachIsComposing, follow == nil else { return }
        let scalars = Array(latestText.unicodeScalars)
        let finished = Set(CoachText.sentences(in: scalars).filter(\.finished).map(\.range))
        let confirmed = unconfirmed.filter { finished.contains($0) }
        unconfirmed = []
        if ai.status().isOn {
            for range in confirmed {
                check(range, scalars: scalars, unfinished: false)
            }
        }
        if active == nil { showCapsule() }
    }

    /// After a pause: Chinese at the end, pinyin, and every finished sentence typed or edited here
    /// that was not checked yet; the sentence at the caret without . ? ! after a longer one.
    private func userPaused() {
        guard let host, !host.coachIsComposing, follow == nil else { return }
        let status = ai.status()
        let text = latestText
        let scalars = Array(text.unicodeScalars)
        let caret = min(host.coachCaret(in: text) ?? scalars.count, scalars.count)
        let sentences = CoachText.sentences(in: scalars)
        unconfirmed = []
        Logger.info("TypeRight: pause check (AI \(status), pinyin waiting \(waitingPinyin != nil), \(jobs.count) requests, \(pending.count) waiting)", category: Logger.ui)

        guard status.isOn else {
            // With the trial used up, today's limit reached and the like, this line is all there is
            // for now: no AI card until the account page is designed.
            if case .memberBlocked = status { ai.blocked() }
            countWithoutAI(sentences, scalars: scalars)
            showNext()
            return
        }

        if behavior().autoTranslateMixed {
            for sentence in sentences where memory.isTouched(sentence.range) && CoachText.shouldAutoTranslate(scalars, in: sentence.range) {
                for run in ChineseText.hanRuns(in: scalars, from: sentence.range.lowerBound, to: sentence.range.upperBound) {
                    translate(CoachMark(text: CoachText.substring(scalars, run), range: run), sentence: CoachText.substring(scalars, sentence.range))
                }
            }
        }
        if let pinyin = waitingPinyin {
            waitingPinyin = nil
            if latestTextStill(has: pinyin.text, at: pinyin.range) {
                let sentence = CoachText.sentence(at: pinyin.range.lowerBound, in: sentences)?.range ?? pinyin.range
                translate(pinyin, sentence: CoachText.substring(scalars, sentence))
            }
        }
        for sentence in sentences where sentence.finished {
            check(sentence.range, scalars: scalars, unfinished: false)
        }
        // No . ? ! yet: chat messages often go out without one, so after a longer pause check what
        // is there as if it were finished.
        if let last = CoachText.sentence(at: caret, in: sentences), !last.finished {
            lingerTimer?.cancel()
            lingerTimer = clock.after(Self.lingerSeconds) { [weak self] in self?.userLingered() }
        }
        showNext()
    }

    private func userLingered() {
        // A card is up: the sentence waits until the user is done with it and stops again.
        guard let host, ai.status().isOn, active?.isThinking ?? true, follow == nil else { return }
        let scalars = Array(latestText.unicodeScalars)
        let caret = min(host.coachCaret(in: latestText) ?? scalars.count, scalars.count)
        // Only when the caret sits at the end of what was typed.
        guard scalars[caret...].allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }),
              let sentence = CoachText.sentence(at: caret, in: CoachText.sentences(in: scalars)), !sentence.finished,
              ChineseText.latinWordCount(in: scalars, from: sentence.range.lowerBound, to: sentence.range.upperBound) >= 4 else { return }
        check(sentence.range, scalars: scalars, unfinished: true)
    }

    /// The same sentence with or without its final . ? ! counts once.
    nonisolated static func sentenceKey(_ sentence: String) -> String {
        sentence.trimmingCharacters(in: CharacterSet(charactersIn: ".?!").union(.whitespacesAndNewlines)).lowercased()
    }

    /// Sends a sentence the user typed or edited here for a check, once per text.
    private func check(_ range: Range<Int>, scalars: [Unicode.Scalar], unfinished: Bool) {
        let sentence = CoachText.substring(scalars, range)
        let key = Self.sentenceKey(sentence)
        guard memory.isTouched(range), !memory.checked.contains(key),
              ChineseText.hanRuns(in: scalars, from: range.lowerBound, to: range.upperBound).isEmpty,
              ChineseText.latinWordCount(in: scalars, from: range.lowerBound, to: range.upperBound) >= 3
        else { return }
        memory.checked.insert(key)
        // A sentence TypeRight already changed was not right the first time, whatever the AI says now.
        let assisted = memory.wasFixed(within: range)
        enqueue(Job(kind: .check(sentence: sentence, unfinished: unfinished, assisted: assisted), range: range, piece: sentence,
                    capsuleAt: CoachText.lastWordRange(in: scalars, within: range), queuedAt: clock.now))
    }

    /// Asks for the English of a fragment once: the fragment counts as offered from now on, whatever
    /// comes back, so a failure or a closed card never sends the same text again by itself.
    private func translate(_ mark: CoachMark, sentence: String, explicit: Bool = false) {
        guard !memory.wasOffered(mark) else { return }
        memory.offer(mark)
        var job = Job(kind: .translate(fragment: mark.text, sentence: sentence), range: mark.range, piece: mark.text,
                      capsuleAt: mark.range, queuedAt: clock.now)
        job.explicit = explicit
        enqueue(job)
    }

    // MARK: - AI: requests

    private func enqueue(_ job: Job) {
        jobs.append(job)
        if job.explicit { present(Card(content: .thinking, range: job.capsuleAt, piece: job.piece, analyzedText: latestText, job: job.id), async: false) }
        startWaitingJobs()
        // Asked for after a pause (a sentence without . ? !): "想一下" at once, not at the next change.
        if active == nil, !userIsTyping { showCapsule() }
    }

    private func startWaitingJobs() {
        while jobs.count(where: { $0.task != nil }) < Self.maxRequests, let index = jobs.firstIndex(where: { $0.task == nil }) {
            start(at: index)
        }
    }

    /// Where a new card's AI request goes. Through our backend each card is one use: it gets its own
    /// use number, which its retries share.
    private func start(at index: Int) {
        let status = ai.status()
        guard let route = status.route() else {
            Logger.info("TypeRight: no AI for this card (\(status))", category: Logger.llm)
            jobs.remove(at: index)
            return
        }
        let job = jobs[index]
        let id = job.id
        jobs[index].startedAt = clock.now
        switch job.kind {
        case let .translate(fragment, sentence):
            let translate = ai.translate
            jobs[index].task = Task { [weak self] in
                do {
                    let result = try await translate(fragment, sentence, route) { partial in
                        self?.answer(id, .translate(source: fragment, result: partial), final: false)
                    }
                    guard !Task.isCancelled else { return }
                    self?.answer(id, .translate(source: fragment, result: result), final: true)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.requestFailed(id, error)
                }
            }
        case let .check(sentence, unfinished, _):
            let check = ai.check
            jobs[index].task = Task { [weak self] in
                do {
                    let result = try await check(sentence, unfinished, route) { partial in
                        self?.answer(id, .sentence(original: sentence, check: partial), final: false)
                    }
                    guard !Task.isCancelled else { return }
                    self?.answer(id, .sentence(original: sentence, check: result), final: true)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.requestFailed(id, error)
                }
            }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].task?.cancel()
        jobs.remove(at: index)
        if active?.job == id, active?.isThinking == true { close(.textChanged) }
        startWaitingJobs()
    }

    /// The request is over; the next one may start.
    private func finish(_ id: UUID) {
        jobs.removeAll { $0.id == id }
        startWaitingJobs()
        if active?.job == id, active?.isThinking == true {
            close(.gone)
            showNext()
        }
    }

    /// More of an answer arrived. The first useful part makes a card; later parts fill it in where it
    /// is (on screen, or waiting its turn).
    private func answer(_ id: UUID, _ content: CoachCardContent, final: Bool) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let job = jobs[index]
        let clean: Bool
        if case let .sentence(_, check) = content {
            clean = check.ok || check.corrected.isEmpty || check.corrected == job.piece
        } else {
            clean = false
        }
        if final, case let .check(_, _, assisted) = job.kind {
            notebook.noteSentence(clean: clean && !assisted)
            if clean, !assisted { notebook.noteCorrectUse(in: job.piece) }
        }
        guard !clean, latestTextStill(has: job.piece, at: job.range) else {
            if final { finish(id) }
            return
        }
        if jobs[index].firstContentAt == nil { jobs[index].firstContentAt = clock.now }
        if active?.job == id, active?.isThinking == false {
            active?.content = content
            if let card = active { refresh(card, final: final) }
        } else if let waiting = pending.firstIndex(where: { $0.job == id }) {
            pending[waiting].content = content
        } else if !job.gotCard {
            let scalars = Array(latestText.unicodeScalars)
            var anchor: Range<Int>?
            if case let .sentence(_, check) = content {
                anchor = CoachText.firstChangeRange(check, in: scalars, within: job.range) ?? CoachText.lastWordRange(in: scalars, within: job.range)
            }
            jobs[index].gotCard = true
            var card = Card(content: content, range: job.range, piece: job.piece, analyzedText: latestText, anchorOverride: anchor, job: id)
            card.askedAt = job.queuedAt
            card.sentAt = job.startedAt
            card.unfinished = job.isUnfinishedCheck
            Logger.info("⏱ first useful words (\(Self.kind(content))): \(Self.ms(clock.now - (job.startedAt ?? job.queuedAt))) ms after the request was sent\(userIsTyping && !job.explicit ? ", held while typing" : "")", category: Logger.llm)
            deliver(card, now: job.explicit)
        }
        if final { finish(id) }
    }

    private func requestFailed(_ id: UUID, _ error: Error) {
        let range = jobFor(id)?.range
        finish(id)
        if case let CoachAIError.member(memberError) = error {
            // Through our backend the trial or membership could not be used (used up, today's limit,
            // offline, device token …). For now that is one info line and no card; the account page is being designed.
            Logger.info("TypeRight: member AI gave no card: \(memberError.kind) (\(memberError.code), HTTP \(memberError.status))", category: Logger.llm)
            return
        }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        Logger.warning("TypeRight: AI request failed: \(message)", category: Logger.llm)
        showFailed(message, at: range, keyRejected: (error as? CoachAIError)?.keyRejected == true)
    }

    // MARK: - Showing and taking cards

    private enum CloseReason {
        case accepted, declined, typedOn, clickedOutside, textChanged, timeUp, gone
        /// Typing along ended before the end (return, an arrow, the field changed elsewhere).
        case leftFollow
    }

    /// "想一下" for the newest request still waiting for its first words, unless it was typed past.
    private func showCapsule() {
        guard active == nil, let job = jobs.last(where: { $0.task != nil && !$0.gotCard && !$0.capsuleTypedAway }) else { return }
        present(Card(content: .thinking, range: job.capsuleAt, piece: CoachText.substring(Array(latestText.unicodeScalars), job.capsuleAt),
                     analyzedText: latestText, job: job.id), async: false)
    }

    /// A failed card, at the range's place in the current text (or the field's corner).
    private func showFailed(_ message: String, at range: Range<Int>?, keyRejected: Bool = false) {
        let scalars = Array(latestText.unicodeScalars)
        let range = range.flatMap { $0.upperBound <= scalars.count ? $0 : nil } ?? 0 ..< 0
        deliver(Card(content: .failed(message, keyRejected: keyRejected), range: range, piece: CoachText.substring(scalars, range), analyzedText: latestText),
                now: true)
    }

    /// A card from the AI (or a failure) waits its turn: it comes when no other card is up and the
    /// user is not typing, after the cards before it in the text. `now`: the user asked for it.
    private func deliver(_ card: Card, now: Bool) {
        pending.append(card)
        pending.sort { $0.range.lowerBound < $1.range.lowerBound }
        if active?.isThinking ?? true, now || !userIsTyping { showNext() }
    }

    /// What waited comes now: the first card in the text, a misspelling typed past, or "想一下".
    private func showNext() {
        guard active?.isThinking ?? true, follow == nil, let host, !host.coachIsComposing else { return }
        let card = nextWaiting()
        guard let card else {
            if active == nil { showCapsule() }
            return
        }
        present(card, async: true)
    }

    /// The first card in the text that may come now. A card waits for a request about earlier text
    /// still running (cards go in sentence order); a misspelling waits for the check of its sentence
    /// and goes when a sentence card covers it.
    private func nextWaiting() -> Card? {
        pending.removeAll { !latestTextStill(has: $0.piece, at: $0.range) && !$0.isFailure }
        let scalars = Array(latestText.unicodeScalars)
        let sentences = CoachText.sentences(in: scalars)
        let sentenceCards = pending.filter(\.isSentence) + [active].compactMap { $0 }.filter(\.isSentence)
        skipped.removeAll { item in
            !latestTextStill(has: item.mark.text, at: item.mark.range)
                || sentenceCards.contains { $0.range.overlaps(item.mark.range) }
        }
        let running = jobs.filter { $0.task != nil || $0.startedAt == nil }
        var choices: [(position: Int, card: Card, skippedIndex: Int?)] = pending.map { ($0.range.lowerBound, $0, nil) }
        for (index, item) in skipped.enumerated() {
            let sentence = CoachText.sentence(at: item.mark.range.lowerBound, in: sentences)?.range ?? item.mark.range
            // Its sentence is being checked: the sentence card may cover it.
            guard !running.contains(where: { $0.isCheck && $0.range.overlaps(sentence) }) else { continue }
            choices.append((item.mark.range.lowerBound,
                            Card(content: .spelling(wrong: item.mark.text, fixes: item.fixes), range: item.mark.range, piece: item.mark.text,
                                 analyzedText: latestText),
                            index))
        }
        choices.sort { $0.position < $1.position }
        guard let first = choices.first,
              !running.contains(where: { !$0.gotCard && $0.range.upperBound <= first.position && !$0.explicit }) || first.card.isFailure
        else { return nil }
        if let index = first.skippedIndex {
            memory.offer(skipped[index].mark)
            skipped.remove(at: index)
        } else {
            pending.removeAll { $0.id == first.card.id }
        }
        var card = first.card
        card.analyzedText = latestText
        return card
    }

    private func present(_ card: Card, async: Bool) {
        guard let host else { return }
        var card = card
        let scalarCount = card.analyzedText.unicodeScalars.count
        let anchorRange = card.anchorOverride ?? card.range
        let anchorStart = clock.now
        let wordAnchor = anchorRange.isEmpty || anchorRange.upperBound > scalarCount ? nil : host.coachAnchor(for: anchorRange, in: card.analyzedText)
        guard let anchor = wordAnchor ?? host.coachFallbackAnchor() else {
            Logger.info("TypeRight: no anchor for card, not showing", category: Logger.ui)
            return
        }
        let anchorDone = clock.now
        closeTimer?.cancel()
        let interactive = card.isThinking || keys.canIntercept
        if !interactive {
            card.keys = .readOnly
        } else if card.content.acceptText != nil, let app = host.coachAppID, copyOnlyApps.contains(app) {
            card.keys = .copy
        } else if card.content.acceptText != nil, !canFollow(card) {
            card.keys = .direct
        }
        guard display.show(card.content, keys: card.keys, anchor: anchor) else {
            // A card nobody can see takes no key and holds no place, as if none had come up. The
            // window it would have used is hidden, so the card shown before is gone as well; an AI
            // request that card waited on goes on and may still bring a card.
            active = nil
            keys.set(nil)
            return
        }
        let shown = clock.now
        active = card
        // A sentence card covers the misspellings in its sentence: they get no card of their own.
        if card.isSentence { skipped.removeAll { card.range.overlaps($0.mark.range) } }
        keys.set(policy(for: card, async: async))
        logShown(card, anchorAt: wordAnchor == nil ? "fallback" : "word", anchorMs: anchorDone - anchorStart, showMs: shown - anchorDone, at: anchor)
        let id = card.id
        if card.isFailure || (card.keys == .readOnly && !card.isThinking) {
            closeTimer = clock.after(card.isFailure ? Self.failureSeconds : Self.readOnlySeconds) { [weak self] in
                guard let self, self.active?.id == id else { return }
                self.close(.timeUp)
                self.showNext()
            }
        }
    }

    /// The card on screen got more of its answer; it keeps its place while it grows.
    private func refresh(_ card: Card, final: Bool) {
        guard display.update(card.content, keys: card.keys) else {
            active = nil
            keys.set(nil)
            return
        }
        if final, let sent = card.sentAt {
            Logger.info("⏱ card \(Self.kind(card.content)) complete on screen: sent→complete \(Self.ms(clock.now - sent)) ms", category: Logger.ui)
        }
    }

    private func logShown(_ card: Card, anchorAt: String, anchorMs: TimeInterval, showMs: TimeInterval, at anchor: CGRect) {
        var timing = "anchor \(Self.ms(anchorMs)) ms, window \(Self.ms(showMs)) ms"
        if let seen = card.seenAt {
            timing += ", seen→on screen \(Self.ms(clock.now - seen)) ms"
            if let key = card.keyLatency, key < 2 { timing += ", key→on screen \(Self.ms(key + clock.now - seen)) ms" }
        }
        if let asked = card.askedAt { timing += ", asked→on screen \(Self.ms(clock.now - asked)) ms" }
        if let sent = card.sentAt { timing += ", sent→on screen \(Self.ms(clock.now - sent)) ms" }
        Logger.info("TypeRight: card \(Self.kind(card.content)) at \(Int(anchor.minX)),\(Int(anchor.minY)) (\(anchorAt))\(card.keys == .readOnly ? " read-only" : "")", category: Logger.ui)
        Logger.info("⏱ card \(Self.kind(card.content)) on screen: \(timing)", category: Logger.ui)
    }

    private static func ms(_ seconds: TimeInterval) -> Int { Int((seconds * 1000).rounded()) }

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
        follow = nil
        cancelAllWords()
        closeTimer?.cancel()
        display.hide()
        keys.set(nil)
        // A spelling card typed past right after its word was hardly seen: it comes back once.
        if reason == .typedOn, card.whileTyping, case let .spelling(wrong, fixes) = card.content {
            skipped.append(Skipped(mark: CoachMark(text: wrong, range: card.range), fixes: fixes))
        }
        Logger.debug("TypeRight: card \(Self.kind(card.content)) closed (\(reason))", category: Logger.ui)
    }

    private func clickedOutside() {
        guard let card = active else { return }
        close(.clickedOutside)
        // Clicking "想一下" away ends its request: no card turns up after that.
        if card.isThinking, let job = card.job { cancel(job) }
        showNext()
    }

    private func keyArrived(_ key: CoachKey, swallowed: Bool) {
        if case let .modifiers(held) = key {
            heldKeysChanged(held)
            return
        }
        // Any other key while the modifier is held: it was a shortcut, not a look at the words.
        cancelAllWords()
        guard var card = active else {
            keys.set(nil)
            return
        }
        if follow != nil {
            followKey(key, swallowed: swallowed)
            return
        }
        switch key {
        case .tab where swallowed:
            if card.keys == .normal {
                startFollow(card)
            } else {
                accept(card)
            }
        case .escape:
            close(.declined)
            showNext()
        case .typed:
            card.keysSinceShown += 1
            if card.keysSinceShown >= Self.typedAway {
                close(.typedOn)
            } else {
                active = card
            }
        case .typesNothing, .modifiers:
            // A screenshot, copy, a function key, switching the input source. A shortcut that does
            // change the text (paste, undo) closes the card once the text it points at changed.
            break
        case .tab, .moves, .deleteBack:
            // A Tab that went to the app, return, an arrow, a delete key: the caret is elsewhere.
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
            let result = await host.coachReplace(range: card.range, with: replacement, analyzedText: card.analyzedText)
            self?.finishWrite(card, replacement: replacement, result: result, app: app, appName: appName)
        }
    }

    private func finishWrite(_ card: Card, replacement: String, result: CoachWriteResult, app: String, appName: String) {
        guard case let .written(text, at) = result else {
            writeFailed(result, at: card.range, replacement: replacement, app: app)
            return
        }
        adopt(text)
        memory.fix(at)
        if case let .sentence(_, check) = card.content { memory.checked.insert(Self.sentenceKey(check.corrected)) }
        notebook.record(card.content, app: appName, context: Self.context(of: card, after: replacement), how: .replaced)
        showNext()
    }

    /// A write that did not happen, or came out wrong: the card says so; in an app where it came
    /// out wrong, Tab copies from then on.
    private func writeFailed(_ result: CoachWriteResult, at range: Range<Int>, replacement: String, app: String) {
        switch result {
        case .written:
            return
        case .notWritten:
            Logger.warning("TypeRight: write-back left the text unchanged in \(app)", category: Logger.analysis)
            showFailed("没改成：这个输入框里的字没变，自己改一下吧。", at: range)
        case .wrongResult:
            Logger.warning("TypeRight: write-back gave the wrong text in \(app); Tab copies there from now on", category: Logger.analysis)
            copyOnlyApps.insert(app)
            copy(replacement)
            showFailed("这个 App 里没改对。改法「\(replacement)」已复制，粘贴替换一下；之后在这里按 Tab 只复制，不直接改。", at: nil)
        }
    }

    /// The field reads `text` after a write TypeRight made.
    private func adopt(_ text: String) {
        _ = take(text)
        remember(text)
    }

    // MARK: - Typing along

    /// Tab types along with this card: the setting says so and, for a sentence card, the app lets
    /// the caret be put on each changed word.
    private func canFollow(_ card: Card) -> Bool {
        guard behavior().tabFollows, let host else { return false }
        switch card.content {
        case .translate, .spelling:
            return true
        case let .sentence(original, check):
            return host.coachCanMoveCaret && !CoachText.placements(of: check.changes, in: original).isEmpty
        case .thinking, .failed:
            return false
        }
    }

    /// The first Tab: the original goes out of the field and the card stays, to be typed along with.
    private func startFollow(_ card: Card) {
        guard let host, let english = card.content.acceptText else { return }
        guard latestTextStill(has: card.piece, at: card.range) else {
            close(.textChanged)
            showNext()
            return
        }
        let scalars = Array(latestText.unicodeScalars)
        let caret = min(host.coachCaret(in: latestText) ?? scalars.count, scalars.count)
        let tail = scalars.count - card.range.upperBound
        closeTimer?.cancel()
        if case let .sentence(original, check) = card.content {
            follow = Follow(card: card, steps: CoachText.placements(of: check.changes, in: original), head: card.range.lowerBound,
                            tail: tail, original: original, filled: check.corrected, caretFromEnd: scalars.count - caret)
        } else {
            var lead = "", trail = ""
            if case .translate = card.content {
                let spaced = CoachText.spaced(english, replacing: card.range, in: scalars)
                if spaced.hasPrefix(" "), !english.hasPrefix(" ") { lead = " " }
                if spaced.hasSuffix(" "), !english.hasSuffix(" ") { trail = " " }
            }
            // The original was all the field had: a space holds the place, so no write has to go
            // over nothing or leave nothing behind.
            if card.range == 0 ..< scalars.count, lead.isEmpty, trail.isEmpty { trail = " " }
            let step = CoachText.Placement(range: 0 ..< card.range.count, from: card.piece, to: english)
            follow = Follow(card: card, steps: [step], head: card.range.lowerBound, tail: tail, original: card.piece,
                            filled: lead + english + trail, lead: lead, trail: trail, caretFromEnd: scalars.count - caret)
        }
        Logger.info("TypeRight: typing along with the \(Self.kind(card.content)) card", category: Logger.ui)
        beginStep()
    }

    /// Takes the words of the current step out of the field; typing along starts once they are gone.
    private func beginStep() {
        guard var follow else { return }
        let scalars = Array(latestText.unicodeScalars)
        let place = follow.steps[follow.step]
        var start = follow.head + place.range.lowerBound
        for done in follow.steps[..<follow.step] {
            start += done.to.unicodeScalars.count - done.range.count
        }
        let range = start ..< start + place.range.count
        guard range.upperBound <= scalars.count, CoachText.substring(scalars, range) == place.from else {
            Logger.info("TypeRight: the words to type along with are not where they were, typing along ends", category: Logger.ui)
            close(.leftFollow)
            showNext()
            return
        }
        follow.phase = .writing
        follow.typed = []
        follow.after = Array(follow.trail.unicodeScalars) + scalars[range.upperBound...]
        self.follow = follow
        keys.set(followPolicy())
        let id = follow.card.id
        write(follow.lead + follow.trail, over: range) { [weak self] result in
            self?.stepWritten(result, cardID: id)
        }
    }

    private func stepWritten(_ result: CoachWriteResult, cardID: UUID) {
        guard var follow, follow.card.id == cardID, follow.phase == .writing, let host else {
            // Typing along ended while TypeRight was writing: nothing more is written.
            if case let .written(text, _) = result { adopt(text) }
            return
        }
        guard case let .written(text, at) = result else {
            close(.leftFollow)
            writeFailed(result, at: follow.card.range, replacement: follow.target, app: host.coachAppID ?? "")
            return
        }
        adopt(text)
        let scalars = Array(text.unicodeScalars)
        let start = min(at.lowerBound + follow.lead.unicodeScalars.count, scalars.count)
        follow.before = Array(scalars[..<start])
        follow.phase = .typing
        follow.anchor = caretAnchor(at: start, in: text) ?? follow.anchor
        let asked = follow.asked
        follow.asked = nil
        self.follow = follow
        if host.coachCaret(in: text) != start, !host.coachSetCaret(start, in: text) {
            Logger.info("TypeRight: the app did not take the caret at \(start)", category: Logger.ui)
        }
        if follow.target.isEmpty {
            // A change that only takes words out: TypeRight took them out, nothing to type.
            stepDone()
            return
        }
        switch asked {
        case .fill:
            fill()
            return
        case .putBack:
            putBack()
            return
        case nil:
            break
        }
        // A translation or spelling card sits under where the English is typed; a sentence card
        // stays where it came up, under the sentence, while the caret goes from change to change.
        guard display.follow(followView(follow), anchor: follow.isSentence ? nil : follow.anchor) else {
            close(.gone)
            return
        }
        keys.set(followPolicy())
        followTextChanged(text)
    }

    /// Compares what is typed between `before` and `after` with the English on the card.
    private func followTextChanged(_ text: String) {
        guard var follow, follow.phase == .typing, let host else { return }
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= follow.before.count + follow.after.count, scalars.starts(with: follow.before),
              scalars.suffix(follow.after.count).elementsEqual(follow.after)
        else {
            Logger.info("TypeRight: the field changed outside the part typed along, typing along ends", category: Logger.ui)
            close(.leftFollow)
            return
        }
        // An input method's letters are not typed yet: only what it commits counts.
        follow.composing = host.coachIsComposing
        if !follow.composing { follow.typed = Array(scalars[follow.before.count ..< scalars.count - follow.after.count]) }
        var moved: CGRect?
        let end = follow.before.count + follow.typed.count
        if !follow.isSentence, !follow.typed.isEmpty, let pinned = follow.anchor, let last = host.coachAnchor(for: end - 1 ..< end, in: text),
           abs(last.midY - pinned.midY) > max(last.height, pinned.height) / 2
        {
            // The typing went on to another line: the card follows to it, and stays put along the line.
            moved = CGRect(x: last.minX, y: last.minY, width: 0, height: last.height)
            follow.anchor = moved
        }
        self.follow = follow
        keys.set(followPolicy())
        let progress = follow.progress()
        if !follow.composing, progress.wrongAt == nil, progress.right == follow.target.unicodeScalars.count {
            stepDone()
            return
        }
        guard display.follow(followView(follow), anchor: moved) else {
            close(.gone)
            return
        }
    }

    /// The current step is typed: on to the next changed word, or done.
    private func stepDone() {
        guard var follow else { return }
        if follow.step + 1 < follow.steps.count {
            follow.step += 1
            self.follow = follow
            beginStep()
        } else {
            finishFollow(filled: false)
        }
    }

    /// Typed to the end or filled in: recorded, the caret back where the user was, the card says so for a moment.
    private func finishFollow(filled: Bool) {
        guard var follow, let host else { return }
        let card = active ?? follow.card
        let text = latestText
        let count = text.unicodeScalars.count
        follow.phase = .done
        follow.filledIn = filled
        self.follow = follow
        let caret = count - follow.caretFromEnd
        if host.coachCaret(in: text) != caret, !host.coachSetCaret(caret, in: text) {
            Logger.info("TypeRight: the app did not take the caret back at \(caret)", category: Logger.ui)
        }
        memory.fix(follow.head ..< count - follow.tail)
        let context: String
        if case let .sentence(_, check) = card.content {
            memory.checked.insert(Self.sentenceKey(check.corrected))
            context = check.corrected
        } else {
            context = Self.context(of: card, after: follow.target)
        }
        notebook.record(card.content, app: host.coachAppName, context: context, how: filled ? .replaced : .typed)
        Logger.info("TypeRight: typed along to the end (\(filled ? "filled in" : "all typed"))", category: Logger.ui)
        keys.set(CoachKeyPolicy(tab: false, tabFrom: 0, esc: true))
        guard display.follow(followView(follow), anchor: nil) else {
            close(.gone)
            return
        }
        let id = card.id
        closeTimer?.cancel()
        closeTimer = clock.after(Self.doneSeconds) { [weak self] in
            guard let self, self.active?.id == id, self.follow?.phase == .done else { return }
            self.close(.accepted)
            self.showNext()
        }
    }

    /// Tab again: what is left is written in, a wrong character along with it.
    private func fill() {
        guard var follow else { return }
        let count = latestText.unicodeScalars.count
        follow.phase = .writing
        self.follow = follow
        let id = follow.card.id
        let filled = follow.filled
        write(filled, over: follow.head ..< count - follow.tail) { [weak self] result in
            guard let self else { return }
            guard self.follow?.card.id == id, case let .written(text, _) = result else {
                if case let .written(text, _) = result { self.adopt(text) } else if self.follow?.card.id == id {
                    self.close(.leftFollow)
                    self.writeFailed(result, at: self.latestTextRange(head: follow.head, tail: follow.tail), replacement: filled,
                                     app: self.host?.coachAppID ?? "")
                }
                return
            }
            self.adopt(text)
            self.finishFollow(filled: true)
        }
    }

    /// Esc, or Backspace at the start: the original goes back where it was, and is not offered again.
    private func putBack() {
        guard var follow else { return }
        let count = latestText.unicodeScalars.count
        follow.phase = .writing
        self.follow = follow
        let id = follow.card.id
        write(follow.original, over: follow.head ..< count - follow.tail) { [weak self] result in
            guard let self else { return }
            guard self.follow?.card.id == id, case let .written(text, at) = result else {
                if case let .written(text, _) = result { self.adopt(text) } else if self.follow?.card.id == id {
                    self.close(.leftFollow)
                    self.writeFailed(result, at: self.latestTextRange(head: follow.head, tail: follow.tail), replacement: follow.original,
                                     app: self.host?.coachAppID ?? "")
                }
                return
            }
            self.adopt(text)
            if !follow.isSentence { self.memory.offer(CoachMark(text: follow.original, range: at)) }
            let caret = text.unicodeScalars.count - follow.caretFromEnd
            if let host = self.host, host.coachCaret(in: text) != caret, !host.coachSetCaret(caret, in: text) {
                Logger.info("TypeRight: the app did not take the caret back at \(caret)", category: Logger.ui)
            }
            Logger.info("TypeRight: typing along ended with Esc, the original is back", category: Logger.ui)
            self.close(.declined)
            self.showNext()
        }
    }

    private func latestTextRange(head: Int, tail: Int) -> Range<Int> {
        let count = latestText.unicodeScalars.count
        return min(head, count) ..< max(min(head, count), count - tail)
    }

    private func followKey(_ key: CoachKey, swallowed: Bool) {
        guard var follow else { return }
        switch follow.phase {
        case .done:
            switch key {
            case .typesNothing, .modifiers:
                break
            default:
                // Typing on after the end: the card goes at once.
                close(key == .escape && swallowed ? .declined : .typedOn)
                showNext()
            }
        case .writing:
            switch key {
            case .tab:
                if swallowed { follow.asked = .fill }
            case .escape, .deleteBack:
                if swallowed { follow.asked = .putBack }
            case .moves:
                close(.leftFollow)
                return
            case .typed, .typesNothing, .modifiers:
                break
            }
            self.follow = follow
        case .typing:
            switch key {
            case .tab:
                if swallowed { fill() }
            case .escape:
                if swallowed { putBack() }
            case .deleteBack:
                if swallowed { putBack() } else { readSoon() }
            case .typed:
                readSoon()
            case .moves:
                close(.leftFollow)
                showNext()
            case .typesNothing, .modifiers:
                break
            }
        }
    }

    private func followPolicy() -> CoachKeyPolicy {
        CoachKeyPolicy(tab: true, tabFrom: 0, esc: true,
                       follow: CoachFollowKeys(typed: follow?.typed.count ?? 0, composing: follow?.composing ?? false))
    }

    private func followView(_ follow: Follow) -> CoachFollow {
        if follow.phase == .done {
            return CoachFollow(phase: .done(filled: follow.filledIn), target: follow.target,
                               right: follow.target.unicodeScalars.count, step: follow.step)
        }
        let progress = follow.progress()
        return CoachFollow(phase: .typing, target: follow.target, right: progress.right, wrongAt: progress.wrongAt,
                           composing: follow.composing, step: follow.step)
    }

    /// Where the caret at `offset` sits on screen: the right edge of the character before it.
    private func caretAnchor(at offset: Int, in text: String) -> CGRect? {
        guard let host else { return nil }
        let scalars = Array(text.unicodeScalars)
        if offset > 0, offset <= scalars.count, scalars[offset - 1] != "\n",
           let before = host.coachAnchor(for: offset - 1 ..< offset, in: text)
        {
            return CGRect(x: before.maxX, y: before.minY, width: 0, height: before.height)
        }
        if offset < scalars.count, let after = host.coachAnchor(for: offset ..< offset + 1, in: text) {
            return CGRect(x: after.minX, y: after.minY, width: 0, height: after.height)
        }
        return nil
    }

    private func write(_ replacement: String, over range: Range<Int>, then: @escaping (CoachWriteResult) -> Void) {
        guard let host else { return }
        let text = latestText
        writeTask = Task {
            let result = await host.coachReplace(range: range, with: replacement, analyzedText: text)
            then(result)
        }
    }

    // MARK: - The card's word list (a modifier held alone)

    private func heldKeysChanged(_ held: CoachModifiers) {
        guard behavior().allWordsKey.matches(held), let card = active, !card.isThinking, !card.isFailure else {
            cancelAllWords()
            return
        }
        guard heldTimer == nil, !allWordsShown else { return }
        heldTimer = clock.after(Self.holdSeconds) { [weak self] in
            guard let self, self.active != nil else { return }
            self.heldTimer = nil
            self.allWordsShown = true
            self.display.showAllWords(true)
        }
    }

    private func cancelAllWords() {
        heldTimer?.cancel()
        heldTimer = nil
        guard allWordsShown else { return }
        allWordsShown = false
        display.showAllWords(false)
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

    /// Without an AI the sentence count comes from the spell checker: a finished sentence typed here
    /// that the analysis found nothing in, and TypeRight did not change, counts as right the first time.
    private func countWithoutAI(_ sentences: [CoachText.Sentence], scalars: [Unicode.Scalar]) {
        guard let analysis = latestAnalysis, analysis.text == latestText else { return }
        for sentence in sentences where sentence.finished && memory.isTouched(sentence.range) {
            let text = CoachText.substring(scalars, sentence.range)
            let key = Self.sentenceKey(text)
            guard !memory.checked.contains(key),
                  ChineseText.latinWordCount(in: scalars, from: sentence.range.lowerBound, to: sentence.range.upperBound) >= 3 else { continue }
            memory.checked.insert(key)
            let clean = !analysis.errors.contains { $0.start < sentence.range.upperBound && $0.end > sentence.range.lowerBound }
                && !memory.wasFixed(within: sentence.range)
            notebook.noteSentence(clean: clean)
            if clean { notebook.noteCorrectUse(in: text) }
        }
    }

    // MARK: - Text helpers

    private func latestTextStill(has piece: String, at range: Range<Int>) -> Bool {
        let scalars = Array(latestText.unicodeScalars)
        return range.upperBound <= scalars.count && CoachText.substring(scalars, range) == piece
    }
}
