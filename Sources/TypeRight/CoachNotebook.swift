//
//  CoachNotebook.swift
//  TypeRight
//
//  What the user took with Tab, kept on this Mac only: the mistake book (spelling and sentence
//  fixes, grouped by kind of mistake) and the word book (English learned from Chinese or pinyin).
//  A point counts as learned once the user writes it right three times without help.
//

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

struct DayStat: Codable, Equatable {
    var day: String
    /// English sentences checked.
    var sentences = 0
    /// Of those, right the first time.
    var clean = 0
    /// Fixes taken with Tab.
    var fixes = 0
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
    }

    private let fileURL: URL
    private var recentCorrectSentences = Set<String>()

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.typeright.app", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.fileURL = base.appendingPathComponent("notebook.json")
        }
        load()
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
        for i in entries.indices where !entries[i].mastered && entries[i].kind == .mistake {
            let entry = entries[i]
            guard !entry.to.isEmpty, Self.contains(sentence, word: entry.to),
                  entry.from.isEmpty || !Self.contains(sentence, word: entry.from) else { continue }
            entries[i].correctUses += 1
            if entries[i].correctUses >= Self.usesToMaster { entries[i].mastered = true }
            changed = true
        }
        if changed { save() }
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

    nonisolated static func contains(_ sentence: String, word: String) -> Bool {
        let pattern = "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: word) + "(?![A-Za-z])"
        return sentence.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode(Stored.self, from: data) else {
            Logger.warning("TypeRight: notebook file unreadable, starting empty", category: Logger.general)
            return
        }
        entries = stored.entries
        days = stored.days
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Stored(entries: entries, days: days)) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.error("TypeRight: could not save notebook: \(error.localizedDescription)", category: Logger.general)
        }
    }
}
