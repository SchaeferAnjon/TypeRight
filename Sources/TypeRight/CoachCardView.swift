//
//  CoachCardView.swift
//  TypeRight
//
//  The word-anchored card (direction A in DESIGN.md): a small card under the word with a tail
//  pointing at it, flipped above when there is no room below. Wrong words are grey and struck
//  through, fixed words green; nothing in the product is marked red.
//

import AVFoundation
import SwiftUI

enum CoachCardContent: Equatable {
    case spelling(wrong: String, fixes: [String])
    case translate(source: String, result: CoachTranslation)
    case sentence(original: String, check: CoachSentenceCheck)
    case thinking
    /// `keyRejected`: the provider turned the saved key down, so the card carries a `danger` dot.
    case failed(String, keyRejected: Bool = false)

    /// The text Tab writes into the field, if this card has one.
    var acceptText: String? {
        switch self {
        case let .spelling(_, fixes): fixes.first
        case let .translate(_, result): result.english
        case let .sentence(_, check): check.ok ? nil : check.corrected
        case .thinking, .failed: nil
        }
    }

    var acceptLabel: String {
        switch self {
        case let .spelling(_, fixes): "改成 \(fixes.first ?? "")"
        case let .translate(_, result): "换成 \(result.english)"
        case .sentence: "整句换掉"
        case .thinking, .failed: ""
        }
    }
}

enum CoachPalette {
    static func fix(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0x52 / 255, green: 0xC6 / 255, blue: 0x90 / 255) : Color(red: 0x13 / 255, green: 0x80 / 255, blue: 0x4B / 255)
    }

    static func fixSoft(_ scheme: ColorScheme) -> Color {
        fix(scheme).opacity(scheme == .dark ? 0.15 : 0.11)
    }

    static func pop(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0x2A / 255, green: 0x2B / 255, blue: 0x30 / 255) : .white
    }

    static func line(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)
    }
}

/// What the keys row says. `copy`: in an app where writing back went wrong, Tab copies the fix
/// instead. `readOnly`: keys cannot be taken (no key tap, or a password field holds Secure Event
/// Input), so no key hints at all and the card leaves by itself.
enum CoachCardKeys: Equatable {
    case normal
    case copy
    case readOnly
}

/// Where the tail sits: on top when the card is under the word, at the bottom when above it.
struct CoachTailPlacement: Equatable {
    var pointsUp: Bool
    var x: CGFloat
}

struct CoachCardView: View {
    let content: CoachCardContent
    let tail: CoachTailPlacement?
    var keys: CoachCardKeys = .normal
    var onSpeak: (String) -> Void = { _ in }

    @Environment(\.colorScheme) private var scheme

    static let tailHeight: CGFloat = 7
    static let shadowMargin: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            if let tail, tail.pointsUp { tailShape(up: true, x: tail.x) }
            card
            if let tail, !tail.pointsUp { tailShape(up: false, x: tail.x) }
        }
        .padding(Self.shadowMargin)
        .fixedSize()
    }

    @ViewBuilder private var card: some View {
        Group {
            switch content {
            case .thinking:
                Text("想一下…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            default:
                VStack(alignment: .leading, spacing: 8) {
                    main
                    if keys != .readOnly { keysRow }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: 440, alignment: .leading)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: content == .thinking ? 999 : 12, style: .continuous)
                .fill(CoachPalette.pop(scheme))
                .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.16), radius: 10, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: content == .thinking ? 999 : 12, style: .continuous)
                .strokeBorder(CoachPalette.line(scheme), lineWidth: 0.5)
        )
    }

    @ViewBuilder private var main: some View {
        switch content {
        case let .spelling(wrong, fixes):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                wrongText(wrong)
                arrow
                fixedText(fixes.first ?? "")
            }
            if fixes.count > 1 {
                Text("也可能是：" + fixes.dropFirst().prefix(3).joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case let .translate(source, result):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(source).font(.system(size: 14)).foregroundStyle(.secondary)
                arrow
                fixedText(result.english)
                if !result.ipa.isEmpty {
                    Text(result.ipa).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Button { onSpeak(result.english) } label: {
                    Image(systemName: "speaker.wave.2").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("听发音")
            }
            if !result.note.isEmpty {
                Text(result.note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .sentence(_, check):
            let sentence = sentenceDiff(check)
            Text(sentence.text)
                .font(.system(size: 15))
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
            if !sentence.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(sentence.notes.enumerated()), id: \.offset) { _, note in
                        Text(note)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) {
                    Rectangle().fill(CoachPalette.line(scheme)).frame(height: 0.5)
                }
            }
        case let .failed(message, keyRejected):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if keyRejected {
                    Circle().fill(TR.danger).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                }
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .thinking:
            EmptyView()
        }
    }

    private var keysRow: some View {
        HStack(spacing: 6) {
            if let accept = content.acceptText {
                KeyCap(label: "Tab")
                Text(keys == .copy ? "复制 \(accept)" : content.acceptLabel).lineLimit(1)
                Spacer().frame(width: 6)
            }
            KeyCap(label: "Esc")
            Text(content.acceptText == nil ? "关掉" : "不改")
            if case .translate = content, keys == .normal {
                Spacer(minLength: 12)
                Text("记进生词本").foregroundStyle(TR.text2)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private var arrow: some View {
        Text("→").font(.system(size: 13)).foregroundStyle(.tertiary)
    }

    private func wrongText(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).strikethrough().foregroundStyle(.secondary)
    }

    private func fixedText(_ text: String) -> some View {
        Text(text).font(.system(size: 18, weight: .semibold)).foregroundStyle(CoachPalette.fix(scheme))
    }

    /// The corrected sentence with each change shown in place: the old words grey and struck
    /// through, right before the new words in green. Changes are found as whole words in the order
    /// they come, so a change `a` never lights up the a inside `have`. Under it the reasons; a change
    /// that could not be placed in the sentence keeps its "old → new" in front of its reason.
    private func sentenceDiff(_ check: CoachSentenceCheck) -> (text: AttributedString, notes: [String]) {
        let corrected = check.corrected
        let found = CoachText.orderedWordRanges(of: check.changes.map(\.to), in: corrected)
        var text = AttributedString()
        var notes: [String] = []
        var cursor = corrected.startIndex
        for (change, hit) in zip(check.changes, found) {
            let why = change.why.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let hit, !change.to.isEmpty, hit.lowerBound >= cursor else {
                notes.append([change.from.isEmpty ? change.to : "\(change.from) → \(change.to)", why].filter { !$0.isEmpty }.joined(separator: "  "))
                continue
            }
            text += AttributedString(corrected[cursor ..< hit.lowerBound])
            // A short change stays on one line with its old words: "I" at a line's end and
            // "have" on the next reads as two changes.
            let together = change.from.count + corrected[hit].count <= 32
            func keep(_ piece: some StringProtocol) -> String {
                together ? piece.replacingOccurrences(of: " ", with: "\u{00A0}") : String(piece)
            }
            if !change.from.isEmpty {
                var old = AttributedString(keep(change.from))
                old.strikethroughStyle = .single
                old.foregroundColor = TR.text3
                old.font = .system(size: 13)
                text += old
                text += AttributedString(together ? "\u{00A0}" : " ")
            }
            var new = AttributedString(keep(corrected[hit]))
            new.foregroundColor = CoachPalette.fix(scheme)
            new.backgroundColor = CoachPalette.fixSoft(scheme)
            new.font = .system(size: 15, weight: .semibold)
            text += new
            cursor = hit.upperBound
            if !why.isEmpty, !notes.contains(why) { notes.append(why) }
        }
        text += AttributedString(corrected[cursor...])
        return (text, Array(notes.prefix(4)))
    }

    private func tailShape(up: Bool, x: CGFloat) -> some View {
        CoachTail(up: up)
            .fill(CoachPalette.pop(scheme))
            .frame(width: 14, height: Self.tailHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(x: max(10, x - 7))
            .zIndex(1)
    }
}

struct CoachTail: Shape {
    let up: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        if up {
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        p.closeSubpath()
        return p
    }
}

/// Reads an English word or phrase aloud with the system voice.
@MainActor
enum CoachSpeaker {
    private static let synthesizer = AVSpeechSynthesizer()

    static func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: CoachSettings.accent == "uk" ? "en-GB" : "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        synthesizer.speak(utterance)
    }
}
