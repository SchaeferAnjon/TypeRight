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

    /// True when `word` splits completely into two or more pinyin syllables.
    static func isLikelyPinyin(_ word: String) -> Bool {
        let lower = word.lowercased()
        guard lower.count >= 4, lower.count <= 24,
              lower.unicodeScalars.allSatisfy({ ("a" ... "z").contains($0) }) else { return false }
        return minimumSyllables(lower) >= 2
    }

    /// Fewest syllables that cover the whole word, or 0 when it cannot be split.
    private static func minimumSyllables(_ word: String) -> Int {
        let chars = Array(word)
        let n = chars.count
        var best = [Int](repeating: Int.max, count: n + 1)
        best[0] = 0
        for start in 0 ..< n where best[start] != Int.max {
            for length in 1 ... min(6, n - start) {
                if syllables.contains(String(chars[start ..< start + length])) {
                    best[start + length] = min(best[start + length], best[start] + 1)
                }
            }
        }
        return best[n] == Int.max ? 0 : best[n]
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
