//
//  PinyinDetector.swift
//  TypeRight
//
//  Tells whether a word the spell checker rejected is really pinyin (`yuyue`), so TypeRight
//  offers the English for it instead of a spelling fix. The syllables are read off the system's
//  own Han-to-Latin transliteration once, so only syllables Mandarin really has are accepted.
//

import Foundation

enum PinyinDetector {
    /// Every toneless syllable (about 410), with ü written as v the way people type it.
    private static let syllables: Set<String> = {
        var view = String.UnicodeScalarView()
        for value in 0x4E00 ... 0x9FFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            view.append(scalar)
            view.append(" ")
        }
        let latin = String(view).applyingTransform(.toLatin, reverse: false) ?? ""
        var set: Set<String> = ["lv", "nv", "lve", "nve"]
        for raw in latin.split(separator: " ") {
            let decomposed = raw.lowercased().decomposedStringWithCanonicalMapping
                .replacingOccurrences(of: "u\u{0308}", with: "v")
            let plain = String(String.UnicodeScalarView(decomposed.unicodeScalars.filter {
                $0.properties.generalCategory != .nonspacingMark
            }))
            if !plain.isEmpty, plain.unicodeScalars.allSatisfy({ ("a" ... "z").contains($0) }) {
                set.insert(plain)
            }
        }
        return set
    }()

    /// Builds the syllable table off the main thread so the first check is instant.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async { _ = syllables.count }
    }

    /// True when `word` splits completely into two or more pinyin syllables. A one-letter syllable
    /// counts only for a, e or o at the start of the word, so `namee` or `emmm` never split.
    static func isLikelyPinyin(_ word: String) -> Bool {
        let lower = word.lowercased()
        guard lower.count >= 4, lower.count <= 24,
              lower.unicodeScalars.allSatisfy({ ("a" ... "z").contains($0) }),
              !isLaughter(lower),
              let parts = split(lower) else { return false }
        return parts.count >= 2
    }

    /// Pinyin rather than a misspelling. Harper's first suggestion close to the word (2 edits or fewer)
    /// means a typo (`hapen` → happen, `meen` → mean), unless the word has syllables English hardly
    /// has (`nihao`, `xiexie`, `pengyou`): Harper knows many names, so `nihao` is one edit from `niha`.
    static func treatAsPinyin(_ word: String, firstSuggestion: String?) -> Bool {
        guard isLikelyPinyin(word) else { return false }
        guard let suggestion = firstSuggestion, editDistance(word.lowercased(), suggestion.lowercased()) <= 2 else { return true }
        return split(word.lowercased())?.contains(where: isDistinctlyChinese) ?? false
    }

    /// Fewest syllables that cover the whole word, or nil when it cannot be split.
    private static func split(_ word: String) -> [String]? {
        let chars = Array(word)
        let n = chars.count
        var best = [Int](repeating: Int.max, count: n + 1)
        var from = [Int](repeating: -1, count: n + 1)
        best[0] = 0
        for start in 0 ..< n where best[start] != Int.max {
            for length in 1 ... min(6, n - start) {
                let piece = String(chars[start ..< start + length])
                guard syllables.contains(piece), length > 1 || (start == 0 && ["a", "e", "o"].contains(piece)) else { continue }
                if best[start] + 1 < best[start + length] {
                    best[start + length] = best[start] + 1
                    from[start + length] = start
                }
            }
        }
        guard best[n] != Int.max else { return nil }
        var parts: [String] = []
        var end = n
        while end > 0 {
            let start = from[end]
            parts.insert(String(chars[start ..< end]), at: 0)
            end = start
        }
        return parts
    }

    /// Syllables that English words rarely contain: x, q, j and zh starts, y with i or u, and finals
    /// such as ao, ou, ie, ue, ui, iu, uo, ei, ian, uan, ang, ong, eng.
    private static func isDistinctlyChinese(_ syllable: String) -> Bool {
        if ["x", "q", "j", "zh"].contains(where: { syllable.hasPrefix($0) }) { return true }
        if syllable.hasPrefix("yi") || syllable.hasPrefix("yu") { return true }
        return ["ao", "ou", "ie", "ue", "ve", "ui", "iu", "uo", "ei", "ia", "ua", "ang", "ong", "eng"].contains { syllable.contains($0) }
    }

    /// haha, hehe, heihei: laughter, not words to translate.
    private static func isLaughter(_ word: String) -> Bool {
        ["ha", "he", "hei", "hia"].contains { unit in
            word.count % unit.count == 0 && String(repeating: unit, count: word.count / unit.count) == word
        }
    }

    /// Edits (insert, delete, replace, swap two neighbours) between two words.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0 ... a.count {
            d[i][0] = i
        }
        for j in 0 ... b.count {
            d[0][j] = j
        }
        for i in 1 ... a.count {
            for j in 1 ... b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }
}

enum ChineseText {
    /// Han characters (CJK Unified Ideographs and Extension A).
    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00 ... 0x9FFF).contains(scalar.value) || (0x3400 ... 0x4DBF).contains(scalar.value)
    }

    /// Runs of Han characters in `scalars`, as half-open scalar ranges.
    static func hanRuns(in scalars: [Unicode.Scalar], from start: Int, to end: Int) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var runStart: Int?
        for i in start ..< end {
            if isHan(scalars[i]) {
                if runStart == nil { runStart = i }
            } else if let s = runStart {
                runs.append(s ..< i)
                runStart = nil
            }
        }
        if let s = runStart { runs.append(s ..< end) }
        return runs
    }

    /// Number of Latin words of two or more letters.
    static func latinWordCount(in scalars: [Unicode.Scalar], from start: Int, to end: Int) -> Int {
        var count = 0
        var letters = 0
        for i in start ..< end {
            let v = scalars[i].value
            if (0x41 ... 0x5A).contains(v) || (0x61 ... 0x7A).contains(v) {
                letters += 1
            } else {
                if letters >= 2 { count += 1 }
                letters = 0
            }
        }
        if letters >= 2 { count += 1 }
        return count
    }
}
