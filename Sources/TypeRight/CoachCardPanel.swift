//
//  CoachCardPanel.swift
//  TypeRight
//
//  Puts the card on screen next to a word without taking focus from the app being typed in.
//  Below the word by default, flipped above when the screen has no room underneath. A card whose
//  answer is still streaming in grows away from the word: its edge next to the word stays put.
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
    /// New content for the card on screen, at the same place; false when it is not on screen any more.
    func update(_ content: CoachCardContent, keys: CoachCardKeys) -> Bool
    func hide()
}

@MainActor
final class CoachCardPanel: CoachCardDisplay {
    /// The gap between the word and the card's tail (DESIGN.md: 9 under the word).
    static let gap: CGFloat = 9

    private var panel: NonActivatingPanel?
    /// Kept between cards: making a hosting view for every card cost more than the card itself.
    private var host: FirstMouseHostingView<CoachCardView>?
    private var measurer: NSHostingView<CoachCardView>?
    private var clickMonitor: Any?
    /// Where the card on screen sits, so an update keeps its place.
    private var placement: (anchor: CGRect, below: Bool, originX: CGFloat, tailX: CGFloat)?

    var onClickOutside: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(_ content: CoachCardContent, keys: CoachCardKeys, anchor: CGRect) -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        let panel = place(content, keys: keys, anchor: anchor)
        let placed = ProcessInfo.processInfo.systemUptime
        panel.orderFrontRegardless()
        guard Self.isOnScreen(panel) else {
            Logger.error("TypeRight: card window not on screen (frame \(NSStringFromRect(panel.frame)), visible \(panel.isVisible)); Tab and Esc stay with the app",
                         category: Logger.ui)
            hide()
            return false
        }
        watchClicks()
        let ordered = ProcessInfo.processInfo.systemUptime
        Logger.debug("⏱ card window: place \(Int((placed - start) * 1000)) ms, order \(Int((ordered - placed) * 1000)) ms", category: Logger.ui)
        return true
    }

    func update(_ content: CoachCardContent, keys: CoachCardKeys) -> Bool {
        guard let panel, panel.isVisible, let placement, let host else { return false }
        let size = measure(content, keys: keys)
        host.rootView = view(content, keys: keys, pointsUp: placement.below, tailX: placement.tailX)
        // Under the word the top edge stays; above it the bottom edge stays.
        let margin = CoachCardView.shadowMargin
        let originY = placement.below ? placement.anchor.minY - Self.gap - size.height + margin : placement.anchor.maxY + Self.gap - margin
        let visible = Self.visibleFrame(for: placement.anchor)
        let originX = min(placement.originX, visible.maxX - size.width + margin - 4)
        panel.setFrame(NSRect(x: originX, y: originY, width: size.width, height: size.height), display: true)
        return Self.isOnScreen(panel)
    }

    func hide() {
        panel?.orderOut(nil)
        placement = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// Sizes the card window for `content` and puts it at `anchor` without ordering it in. `show`
    /// goes through here, and so do the tests and the pictures of the cards.
    func place(_ content: CoachCardContent, keys: CoachCardKeys, anchor: CGRect) -> NSPanel {
        let margin = CoachCardView.shadowMargin
        let visible = Self.visibleFrame(for: anchor)

        let size = measure(content, keys: keys)
        let below = anchor.minY - Self.gap - size.height + margin >= visible.minY
        // The card's left edge lines up with the word's (the panel is wider by the shadow margin).
        var originX = anchor.minX - margin
        originX = min(max(originX, visible.minX - margin + 4), visible.maxX - size.width + margin - 4)
        let originY = below ? anchor.minY - Self.gap - size.height + margin : anchor.maxY + Self.gap - margin
        let tailX = anchor.minX + min(anchor.width / 2, 16) - originX - margin

        let rootView = view(content, keys: keys, pointsUp: below, tailX: tailX)
        let host: FirstMouseHostingView<CoachCardView>
        if let kept = self.host {
            kept.rootView = rootView
            host = kept
        } else {
            host = FirstMouseHostingView(rootView: rootView)
            // The window sets this view's size; left to itself it would resize the window to its own liking.
            host.sizingOptions = []
            self.host = host
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        if panel.contentView !== host { panel.contentView = host }
        panel.setFrame(NSRect(x: originX, y: originY, width: size.width, height: size.height), display: false)
        placement = (anchor, below, originX, tailX)
        return panel
    }

    /// The card's size with its shadow margin. The tail does not change it, so it is measured with any tail.
    private func measure(_ content: CoachCardContent, keys: CoachCardKeys) -> CGSize {
        let probe = CoachCardView(content: content, tail: CoachTailPlacement(pointsUp: true, x: 20), keys: keys)
        if let measurer {
            measurer.rootView = probe
            return measurer.fittingSize
        }
        // Measured by a view the window does not size (one with `sizingOptions = []` measures 0 × 0).
        let measurer = NSHostingView(rootView: probe)
        self.measurer = measurer
        return measurer.fittingSize
    }

    private func view(_ content: CoachCardContent, keys: CoachCardKeys, pointsUp: Bool, tailX: CGFloat) -> CoachCardView {
        CoachCardView(content: content, tail: CoachTailPlacement(pointsUp: pointsUp, x: tailX), keys: keys,
                      onSpeak: { CoachSpeaker.speak($0) })
    }

    private static func visibleFrame(for anchor: CGRect) -> CGRect {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
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
