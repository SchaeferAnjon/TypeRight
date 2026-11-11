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
}

/// Square switch (track radius 5, knob radius 3), green when on.
struct SquareToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
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
    }
}

/// A titled group of rows with hairline separators, like System Settings.
struct TRGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(TR.text2).padding(.leading, 2)
            }
            VStack(spacing: 0) { content }
                .background(TR.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TR.line, lineWidth: 0.5))
        }
    }
}

/// One settings row: title, optional note, a control on the right.
struct TRRow<Trailing: View>: View {
    let title: String
    var note: String?
    var last = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13)).foregroundStyle(TR.text)
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
            if !last { Rectangle().fill(TR.line).frame(height: 0.5).padding(.leading, 14) }
        }
    }
}

/// Small segmented choice drawn like the prototype (not the system segmented control).
struct TRSegmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let (value, label) = options[i]
                Button { selection = value } label: {
                    Text(label)
                        .font(.system(size: 12, weight: selection == value ? .medium : .regular))
                        .foregroundStyle(selection == value ? TR.text : TR.text2)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(selection == value ? TR.card : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .shadow(color: selection == value ? .black.opacity(0.08) : .clear, radius: 1, y: 0.5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(TR.fill, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(TR.line, lineWidth: 0.5))
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
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(TR.bg)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(TR.text.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct TRPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(TR.text)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(configuration.isPressed ? TR.sel : TR.fill, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(TR.line2, lineWidth: 0.5))
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

/// The mini picture used on the welcome step and at the top of Settings › General.
struct TRCardPreview: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(TR.fill)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(TR.line, lineWidth: 0.5))
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("I want to ").foregroundStyle(TR.text)
                    Text("预约")
                        .foregroundStyle(TR.text)
                        .background(TR.markSoft, in: RoundedRectangle(cornerRadius: 2))
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(TR.mark).frame(height: 1.5).offset(y: 2)
                        }
                    Text(" a meeting room").foregroundStyle(TR.text)
                    Spacer()
                }
                .font(.system(size: 15))
                .padding(.horizontal, 18)
                .frame(width: 440, height: 54)
                .background(TR.card, in: RoundedRectangle(cornerRadius: 10))
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
                .background(TR.card, in: RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .offset(y: -2)
            }
        }
        .frame(height: 150)
    }
}
