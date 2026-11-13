//
//  CoachDictionary.swift
//  TypeRight
//
//  What the word layer shows when the mouse stops on an English word of a card: the word's IPA
//  and its Chinese meaning, from the Mac's own 牛津英汉汉英词典. No AI and no network: a word
//  takes 0.1 to 4 ms here once the dictionary is open (opening it takes 100 to 200 ms, done ahead).
//
//  The public `DCSCopyTextDefinition` only reads the default dictionary (English-only on most
//  Macs), so the dictionary is picked by its identifier through the private DictionaryServices
//  calls, looked up with `dlsym` so a macOS without them only loses the word layer's meaning.
//

import CoreServices
import Foundation
import NaturalLanguage

/// What the word layer shows for one word.
struct CoachWordInfo: Equatable {
    enum Status: Equatable {
        case found
        /// The dictionary has no entry headed by this word.
        case notFound
        /// 牛津英汉汉英词典 is not on this Mac (it is downloaded from the Dictionary app's settings).
        case noDictionary
    }

    struct Sense: Equatable {
        /// `n.`, `v.`, `adj.` …
        var pos: String
        var meaning: String
    }

    /// As it reads on the card.
    var word: String
    /// `/mɪks/`, or empty.
    var ipa: String
    /// At most two, one per part of speech.
    var senses: [Sense]
    var status: Status

    /// The line under the word when there is no meaning to show.
    var emptyLine: String? {
        switch status {
        case .found: nil
        case .notFound: word.first?.isUppercase == true ? "词典里没有，可能是人名或地名" : "词典里没有这个词"
        case .noDictionary: "装上系统的英汉词典就能看中文意思"
        }
    }
}

/// One dictionary record, read from the XHTML the dictionary keeps it in.
struct CoachDictionaryEntry: Equatable {
    struct Group: Equatable {
        /// `transitive verb`, `noun`, or for a word form `past tense`.
        var label: String
        /// Chinese meanings marked as definitions (examples left out).
        var meanings: [String]
        /// Words the group points to (`went` → `go`).
        var links: [String]
    }

    /// The word the entry is headed by.
    var title: String
    /// IPA by dialect: `AmE`, `BrE`, or `""` when the entry does not say.
    var ipa: [String: String]
    var groups: [Group]

    /// Reads a record; only the start of a long entry (`go`) is read, enough for two parts of speech.
    static func parse(_ xhtml: String) -> CoachDictionaryEntry? {
        let scanner = CoachRecordScanner()
        let parser = XMLParser(data: Data(xhtml.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = scanner
        parser.parse()
        guard !scanner.entry.title.isEmpty else { return nil }
        return scanner.entry
    }
}

/// Walks a record's XHTML once and stops after a few groups.
private final class CoachRecordScanner: NSObject, XMLParserDelegate {
    private static let groupLimit = 6

    var entry = CoachDictionaryEntry(title: "", ipa: [:], groups: [])
    private var dialects: [String?] = []
    private var classes: [Set<Substring>] = []
    private var capture: (kind: String, depth: Int)?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI _: String?, qualifiedName _: String?,
                attributes: [String: String] = [:])
    {
        let cls = Set((attributes["class"] ?? "").split(separator: " "))
        if name == "d:entry" { entry.title = attributes["d:title"] ?? "" }
        let dialect = cls.contains("prx") ? attributes["dialect"] : dialects.last ?? nil
        if cls.contains("gramb") {
            if entry.groups.count >= Self.groupLimit {
                parser.abortParsing()
                return
            }
            entry.groups.append(.init(label: "", meanings: [], links: []))
        }
        if capture == nil {
            var kind: String?
            if cls.contains("ps") || (cls.contains("gr") && cls.contains("x_xdh")) {
                kind = "label"
            } else if cls.contains("trans"), attributes["d:def"] != nil, !cls.contains("ty_pinyin") {
                kind = "meaning"
            } else if cls.contains("ph") {
                kind = "ipa"
            } else if name == "a", classes.last?.contains("xr") == true, let title = attributes["title"], !entry.groups.isEmpty {
                entry.groups[entry.groups.count - 1].links.append(title)
            }
            if let kind {
                capture = (kind, classes.count)
                text = ""
            }
        }
        classes.append(cls)
        dialects.append(dialect)
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        if capture != nil { text += string }
    }

    func parser(_: XMLParser, didEndElement _: String, namespaceURI _: String?, qualifiedName _: String?) {
        classes.removeLast()
        let dialect = dialects.removeLast()
        guard let capture, capture.depth == classes.count else { return }
        self.capture = nil
        let value = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",|")))
        guard !value.isEmpty else { return }
        switch capture.kind {
        case "label":
            if let last = entry.groups.indices.last, entry.groups[last].label.isEmpty { entry.groups[last].label = value }
        case "meaning":
            if let last = entry.groups.indices.last, !entry.groups[last].meanings.contains(value) { entry.groups[last].meanings.append(value) }
        default:
            // A pronunciation outside the BrE / AmE pair (an inflection's) is kept only when there is no other.
            let key = dialect ?? ""
            if entry.ipa[key] == nil { entry.ipa[key] = value }
        }
    }
}

/// Turns records into what the word layer shows. `records` gives the XHTML of every record the
/// dictionary finds for a search, or nil when the dictionary is not on this Mac; `lemma` gives the
/// word a form belongs to (snowing → snow).
struct CoachWordLookup {
    let records: (String) -> [String]?
    var lemma: (String) -> String? = CoachWordLookup.englishLemma

    func info(for word: String, accent: String) -> CoachWordInfo {
        guard let found = records(word) else {
            return CoachWordInfo(word: word, ipa: "", senses: [], status: .noDictionary)
        }
        // Searching `Huang` finds 肓 huāng: an entry headed by another word counts as nothing found.
        guard let entry = Self.entry(headed: word, in: found) else {
            return formInfo(for: word, found: found) ?? CoachWordInfo(word: word, ipa: "", senses: [], status: .notFound)
        }
        var senses = Self.senses(of: entry)
        if senses.isEmpty, let group = entry.groups.first, let base = group.links.first,
           base.lowercased() != word.lowercased(),
           let baseEntry = records(base).flatMap({ Self.entry(headed: base, in: $0) }),
           let first = Self.senses(of: baseEntry).first
        {
            // `went`: "past tense → go". One hop to go for the meaning.
            senses = [CoachWordInfo.Sense(pos: first.pos, meaning: "\(base) \(Self.formName(group.label))：\(first.meaning)")]
        }
        let ipa = entry.ipa[accent == "uk" ? "BrE" : "AmE"] ?? entry.ipa["AmE"] ?? entry.ipa["BrE"] ?? entry.ipa[""]
        return CoachWordInfo(word: word, ipa: ipa.map { "/\($0)/" } ?? "", senses: senses, status: .found)
    }

    /// A form without an entry of its own (snowing, stories): the meanings of its word, under a line
    /// that says whose form it is. No IPA: the dictionary has only its word's.
    private func formInfo(for word: String, found: [String]) -> CoachWordInfo? {
        guard let base = lemma(word), base.lowercased() != word.lowercased(),
              let entry = Self.entry(headed: base, in: found) ?? records(base).flatMap({ Self.entry(headed: base, in: $0) })
        else { return nil }
        let senses = Self.senses(of: entry)
        guard !senses.isEmpty else { return nil }
        let line = CoachWordInfo.Sense(pos: "", meaning: "\(base) \(Self.formName(""))")
        return CoachWordInfo(word: word, ipa: "", senses: [line] + senses, status: .found)
    }

    /// The word an English form belongs to, as the system's language tools see it.
    static func englishLemma(_ word: String) -> String? {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = word
        tagger.setLanguage(.english, range: word.startIndex ..< word.endIndex)
        return tagger.tag(at: word.startIndex, unit: .word, scheme: .lemma).0?.rawValue
    }

    /// The first entry headed by `word`: same case first (`A` the letter, `a` the article), then any case.
    static func entry(headed word: String, in records: [String]) -> CoachDictionaryEntry? {
        let entries = records.compactMap(CoachDictionaryEntry.parse)
        return entries.first { $0.title == word } ?? entries.first { $0.title.lowercased() == word.lowercased() }
    }

    /// At most two parts of speech, two meanings each: `v. 使…混合；调制`.
    static func senses(of entry: CoachDictionaryEntry) -> [CoachWordInfo.Sense] {
        var out: [CoachWordInfo.Sense] = []
        for group in entry.groups where !group.meanings.isEmpty {
            let pos = partOfSpeech(group.label)
            guard !out.contains(where: { $0.pos == pos }) else { continue }
            out.append(.init(pos: pos, meaning: group.meanings.prefix(2).joined(separator: "；")))
            if out.count == 2 { break }
        }
        return out
    }

    static func partOfSpeech(_ label: String) -> String {
        let label = label.lowercased()
        let names: [(String, String)] = [
            ("adverb", "adv."), ("verb", "v."), ("pronoun", "pron."), ("noun", "n."), ("adjective", "adj."),
            ("preposition", "prep."), ("conjunction", "conj."), ("article", "art."), ("exclamation", "int."),
            ("interjection", "int."), ("determiner", "det."), ("numeral", "num."), ("number", "num."),
        ]
        return names.first { label.contains($0.0) }?.1 ?? label
    }

    /// `past tense` → 的过去式, for "went: go 的过去式".
    static func formName(_ label: String) -> String {
        switch label.lowercased() {
        case "past tense": "的过去式"
        case "past participle": "的过去分词"
        case "past tense, past participle", "past tense and past participle": "的过去式和过去分词"
        case "3rd person singular present": "的第三人称单数"
        case "present participle": "的现在分词"
        case "plural": "的复数"
        case "comparative": "的比较级"
        case "superlative": "的最高级"
        default: "的变化形式"
        }
    }
}

/// The dictionary on this Mac, behind one queue: the DictionaryServices calls never run on two
/// threads at once, and the main thread waits only for a word it has not looked up before.
final class CoachDictionary: @unchecked Sendable {
    static let shared = CoachDictionary(records: CoachSystemDictionary.records)

    private let lookup: CoachWordLookup
    private let queue = DispatchQueue(label: "TypeRight.dictionary", qos: .userInitiated)
    /// Touched on `queue` only.
    private var cache: [String: CoachWordInfo] = [:]

    init(records: @escaping (String) -> [String]?) {
        lookup = CoachWordLookup(records: records)
    }

    /// Opens the dictionary and loads the language model ahead of the first card.
    func warmUp() {
        queue.async { [lookup] in
            _ = lookup.records("the")
            _ = lookup.lemma("snowing")
        }
    }

    /// Looks the card's words up while the user reads it, so a stop on a word shows at once.
    func prefetch(_ words: [String], accent: String) {
        queue.async { [self] in
            for word in words {
                _ = cached(word, accent: accent)
            }
        }
    }

    func info(for word: String, accent: String) -> CoachWordInfo {
        queue.sync { cached(word, accent: accent) }
    }

    private func cached(_ word: String, accent: String) -> CoachWordInfo {
        let key = accent + "|" + word
        if let known = cache[key] { return known }
        let info = lookup.info(for: word, accent: accent)
        // A missing dictionary may be downloaded while TypeRight runs: that answer is not kept.
        if info.status != .noDictionary {
            if cache.count > 2000 { cache.removeAll() }
            cache[key] = info
        }
        return info
    }
}

/// 牛津英汉汉英词典 through DictionaryServices' private calls.
enum CoachSystemDictionary {
    static let identifier = "com.apple.dictionary.zh_CN-en.OCD"

    private typealias CopyAvailable = @convention(c) () -> Unmanaged<CFSet>?
    private typealias GetIdentifier = @convention(c) (CFTypeRef) -> Unmanaged<CFString>?
    private typealias GetURL = @convention(c) (CFTypeRef) -> Unmanaged<CFURL>?
    private typealias CopyRecords = @convention(c) (CFTypeRef, CFString, UnsafeRawPointer?, UnsafeRawPointer?) -> Unmanaged<CFArray>?
    private typealias CopyData = @convention(c) (CFTypeRef, Int) -> Unmanaged<CFString>?

    private struct Calls {
        let copyAvailable: CopyAvailable
        let identifier: GetIdentifier
        let url: GetURL
        let copyRecords: CopyRecords
        let copyData: CopyData
    }

    private static let calls: Calls? = {
        let all = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let available = dlsym(all, "DCSCopyAvailableDictionaries"),
              let identifier = dlsym(all, "DCSDictionaryGetIdentifier"),
              let url = dlsym(all, "DCSDictionaryGetURL"),
              let records = dlsym(all, "DCSCopyRecordsForSearchString"),
              let data = dlsym(all, "DCSRecordCopyData")
        else {
            Logger.warning("TypeRight: DictionaryServices calls not found; the word layer has no meanings", category: Logger.general)
            return nil
        }
        return Calls(copyAvailable: unsafeBitCast(available, to: CopyAvailable.self),
                     identifier: unsafeBitCast(identifier, to: GetIdentifier.self),
                     url: unsafeBitCast(url, to: GetURL.self),
                     copyRecords: unsafeBitCast(records, to: CopyRecords.self),
                     copyData: unsafeBitCast(data, to: CopyData.self))
    }()

    /// Found once; while missing it is looked for again at most once a minute (it may be downloaded meanwhile).
    nonisolated(unsafe) private static var dictionary: CFTypeRef?
    nonisolated(unsafe) private static var lastSearch: Date?

    /// Called on CoachDictionary's queue only.
    static func records(_ word: String) -> [String]? {
        guard let calls, let dictionary = openDictionary(calls) else { return nil }
        guard let found = calls.copyRecords(dictionary, word as CFString, nil, nil)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        return found.prefix(8).compactMap { calls.copyData($0, 0)?.takeRetainedValue() as String? }
    }

    private static func openDictionary(_ calls: Calls) -> CFTypeRef? {
        if let dictionary { return dictionary }
        if let lastSearch, Date().timeIntervalSince(lastSearch) < 60 { return nil }
        lastSearch = Date()
        let all = (calls.copyAvailable()?.takeRetainedValue() as NSSet?)?.allObjects ?? []
        let match = all.first { (calls.identifier($0 as CFTypeRef)?.takeUnretainedValue() as String?) == identifier }
        guard let match, let url = calls.url(match as CFTypeRef)?.takeUnretainedValue() as URL?,
              FileManager.default.fileExists(atPath: url.path)
        else {
            Logger.info("TypeRight: 牛津英汉汉英词典 is not on this Mac; the word layer says how to add it", category: Logger.general)
            return nil
        }
        dictionary = match as CFTypeRef
        return dictionary
    }
}
