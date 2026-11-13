//
//  CoachText.swift
//  TypeRight
//
//  Text rules the typing coach decides by, kept free of the app and the screen so each one can be
//  tested on its own. Positions are Unicode scalar offsets, the unit Harper reports errors in.
//

import Foundation

enum CoachText {
    static let sentenceEnds: Set<Unicode.Scalar> = [".", "?", "!", "\n", "。", "？", "！"]

    /// What may follow a word for it to count as finished. Path and handle characters
    /// (`/ - _ @`, digits) do not, so `src/` + Tab in a terminal is left alone.
    static let wordEnds: Set<Unicode.Scalar> = [" ", ",", ".", "!", "?", ";", ":", "，", "。", "！", "？", "；", "："]

    static func substring(_ scalars: [Unicode.Scalar], _ range: Range<Int>) -> String {
        let clamped = range.clamped(to: 0 ..< scalars.count)
        return String(String.UnicodeScalarView(scalars[clamped]))
    }

    static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a" ... "z").contains(scalar) || ("A" ... "Z").contains(scalar)
    }

    static func isLatinLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        isLatinLetter(scalar) || ("0" ... "9").contains(scalar)
    }

    // MARK: Sentences

    /// From just after the previous sentence end up to `end`.
    static func sentenceRange(endingNear end: Int, in scalars: [Unicode.Scalar]) -> Range<Int> {
        let end = min(max(end, 0), scalars.count)
        var start = end
        while start > 0, !sentenceEnds.contains(scalars[start - 1]) {
            start -= 1
        }
        while start < end, scalars[start] == " " || scalars[start] == "\t" {
            start += 1
        }
        return start ..< end
    }

    /// The sentence whose . ? ! sits right before the caret (spaces allowed in between).
    static func finishedSentence(before caret: Int, in scalars: [Unicode.Scalar]) -> Range<Int>? {
        var end = min(max(caret, 0), scalars.count)
        while end > 0, scalars[end - 1] == " " {
            end -= 1
        }
        guard end > 0, [".", "?", "!"].contains(scalars[end - 1]) else { return nil }
        let range = sentenceRange(endingNear: end - 1, in: scalars)
        return range.lowerBound < end - 1 ? range.lowerBound ..< end : nil
    }

    static func lastWordRange(in scalars: [Unicode.Scalar], within range: Range<Int>) -> Range<Int> {
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

    /// A sentence of the field and whether it was ended with . ? ! (a line break or the end of the
    /// text without one leaves it unfinished).
    struct Sentence: Equatable {
        var range: Range<Int>
        var finished: Bool
    }

    static let terminators: Set<Unicode.Scalar> = [".", "?", "!", "。", "？", "！"]
    /// Closing quotes and brackets that belong to the sentence they follow: `He said "hi."`.
    static let closers: Set<Unicode.Scalar> = ["\"", "'", "”", "’", ")", "]", "}", "」", "』", "）", "》"]

    /// Every sentence of the text, the way people type in chat boxes: `i dont now this .this is
    /// vertical, bro. Hope you're doing good.` is three sentences. A period without a space after it
    /// ends a sentence only when a space comes before it (`this .this`) or a capital follows a word
    /// (`good.Thanks`), so `3.5`, `example.com` and `README.md` stay whole.
    static func sentences(in scalars: [Unicode.Scalar]) -> [Sentence] {
        var out: [Sentence] = []
        var start = 0
        func emit(_ end: Int, finished: Bool) {
            var lower = start
            while lower < end, isSpace(scalars[lower]) {
                lower += 1
            }
            var upper = end
            while upper > lower, isSpace(scalars[upper - 1]) {
                upper -= 1
            }
            if lower < upper { out.append(Sentence(range: lower ..< upper, finished: finished)) }
            start = end
        }
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "\n" || c == "\r" {
                emit(i, finished: false)
                start = i + 1
                i += 1
                continue
            }
            guard terminators.contains(c) else {
                i += 1
                continue
            }
            var j = i
            while j < scalars.count, terminators.contains(scalars[j]) {
                j += 1
            }
            while j < scalars.count, closers.contains(scalars[j]) {
                j += 1
            }
            if endsSentence(scalars, run: i ..< j) { emit(j, finished: true) }
            i = j
        }
        emit(scalars.count, finished: false)
        return out
    }

    /// Whether the terminators at `run` (closing quotes included) end a sentence.
    private static func endsSentence(_ s: [Unicode.Scalar], run: Range<Int>) -> Bool {
        guard run.upperBound < s.count else { return true }
        let next = s[run.upperBound]
        if isSpace(next) || next == "\n" || next == "\r" { return true }
        let before = run.lowerBound > 0 ? s[run.lowerBound - 1] : " "
        let onlyPeriods = s[run].allSatisfy { $0 == "." || closers.contains($0) }
        if !onlyPeriods {
            // `really?yes`, but not `/?q=1` in a link.
            return ChineseText.isHan(next) || (isLetter(next) && (isLetter(before) || isSpace(before)))
        }
        if ChineseText.isHan(next) { return true }
        guard isLetter(next) else { return false }
        if isSpace(before) { return true }
        // `good.Thanks`: a capital right after a word of two letters or more.
        guard ("A" ... "Z").contains(next), ("a" ... "z").contains(before) else { return false }
        let letters = s[..<run.lowerBound].reversed().prefix { isLatinLetter($0) }.count
        return letters >= 2
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\u{00A0}"
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.letters.contains(scalar)
    }

    /// The sentence that holds `offset`, or the one ending right there.
    static func sentence(at offset: Int, in sentences: [Sentence]) -> Sentence? {
        sentences.first { $0.range.contains(offset) || $0.range.upperBound == offset }
    }

    // MARK: Words

    /// Words the edit just finished: a word of Latin letters (with ' ’ and - inside) right before a
    /// space or punctuation the edit typed. Words in paths, handles and links (`src/x`, `@x`, `a.b`)
    /// are left alone.
    static func finishedWords(in scalars: [Unicode.Scalar], by edit: Edit) -> [Range<Int>] {
        let typed = edit.start ..< min(edit.start + edit.inserted, scalars.count)
        var out: [Range<Int>] = []
        for end in typed where wordEnds.contains(scalars[end]) {
            var start = end
            while start > 0, isWordPart(scalars, at: start - 1) {
                start -= 1
            }
            guard start < end,
                  scalars[start ..< end].count(where: isLatinLetter) >= 2,
                  isLatinLetter(scalars[start]),
                  start == 0 || isWordBoundaryBefore(scalars[start - 1]) else { continue }
            var trimmed = end
            while trimmed > start, !isLatinLetter(scalars[trimmed - 1]) {
                trimmed -= 1
            }
            out.append(start ..< trimmed)
        }
        return out
    }

    private static func isWordPart(_ s: [Unicode.Scalar], at index: Int) -> Bool {
        let c = s[index]
        if isLatinLetter(c) { return true }
        guard c == "'" || c == "’" || c == "-" else { return false }
        return index > 0 && isLatinLetter(s[index - 1])
    }

    private static func isWordBoundaryBefore(_ scalar: Unicode.Scalar) -> Bool {
        isSpace(scalar) || scalar == "\n" || ["(", "\"", "“", "‘", "'", "["].contains(scalar)
            || ChineseText.isHan(scalar) || ["?", "!", ",", ";", ":", "。", "？", "！", "，", "；", "："].contains(scalar)
    }

    // MARK: Sentence edits from the AI

    /// The sentence with the AI's edits put in: each `from` found as whole words (exact case first),
    /// near where the previous one was, never overlapping another. Returns the indices of the edits
    /// that found their place; the others are left out of the sentence.
    static func applying(_ edits: [(from: String, to: String)], to original: String) -> (text: String, placed: [Int]) {
        let spots = spots(of: edits, in: original)
        var text = ""
        var at = original.startIndex
        for spot in spots {
            text += original[at ..< spot.range.lowerBound]
            text += spot.to
            at = spot.range.upperBound
        }
        text += original[at...]
        return (text, spots.map(\.index).sorted())
    }

    /// Where `applying` puts each edit in `original`, in the order of the text.
    private static func spots(of edits: [(from: String, to: String)], in original: String) -> [(range: Range<String.Index>, to: String, index: Int)] {
        var spots: [(range: Range<String.Index>, to: String, index: Int)] = []
        var cursor = original.startIndex
        for (index, edit) in edits.enumerated() where !edit.from.isEmpty && edit.from != edit.to {
            let tries: [Range<String.Index>?] = [
                wordRange(of: edit.from, in: original, from: cursor),
                wordRange(of: edit.from, in: original),
                wordRange(of: edit.from, in: original, from: cursor, options: .caseInsensitive),
                wordRange(of: edit.from, in: original, options: .caseInsensitive),
            ]
            guard var found = tries.compactMap({ $0 }).first(where: { hit in !spots.contains { $0.range.overlaps(hit) } }) else { continue }
            if edit.to.isEmpty { found = widenedOverASpace(found, in: original) }
            spots.append((found, edit.to, index))
            cursor = found.upperBound
        }
        return spots.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// One change of a sentence card where it sits in the original sentence: `range` (scalar offsets)
    /// becomes `to`. A change that only takes words out has an empty `to`.
    struct Placement: Equatable {
        var range: Range<Int>
        var from: String
        var to: String
    }

    /// The card's changes where they sit in `original`, in the order of the text, placed the same
    /// way the corrected sentence was made. Typing along goes from one to the next.
    static func placements(of changes: [CoachSentenceCheck.Change], in original: String) -> [Placement] {
        let scalars = original.unicodeScalars
        return spots(of: changes.map { ($0.from, $0.to) }, in: original).map { spot in
            let start = scalars.distance(from: scalars.startIndex, to: spot.range.lowerBound)
            let length = scalars.distance(from: spot.range.lowerBound, to: spot.range.upperBound)
            return Placement(range: start ..< start + length, from: String(original[spot.range]), to: spot.to)
        }
    }

    /// A word taken out takes one space with it, so `I very like it` becomes `I like it`.
    private static func widenedOverASpace(_ range: Range<String.Index>, in text: String) -> Range<String.Index> {
        if range.upperBound < text.endIndex, text[range.upperBound] == " " {
            return range.lowerBound ..< text.index(after: range.upperBound)
        }
        if range.lowerBound > text.startIndex, text[text.index(before: range.lowerBound)] == " " {
            return text.index(before: range.lowerBound) ..< range.upperBound
        }
        return range
    }

    /// Chinese turns into English by itself only in a sentence that is mostly English: it starts
    /// with a Latin word, has at least two Latin words of two letters or more, and at least as many
    /// of those as runs of Chinese. `明天 meeting 改到下午` or `OK，我明天到` wait for the translate key.
    static func shouldAutoTranslate(_ scalars: [Unicode.Scalar], in range: Range<Int>) -> Bool {
        let range = range.clamped(to: 0 ..< scalars.count)
        guard let first = scalars[range].first(where: { isLatinLetter($0) || ChineseText.isHan($0) }),
              isLatinLetter(first) else { return false }
        let han = ChineseText.hanRuns(in: scalars, from: range.lowerBound, to: range.upperBound).count
        let latin = ChineseText.latinWordCount(in: scalars, from: range.lowerBound, to: range.upperBound)
        return han > 0 && latin >= 2 && latin >= han
    }

    // MARK: Edits between two readings of a field

    /// The one stretch that differs between two texts: `removed` scalars at `start` of the old text
    /// became `inserted` scalars. Several edits between two readings show up as one covering edit.
    struct Edit: Equatable {
        let start: Int
        let removed: Int
        let inserted: Int

        /// How much was typed or deleted.
        var size: Int { max(removed, inserted) }

        /// Where `range` of the old text is in the new one, or nil when the edit touched it.
        func shift(_ range: Range<Int>) -> Range<Int>? {
            if range.upperBound <= start { return range }
            if range.lowerBound >= start + removed {
                let delta = inserted - removed
                return range.lowerBound + delta ..< range.upperBound + delta
            }
            return nil
        }
    }

    static func edit(from old: String, to new: String) -> Edit? {
        guard old != new else { return nil }
        let a = Array(old.unicodeScalars)
        let b = Array(new.unicodeScalars)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        return Edit(start: prefix, removed: a.count - prefix - suffix, inserted: b.count - prefix - suffix)
    }

    /// `text` with `range` replaced.
    static func replacing(_ range: Range<Int>, in text: String, with replacement: String) -> String {
        let scalars = Array(text.unicodeScalars)
        let range = range.clamped(to: 0 ..< scalars.count)
        var view = String.UnicodeScalarView(scalars[..<range.lowerBound])
        view.append(contentsOf: replacement.unicodeScalars)
        view.append(contentsOf: scalars[range.upperBound...])
        return String(view)
    }

    /// English written over Chinese that touches Latin letters or digits gets a space on that side:
    /// `to预约a` becomes `to book a`, not `tobooka`.
    static func spaced(_ replacement: String, replacing range: Range<Int>, in scalars: [Unicode.Scalar]) -> String {
        var out = replacement
        if range.lowerBound > 0, range.lowerBound <= scalars.count, isLatinLetterOrDigit(scalars[range.lowerBound - 1]),
           let first = replacement.unicodeScalars.first, isLatinLetterOrDigit(first)
        {
            out = " " + out
        }
        if range.upperBound < scalars.count, isLatinLetterOrDigit(scalars[range.upperBound]),
           let last = replacement.unicodeScalars.last, isLatinLetterOrDigit(last)
        {
            out += " "
        }
        return out
    }

    // MARK: Words inside a sentence

    /// `piece` as whole words in `text` at or after `from`: a change `a` is never found inside `have`.
    static func wordRange(of piece: String, in text: String, from: String.Index? = nil,
                          options: String.CompareOptions = []) -> Range<String.Index>?
    {
        guard !piece.isEmpty else { return nil }
        var searchStart = from ?? text.startIndex
        while searchStart < text.endIndex, let found = text.range(of: piece, options: options, range: searchStart ..< text.endIndex) {
            let startsWord = piece.first.map(isWordCharacter) ?? false
            let endsWord = piece.last.map(isWordCharacter) ?? false
            let beforeOK = !startsWord || found.lowerBound == text.startIndex || !isWordCharacter(text[text.index(before: found.lowerBound)])
            let afterOK = !endsWord || found.upperBound == text.endIndex || !isWordCharacter(text[found.upperBound])
            if beforeOK, afterOK { return found }
            searchStart = text.index(after: found.lowerBound)
        }
        return nil
    }

    /// Where each change sits, in the order the changes come: each search starts after the previous find.
    static func orderedWordRanges(of pieces: [String], in text: String) -> [Range<String.Index>?] {
        var cursor = text.startIndex
        return pieces.map { piece in
            guard let found = wordRange(of: piece, in: text, from: cursor) else { return nil }
            cursor = found.upperBound
            return found
        }
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    /// The scalar range of the first change's original words inside `range` of `scalars`.
    static func firstChangeRange(_ check: CoachSentenceCheck, in scalars: [Unicode.Scalar], within range: Range<Int>) -> Range<Int>? {
        let sentence = substring(scalars, range)
        let found = orderedWordRanges(of: check.changes.map(\.from), in: sentence)
        for (change, hit) in zip(check.changes, found) where !change.from.isEmpty {
            guard let hit else { continue }
            let start = sentence.unicodeScalars.distance(from: sentence.unicodeScalars.startIndex, to: hit.lowerBound)
            let length = sentence.unicodeScalars.distance(from: hit.lowerBound, to: hit.upperBound)
            return range.lowerBound + start ..< range.lowerBound + start + length
        }
        return nil
    }
}

/// A set that forgets its oldest members past `limit`.
struct CappedSet<Element: Hashable> {
    let limit: Int
    private var members = Set<Element>()
    private var order: [Element] = []

    init(limit: Int) {
        self.limit = limit
    }

    func contains(_ element: Element) -> Bool { members.contains(element) }

    var count: Int { members.count }

    mutating func insert(_ element: Element) {
        guard members.insert(element).inserted else { return }
        order.append(element)
        if order.count > limit {
            let dropped = order.removeFirst()
            members.remove(dropped)
        }
    }
}
