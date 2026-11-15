//
//  CoachCardPanel.swift
//  TypeRight
//
//  Puts the card on screen next to a word without taking focus from the app being typed in.
//  Below the word by default, above it when the visible part of the word's screen has no room
//  underneath, and pushed onto the screen when neither side has room: it may cover the word, it is
//  never cut off. The side is picked for the card as tall as it may still get, since an AI answer
//  streams in English first and its note after. A card that grows away from the word keeps its
//  edge next to the word; one that outgrows its side anyway turns over once and stays there.
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
    /// Called when the user clicks a button on a notice card.
    var onNoticeAction: ((CoachNotice.Action) -> Void)? { get set }
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

/// A screen as the card and the word layer see it (made up in tests): where it is, the part a
/// window may use (no menu bar, no Dock) and its pixel density.
struct CoachScreen: Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
    var scale: CGFloat

    @MainActor static func all() -> [CoachScreen] {
        NSScreen.screens.map { CoachScreen(frame: $0.frame, visibleFrame: $0.visibleFrame, scale: $0.backingScaleFactor) }
    }

    /// The screen a word is on: the one holding its middle (a caret has no width, and a rectangle
    /// without width meets no screen's frame), else one it touches, else the one with the menu bar.
    static func containing(_ rect: CGRect, among screens: [CoachScreen]) -> CoachScreen {
        let middle = CGPoint(x: rect.midX, y: rect.midY)
        return screens.first(where: { $0.frame.contains(middle) }) ?? screens.first(where: { $0.frame.intersects(rect) }) ?? screens.first
            ?? CoachScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
    }
}

/// Where a window with a tail (the card, the word layer) or without one (the ⌥ list) goes next to
/// a rectangle on screen. Heights and edges here are the solid part's, inside the shadow margin.
enum CoachPlacement {
    /// Under `rect` when something `height` tall fits there, else above it when it fits there, else
    /// on the side with more room. `preferring` false tries above first.
    static func below(height: CGFloat, beside rect: CGRect, gap: CGFloat, in visible: CGRect, preferring first: Bool = true) -> Bool {
        let roomBelow = rect.minY - gap - visible.minY
        let roomAbove = visible.maxY - rect.maxY - gap
        if height <= (first ? roomBelow : roomAbove) { return first }
        if height <= (first ? roomAbove : roomBelow) { return !first }
        return roomBelow == roomAbove ? first : roomBelow > roomAbove
    }

    /// The window on that side of `rect`, `gap` from it, its solid left edge at `left`, moved into
    /// `visible` where it would stick out (over `rect` rather than off the screen). Something taller
    /// than the screen keeps its top on it, where it starts.
    static func frame(size: CGSize, margin: CGFloat, left: CGFloat, below: Bool, beside rect: CGRect, gap: CGFloat, in visible: CGRect) -> CGRect {
        let width = size.width - 2 * margin
        let height = size.height - 2 * margin
        let x = min(max(left, visible.minX + 4), visible.maxX - 4 - width)
        let y = min(max(below ? rect.minY - gap - height : rect.maxY + gap, visible.minY), visible.maxY - height)
        return CGRect(x: x - margin, y: y - margin, width: size.width, height: size.height)
    }

    /// The tail's middle from the solid left edge, to point at `x` on screen; kept off the right
    /// corner (the view keeps it off the left one).
    static func tailX(pointingAt x: CGFloat, frame: CGRect, margin: CGFloat) -> CGFloat {
        min(x - frame.minX - margin, frame.width - 2 * margin - 17)
    }
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
    /// Where the card on screen sits, so an update keeps its place: the word, the side of it, whether
    /// it turned over while growing (it does not turn back), and the tail.
    private var placement: (anchor: CGRect, below: Bool, turned: Bool, tailX: CGFloat)?

    private var content: CoachCardContent = .thinking
    private var keys: CoachCardKeys = .normal
    private var followState: CoachFollow?
    private var minWidth: CGFloat = 0

    private let screens: @MainActor () -> [CoachScreen]
    private let layer: CoachWordLayer
    private var spots: [CoachWordSpot] = []
    private var hot: CoachWordSpot?
    private var openTimer: DispatchWorkItem?
    private var leaveTimer: DispatchWorkItem?
    private var layerClosedAt: TimeInterval = -.infinity
    private var listShown = false

    var onClickOutside: (() -> Void)?
    var onNoticeAction: ((CoachNotice.Action) -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    init(screens: @escaping @MainActor () -> [CoachScreen] = CoachScreen.all) {
        self.screens = screens
        layer = CoachWordLayer(screens: screens)
    }

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
        guard let panel, panel.isVisible, let placement else { return false }
        if content.hoverWords != self.content.hoverWords {
            CoachDictionary.shared.prefetch(content.hoverWords, accent: CoachSettings.accent)
        }
        self.content = content
        self.keys = keys
        let screen = screen(for: placement.anchor)
        let size = measure(content, on: screen)
        // It stays on its side while it fits there (under the word the top edge stays, above it the
        // bottom edge); grown out of it, it turns over once, to the other side if that has room.
        let below = placement.turned ? placement.below
            : CoachPlacement.below(height: size.height - 2 * CoachCardView.shadowMargin, beside: placement.anchor, gap: Self.gap,
                                   in: screen.visibleFrame, preferring: placement.below)
        let before = panel.frame
        put(size: size, below: below, turned: placement.turned || below != placement.below, anchor: placement.anchor, in: screen.visibleFrame)
        if panel.frame != before {
            // What hangs off the card follows it: the ⌥ list is put again, a word's layer closes once its word moved.
            if listShown {
                showAllWords(true)
            } else if hot != nil, panel.frame.minX != before.minX || panel.frame.maxY != before.maxY {
                closeWord()
            }
        }
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
        let screen = screen(for: anchor)
        let size = measure(content, on: screen)
        let tallest = Self.grown(content).map { max(measure($0, on: screen).height, size.height) } ?? size.height
        let below = CoachPlacement.below(height: tallest - 2 * CoachCardView.shadowMargin, beside: anchor, gap: Self.gap, in: screen.visibleFrame)
        return put(size: size, below: below, turned: false, anchor: anchor, in: screen.visibleFrame)
    }

    /// The card window at its size on that side of the word, on screen.
    @discardableResult
    private func put(size: CGSize, below: Bool, turned: Bool, anchor: CGRect, in visible: CGRect) -> NSPanel {
        let margin = CoachCardView.shadowMargin
        // The card's left edge lines up with the word's; the tail points into the word, at most 16 in.
        let frame = CoachPlacement.frame(size: size, margin: margin, left: anchor.minX, below: below, beside: anchor, gap: Self.gap, in: visible)
        let tailX = CoachPlacement.tailX(pointingAt: anchor.minX + min(anchor.width / 2, 16), frame: frame, margin: margin)

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
        panel.setFrame(frame, display: panel.isVisible)
        placement = (anchor, below, turned, tailX)
        return panel
    }

    /// The card as tall as it may still get, when it may still grow. An AI answer streams in English
    /// first: until its note (a sentence card's reasons) starts coming, the card is measured with a
    /// stand-in of a usual length there, two lines of note or a line per reason. A longer one turns
    /// the card over in `update`.
    private static func grown(_ content: CoachCardContent) -> CoachCardContent? {
        switch content {
        case let .translate(source, result) where result.note.isEmpty:
            return .translate(source: source, result: CoachTranslation(english: result.english, ipa: result.ipa, note: String(repeating: "讲", count: 56)))
        case let .sentence(original, check) where check.changes.contains(where: { $0.why.isEmpty }):
            // Each stand-in is different: the card shows a reason once however many changes give it.
            let changes = check.changes.enumerated().map { index, change in
                change.why.isEmpty ? CoachSentenceCheck.Change(from: change.from, to: change.to, why: String(repeating: "讲", count: 24) + "\(index)", type: change.type)
                    : change
            }
            return .sentence(original: original, check: CoachSentenceCheck(ok: check.ok, corrected: check.corrected, changes: changes))
        default:
            return nil
        }
    }

    /// The card's size with its shadow margin. The tail does not change it, so it is measured with any tail.
    /// Measured at the pixel density of the screen the card goes on: the card's text is many small
    /// pieces (a word to stop on, a Chinese character where a line may break), each rounded to whole
    /// pixels, so measured at 1× it came out 5 points wider than it draws at 2×.
    private func measure(_ content: CoachCardContent, on screen: CoachScreen) -> CGSize {
        let probe = CoachCardView(content: content, tail: CoachTailPlacement(pointsUp: true, x: 20), keys: keys,
                                  follow: followState, minWidth: minWidth)
        let measured = AnyView(probe.environment(\.displayScale, screen.scale))
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
                      onWords: { [weak self] in self?.spots = $0 },
                      onNotice: { [weak self] in self?.onNoticeAction?($0) })
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

    private func screen(for anchor: CGRect) -> CoachScreen {
        CoachScreen.containing(anchor, among: screens())
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
