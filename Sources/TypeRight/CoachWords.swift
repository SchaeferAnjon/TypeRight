//
//  CoachWords.swift
//  TypeRight
//
//  The English words on a card the mouse can stop on, and how the card's text is cut into pieces
//  that stay on one line. Kept free of the screen so the rules can be tested on their own.
//

import Foundation

enum CoachWords {
    /// Words too small to be worth a look; the mouse passes over them without a flicker.
    static let functionWords: Set<String> = Set("""
    a an the of and or but nor to in on at by for with from as than that this these those it its i you he she we \
    they me him her us them my your his our their is are was were be been am do does did will would can could shall \
    should may might must not if so
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    /// Whether a word TypeRight gave on the card opens the word layer. `always`: it is the change of
    /// a sentence card, or the only word on the card.
    static func isHoverable(_ word: String, always: Bool = false) -> Bool {
        always || !isFunctionWord(word)
    }

    /// A small word, or one written short with one: it's, I'm, don't, we'll.
    static func isFunctionWord(_ word: String) -> Bool {
        let word = word.lowercased().replacingOccurrences(of: "’", with: "'")
        if functionWords.contains(word) || word.hasSuffix("n't") { return true }
        guard let mark = word.firstIndex(of: "'") else { return false }
        return functionWords.union(["there", "let", "what", "who", "where", "how"]).contains(String(word[..<mark]))
    }

    /// A piece of the card's text that is never split across lines.
    struct Piece: Equatable {
        enum Kind: Equatable { case word, space, han, other }
        var text: String
        var kind: Kind
        /// Scalar offset in the text it came from.
        var offset: Int
    }

    /// Punctuation that never starts a line (it goes with the piece before it).
    static let closing: Set<Unicode.Scalar> = [
        ",", ".", ";", ":", "!", "?", ")", "]", "}", "%", "”", "’", "，", "。", "、", "；", "：", "！", "？", "）", "」", "』", "》", "…",
    ]
    /// Punctuation that never ends a line (it goes with the piece after it).
    static let opening: Set<Unicode.Scalar> = ["(", "[", "{", "“", "‘", "（", "「", "『", "《"]

    /// The text cut into units that stay on one line: a Latin word with what touches it, a single
    /// Chinese character with the punctuation after it, or a run of spaces. A line may break
    /// between any two units.
    static func units(of text: String) -> [[Piece]] {
        var units: [[Piece]] = []
        for piece in pieces(of: text) {
            if let last = units.last?.last, glued(last, piece) {
                units[units.count - 1].append(piece)
            } else {
                units.append([piece])
            }
        }
        return units
    }

    /// The English words of `text`, with their scalar offsets.
    static func words(in text: String) -> [Piece] {
        pieces(of: text).filter { $0.kind == .word }
    }

    private static func glued(_ a: Piece, _ b: Piece) -> Bool {
        if a.kind == .space || b.kind == .space { return false }
        if let first = b.text.unicodeScalars.first, closing.contains(first) { return true }
        if let last = a.text.unicodeScalars.last, opening.contains(last) { return true }
        return a.kind != .han && b.kind != .han
    }

    private static func pieces(of text: String) -> [Piece] {
        let scalars = Array(text.unicodeScalars)
        var out: [Piece] = []
        var i = 0
        func emit(_ range: Range<Int>, _ kind: Piece.Kind) {
            out.append(Piece(text: CoachText.substring(scalars, range), kind: kind, offset: range.lowerBound))
        }
        while i < scalars.count {
            let c = scalars[i]
            if CoachText.isLatinLetter(c) {
                var end = i + 1
                while end < scalars.count {
                    let next = scalars[end]
                    if CoachText.isLatinLetter(next) {
                        end += 1
                    } else if ["'", "’", "-"].contains(next), end + 1 < scalars.count, CoachText.isLatinLetter(scalars[end + 1]) {
                        end += 2
                    } else {
                        break
                    }
                }
                emit(i ..< end, .word)
                i = end
            } else if c == " " || c == "\u{00A0}" {
                var end = i + 1
                while end < scalars.count, scalars[end] == " " || scalars[end] == "\u{00A0}" {
                    end += 1
                }
                emit(i ..< end, .space)
                i = end
            } else {
                emit(i ..< i + 1, ChineseText.isHan(c) ? .han : .other)
                i += 1
            }
        }
        return out
    }
}
