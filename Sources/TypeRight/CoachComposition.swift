//
//  CoachComposition.swift
//  TypeRight
//
//  Is an input method composing in the field? AppKit and WebKit say so through
//  AXTextInputMarkedRange; Chrome and the other Chromium-based apps do not (their accessibility
//  has no such attribute), so there pinyin syllables like `yu yue` sat in the field and were taken
//  for misspellings. Where the app does not say, TypeRight guesses from two things it can see: the
//  current input source turns Latin letters into Chinese or Japanese, and the letters before the
//  caret were typed after the last space or punctuation key (an input method commits with a space,
//  a digit or Return; its own syllable breaks are not keys). When unsure it holds back: no spelling
//  card, no AI request, until a word end is typed or the letters turn into Chinese.
//

import Carbon
import Foundation

enum CoachComposing: Equatable, Sendable {
    /// Nothing is being composed.
    case no
    /// The app says an input method holds text it has not committed.
    case yes
    /// The app does not say, and the letters before the caret may be an input method's syllables.
    case maybe
}

enum CoachComposition {
    /// Letters typed longer ago than this are not taken for syllables any more.
    static let recent: TimeInterval = 60

    /// - Parameters:
    ///   - marked: what the app says about marked text; nil when it does not say.
    ///   - lettersCompose: the input source turns Latin letters into Chinese or Japanese.
    ///   - lettersSinceWordEnd: a letter key was pressed after the last space or punctuation key.
    static func state(marked: Bool?, lettersCompose: @autoclosure () -> Bool, lettersSinceWordEnd: Bool,
                      scalars: [Unicode.Scalar], caret: Int) -> CoachComposing {
        if let marked { return marked ? .yes : .no }
        guard lettersSinceWordEnd, caret > 0, caret <= scalars.count, lettersCompose() else { return .no }
        // Syllables sit right before the caret; an input method shows its breaks as ' (WeChat, Sogou) or a space.
        let last = scalars[caret - 1]
        return CoachText.isLatinLetter(last) || last == "'" || last == " " ? .maybe : .no
    }
}

/// The current keyboard input source, as Text Input Sources reports it.
struct CoachInputSource: Equatable, Sendable {
    var id: String
    /// The input mode of a source that has modes (com.apple.inputmethod.SCIM.ITABC, …).
    var mode: String?
    /// An input method (it composes), not a plain keyboard layout.
    var isInputMethod: Bool
    var languages: [String]

    /// Pinyin, Wubi, Zhuyin, Japanese Kana and the like turn typed Latin letters into their script
    /// while they compose; their Roman (direct) modes do not.
    var composesLetters: Bool {
        guard isInputMethod, languages.contains(where: { $0.hasPrefix("zh") || $0.hasPrefix("ja") }) else { return false }
        return !(mode ?? id).lowercased().hasSuffix(".roman")
    }

    static var current: CoachInputSource? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        func string(_ key: CFString) -> String? {
            guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        }
        let type = string(kTISPropertyInputSourceType)
        var languages: [String] = []
        if let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
            languages = (Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String]) ?? []
        }
        return CoachInputSource(id: string(kTISPropertyInputSourceID) ?? "", mode: string(kTISPropertyInputModeID),
                                isInputMethod: type == (kTISTypeKeyboardInputMode as String) || type == (kTISTypeKeyboardInputMethodWithoutModes as String),
                                languages: languages)
    }
}
