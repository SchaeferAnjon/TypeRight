//
//  CoachNotebook.swift
//  TypeRight
//
//  What the user took with Tab, kept on this Mac only: the mistake book (spelling and sentence
//  fixes, grouped by kind of mistake) and the word book (English learned from Chinese or pinyin).
//  A point counts as learned once the user writes it right three times without help.
//

import AppKit
import Combine
import Foundation

enum MistakeCategory: String, Codable, CaseIterable, Identifiable {
    case spelling, article, tense, plural, preposition, chinglish, agreement, capitalization, wordChoice, punctuation, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spelling: "拼写"
        case .article: "冠词"
        case .tense: "时态"
        case .plural: "单复数"
        case .preposition: "介词"
        case .chinglish: "中式表达"
        case .agreement: "主谓一致"
        case .capitalization: "大小写"
        case .wordChoice: "用词"
        case .punctuation: "标点"
        case .other: "其他"
        }
    }

    /// The `type` the AI writes for each change.
    init(aiType: String) {
        switch aiType.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "spelling": self = .spelling
        case "article": self = .article
        case "tense": self = .tense
        case "plural", "number": self = .plural
        case "preposition": self = .preposition
        case "chinglish", "unnatural", "idiom": self = .chinglish
        case "agreement", "subject-verb": self = .agreement
        case "capitalization", "case": self = .capitalization
        case "word-choice", "wordchoice", "word": self = .wordChoice
        case "punctuation": self = .punctuation
        default: self = .other
        }
    }
}

struct NotebookEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case mistake, word }

    var id = UUID()
    var kind: Kind
    var category: MistakeCategory
    var from: String
    var to: String
    var why: String
    var ipa: String
    /// The sentence as it read after the fix, for context.
    var context: String
    var app: String
    var date: Date
    /// How many times this same fix was needed.
    var times = 1
    /// Times the user later wrote it right on their own.
    var correctUses = 0
    var mastered = false
}

extension NotebookEntry {
    private enum CodingKeys: String, CodingKey {
        case id, kind, category, from, to, why, ipa, context, app, date, times, correctUses, mastered
    }

    /// Fields added later or missing get defaults and an unknown kind of mistake becomes "other",
    /// so a notebook written by another version still opens.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        id = value(.id, UUID())
        kind = Kind(rawValue: value(.kind, "")) ?? .mistake
        category = MistakeCategory(rawValue: value(.category, "")) ?? .other
        from = value(.from, "")
        to = value(.to, "")
        why = value(.why, "")
        ipa = value(.ipa, "")
        context = value(.context, "")
        app = value(.app, "")
        date = value(.date, .distantPast)
        times = value(.times, 1)
        correctUses = value(.correctUses, 0)
        mastered = value(.mastered, false)
    }
}

struct DayStat: Codable, Equatable {
    var day: String
    /// English sentences checked.
    var sentences = 0
    /// Of those, right the first time.
    var clean = 0
    /// Fixes taken with Tab.
    var fixes = 0

    init(day: String) {
        self.day = day
    }

    private enum CodingKeys: String, CodingKey { case day, sentences, clean, fixes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = (try? c.decodeIfPresent(String.self, forKey: .day)) ?? ""
        sentences = ((try? c.decodeIfPresent(Int.self, forKey: .sentences)) ?? nil) ?? 0
        clean = ((try? c.decodeIfPresent(Int.self, forKey: .clean)) ?? nil) ?? 0
        fixes = ((try? c.decodeIfPresent(Int.self, forKey: .fixes)) ?? nil) ?? 0
    }
}

@MainActor
final class CoachNotebook: ObservableObject {
    static let shared = CoachNotebook()

    static let usesToMaster = 3

    @Published private(set) var entries: [NotebookEntry] = []
    @Published private(set) var days: [DayStat] = []

    private struct Stored: Codable {
        var entries: [NotebookEntry]
        var days: [DayStat]

        init(entries: [NotebookEntry], days: [DayStat]) {
            self.entries = entries
            self.days = days
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            entries = try c.decodeIfPresent([NotebookEntry].self, forKey: .entries) ?? []
            days = try c.decodeIfPresent([DayStat].self, forKey: .days) ?? []
        }
    }

    let fileURL: URL
    /// Beyond this many entries the oldest go, learned ones first.
    let maxEntries: Int
    /// Off when an unreadable file could not be moved aside: nothing is written over it this run.
    private(set) var canWrite = true
    private var recentCorrectSentences = CappedSet<String>(limit: 500)
    /// Writes happen on this queue, at most one per `saveDelay`, with the latest state.
    private let writer = DispatchQueue(label: "TypeRight.notebook", qos: .utility)
    private var saveScheduled = false
    static let saveDelay: TimeInterval = 0.5
    private var quitObserver: NSObjectProtocol?

    init(fileURL: URL? = nil, maxEntries: Int = 5000) {
        self.maxEntries = maxEntries
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            let base = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.typeright.app", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            } catch {
                Logger.error("TypeRight: could not create \(base.path): \(error.localizedDescription)", category: Logger.general)
            }
            self.fileURL = base.appendingPathComponent("notebook.json")
        }
        load()
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    // MARK: Recording

    func record(_ content: CoachCardContent, app: String, context: String) {
        let now = Date()
        switch content {
        case let .spelling(wrong, fixes):
            add(NotebookEntry(kind: .mistake, category: .spelling, from: wrong, to: fixes.first ?? "", why: "",
                              ipa: "", context: context, app: app, date: now))
        case let .translate(source, result):
            add(NotebookEntry(kind: .word, category: .other, from: source, to: result.english, why: result.note,
                              ipa: result.ipa, context: context, app: app, date: now))
        case let .sentence(_, check):
            for change in check.changes where !change.to.isEmpty || !change.from.isEmpty {
                add(NotebookEntry(kind: .mistake, category: MistakeCategory(aiType: change.type), from: change.from,
                                  to: change.to, why: change.why, ipa: "", context: check.corrected, app: app, date: now))
            }
        case .thinking, .failed:
            return
        }
        bumpToday { $0.fixes += 1 }
        save()
    }

    /// One English sentence was checked; `clean` when it needed no fix.
    func noteSentence(clean: Bool) {
        bumpToday {
            $0.sentences += 1
            if clean { $0.clean += 1 }
        }
        save()
    }

    /// The user wrote `sentence` without help: every open point it uses correctly moves closer to learned.
    func noteCorrectUse(in sentence: String) {
        let key = sentence.lowercased()
        guard !recentCorrectSentences.contains(key) else { return }
        recentCorrectSentences.insert(key)
        var changed = false
        for i in entries.indices where !entries[i].mastered && Self.usesCorrectly(entries[i], in: sentence) {
            entries[i].correctUses += 1
            if entries[i].correctUses >= Self.usesToMaster { entries[i].mastered = true }
            changed = true
        }
        if changed { save() }
    }

    /// Whether `sentence` uses this point the right way.
    /// - A word from the word book counts when the user writes it.
    /// - A capitalization fix (i → I) is compared letter case and all.
    /// - An added word (from is empty) counts only between the same neighbours as in the fixed sentence;
    ///   without a neighbour there is nothing to tell a right use from a chance one, so it never counts.
    /// - Anything else counts when the fix is there and the mistake is not.
    nonisolated static func usesCorrectly(_ entry: NotebookEntry, in sentence: String) -> Bool {
        guard entry.to.contains(where: { $0.isLetter }) else { return false }
        switch entry.kind {
        case .word:
            return contains(sentence, word: entry.to)
        case .mistake:
            if entry.from.isEmpty {
                guard let phrase = insertionPhrase(entry.to, in: entry.context) else { return false }
                return contains(sentence, word: phrase)
            }
            if entry.from.lowercased() == entry.to.lowercased() {
                return contains(sentence, word: entry.to, caseSensitive: true)
                    && !contains(sentence, word: entry.from, caseSensitive: true)
            }
            return contains(sentence, word: entry.to) && !contains(sentence, word: entry.from)
        }
    }

    /// The added words with the word before and the word after them in `context`, e.g. "to the store".
    nonisolated static func insertionPhrase(_ added: String, in context: String) -> String? {
        guard let found = CoachText.wordRange(of: added, in: context) else { return nil }
        let before = context[..<found.lowerBound].split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).last
        let after = context[found.upperBound...].split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).first
        guard before != nil || after != nil else { return nil }
        return ([before.map(String.init), added, after.map(String.init)] as [String?]).compactMap { $0 }.joined(separator: " ")
    }

    func setMastered(_ id: UUID, _ mastered: Bool) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].mastered = mastered
        if !mastered { entries[i].correctUses = 0 }
        save()
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clearAll() {
        entries = []
        days = []
        save()
    }

    // MARK: Reading

    var mistakes: [NotebookEntry] { entries.filter { $0.kind == .mistake }.sorted { $0.date > $1.date } }
    var words: [NotebookEntry] { entries.filter { $0.kind == .word }.sorted { $0.date > $1.date } }

    var today: [NotebookEntry] {
        let start = Calendar.current.startOfDay(for: Date())
        return entries.filter { $0.date >= start }.sorted { $0.date > $1.date }
    }

    /// Points that need one more correct use.
    var almostLearned: [NotebookEntry] {
        mistakes.filter { !$0.mastered && $0.correctUses == Self.usesToMaster - 1 }
    }

    /// The last `count` days, oldest first, with empty days filled in.
    func lastDays(_ count: Int) -> [DayStat] {
        let byDay = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let calendar = Calendar.current
        return (0 ..< count).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            let key = Self.dayKey(date)
            return byDay[key] ?? DayStat(day: key)
        }
    }

    // MARK: Private

    private func add(_ entry: NotebookEntry) {
        if let i = entries.firstIndex(where: {
            $0.kind == entry.kind && $0.from.lowercased() == entry.from.lowercased() && $0.to.lowercased() == entry.to.lowercased()
        }) {
            entries[i].times += 1
            entries[i].date = entry.date
            entries[i].context = entry.context
            entries[i].app = entry.app
            entries[i].correctUses = 0
            entries[i].mastered = false
        } else {
            entries.append(entry)
        }
        if entries.count > maxEntries {
            let dropped = entries.sorted { ($0.mastered ? 0 : 1, $0.date) < ($1.mastered ? 0 : 1, $1.date) }
                .prefix(entries.count - maxEntries).map(\.id)
            let gone = Set(dropped)
            entries.removeAll { gone.contains($0.id) }
        }
    }

    private func bumpToday(_ change: (inout DayStat) -> Void) {
        let key = Self.dayKey(Date())
        if let i = days.firstIndex(where: { $0.day == key }) {
            change(&days[i])
        } else {
            var stat = DayStat(day: key)
            change(&stat)
            days.append(stat)
        }
        if days.count > 400 { days.removeFirst(days.count - 400) }
    }

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    nonisolated static func contains(_ sentence: String, word: String, caseSensitive: Bool = false) -> Bool {
        let pattern = "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: word) + "(?![A-Za-z])"
        let options: String.CompareOptions = caseSensitive ? [.regularExpression] : [.regularExpression, .caseInsensitive]
        return sentence.range(of: pattern, options: options) != nil
    }

    /// A file that cannot be read is moved aside (same folder, name with the time) and kept;
    /// new records then go into a new file. If it cannot be moved, nothing is written this run.
    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let stored = try decoder.decode(Stored.self, from: Data(contentsOf: fileURL))
            entries = stored.entries
            days = stored.days
        } catch {
            Logger.error("TypeRight: notebook file unreadable: \(error)", category: Logger.general)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = fileURL.deletingLastPathComponent()
                .appendingPathComponent("\(fileURL.deletingPathExtension().lastPathComponent)-unreadable-\(stamp).json")
            do {
                try FileManager.default.moveItem(at: fileURL, to: aside)
                Logger.warning("TypeRight: unreadable notebook kept as \(aside.lastPathComponent), starting a new one", category: Logger.general)
            } catch {
                canWrite = false
                Logger.error("TypeRight: could not move the unreadable notebook aside (\(error.localizedDescription)); not writing this run", category: Logger.general)
            }
        }
    }

    private func save() {
        guard canWrite, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay) { [weak self] in
            MainActor.assumeIsolated { self?.writeNow() }
        }
    }

    /// Writes what is pending now and waits for it (quitting, tests).
    func flush() {
        if saveScheduled { writeNow() }
        writer.sync {}
    }

    private func writeNow() {
        guard saveScheduled else { return }
        saveScheduled = false
        let stored = Stored(entries: entries, days: days)
        let url = fileURL
        writer.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            do {
                try encoder.encode(stored).write(to: url, options: .atomic)
            } catch {
                Logger.error("TypeRight: could not save notebook: \(error.localizedDescription)", category: Logger.general)
            }
        }
    }
}
