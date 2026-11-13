//
//  CoachCardPanel.swift
//  TypeRight
//
//  Puts the card on screen next to a word without taking focus from the app being typed in.
//  Below the word by default, flipped above when the screen has no room underneath. A card whose
//  answer is still streaming in grows away from the word: its edge next to the word stays put.
//
//  It also watches the mouse over the card: resting 0.25 s on an English word opens the word
//  layer (IPA, meaning, sound) under it; once one is open, the next word opens at once; leaving
//  closes it after 0.18 s, time enough to reach the layer's speaker. The mouse is read from event
//  monitors, not tracking areas: the card belongs to an app in the background, and in the running
//  app a tracking area missed the first stop on a word of a new card.
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
    /// The card while the user types along with it (nil: the plain card). With an `anchor` the card
    /// moves there (typing went on to another line); false when it is not on screen any more.
    func follow(_ state: CoachFollow?, anchor: CGRect?) -> Bool
    /// Every word on the card with its IPA and meaning, under the card, while the user holds the key.
    func showAllWords(_ shown: Bool)
    func hide()
}

@MainActor
final class CoachCardPanel: CoachCardDisplay {
    /// The gap between the word and the card's tail (DESIGN.md: 9 under the word).
    static let gap: CGFloat = 9
    /// Resting on a word this long opens its layer.
    static let hoverDelay: TimeInterval = 0.25
    /// The layer closes this long after the mouse left the word and the layer.
    static let leaveDelay: TimeInterval = 0.18

    private var panel: NonActivatingPanel?
    /// Kept between cards: making a hosting view for every card cost more than the card itself.
    private var host: FirstMouseHostingView<CoachCardView>?
    private var measurer: NSHostingView<AnyView>?
    private var clickMonitor: Any?
    private var mouseMonitors: [Any] = []
    /// The mouse was over the card or the word layer at the last move.
    private var mouseOver = false
    /// Where the card on screen sits, so an update keeps its place.
    private var placement: (anchor: CGRect, below: Bool, originX: CGFloat, tailX: CGFloat)?

    private var content: CoachCardContent = .thinking
    private var keys: CoachCardKeys = .normal
    private var followState: CoachFollow?
    private var minWidth: CGFloat = 0

    private let layer = CoachWordLayer()
    private var spots: [CoachWordSpot] = []
    private var hot: CoachWordSpot?
    private var openTimer: DispatchWorkItem?
    private var leaveTimer: DispatchWorkItem?
    private var layerClosedAt: TimeInterval = -.infinity
    private var listShown = false

    var onClickOutside: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(_ content: CoachCardContent, keys: CoachCardKeys, anchor: CGRect) -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        closeWord()
        hideList()
        followState = nil
        minWidth = 0
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
        watchMouse()
        CoachDictionary.shared.prefetch(content.hoverWords, accent: CoachSettings.accent)
        let ordered = ProcessInfo.processInfo.systemUptime
        Logger.debug("⏱ card window: place \(Int((placed - start) * 1000)) ms, order \(Int((ordered - placed) * 1000)) ms", category: Logger.ui)
        return true
    }

    func update(_ content: CoachCardContent, keys: CoachCardKeys) -> Bool {
        guard let panel, panel.isVisible, let placement, let host else { return false }
        if content.hoverWords != self.content.hoverWords {
            CoachDictionary.shared.prefetch(content.hoverWords, accent: CoachSettings.accent)
        }
        self.content = content
        self.keys = keys
        let size = measure(on: Self.screen(for: placement.anchor))
        host.rootView = view(pointsUp: placement.below, tailX: placement.tailX)
        // Under the word the top edge stays; above it the bottom edge stays.
        let margin = CoachCardView.shadowMargin
        let originY = placement.below ? placement.anchor.minY - Self.gap - size.height + margin : placement.anchor.maxY + Self.gap - margin
        let visible = Self.visibleFrame(for: placement.anchor)
        let originX = min(placement.originX, visible.maxX - size.width + margin - 4)
        panel.setFrame(NSRect(x: originX, y: originY, width: size.width, height: size.height), display: true)
        return Self.isOnScreen(panel)
    }

    func follow(_ state: CoachFollow?, anchor: CGRect?) -> Bool {
        guard let panel, panel.isVisible else { return false }
        if followState == nil, state != nil {
            // From here the card keeps at least its width: the keys row changes as the user types.
            minWidth = panel.frame.width - 2 * CoachCardView.shadowMargin
        } else if state == nil {
            minWidth = 0
        }
        followState = state
        if let anchor {
            closeWord()
            _ = place(content, keys: keys, anchor: anchor)
            return Self.isOnScreen(panel)
        }
        return update(content, keys: keys)
    }

    func showAllWords(_ shown: Bool) {
        guard shown else {
            hideList()
            return
        }
        let words = content.hoverWords
        guard let panel, panel.isVisible, let placement, !words.isEmpty else { return }
        closeWord()
        let accent = CoachSettings.accent
        let margin = CoachCardView.shadowMargin
        var body = panel.frame.insetBy(dx: margin, dy: margin)
        body.size.height -= CoachCardView.tailHeight
        if !placement.below { body.origin.y += CoachCardView.tailHeight }
        let key = CoachSettings.allWordsKey == .control ? "⌃" : "⌥"
        layer.showList(words.map { CoachDictionary.shared.info(for: $0, accent: accent) }, key: key, near: body)
        listShown = true
    }

    func hide() {
        panel?.orderOut(nil)
        placement = nil
        followState = nil
        minWidth = 0
        closeWord()
        hideList()
        spots = []
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors = []
        mouseOver = false
    }

    /// Sizes the card window for `content` and puts it at `anchor` without ordering it in. `show`
    /// goes through here, and so do the tests and the pictures of the cards.
    func place(_ content: CoachCardContent, keys: CoachCardKeys, anchor: CGRect) -> NSPanel {
        self.content = content
        self.keys = keys
        let margin = CoachCardView.shadowMargin
        let visible = Self.visibleFrame(for: anchor)

        let size = measure(on: Self.screen(for: anchor))
        let below = anchor.minY - Self.gap - size.height + margin >= visible.minY
        // The card's left edge lines up with the word's (the panel is wider by the shadow margin).
        var originX = anchor.minX - margin
        originX = min(max(originX, visible.minX - margin + 4), visible.maxX - size.width + margin - 4)
        let originY = below ? anchor.minY - Self.gap - size.height + margin : anchor.maxY + Self.gap - margin
        let tailX = anchor.minX + min(anchor.width / 2, 16) - originX - margin

        let rootView = view(pointsUp: below, tailX: tailX)
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
    /// Measured at the pixel density of the screen the card goes on: the card's text is many small
    /// pieces (a word to stop on, a Chinese character where a line may break), each rounded to whole
    /// pixels, so measured at 1× it came out 5 points wider than it draws at 2×.
    private func measure(on screen: NSScreen?) -> CGSize {
        let probe = CoachCardView(content: content, tail: CoachTailPlacement(pointsUp: true, x: 20), keys: keys,
                                  follow: followState, minWidth: minWidth)
        let measured = AnyView(probe.environment(\.displayScale, screen?.backingScaleFactor ?? 2))
        if let measurer {
            measurer.rootView = measured
            return measurer.fittingSize
        }
        // Measured by a view the window does not size (one with `sizingOptions = []` measures 0 × 0).
        let measurer = NSHostingView(rootView: measured)
        self.measurer = measurer
        return measurer.fittingSize
    }

    private func view(pointsUp: Bool, tailX: CGFloat) -> CoachCardView {
        CoachCardView(content: content, tail: CoachTailPlacement(pointsUp: pointsUp, x: tailX), keys: keys,
                      follow: followState, hot: hot?.id, minWidth: minWidth,
                      onSpeak: { CoachSpeaker.speak($0) },
                      onWords: { [weak self] in self?.spots = $0 })
    }

    // MARK: Words under the mouse

    /// Every mouse move while the card is up, over any app (global) or over the card itself (local).
    private func watchMouse() {
        guard mouseMonitors.isEmpty else { return }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseAt(NSEvent.mouseLocation) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated { self?.mouseAt(NSEvent.mouseLocation) }
            return event
        }
        mouseMonitors = [global, local].compactMap { $0 }
    }

    private func mouseAt(_ location: CGPoint) {
        guard let panel, panel.isVisible, let host else { return }
        if let frame = layer.frame, frame.contains(location) {
            // On the layer (to reach its speaker): it stays.
            mouseOver = true
            leaveTimer?.cancel()
            openTimer?.cancel()
            return
        }
        if panel.frame.contains(location) {
            mouseOver = true
            mouseMoved(to: host.convert(panel.convertPoint(fromScreen: location), from: nil))
            return
        }
        guard mouseOver else { return }
        mouseOver = false
        mouseLeftCard()
    }

    private func mouseMoved(to point: CGPoint) {
        let spot = spots.first { $0.frame.insetBy(dx: -1, dy: -2).contains(point) }
        if let hot, spot?.id == hot.id {
            leaveTimer?.cancel()
            return
        }
        openTimer?.cancel()
        guard let spot else {
            if hot != nil { leaveSoon() }
            return
        }
        leaveTimer?.cancel()
        // One layer was just open: the next word comes at once, as the mouse moves along the line.
        if hot != nil || ProcessInfo.processInfo.systemUptime - layerClosedAt < 0.3 {
            openWord(spot)
            return
        }
        let timer = DispatchWorkItem { [weak self] in self?.openWord(spot) }
        openTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: timer)
    }

    private func mouseLeftCard() {
        openTimer?.cancel()
        if hot != nil { leaveSoon() }
    }

    private func openWord(_ spot: CoachWordSpot) {
        guard let panel, panel.isVisible, let host, let placement else { return }
        hideList()
        let info = CoachDictionary.shared.info(for: spot.word, accent: CoachSettings.accent)
        let word = panel.convertToScreen(host.convert(spot.frame, to: nil))
        layer.show(info, at: word, up: !placement.below)
        hot = spot
        host.rootView = view(pointsUp: placement.below, tailX: placement.tailX)
    }

    private func leaveSoon() {
        leaveTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in self?.closeWord() }
        leaveTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.leaveDelay, execute: timer)
    }

    private func closeWord() {
        openTimer?.cancel()
        leaveTimer?.cancel()
        guard hot != nil else { return }
        hot = nil
        if !listShown { layer.hide() }
        layerClosedAt = ProcessInfo.processInfo.systemUptime
        if let host, let placement { host.rootView = view(pointsUp: placement.below, tailX: placement.tailX) }
    }

    private func hideList() {
        guard listShown else { return }
        listShown = false
        layer.hide()
    }

    // MARK: Window

    private static func screen(for anchor: CGRect) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
    }

    private static func visibleFrame(for anchor: CGRect) -> CGRect {
        screen(for: anchor)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
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
