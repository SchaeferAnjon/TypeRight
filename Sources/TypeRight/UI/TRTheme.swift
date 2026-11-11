//
//  TRTheme.swift
//  TypeRight
//
//  Colors and small parts from DESIGN.md: one green for "fixed", no red for mistakes,
//  square toggles, hairline groups, key caps.
//

import AppKit
import SwiftUI

enum TR {
    private static func dynamicNS(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: dynamicNS(light, dark))
    }

    private static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    static let bg = dynamic(hex(0xFAFAFB), hex(0x16171A))
    static let side = dynamic(hex(0xF3F3F5), hex(0x1C1D20))
    static let card = dynamic(hex(0xFFFFFF), hex(0x212226))
    /// Pop-ups and anything drawn on top of a card or a `fill` (the welcome picture's field and card).
    static let pop = dynamic(hex(0xFFFFFF), hex(0x2A2B30))
    static let text = dynamic(hex(0x1D1D1F), hex(0xF2F2F4))
    static let text2 = dynamic(hex(0x6E6E73), hex(0xA1A1A8))
    static let text3 = dynamic(hex(0x9A9AA0), hex(0x6E6E76))
    static let line = dynamic(hex(0x000000, 0.08), hex(0xFFFFFF, 0.09))
    static let line2 = dynamic(hex(0x000000, 0.14), hex(0xFFFFFF, 0.16))
    static let fill = dynamic(hex(0x000000, 0.04), hex(0xFFFFFF, 0.06))
    static let sel = dynamic(hex(0x000000, 0.07), hex(0xFFFFFF, 0.10))
    static let fixNS = dynamicNS(hex(0x13804B), hex(0x52C690))
    static let fix = Color(nsColor: fixNS)
    static let fixSoft = dynamic(hex(0x13804B, 0.11), hex(0x52C690, 0.15))
    static let markNS = dynamicNS(hex(0xC98A12), hex(0xE2A84A))
    static let mark = Color(nsColor: markNS)
    static let markSoft = dynamic(hex(0xE8AA28, 0.17), hex(0xE2A84A, 0.18))
    static let dangerNS = dynamicNS(hex(0xC0362C), hex(0xFF6B5E))
    static let danger = Color(nsColor: dangerNS)
    static let ok = fix
    static let warn = mark

    /// What a control looks like while it cannot be used (the prototype's `:disabled`).
    static let disabledOpacity = 0.4
}

/// Square switch (track radius 5, knob radius 3), green when on.
struct SquareToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SquareToggle(configuration: configuration)
    }
}

private struct SquareToggle: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { configuration.isOn.toggle() } label: {
            HStack {
                configuration.label
                Spacer(minLength: 12)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(configuration.isOn ? TR.fix : TR.line2)
                        .frame(width: 32, height: 18)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .padding(2)
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                }
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : TR.disabledOpacity)
    }
}

/// A titled group of rows with hairline separators, like System Settings. `note` is one line of
/// explanation under the group.
struct TRGroup<Content: View>: View {
    var title: String?
    var note: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(TR.text2).padding(.leading, 2)
            }
            VStack(spacing: 0) { content }
                .background(TR.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TR.line, lineWidth: 0.5))
            if let note {
                Text(note).font(.system(size: 12)).foregroundStyle(TR.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// One settings row: an optional icon, title, optional note, a control on the right.
struct TRRow<Leading: View, Trailing: View>: View {
    let title: String
    var note: String?
    var last = false
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    /// Icons sit in a 22 wide column, so the hairline starts under the title.
    private var hasLeading: Bool { Leading.self != EmptyView.self }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                if hasLeading {
                    leading.frame(width: 22)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13)).foregroundStyle(TR.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note {
                        Text(note).font(.system(size: 12)).foregroundStyle(TR.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                // A long note takes the row's width before it wraps, instead of sharing it with the spacer.
                .layoutPriority(1)
                Spacer(minLength: 12)
                trailing
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
            if !last { Rectangle().fill(TR.line).frame(height: 0.5).padding(.leading, hasLeading ? 48 : 14) }
        }
    }
}

extension TRRow where Leading == EmptyView {
    init(title: String, note: String? = nil, last: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, note: note, last: last, leading: { EmptyView() }, trailing: trailing)
    }
}

/// A row that opens a web page: the whole row is the click target, with a small arrow on the right.
struct TRLinkRow: View {
    let title: String
    var note: String?
    var value: String?
    var last = false
    let url: URL

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            TRRow(title: title, note: note, last: last) {
                HStack(spacing: 8) {
                    if let value { Text(value).font(.system(size: 12)).foregroundStyle(TR.text2) }
                    Image(systemName: "arrow.up.forward").font(.system(size: 11, weight: .medium)).foregroundStyle(TR.text2)
                }
            }
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
    }
}

/// A web link inside a line of text: secondary color with a small arrow, never the system blue.
struct TRInlineLink: View {
    let title: String
    let url: URL

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "arrow.up.forward").font(.system(size: 10, weight: .medium))
            }
            .font(.system(size: 12))
            .foregroundStyle(TR.text2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
    }
}

/// Small segmented choice drawn like the prototype (not the system segmented control).
struct TRSegmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let (value, label) = options[i]
                Button { selection = value } label: {
                    Text(label)
                        .font(.system(size: 12, weight: selection == value ? .medium : .regular))
                        .foregroundStyle(selection == value ? TR.text : TR.text2)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(selection == value ? TR.card : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .shadow(color: selection == value ? .black.opacity(0.08) : .clear, radius: 1, y: 0.5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(2)
        .background(TR.fill, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(TR.line, lineWidth: 0.5))
        .opacity(isEnabled ? 1 : TR.disabledOpacity)
    }
}

/// Sidebar row used by the main window, settings and onboarding.
struct TRSideItem: View {
    let icon: String
    let title: String
    var count: Int?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13)).frame(width: 18).foregroundStyle(TR.text)
                Text(title).font(.system(size: 13)).foregroundStyle(TR.text)
                Spacer()
                if let count { Text("\(count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(TR.text3) }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(selected ? TR.sel : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The primary button: ink background, one per screen.
struct TRInkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TRButtonBody(enabledOpacity: 1) {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TR.bg)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(TR.text.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
    }
}

/// The ordinary button: hairline border, `tint` for the words (`TR.danger` for 清空 and the like).
struct TRPlainButtonStyle: ButtonStyle {
    var tint: Color = TR.text

    func makeBody(configuration: Configuration) -> some View {
        TRButtonBody(enabledOpacity: 1) {
            configuration.label
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(configuration.isPressed ? TR.sel : TR.fill, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(TR.line2, lineWidth: 0.5))
                .contentShape(Rectangle())
        }
    }
}

/// A quiet button without a border (the prototype's `.btn.ghost`), for 移除 in lists.
struct TRGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TRButtonBody(enabledOpacity: 1) {
            configuration.label
                .font(.system(size: 13))
                .foregroundStyle(TR.text2)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(configuration.isPressed ? TR.sel : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
    }
}

/// Dims a button while it is disabled; a ButtonStyle cannot read the environment itself.
private struct TRButtonBody<Content: View>: View {
    let enabledOpacity: Double
    @ViewBuilder var content: Content
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        content.opacity(isEnabled ? enabledOpacity : TR.disabledOpacity)
    }
}

/// A status dot with a few words beside it (DESIGN.md: status colors only on dots and small text).
struct TRStatusDot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12)).foregroundStyle(TR.text2).lineLimit(1)
        }
    }
}

/// A one-line text box like the prototype's input (28 high, radius 6, hairline border).
struct TRTextField: View {
    let placeholder: String
    @Binding var text: String
    /// Search boxes get a magnifier in front and a clear button once something is typed.
    var search = false
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            if search {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(TR.text2)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(TR.text)
                .onSubmit(onSubmit)
            if search, !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(TR.text3)
                }
                .buttonStyle(.plain)
                .help("清掉")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(TR.card, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(TR.line2, lineWidth: 0.5))
    }
}

/// A key cap. `small` is the 20 high cap in the cards' key row; the others are the 28 high caps
/// in settings: `set` shows a chosen key, `fixed` a key that cannot be changed, `unset` the dashed
/// 选一个键, `recording` the green cap while keys are being pressed.
struct KeyCap: View {
    enum Look { case small, set, fixed, unset, recording }

    let label: String
    var look: Look = .small

    var body: some View {
        if look == .small {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TR.text2)
                .padding(.horizontal, 5)
                .frame(minWidth: 22, minHeight: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(TR.fill))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(TR.line2, lineWidth: 0.5))
        } else {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(minWidth: 30, minHeight: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(background))
                .overlay(border)
        }
    }

    private var foreground: Color {
        switch look {
        case .unset: TR.text3
        case .recording: TR.fix
        default: TR.text2
        }
    }

    private var background: Color {
        switch look {
        case .unset: .clear
        case .recording: TR.fixSoft
        default: TR.fill
        }
    }

    @ViewBuilder private var border: some View {
        switch look {
        case .unset:
            RoundedRectangle(cornerRadius: 6).strokeBorder(TR.line2, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        case .recording:
            RoundedRectangle(cornerRadius: 6).strokeBorder(TR.fix, lineWidth: 0.5)
        case .set:
            RoundedRectangle(cornerRadius: 6).strokeBorder(TR.line2, lineWidth: 0.5)
        case .fixed, .small:
            EmptyView()
        }
    }
}

/// "was → now" with the old text grey and struck through, the new text green.
struct TRDiffText: View {
    let from: String
    let to: String
    var size: CGFloat = 13

    /// One paragraph, so a long pair wraps as a sentence instead of as two columns.
    var body: some View {
        Text(attributed).font(.system(size: size)).fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        if !from.isEmpty {
            var old = AttributedString(from)
            old.strikethroughStyle = .single
            old.foregroundColor = TR.text3
            result += old
            result += AttributedString("  ")
        }
        var new = AttributedString(" \(to) ")
        new.foregroundColor = TR.fix
        new.backgroundColor = TR.fixSoft
        new.font = .system(size: size, weight: .medium)
        result += new
        return result
    }
}

/// Text with "here is something to fix" spots: amber dotted underline on a soft amber background
/// (DESIGN.md: `mark` / `mark-soft`, never a red squiggle).
enum TRMarked {
    static func text(_ pieces: [(String, marked: Bool)]) -> AttributedString {
        var result = AttributedString()
        for piece in pieces {
            var part = AttributedString(piece.0)
            if piece.marked {
                part.backgroundColor = TR.markSoft
                part.underlineStyle = Text.LineStyle(pattern: .dot, color: TR.mark)
            }
            result += part
        }
        return result
    }
}

/// The mini picture used on the welcome step and at the top of Settings › General.
struct TRCardPreview: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(TR.fill)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(TR.line, lineWidth: 0.5))
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text(TRMarked.text([("I want to ", false), ("预约", true), (" a meeting room", false)]))
                        .foregroundStyle(TR.text)
                    Spacer()
                }
                .font(.system(size: 15))
                .padding(.horizontal, 18)
                .frame(width: 440, height: 54)
                .background(TR.pop, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(TR.line2, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                HStack(spacing: 8) {
                    Text("预约").foregroundStyle(TR.text2).font(.system(size: 13))
                    Text("→").foregroundStyle(TR.text3).font(.system(size: 12))
                    Text("book").foregroundStyle(TR.fix).font(.system(size: 16, weight: .semibold))
                    Text("/bʊk/").foregroundStyle(TR.text2).font(.system(size: 12))
                    KeyCap(label: "Tab")
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(TR.pop, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(TR.line2, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .offset(y: -2)
            }
        }
        .frame(height: 150)
    }
}

/// Names written the way DESIGN.md asks (`text-autospace: normal`): a space between Chinese and
/// Latin letters or digits, so the system's "Safari浏览器" reads "Safari 浏览器" everywhere.
enum TRText {
    static func autospaced(_ text: String) -> String {
        var result = ""
        var previous: Character?
        for character in text {
            if let previous, needsSpace(previous, character) { result.append(" ") }
            result.append(character)
            previous = character
        }
        return result
    }

    private static func needsSpace(_ a: Character, _ b: Character) -> Bool {
        (isHan(a) && isLatin(b)) || (isLatin(a) && isHan(b))
    }

    private static func isHan(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x4E00 ... 0x9FFF).contains($0.value) || (0x3400 ... 0x4DBF).contains($0.value) }
    }

    private static func isLatin(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }
}
