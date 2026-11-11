//
//  CoachCardPanel.swift
//  TypeRight
//
//  Puts the card on screen next to a word without taking focus from the app being typed in.
//  Below the word by default, flipped above when the screen has no room underneath.
//

import AppKit
import SwiftUI

/// Where the coach puts a card (a fake in unit tests).
@MainActor
protocol CoachCardDisplay: AnyObject {
    /// Called when the user clicks anywhere outside the card.
    var onClickOutside: (() -> Void)? { get set }
    /// - Parameter anchor: the word's bounds in Cocoa screen coordinates (origin bottom left).
    func show(_ content: CoachCardContent, keys: CoachCardKeys, anchor: CGRect)
    func hide()
}

@MainActor
final class CoachCardPanel: CoachCardDisplay {
    private var panel: NonActivatingPanel?
    private var clickMonitor: Any?

    var onClickOutside: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(_ content: CoachCardContent, keys: CoachCardKeys, anchor: CGRect) {
        let gap: CGFloat = 9
        let margin = CoachCardView.shadowMargin
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        // Measure once without a tail to learn the card's size.
        let size = measure(CoachCardView(content: content, tail: CoachTailPlacement(pointsUp: true, x: 20), keys: keys))
        let below = anchor.minY - gap - size.height + margin >= visible.minY
        // The card's left edge lines up with the word's (the panel is wider by the shadow margin).
        var originX = anchor.minX - margin
        originX = min(max(originX, visible.minX - margin + 4), visible.maxX - size.width + margin - 4)
        let originY = below ? anchor.minY - gap - size.height + margin : anchor.maxY + gap - margin
        let tailX = anchor.minX + min(anchor.width / 2, 16) - originX - margin

        let view = CoachCardView(
            content: content,
            tail: CoachTailPlacement(pointsUp: below, x: tailX),
            keys: keys,
            onSpeak: { CoachSpeaker.speak($0) }
        )
        let frame = NSRect(x: originX, y: originY, width: size.width, height: size.height)
        present(view, frame: frame)
    }

    func hide() {
        panel?.orderOut(nil)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    private func measure(_ view: CoachCardView) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        return host.fittingSize
    }

    private func present(_ view: CoachCardView, frame: NSRect) {
        let host = FirstMouseHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: frame.size)

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = host
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, panel.isVisible else { return }
                    if !panel.frame.contains(NSEvent.mouseLocation) { self.onClickOutside?() }
                }
            }
        }
    }

    private func makePanel() -> NonActivatingPanel {
        let panel = NonActivatingPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }
}
