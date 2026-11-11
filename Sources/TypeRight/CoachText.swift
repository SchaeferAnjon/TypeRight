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
    static func wordRange(of piece: String, in text: String, from: String.Index? = nil) -> Range<String.Index>? {
        guard !piece.isEmpty else { return nil }
        var searchStart = from ?? text.startIndex
        while searchStart < text.endIndex, let found = text.range(of: piece, range: searchStart ..< text.endIndex) {
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
