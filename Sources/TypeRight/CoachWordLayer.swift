//
//  CoachWordLayer.swift
//  TypeRight
//
//  The small layer over a card: one word's IPA, meaning and sound when the mouse stops on it, or
//  every word on the card while the user holds ⌥. It never takes focus, like the card, and sits
//  one level above it.
//

import AppKit
import SwiftUI

struct CoachWordLayerView: View {
    enum Mode: Equatable {
        case word(CoachWordInfo)
        /// Every word on the card; `key` is the modifier being held.
        case list([CoachWordInfo], key: String)
    }

    let mode: Mode
    var tail: CoachTailPlacement?
    var onSpeak: (String) -> Void = { _ in }

    @Environment(\.colorScheme) private var scheme

    static let margin: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            if let tail, tail.pointsUp { tailShape(up: true, x: tail.x) }
            box
            if let tail, !tail.pointsUp { tailShape(up: false, x: tail.x) }
        }
        .padding(Self.margin)
        .fixedSize()
    }

    private var box: some View {
        Group {
            switch mode {
            case let .word(info):
                CardWidth(maxWidth: 300, minWidth: 180) { word(info) }
                    .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 10)
            case let .list(infos, key):
                CardWidth(maxWidth: 460, minWidth: 300) { list(infos, key: key) }
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(CoachPalette.pop(scheme))
                .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.16), radius: 12, y: 5)
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(TR.line2, lineWidth: 0.5))
    }

    private func word(_ info: CoachWordInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 8) {
                Text(info.word).font(.system(size: 15, weight: .semibold)).foregroundStyle(TR.text)
                if !info.ipa.isEmpty {
                    Text(info.ipa).font(.system(size: 13)).foregroundStyle(TR.text2)
                }
                Spacer(minLength: 8)
                Button { onSpeak(info.word) } label: {
                    Image(systemName: "speaker.wave.2").font(.system(size: 12)).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(TR.text2)
                .help("听发音")
                .padding(.trailing, -6)
            }
            ForEach(Array(info.senses.enumerated()), id: \.offset) { _, sense in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(sense.pos).font(.system(size: 11)).foregroundStyle(TR.text3).frame(minWidth: 24, alignment: .leading)
                    Text(sense.meaning).font(.system(size: 13)).foregroundStyle(TR.text).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let empty = info.emptyLine {
                Text(empty).font(.system(size: 12)).foregroundStyle(TR.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func list(_ infos: [CoachWordInfo], key: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("按住 \(key)：这张卡上的单词，松开就收起").font(.system(size: 12)).foregroundStyle(TR.text3)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 0) {
                ForEach(Array(infos.enumerated()), id: \.offset) { index, info in
                    if index > 0 {
                        Rectangle().fill(TR.line).frame(height: 0.5).gridCellUnsizedAxes(.horizontal)
                    }
                    GridRow {
                        Text(info.word).font(.system(size: 14, weight: .semibold)).foregroundStyle(TR.text)
                        Text(info.ipa).font(.system(size: 12)).foregroundStyle(TR.text2)
                        meanings(info).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func meanings(_ info: CoachWordInfo) -> Text {
        guard !info.senses.isEmpty else {
            return Text(info.emptyLine ?? "").font(.system(size: 12)).foregroundStyle(TR.text3)
        }
        return info.senses.enumerated().reduce(Text("")) { text, item in
            let pos = item.element.pos.isEmpty ? "" : item.element.pos + " "
            return text + Text((item.offset > 0 ? "　" : "") + pos).font(.system(size: 11)).foregroundStyle(TR.text3)
                + Text(item.element.meaning).font(.system(size: 12)).foregroundStyle(TR.text)
        }
    }

    /// The tail with a hairline along its two sides: the layer sits on the card, the same colour as it.
    private func tailShape(up: Bool, x: CGFloat) -> some View {
        CoachTail(up: up)
            .fill(CoachPalette.pop(scheme))
            .overlay(CoachTailSides(up: up).stroke(TR.line2, lineWidth: 0.5))
            .frame(width: 14, height: CoachCardView.tailHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(x: max(10, x - 7))
            .zIndex(1)
    }
}

private struct CoachTailSides: Shape {
    let up: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let tip = CGPoint(x: rect.midX, y: up ? rect.minY : rect.maxY)
        p.move(to: CGPoint(x: rect.minX, y: up ? rect.maxY : rect.minY))
        p.addLine(to: tip)
        p.addLine(to: CGPoint(x: rect.maxX, y: up ? rect.maxY : rect.minY))
        return p
    }
}

/// The layer's window: one at a time, a word or the list.
@MainActor
final class CoachWordLayer {
    /// The gap between the word and the layer's tail.
    static let gap: CGFloat = 8
    /// The gap between the card and the list of its words.
    static let listGap: CGFloat = 6

    private var panel: NonActivatingPanel?
    private var host: FirstMouseHostingView<CoachWordLayerView>?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Where the layer is on screen while it is shown.
    var frame: CGRect? { isVisible ? panel?.frame : nil }

    /// Under the word (`word` in screen coordinates), opening downwards; `up` opens it above the word
    /// (the card itself sits above its word). Its left edge is 12 before the word, the tail on the word's middle.
    func show(_ info: CoachWordInfo, at word: CGRect, up: Bool) {
        let margin = CoachWordLayerView.margin
        let size = Self.size(of: CoachWordLayerView(mode: .word(info), tail: CoachTailPlacement(pointsUp: true, x: 20)), near: word)
        let visible = Self.visibleFrame(for: word)
        var originX = word.minX - 12 - margin
        originX = min(max(originX, visible.minX - margin + 4), visible.maxX - size.width + margin - 4)
        let originY = up ? word.maxY + Self.gap - margin : word.minY - Self.gap - size.height + margin
        let tailX = word.midX - originX - margin
        put(CoachWordLayerView(mode: .word(info), tail: CoachTailPlacement(pointsUp: !up, x: tailX), onSpeak: { CoachSpeaker.speak($0) }),
            frame: NSRect(x: originX, y: originY, width: size.width, height: size.height))
    }

    /// Under the card (`card` is its body in screen coordinates), or above it without room below.
    func showList(_ infos: [CoachWordInfo], key: String, near card: CGRect) {
        let margin = CoachWordLayerView.margin
        let view = CoachWordLayerView(mode: .list(infos, key: key), onSpeak: { CoachSpeaker.speak($0) })
        let size = Self.size(of: view, near: card)
        let visible = Self.visibleFrame(for: card)
        let originX = min(max(card.minX - margin, visible.minX - margin + 4), visible.maxX - size.width + margin - 4)
        var originY = card.minY - Self.listGap - size.height + margin
        if originY + margin < visible.minY { originY = card.maxY + Self.listGap - margin }
        put(view, frame: NSRect(x: originX, y: originY, width: size.width, height: size.height))
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func put(_ view: CoachWordLayerView, frame: NSRect) {
        let host: FirstMouseHostingView<CoachWordLayerView>
        if let kept = self.host {
            kept.rootView = view
            host = kept
        } else {
            host = FirstMouseHostingView(rootView: view)
            host.sizingOptions = []
            self.host = host
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        if panel.contentView !== host { panel.contentView = host }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    /// Measured at the pixel density it is drawn at (see CoachCardPanel.measure).
    private static func size(of view: CoachWordLayerView, near rect: CGRect) -> CGSize {
        TRFitting.size(of: view.environment(\.displayScale, screen(for: rect)?.backingScaleFactor ?? 2))
    }

    private static func screen(for rect: CGRect) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main
    }

    private static func visibleFrame(for rect: CGRect) -> CGRect {
        screen(for: rect)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func makePanel() -> NonActivatingPanel {
        let panel = NonActivatingPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // One above the card.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }
}
