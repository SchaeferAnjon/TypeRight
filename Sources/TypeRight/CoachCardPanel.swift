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
    /// - Returns: true when the card is really on screen at its size. On false nothing is shown,
    ///   and the coach must not take Tab or Esc for a card nobody can see.
    func show(_ content: CoachCardContent, keys: CoachCardKeys, anchor: CGRect) -> Bool
    func hide()
}

@MainActor
final class CoachCardPanel: CoachCardDisplay {
    /// The gap between the word and the card's tail (DESIGN.md: 9 under the word).
    static let gap: CGFloat = 9

    private var panel: NonActivatingPanel?
    private var clickMonitor: Any?

    var onClickOutside: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(_ content: CoachCardContent, keys: CoachCardKeys, anchor: CGRect) -> Bool {
        let panel = place(content, keys: keys, anchor: anchor)
        panel.orderFrontRegardless()
        guard Self.isOnScreen(panel) else {
            Logger.error("TypeRight: card window not on screen (frame \(NSStringFromRect(panel.frame)), visible \(panel.isVisible)); Tab and Esc stay with the app",
                         category: Logger.ui)
            hide()
            return false
        }
        watchClicks()
        return true
    }

    func hide() {
        panel?.orderOut(nil)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// Sizes the card window for `content` and puts it at `anchor` without ordering it in. `show`
    /// goes through here, and so do the tests and the pictures of the cards.
    func place(_ content: CoachCardContent, keys: CoachCardKeys, anchor: CGRect) -> NSPanel {
        let margin = CoachCardView.shadowMargin
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        // The tail does not change the card's size, so measure once with any tail.
        let size = TRFitting.size(of: CoachCardView(content: content, tail: CoachTailPlacement(pointsUp: true, x: 20), keys: keys))
        let below = anchor.minY - Self.gap - size.height + margin >= visible.minY
        // The card's left edge lines up with the word's (the panel is wider by the shadow margin).
        var originX = anchor.minX - margin
        originX = min(max(originX, visible.minX - margin + 4), visible.maxX - size.width + margin - 4)
        let originY = below ? anchor.minY - Self.gap - size.height + margin : anchor.maxY + Self.gap - margin
        let tailX = anchor.minX + min(anchor.width / 2, 16) - originX - margin

        let view = CoachCardView(
            content: content,
            tail: CoachTailPlacement(pointsUp: below, x: tailX),
            keys: keys,
            onSpeak: { CoachSpeaker.speak($0) }
        )
        // The window sets this view's size; left to itself it would resize the window to its own liking.
        let host = FirstMouseHostingView(rootView: view)
        host.sizingOptions = []

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = host
        panel.setFrame(NSRect(x: originX, y: originY, width: size.width, height: size.height), display: false)
        return panel
    }

    /// The card is really there: ordered in, on a screen, not zero-sized, its content as big as the window.
    static func isOnScreen(_ window: NSWindow) -> Bool {
        let frame = window.frame
        guard window.isVisible, frame.width >= 1, frame.height >= 1, let content = window.contentView,
              abs(content.frame.width - frame.width) < 1, abs(content.frame.height - frame.height) < 1 else { return false }
        return NSScreen.screens.contains { $0.frame.intersects(frame) }
    }

    private func watchClicks() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) { self.onClickOutside?() }
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
