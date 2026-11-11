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
    case failed(String)

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
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .sentence(_, check):
            Text(highlighted(check))
                .font(.system(size: 15))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(check.changes.prefix(4).enumerated()), id: \.offset) { _, change in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(change.from).strikethrough().foregroundStyle(.secondary)
                        Text("→").foregroundStyle(.tertiary)
                        Text(change.to).fontWeight(.medium).foregroundStyle(CoachPalette.fix(scheme))
                        Text(change.why).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12.5))
                }
            }
        case let .failed(message):
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                Text("记进生词本").foregroundStyle(.tertiary)
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

    /// The corrected sentence with each changed piece tinted green: whole words only, found in the
    /// order of the changes, so a change `a` never lights up the a inside `have`.
    private func highlighted(_ check: CoachSentenceCheck) -> AttributedString {
        var text = AttributedString(check.corrected)
        for found in CoachText.orderedWordRanges(of: check.changes.map(\.to), in: check.corrected) {
            guard let found, let range = Range(found, in: text) else { continue }
            text[range].foregroundColor = CoachPalette.fix(scheme)
            text[range].backgroundColor = CoachPalette.fixSoft(scheme)
        }
        return text
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

struct KeyCap: View {
    let label: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(CoachPalette.line(scheme), lineWidth: 0.5))
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
