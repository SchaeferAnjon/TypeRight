//
//  CoachCardView.swift
//  TypeRight
//
//  The word-anchored card (direction A in DESIGN.md): a small card under the word with a tail
//  pointing at it, flipped above when there is no room below. Wrong words are grey and struck
//  through, fixed words green; nothing in the product is marked red.
//
//  The English TypeRight gives is laid out word by word, so the mouse can stop on a word and see
//  its IPA and meaning (CoachCardPanel watches the mouse). While the user types the English along
//  with the card, each character typed right turns green, a wrong one gets the amber mark.
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
    /// The membership cannot be used (said once, CoachNotice): no Tab, Esc closes, buttons for the mouse.
    case notice(CoachNotice)
    /// The same thing after that: a small capsule under the Chinese word that goes by itself.
    case pill(String)

    /// The text Tab writes into the field, if this card has one.
    var acceptText: String? {
        switch self {
        case let .spelling(_, fixes): fixes.first
        case let .translate(_, result): result.english
        case let .sentence(_, check): check.ok ? nil : check.corrected
        case .thinking, .failed, .notice, .pill: nil
        }
    }

    var acceptLabel: String {
        switch self {
        case let .spelling(_, fixes): "改成 \(fixes.first ?? "")"
        case let .translate(_, result): "换成 \(result.english)"
        case .sentence: "整句换掉"
        case .thinking, .failed, .notice, .pill: ""
        }
    }

    /// The English words on the card that open the word layer, each once, in the order they show:
    /// what TypeRight gave (the translation, the spelling and its other guesses, a sentence card's
    /// changed words) and the English inside the explanations. The user's own words do not.
    var hoverWords: [String] {
        var words: [String] = []
        func add(_ text: String, always: Bool) {
            for piece in CoachWords.words(in: text) where CoachWords.isHoverable(piece.text, always: always) {
                if !words.contains(where: { $0.lowercased() == piece.text.lowercased() }) { words.append(piece.text) }
            }
        }
        switch self {
        case let .spelling(_, fixes):
            fixes.prefix(4).forEach { add($0, always: true) }
        case let .translate(_, result):
            add(result.english, always: CoachWords.words(in: result.english).count == 1)
            add(result.note, always: false)
        case let .sentence(original, check):
            CoachText.placements(of: check.changes, in: original).forEach { add($0.to, always: true) }
            check.changes.forEach { add($0.why, always: false) }
        case .thinking, .failed, .notice, .pill:
            break
        }
        return words
    }
}

/// The prototype's small button on a notice card (24 high, 12 font, hairline).
private struct NoticeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(TR.text)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(configuration.isPressed ? TR.sel : TR.fill, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(TR.line2, lineWidth: 0.5))
            .contentShape(Rectangle())
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

/// What the keys row says. `normal`: Tab types along first. `direct`: Tab writes the fix at once
/// (设置 › 快捷键 › 按 Tab › 直接换, or a sentence card in an app where the caret cannot be put on
/// a word). `copy`: in an app where writing back went wrong, Tab copies the fix instead.
/// `readOnly`: keys cannot be taken (no key tap, or a password field holds Secure Event Input), so
/// no key hints at all and the card leaves by itself.
enum CoachCardKeys: Equatable {
    case normal
    case direct
    case copy
    case readOnly
}

/// The card while the user types its English in the field.
struct CoachFollow: Equatable {
    enum Phase: Equatable {
        case typing
        /// Recorded: all typed, or (`filled`) the rest filled in with Tab.
        case done(filled: Bool)
    }

    var phase: Phase = .typing
    /// The English being typed now; on a sentence card, the changed words at `step`.
    var target: String
    /// Characters of `target` typed right.
    var right = 0
    /// The character of `target` where typing went wrong (`target`'s length: one character too many).
    var wrongAt: Int?
    /// An input method holds letters it has not committed.
    var composing = false
    /// The app does not say whether an input method composes, and a Chinese one is on: the letters
    /// count, and the card reminds that syllables only count once they are committed.
    var inputMethodOn = false
    /// Sentence cards: which change is being typed.
    var step = 0
}

/// Where the tail sits: on top when the card is under the word, at the bottom when above it.
struct CoachTailPlacement: Equatable {
    var pointsUp: Bool
    var x: CGFloat
}

/// A word on the card the mouse can stop on, in the card view's coordinates (top-left origin).
struct CoachWordSpot: Equatable {
    var id: Int
    var word: String
    var frame: CGRect
}

struct CoachCardView: View {
    let content: CoachCardContent
    let tail: CoachTailPlacement?
    var keys: CoachCardKeys = .normal
    var follow: CoachFollow?
    /// The word the mouse rests on (a spot id): it gets a soft background.
    var hot: Int?
    /// While typing along the card keeps at least this width, so it does not jump as the keys row changes.
    var minWidth: CGFloat = 0
    var onSpeak: (String) -> Void = { _ in }
    /// Every word the mouse can stop on, whenever the layout changes.
    var onWords: ([CoachWordSpot]) -> Void = { _ in }
    /// A notice card's button.
    var onNotice: (CoachNotice.Action) -> Void = { _ in }

    @Environment(\.colorScheme) private var scheme

    static let tailHeight: CGFloat = 7
    static let shadowMargin: CGFloat = 14
    static let maxWidth: CGFloat = 440

    var body: some View {
        VStack(spacing: 0) {
            if let tail, tail.pointsUp { tailShape(up: true, x: tail.x) }
            card
            if let tail, !tail.pointsUp { tailShape(up: false, x: tail.x) }
        }
        .padding(Self.shadowMargin)
        .fixedSize()
        .overlayPreferenceValue(CoachWordAnchors.self) { anchors in
            GeometryReader { geo in
                Color.clear.preference(key: CoachWordSpots.self,
                                       value: anchors.map { CoachWordSpot(id: $0.id, word: $0.word, frame: geo[$0.bounds]) })
            }
        }
        .onPreferenceChange(CoachWordSpots.self) { onWords($0) }
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
            case let .pill(text):
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(TR.warn)
                    Text(text).font(.system(size: 12)).foregroundStyle(TR.text2).lineLimit(1)
                }
                .padding(.leading, 8).padding(.trailing, 9).frame(height: 24)
            case let .notice(notice):
                CardWidth(maxWidth: Self.noticeWidth, minWidth: 0) {
                    noticeBody(notice)
                        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 9)
                }
            default:
                CardWidth(maxWidth: Self.maxWidth, minWidth: minWidth) {
                    VStack(alignment: .leading, spacing: 8) {
                        main
                        if follow?.composing == true || follow?.inputMethodOn == true, follow?.phase == .typing { composingHint }
                        if keys != .readOnly { keysRow }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: isCapsule ? 999 : 12, style: .continuous)
                .fill(CoachPalette.pop(scheme))
                .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.16), radius: 10, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: isCapsule ? 999 : 12, style: .continuous)
                .strokeBorder(CoachPalette.line(scheme), lineWidth: 0.5)
        )
    }

    /// The prototype's notice card is at most 380 wide.
    static let noticeWidth: CGFloat = 380

    private var isCapsule: Bool {
        switch content {
        case .thinking, .pill: true
        default: false
        }
    }

    /// Title, what happened, the buttons, and Esc 知道了 (no Tab: there is nothing to write).
    private func noticeBody(_ notice: CoachNotice) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 13)).foregroundStyle(TR.warn)
                Text(notice.title).font(.system(size: 13, weight: .medium)).foregroundStyle(TR.text)
            }
            Text(notice.body).font(.system(size: 12)).foregroundStyle(TR.text2).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            if !notice.links.isEmpty {
                HStack(spacing: 6) {
                    ForEach(notice.links, id: \.label) { link in
                        Button(link.label) { onNotice(link.action) }
                            .buttonStyle(NoticeButtonStyle())
                    }
                }
                .padding(.top, 9)
            }
            if keys != .readOnly {
                HStack(spacing: 5) {
                    KeyCap(label: "Esc")
                    Text("知道了")
                    Spacer(minLength: 12)
                    Text("接着打字它就走开").foregroundStyle(TR.text3)
                }
                .font(.system(size: 12)).foregroundStyle(TR.text2).lineLimit(1)
                .padding(.top, 8)
            }
        }
    }

    // MARK: Main part of each card

    private enum Section: Int {
        case english = 1, others, note, sentence, why
    }

    @ViewBuilder private var main: some View {
        switch content {
        case let .spelling(wrong, fixes):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                wrongText(wrong)
                arrow
                english(fixes.first ?? "", always: true)
            }
            if fixes.count > 1, follow == nil {
                flow(otherGuesses(Array(fixes.dropFirst().prefix(3))), lineSpacing: 4)
            }
        case let .translate(source, result):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(source).font(.system(size: 14)).foregroundStyle(TR.text2)
                arrow
                english(result.english, always: CoachWords.words(in: result.english).count == 1)
                Button { onSpeak(result.english) } label: {
                    Image(systemName: "speaker.wave.2").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(TR.text2)
                .help("听整个短语")
            }
            if !result.note.isEmpty {
                flow(units(result.note, look: .note, section: .note), lineSpacing: 5)
            }
        case let .sentence(original, check):
            let placements = CoachText.placements(of: check.changes, in: original)
            sentenceHeader(changes: placements.count)
            flow(sentence(original, placements), lineSpacing: 7)
            let notes = sentenceNotes(check, placed: placements)
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(notes.enumerated()), id: \.offset) { index, note in
                        flow(units(note, look: .why, section: .why, offset: index * 1000), lineSpacing: 4)
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
        case .thinking, .notice, .pill:
            EmptyView()
        }
    }

    /// The green English: words to stop on, or while typing along, character by character.
    private func english(_ text: String, always: Bool) -> some View {
        let units: [FlowUnit] = if let follow {
            followUnits(text, follow: follow, look: .english, section: .english, always: always)
        } else {
            self.units(text, look: .english, section: .english, always: always)
        }
        return flow(units, lineSpacing: 2)
    }

    private func otherGuesses(_ guesses: [String]) -> [FlowUnit] {
        var out = units("也可能是：", look: .note, section: .others)
        for (index, guess) in guesses.enumerated() {
            if index > 0 { out += units(" · ", look: .note, section: .others, offset: 90000 + index) }
            out += units(guess, look: .note, section: .others, offset: index * 1000, always: true)
        }
        return out
    }

    private func sentenceHeader(changes: Int) -> some View {
        let right: String = switch follow?.phase {
        case .typing?: "第 \((follow?.step ?? 0) + 1) 处，共 \(changes) 处"
        case .done?: "改好了"
        case nil: "改了 \(changes) 处"
        }
        return HStack(spacing: 6) {
            Image(systemName: "text.badge.checkmark").font(.system(size: 12))
            Text("整句").font(.system(size: 12, weight: .medium))
            Spacer(minLength: 12)
            Text(right).font(.system(size: 12)).foregroundStyle(TR.text3)
        }
        .foregroundStyle(TR.text2)
    }

    /// The sentence with each change in place. On the card: the old words grey and struck through
    /// before the new ones in green. While typing along: the changes become blanks, the one being
    /// typed lighting up character by character, the ones done green.
    private func sentence(_ original: String, _ placements: [CoachText.Placement]) -> [FlowUnit] {
        let scalars = Array(original.unicodeScalars)
        var out: [FlowUnit] = []
        var at = 0
        for (index, place) in placements.enumerated() {
            out += units(CoachText.substring(scalars, at ..< place.range.lowerBound), look: .plain, section: .sentence, offset: at)
            let offset = 100 * (index + 1) * 1000
            let state: ChangeState = switch follow?.phase {
            case nil: .shown
            case .done?: .done
            case .typing?: index < (follow?.step ?? 0) ? .done : index == follow?.step ? .now : .later
            }
            switch state {
            case .shown:
                out += change(from: place.from, to: place.to, offset: offset)
            case .done:
                out += together(units(place.to, look: .inserted, section: .sentence, offset: offset, always: true))
            case .now:
                if let follow, !place.to.isEmpty {
                    out += together(followUnits(place.to, follow: follow, look: .blankNow, section: .sentence, offset: offset, always: true))
                }
            case .later:
                out += place.to.isEmpty ? units(place.from, look: .old, section: .sentence, offset: offset)
                    : together(units(place.to, look: .blankLater, section: .sentence, offset: offset, always: true))
            }
            at = place.range.upperBound
        }
        out += units(CoachText.substring(scalars, at ..< scalars.count), look: .plain, section: .sentence, offset: at)
        return out
    }

    private enum ChangeState { case shown, done, now, later }

    /// Old words struck through, then the new ones. A short change stays on one line with its old
    /// words: "I" at a line's end and "have" on the next reads as two changes.
    private func change(from: String, to: String, offset: Int) -> [FlowUnit] {
        let old = units(from.trimmingCharacters(in: .whitespaces), look: .old, section: .sentence, offset: offset)
        guard !to.isEmpty else { return old }
        let new = units(to, look: .inserted, section: .sentence, offset: offset + 500, always: true)
        guard from.count + to.count <= 32 else { return old + [FlowUnit(segments: [FlowSegment(text: " ", look: .plain)], isSpace: true)] + new }
        let glued = (old + [FlowUnit(segments: [FlowSegment(text: "\u{00A0}", look: .old)], isSpace: false)] + new).flatMap { unit in
            unit.isSpace ? [FlowSegment(text: "\u{00A0}", look: unit.segments.first?.look ?? .plain)] : unit.segments
        }
        return [FlowUnit(segments: glued, isSpace: false)]
    }

    /// A short change as one piece that stays on one line, under one background or one blank line.
    private func together(_ units: [FlowUnit]) -> [FlowUnit] {
        guard units.count > 1, units.reduce(0, { $0 + $1.segments.reduce(0) { $0 + $1.text.count } }) <= 32 else { return units }
        return [FlowUnit(segments: units.flatMap(\.segments), isSpace: false)]
    }

    /// The reasons under a sentence card; a change that could not be placed keeps its "old → new" in front.
    private func sentenceNotes(_ check: CoachSentenceCheck, placed: [CoachText.Placement]) -> [String] {
        var notes: [String] = []
        var left = placed
        for change in check.changes {
            let why = change.why.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = left.firstIndex(where: { $0.to == change.to && $0.from.lowercased().contains(change.from.lowercased()) }) {
                left.remove(at: index)
                if !why.isEmpty, !notes.contains(why) { notes.append(why) }
            } else {
                notes.append([change.from.isEmpty ? change.to : "\(change.from) → \(change.to)", why].filter { !$0.isEmpty }.joined(separator: "  "))
            }
        }
        return Array(notes.prefix(4))
    }

    // MARK: Pieces of text

    /// How a piece of the card's text looks.
    private enum Look {
        case english, note, why, plain, old, inserted, blankNow, blankLater

        var size: CGFloat {
            switch self {
            case .english: 18
            case .note: 12
            case .why: 13
            case .old: 13
            case .plain, .inserted, .blankNow, .blankLater: 15
            }
        }

        var weight: Font.Weight {
            switch self {
            case .english, .inserted, .blankNow, .blankLater: .semibold
            default: .regular
            }
        }
    }

    private struct FlowSegment {
        var text: String
        var look: Look
        /// Set when the mouse can stop on it.
        var spot: Int?
        var word: String?
        /// Scalar offset of the segment in the text it came from.
        var at = 0
        /// While typing along: the offset of this segment's first character in the English typed.
        var followOffset: Int?
    }

    private struct FlowUnit {
        var segments: [FlowSegment]
        var isSpace: Bool
    }

    private func units(_ text: String, look: Look, section: Section, offset: Int = 0, always: Bool = false) -> [FlowUnit] {
        CoachWords.units(of: text).map { pieces in
            FlowUnit(segments: pieces.map { piece in
                let hover = piece.kind == .word && hoverable(look) && CoachWords.isHoverable(piece.text, always: always)
                return FlowSegment(text: piece.text, look: look, spot: hover ? spotID(section, offset + piece.offset) : nil,
                                   word: hover ? piece.text : nil, at: piece.offset)
            }, isSpace: pieces.first?.kind == .space)
        }
    }

    private func followUnits(_ text: String, follow _: CoachFollow, look: Look, section: Section, offset: Int = 0,
                             always: Bool) -> [FlowUnit]
    {
        units(text, look: look, section: section, offset: offset, always: always).map { unit in
            var unit = unit
            // A space is a character to type too: it gets drawn, and marked when typed wrong.
            unit.isSpace = false
            unit.segments = unit.segments.map { segment in
                var segment = segment
                segment.followOffset = segment.at
                return segment
            }
            return unit
        }
    }

    private func hoverable(_ look: Look) -> Bool {
        switch look {
        case .english, .note, .why, .inserted, .blankNow, .blankLater: true
        case .plain, .old: false
        }
    }

    private func spotID(_ section: Section, _ offset: Int) -> Int {
        section.rawValue * 10_000_000 + offset
    }

    private func flow(_ units: [FlowUnit], lineSpacing: CGFloat) -> some View {
        CoachFlow(lineSpacing: lineSpacing) {
            ForEach(Array(units.enumerated()), id: \.offset) { _, unit in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    ForEach(Array(runs(of: unit.segments).enumerated()), id: \.offset) { _, run in
                        runView(run)
                    }
                }
                .layoutValue(key: CoachFlowSpace.self, value: unit.isSpace)
            }
        }
    }

    /// Neighbouring segments that look the same: a change like "I have" gets one green background.
    private func runs(of segments: [FlowSegment]) -> [[FlowSegment]] {
        var runs: [[FlowSegment]] = []
        for segment in segments {
            if let last = runs.last?.last, last.look == segment.look {
                runs[runs.count - 1].append(segment)
            } else {
                runs.append([segment])
            }
        }
        return runs
    }

    private func runView(_ run: [FlowSegment]) -> some View {
        let look = run.first?.look ?? .plain
        let boxed = look == .inserted || look == .blankNow || look == .blankLater
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(run.enumerated()), id: \.offset) { _, segment in
                segmentView(segment)
            }
        }
        .padding(.horizontal, boxed ? 2 : 0)
        .background(look == .inserted ? CoachPalette.fixSoft(scheme) : .clear, in: RoundedRectangle(cornerRadius: 3))
        .overlay(alignment: .bottom) { blankLine(look) }
    }

    @ViewBuilder private func segmentView(_ segment: FlowSegment) -> some View {
        let base = Group {
            if let follow, segment.followOffset != nil {
                followText(segment, follow: follow)
            } else {
                styled(Text(segment.text), segment.look, color: color(segment.look))
            }
        }
        .background(hotBackground(segment), in: RoundedRectangle(cornerRadius: 3))
        if let spot = segment.spot, let word = segment.word {
            base.anchorPreference(key: CoachWordAnchors.self, value: .bounds) { [CoachWordAnchor(id: spot, word: word, bounds: $0)] }
        } else {
            base
        }
    }

    /// The English being typed along, one character at a time: green when typed right, the amber mark
    /// where it went wrong, grey still to type; a green bar where the next character goes.
    private func followText(_ segment: FlowSegment, follow: CoachFollow) -> some View {
        let start = segment.followOffset ?? 0
        let characters = Array(segment.text.unicodeScalars)
        let typing = follow.phase == .typing
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(characters.indices, id: \.self) { index in
                let position = start + index
                let done = !typing || position < follow.right
                let wrong = typing && follow.wrongAt == position
                styled(Text(String(characters[index])), segment.look, color: wrong ? TR.mark : done ? TR.fix : TR.text3)
                    .background(wrong ? TR.markSoft : .clear, in: RoundedRectangle(cornerRadius: 2))
                    .overlay(alignment: .bottom) {
                        if wrong { DottedLine().stroke(TR.mark, style: StrokeStyle(lineWidth: 1.5, dash: [1.5, 2])).frame(height: 1.5) }
                    }
                    .overlay(alignment: .leading) {
                        if typing, follow.wrongAt == nil, position == follow.right { caretBar.offset(x: -1) }
                    }
                    .overlay(alignment: .trailing) {
                        if typing, follow.wrongAt == nil, position + 1 == follow.right,
                           follow.right == follow.target.unicodeScalars.count { caretBar.offset(x: 1) }
                    }
            }
        }
    }

    private var caretBar: some View {
        RoundedRectangle(cornerRadius: 1).fill(TR.fix).frame(width: 2).padding(.vertical, 2)
    }

    private func styled(_ text: Text, _ look: Look, color: Color) -> some View {
        text.font(.system(size: look.size, weight: look.weight))
            .strikethrough(look == .old)
            .foregroundStyle(color)
    }

    private func color(_ look: Look) -> Color {
        switch look {
        case .english, .inserted: CoachPalette.fix(scheme)
        case .note: TR.text2
        case .why, .plain: TR.text
        case .old, .blankLater: TR.text3
        case .blankNow: TR.text3
        }
    }

    /// The word the mouse rests on: green words get the green tint, words in the explanations grey.
    private func hotBackground(_ segment: FlowSegment) -> Color {
        guard segment.spot != nil, segment.spot == hot else { return .clear }
        switch segment.look {
        case .english, .inserted, .blankNow, .blankLater: return CoachPalette.fixSoft(scheme)
        default: return TR.sel
        }
    }

    @ViewBuilder private func blankLine(_ look: Look) -> some View {
        if look == .blankNow || look == .blankLater {
            DottedLine()
                .stroke(look == .blankNow ? CoachPalette.fix(scheme) : TR.line2, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                .frame(height: 1.5)
                .offset(y: 1)
        }
    }

    // MARK: Keys row

    private var composingHint: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(TR.warn)
            Text(follow?.composing == true ? "输入法在拼字：上屏的字才算。中文输入法下按 ⇧ 切到英文再打。"
                : "中文输入法开着：拼音上屏才算。打英文请按 ⇧ 切到英文再打。")
                .font(.system(size: 12)).foregroundStyle(TR.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var keysRow: some View {
        HStack(spacing: 5) {
            switch follow?.phase {
            case let .done(filled)?:
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(CoachPalette.fix(scheme))
                Text("\(filled ? "补全了" : "打对了")，记进\(bookName)")
                    .fontWeight(.medium).foregroundStyle(CoachPalette.fix(scheme))
                Text("· \(filled ? NotebookEntry.Help.replaced.title : NotebookEntry.Help.typed.title)").foregroundStyle(TR.text3)
            case .typing?:
                if follow?.wrongAt != nil {
                    key("⌫", "退回去改")
                    key("Tab", "补全")
                } else {
                    key("Tab", "补全剩下的")
                }
                key("Esc", putBackLabel, last: true)
            case nil:
                startKeys
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(TR.text2)
        .lineLimit(1)
    }

    @ViewBuilder private var startKeys: some View {
        if let accept = content.acceptText {
            switch keys {
            case .normal:
                key("Tab", isSentence ? "跟着打改的词" : "跟着打")
                KeyCap(label: "Tab")
                key("Tab", isSentence ? "整句换掉" : "直接换")
            case .copy:
                key("Tab", "复制 \(accept)")
            case .direct, .readOnly:
                key("Tab", content.acceptLabel)
            }
            key("Esc", "不改", last: true)
        } else {
            key("Esc", "关掉", last: true)
        }
    }

    private func key(_ label: String, _ text: String, last: Bool = false) -> some View {
        HStack(spacing: 5) {
            KeyCap(label: label)
            Text(text)
            if !last { Spacer().frame(width: 3) }
        }
    }

    private var isSentence: Bool {
        if case .sentence = content { return true }
        return false
    }

    private var bookName: String {
        if case .translate = content { return "生词本" }
        return "错题本"
    }

    private var putBackLabel: String {
        switch content {
        case let .translate(source, _): "放回「\(source)」"
        case let .spelling(wrong, _): "放回 \(wrong)"
        default: "放回原句"
        }
    }

    // MARK: Small parts

    private var arrow: some View {
        Text("→").font(.system(size: 13)).foregroundStyle(TR.text3)
    }

    private func wrongText(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).strikethrough().foregroundStyle(TR.text2)
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

/// A horizontal line across its frame, for dashed and dotted underlines.
private struct DottedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

private struct CoachWordAnchor {
    var id: Int
    var word: String
    var bounds: Anchor<CGRect>
}

private struct CoachWordAnchors: PreferenceKey {
    static let defaultValue: [CoachWordAnchor] = []

    static func reduce(value: inout [CoachWordAnchor], nextValue: () -> [CoachWordAnchor]) {
        value += nextValue()
    }
}

private struct CoachWordSpots: PreferenceKey {
    static let defaultValue: [CoachWordSpot] = []

    static func reduce(value: inout [CoachWordSpot], nextValue: () -> [CoachWordSpot]) {
        value += nextValue()
    }
}

/// Marks a run of spaces in a CoachFlow: it never starts a line.
private struct CoachFlowSpace: LayoutValueKey {
    static let defaultValue = false
}

/// Lays pieces of text out like a paragraph: left to right, on to a new line when the next piece
/// does not fit, each piece on its line's baseline. Asked for no particular width, it is one line.
struct CoachFlow: Layout {
    var lineSpacing: CGFloat = 0

    private struct Line {
        var items: [(index: Int, x: CGFloat, ascent: CGFloat)] = []
        var width: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
    }

    /// Lines up with the text around it on its first line's baseline (the green English next to "风雪交加 →").
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews,
                           cache _: inout ()) -> CGFloat?
    {
        let lines = arrange(subviews, width: bounds.width)
        guard let first = lines.first, let last = lines.last else { return nil }
        if guide == .firstTextBaseline { return bounds.minY + first.ascent }
        if guide == .lastTextBaseline {
            let above = lines.dropLast().reduce(0) { $0 + $1.ascent + $1.descent + lineSpacing }
            return bounds.minY + above + last.ascent
        }
        return nil
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let lines = arrange(subviews, width: proposal.width ?? .infinity)
        let height = lines.reduce(0) { $0 + $1.ascent + $1.descent } + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: lines.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let lines = arrange(subviews, width: bounds.width)
        var placed = Set<Int>()
        var y = bounds.minY
        for line in lines {
            for item in line.items {
                subviews[item.index].place(at: CGPoint(x: bounds.minX + item.x, y: y + line.ascent - item.ascent), proposal: .unspecified)
                placed.insert(item.index)
            }
            y += line.ascent + line.descent + lineSpacing
        }
        // Spaces left out at the start of a line take no room.
        for index in subviews.indices where !placed.contains(index) {
            subviews[index].place(at: bounds.origin, proposal: .zero)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        var x: CGFloat = 0
        for index in subviews.indices {
            let subview = subviews[index]
            let isSpace = subview[CoachFlowSpace.self]
            if isSpace, line.items.isEmpty { continue }
            let size = subview.sizeThatFits(.unspecified)
            if !isSpace, !line.items.isEmpty, x + size.width > width + 0.5 {
                lines.append(line)
                line = Line()
                x = 0
            }
            let ascent = subview.dimensions(in: .unspecified)[VerticalAlignment.firstTextBaseline]
            line.items.append((index, x, ascent))
            x += size.width
            if !isSpace { line.width = x }
            line.ascent = max(line.ascent, ascent)
            line.descent = max(line.descent, size.height - ascent)
        }
        if !line.items.isEmpty { lines.append(line) }
        return lines
    }
}

/// As wide as the content wants, up to `maxWidth` and at least `minWidth`, and as tall as the
/// content is at that width. A `.frame(maxWidth:)` here measured a sentence that wraps as one long
/// line, so the card window came out a line short and cut off the bottom of the card.
struct CardWidth: Layout {
    let maxWidth: CGFloat
    var minWidth: CGFloat = 0

    func sizeThatFits(proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = max(min(content.sizeThatFits(.unspecified).width, maxWidth), min(minWidth, maxWidth))
        let size = content.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: max(size.width, width), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
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
