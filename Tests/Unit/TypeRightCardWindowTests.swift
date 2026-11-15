//
//  TypeRightCardWindowTests.swift
//  TypeRight
//
//  The card window and the menu header as the app really sizes them: the code that shows them
//  measures and places them here too, it just never orders a card onto the screen. On 2026-11-11
//  every card window in the running app was 0 × 0, while the pictures, drawn their own way,
//  looked fine.
//

import AppKit
import SwiftUI
@testable import TextWarden
import XCTest

/// The cards the coach shows, with the words the app really uses; the pictures draw them too.
@MainActor
enum TypeRightCardSamples {
    static func cards() throws -> [(name: String, content: CoachCardContent)] {
        [
            ("spelling", .spelling(wrong: "tomorow", fixes: ["tomorrow", "tomorrows"])),
            ("translate", .translate(source: "预约", result: CoachTranslation(english: "book", ipa: "/bʊk/",
                                                                           note: "订会议室、餐厅用 book；约医生说 make an appointment。"))),
            ("sentence", .sentence(original: "I want to book a meeting room tomorrow because I has a question.",
                                   check: CoachSentenceCheck(ok: false,
                                                             corrected: "I want to book a meeting room tomorrow because I have a question.",
                                                             changes: [.init(from: "I has", to: "I have", why: "主语是 I，动词要用 have。", type: "agreement")]))),
            ("sentence-local", try localSentence("I has a question.", [("has", "Agreement::the_form_of_the_verb_must_agree_in", "have")])),
            ("thinking", .thinking),
            ("failed", .failed(try XCTUnwrap(CoachAIError.http(401).errorDescription), keyRejected: true)),
        ]
    }

    /// The card without AI for Harper's findings (words, lint id, fix) in `text`, as CoachLocalGrammar makes it.
    static func localSentence(_ text: String, _ findings: [(words: String, id: String, fix: String)]) throws -> CoachCardContent {
        let scalars = Array(text.unicodeScalars)
        let errors = try findings.map { item in
            let found = try XCTUnwrap(CoachText.wordRange(of: item.words, in: text))
            let start = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: found.lowerBound)
            return GrammarErrorModel(start: start, end: start + item.words.unicodeScalars.count, message: "", severity: .warning,
                                     category: String(item.id.prefix { $0 != ":" }), lintId: item.id, suggestions: [item.fix])
        }
        return .sentence(original: text, check: try XCTUnwrap(CoachLocalGrammar.check(0 ..< scalars.count, in: scalars, errors: errors)))
    }

    /// A word in the middle of the main screen, in Cocoa coordinates.
    static func word() throws -> CGRect {
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        return CGRect(x: visible.minX + 200, y: visible.midY, width: 64, height: 17)
    }
}

@MainActor
final class TypeRightCardWindowTests: XCTestCase {
    private let margin = CoachCardView.shadowMargin

    // MARK: Cards

    func testEveryCardWindowIsAsBigAsItsCard() throws {
        let word = try TypeRightCardSamples.word()
        for (name, content) in try TypeRightCardSamples.cards() {
            for keys in [CoachCardKeys.normal, .readOnly] where content != .thinking || keys == .normal {
                let label = "\(name) \(keys)"
                let window = CoachCardPanel().place(content, keys: keys, anchor: word)
                XCTAssertFalse(window.isVisible, "the test never puts a card on screen")
                let frame = window.frame
                // The smallest card is the 想一下… capsule: a line of 12 pt text inside the shadow margin.
                XCTAssertGreaterThanOrEqual(frame.width, 2 * margin + 50, label)
                XCTAssertGreaterThanOrEqual(frame.height, 2 * margin + CoachCardView.tailHeight + 20, label)
                let host = try XCTUnwrap(window.contentView, label)
                XCTAssertEqual(host.frame.size, frame.size, label)

                // Under the word (DESIGN.md): the tail's tip 9 below it, the card's left edge on the word's.
                XCTAssertEqual(frame.maxY - margin, word.minY - CoachCardPanel.gap, accuracy: 0.5, label)
                XCTAssertEqual(frame.minX + margin, word.minX, accuracy: 0.5, label)

                // What is drawn fits the window: the solid card (tail included) sits exactly inside the
                // shadow margin, so nothing is cut off and the window is not bigger than the card.
                let solid = try XCTUnwrap(solidBounds(of: window), "\(label): nothing drawn")
                XCTAssertEqual(solid.minX, margin, accuracy: 1.5, label)
                XCTAssertEqual(solid.maxX, frame.width - margin, accuracy: 1.5, label)
                XCTAssertEqual(solid.minY, margin, accuracy: 1.5, "\(label): tail tip")
                XCTAssertEqual(solid.maxY, frame.height - margin, accuracy: 1.5, label)
            }
        }
    }

    func testCardFlipsAboveTheWordWithoutRoomBelow() throws {
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let word = CGRect(x: visible.minX + 200, y: visible.minY + 4, width: 64, height: 17)
        let window = CoachCardPanel().place(.spelling(wrong: "tomorow", fixes: ["tomorrow"]), keys: .normal, anchor: word)
        XCTAssertGreaterThan(window.frame.height, 2 * margin + 20)
        XCTAssertEqual(window.frame.minY + margin, word.maxY + CoachCardPanel.gap, accuracy: 0.5, "the tail's tip 9 above the word")
        let solid = try XCTUnwrap(solidBounds(of: window))
        XCTAssertEqual(solid.maxY, window.frame.height - margin, accuracy: 1.5, "tail tip at the bottom")
    }

    /// The check `show` makes before the coach may take Tab and Esc.
    func testOnlyACardReallyOnScreenCounts() throws {
        let word = try TypeRightCardSamples.word()
        let placed = CoachCardPanel().place(.spelling(wrong: "tomorow", fixes: ["tomorrow"]), keys: .normal, anchor: word)
        XCTAssertFalse(CoachCardPanel.isOnScreen(placed), "placed but not ordered in")

        // A 0 × 0 window ordered in, like the card window of 2026-11-11. Nothing of it can be seen.
        let empty = clearWindow(NSRect(x: word.minX, y: word.minY, width: 0, height: 0))
        defer { empty.orderOut(nil) }
        XCTAssertTrue(empty.isVisible)
        XCTAssertFalse(CoachCardPanel.isOnScreen(empty))

        // Same place and a card's size, ordered in but fully transparent and click-through.
        let card = clearWindow(NSRect(x: word.minX, y: word.minY - 80, width: 180, height: 70))
        defer { card.orderOut(nil) }
        XCTAssertTrue(CoachCardPanel.isOnScreen(card))
        card.setFrame(NSRect(x: -40000, y: -40000, width: 180, height: 70), display: false)
        XCTAssertFalse(CoachCardPanel.isOnScreen(card), "off every screen")
    }

    // MARK: Near the edges of the screen

    /// Made-up screens, so these tests do not depend on the Mac they run on. The first is like this
    /// MacBook's (1512 × 982, menu bar 38, Dock hidden); the second sits to its right and lower,
    /// with a menu bar and a Dock of its own.
    private static let laptop = CoachScreen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                            visibleFrame: CGRect(x: 0, y: 4, width: 1512, height: 940), scale: 2)
    private static let side = CoachScreen(frame: CGRect(x: 1512, y: -300, width: 1920, height: 1080),
                                          visibleFrame: CGRect(x: 1512, y: -230, width: 1920, height: 985), scale: 1)

    /// The note the user saw cut off at the bottom of the screen in Orca on 2026-11-15.
    private static let note = "Use this casual short form when pointing at something nearby; use \"What is this?\" for a more formal tone."

    private static func whatsThis(note: String) -> CoachCardContent {
        .translate(source: "这是?", result: CoachTranslation(english: "What's this?", ipa: note.isEmpty ? "" : "/wʌts ðɪs/", note: note))
    }

    /// The note as it streams in, a few words at a time, ending with all of it.
    private static func streamed(_ note: String) -> [String] {
        let words = note.split(separator: " ", omittingEmptySubsequences: false)
        return stride(from: 3, through: words.count, by: 3).map { words.prefix($0).joined(separator: " ") } + [note]
    }

    /// The user's case: the word low on the screen, room under it for the English line but not for
    /// the note that comes after it (on a sentence card: the reasons after the changes). The card
    /// goes above the word from the start and grows upwards there, its tail staying on the word.
    func testStreamingCardLowOnTheScreenGoesAboveAndGrowsUpwards() throws {
        let screen = Self.laptop
        func sentence(_ why: String) -> CoachCardContent {
            .sentence(original: "Yesterday I has a question about the meeting room.",
                      check: CoachSentenceCheck(ok: false, corrected: "Yesterday I had a question about the meeting room.",
                                                changes: [.init(from: "I has", to: "I had", why: why, type: "tense")]))
        }
        let kinds: [(name: String, steps: [CoachCardContent])] = [
            ("translate", [Self.whatsThis(note: "")] + Self.streamed(Self.note).map { Self.whatsThis(note: $0) }),
            ("sentence", ["", "说的是昨天，", "说的是昨天，动词用过去式 had。"].map(sentence)),
        ]
        for kind in kinds {
            let first = try XCTUnwrap(kind.steps.first)
            let last = try XCTUnwrap(kind.steps.last)
            let short = try solidHeight(first, on: screen)
            let full = try solidHeight(last, on: screen)
            XCTAssertGreaterThan(full, short + 15, "\(kind.name): what comes later makes the card taller")
            let word = CGRect(x: 622, y: screen.visibleFrame.minY + CoachCardPanel.gap + (short + full) / 2, width: 40, height: 17)

            let panel = CoachCardPanel(screens: { [screen] })
            let window = panel.place(first, keys: .normal, anchor: word)
            ghost(window)
            defer { window.orderOut(nil) }
            assertAbove(window, word, "\(kind.name), first part: picked for the whole card")
            assertInside(window, screen.visibleFrame, "\(kind.name), first part")
            for (index, step) in kind.steps.enumerated().dropFirst() {
                _ = panel.update(step, keys: .normal)
                assertAbove(window, word, "\(kind.name) step \(index)")
                assertInside(window, screen.visibleFrame, "\(kind.name) step \(index)")
            }
            XCTAssertEqual(window.frame.height - 2 * margin, full, accuracy: 1, "\(kind.name): all of it is in")
        }
    }

    /// A note longer than any the card makes room for: the card under the word turns over to the top
    /// once, when it no longer fits, and from there grows upwards. It never goes back down.
    func testCardThatOutgrowsTheRoomBelowTurnsOverOnce() throws {
        let screen = Self.laptop
        let long = Array(repeating: Self.note, count: 3).joined(separator: " ")
        let reserved = try solidHeight(Self.whatsThis(note: Self.note), on: screen)
        let full = try solidHeight(Self.whatsThis(note: long), on: screen)
        XCTAssertGreaterThan(full, reserved + 30)
        let word = CGRect(x: 300, y: screen.visibleFrame.minY + CoachCardPanel.gap + reserved + 10, width: 40, height: 17)

        let panel = CoachCardPanel(screens: { [screen] })
        let window = panel.place(Self.whatsThis(note: ""), keys: .normal, anchor: word)
        ghost(window)
        defer { window.orderOut(nil) }
        XCTAssertLessThan(window.frame.midY, word.midY, "room below for a usual note: under the word")
        var sides = [false]
        for note in Self.streamed(long) {
            _ = panel.update(Self.whatsThis(note: note), keys: .normal)
            assertInside(window, screen.visibleFrame, "\(note.count) characters")
            let above = window.frame.midY > word.midY
            if above != sides.last { sides.append(above) }
            if above {
                XCTAssertEqual(window.frame.minY + margin, word.maxY + CoachCardPanel.gap, accuracy: 0.5, "above: the tail stays on the word")
            } else {
                XCTAssertEqual(window.frame.maxY - margin, word.minY - CoachCardPanel.gap, accuracy: 0.5, "below: the tail stays on the word")
            }
        }
        XCTAssertEqual(sides, [false, true], "under the word, then above it once")
        let tip = try XCTUnwrap(tailTip(of: window))
        XCTAssertEqual(tip.y, window.frame.height - margin, accuracy: 1.5, "the tail at the bottom, pointing down at the word")
    }

    /// Near the right edge the card moves left to stay on screen, also when it grows wider, and its
    /// tail still points at the word.
    func testCardAtTheRightEdgeMovesLeftWithItsTailOnTheWord() throws {
        let screen = Self.laptop
        let word = CGRect(x: screen.visibleFrame.maxX - 70, y: screen.visibleFrame.midY, width: 40, height: 17)
        let panel = CoachCardPanel(screens: { [screen] })
        let window = panel.place(Self.whatsThis(note: ""), keys: .normal, anchor: word)
        ghost(window)
        defer { window.orderOut(nil) }
        for content in [Self.whatsThis(note: ""), Self.whatsThis(note: Self.note)] {
            _ = panel.update(content, keys: .normal)
            let label = content == Self.whatsThis(note: "") ? "English only" : "with the note"
            assertInside(window, screen.visibleFrame, label)
            let tip = try XCTUnwrap(tailTip(of: window), label)
            XCTAssertEqual(window.frame.minX + tip.x, word.minX + 16, accuracy: 2, "\(label): the tail points at the word")
        }
        XCTAssertGreaterThan(window.frame.width - 2 * margin, 300, "the card did grow wider")
    }

    /// A screen so low that the card fits neither under nor above the word: it goes where there is
    /// more room and is pushed onto the screen, over the word if it must.
    func testCardWithRoomOnNeitherSideStaysOnScreen() throws {
        let full = try solidHeight(Self.whatsThis(note: Self.note), on: Self.laptop)
        let visible = CGRect(x: 0, y: 4, width: 1512, height: full + 30)
        let screen = CoachScreen(frame: CGRect(x: 0, y: 0, width: 1512, height: visible.maxY + 38), visibleFrame: visible, scale: 2)
        for (name, y) in [("lower half", visible.minY + 20), ("upper half", visible.maxY - 37)] {
            let word = CGRect(x: 400, y: y, width: 40, height: 17)
            let window = CoachCardPanel(screens: { [screen] }).place(Self.whatsThis(note: Self.note), keys: .normal, anchor: word)
            assertInside(window, visible, name)
            XCTAssertEqual(window.frame.midY > word.midY, name == "lower half", "\(name): on the side with more room")
        }
    }

    /// The word layer (a word on the card under the mouse) at the bottom right of the screen: it turns
    /// over to the top and moves left, its tail on the word. Above a card at the top, it turns down.
    func testWordLayerStaysOnScreenAtTheEdges() throws {
        let screen = Self.laptop
        let info = CoachWordInfo(word: "nearby", ipa: "/ˌnɪrˈbaɪ/", senses: [.init(pos: "adj.", meaning: "附近的；邻近的"), .init(pos: "adv.", meaning: "在附近")],
                                 status: .found)
        let layer = CoachWordLayer(screens: { [screen] })
        let cases: [(name: String, word: CGRect, up: Bool)] = [
            ("bottom right", CGRect(x: screen.visibleFrame.maxX - 60, y: screen.visibleFrame.minY + 12, width: 44, height: 18), false),
            ("top right", CGRect(x: screen.visibleFrame.maxX - 60, y: screen.visibleFrame.maxY - 30, width: 44, height: 18), true),
        ]
        for item in cases {
            let window = layer.place(info, at: item.word, up: item.up)
            XCTAssertFalse(window.isVisible, "placed, not ordered in")
            assertInside(window, screen.visibleFrame, item.name, margin: CoachWordLayerView.margin)
            XCTAssertEqual(window.frame.midY > item.word.midY, !item.up, "\(item.name): turned over")
            let tip = try XCTUnwrap(tailTip(of: window), item.name)
            XCTAssertEqual(window.frame.minX + tip.x, item.word.midX, accuracy: 2, "\(item.name): the tail on the word")
        }
    }

    /// A word on the second screen: the card goes by that screen's visible area, also for a caret
    /// with no width (a zero-width rectangle meets no screen frame).
    func testCardOnTheSecondScreenGoesByThatScreen() throws {
        let screens = [Self.laptop, Self.side]
        let visible = Self.side.visibleFrame
        let short = try solidHeight(Self.whatsThis(note: ""), on: Self.side)
        let full = try solidHeight(Self.whatsThis(note: Self.note), on: Self.side)
        for (name, width) in [("word", 40.0), ("caret", 0.0)] {
            let word = CGRect(x: visible.minX + 300, y: visible.minY + CoachCardPanel.gap + (short + full) / 2, width: width, height: 17)
            let panel = CoachCardPanel(screens: { screens })
            let window = panel.place(Self.whatsThis(note: ""), keys: .normal, anchor: word)
            ghost(window)
            defer { window.orderOut(nil) }
            for note in Self.streamed(Self.note) {
                _ = panel.update(Self.whatsThis(note: note), keys: .normal)
                assertInside(window, visible, "\(name): \(note.count) characters")
                assertAbove(window, word, name)
            }
            XCTAssertEqual(window.frame.minX + margin, word.minX, accuracy: 0.5, "\(name): left edge on the word")
        }
    }

    /// The ⌥ list under a card low on a low screen, and above one high on it: on screen either way.
    func testWordListStaysOnScreen() throws {
        let visible = CGRect(x: 0, y: 4, width: 1512, height: 300)
        let screen = CoachScreen(frame: CGRect(x: 0, y: 0, width: 1512, height: 342), visibleFrame: visible, scale: 2)
        let infos = ["casual", "short", "form", "pointing", "nearby", "formal"].map {
            CoachWordInfo(word: $0, ipa: "/ˈwɜrd/", senses: [.init(pos: "adj.", meaning: "一个常见的意思；另一个意思")], status: .found)
        }
        let layer = CoachWordLayer(screens: { [screen] })
        for (name, card) in [("card low", CGRect(x: 1200, y: visible.minY + 20, width: 300, height: 110)),
                             ("card high", CGRect(x: 1200, y: visible.maxY - 130, width: 300, height: 110))]
        {
            let window = layer.placeList(infos, key: "⌥", near: card)
            assertInside(window, visible, name, margin: CoachWordLayerView.margin)
        }
    }

    // MARK: Menu header

    func testMenuHeaderIsAsTallAsItsContent() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tr-menu-header-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let notebook = CoachNotebook(fileURL: file)
        let menu = TypeRightMenu.shared.build(state: TRMenuState(app: nil, allPaused: false, ai: TRMenuAILine(tone: .off, title: "AI：没开，只在本机查拼写语法", opens: .account),
                                                                         needsAccess: false), notebook: notebook)
        let header = try XCTUnwrap(menu.items.first?.view, "the first item is the header view")
        XCTAssertEqual(header.frame.width, TRMenuHeader.width)
        // 今天改了 N 处 (15 pt), a line of 12 pt under it, 12 of space, 24 of bars, 12 above and below.
        XCTAssertGreaterThanOrEqual(header.frame.height, 12 + 15 + 12 + 12 + 24 + 12)

        let window = NSWindow(contentRect: header.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = header
        XCTAssertEqual(header.frame.height, window.frame.height)
        let bars = try XCTUnwrap(drawnBounds(of: window, where: {
            $0.alphaComponent > 0.3 && $0.greenComponent > $0.redComponent + 0.15 && $0.greenComponent > $0.blueComponent + 0.05
        }), "the 14 green bars are drawn")
        XCTAssertGreaterThan(bars.width, TRMenuHeader.width - 2 * 14 - 4, "all 14 bars")
        XCTAssertEqual(bars.maxY, header.frame.height - 12, accuracy: 1.5, "the bars end 12 above the bottom: nothing is cut off")
        let text = try XCTUnwrap(drawnBounds(of: window, where: { $0.alphaComponent > 0.5 }))
        XCTAssertEqual(text.minY, 12, accuracy: 4, "the title starts 12 below the top")
    }

    // MARK: Helpers

    /// The solid card's height (tail included) for `content`, as the panel measures it on `screen`.
    private func solidHeight(_ content: CoachCardContent, on screen: CoachScreen) throws -> CGFloat {
        let middle = CGRect(x: screen.visibleFrame.minX + 200, y: screen.visibleFrame.midY, width: 40, height: 17)
        let window = CoachCardPanel(screens: { [screen] }).place(content, keys: .normal, anchor: middle)
        return window.frame.height - 2 * margin
    }

    /// Orders a placed card in without anyone seeing or clicking it, so `update` takes it as on screen.
    private func ghost(_ window: NSWindow) {
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
    }

    /// The solid part of the window (inside its shadow margin) lies in `visible`.
    private func assertInside(_ window: NSWindow, _ visible: CGRect, _ label: String, margin: CGFloat = CoachCardView.shadowMargin,
                              file: StaticString = #filePath, line: UInt = #line)
    {
        let solid = window.frame.insetBy(dx: margin, dy: margin)
        XCTAssertTrue(visible.insetBy(dx: -0.5, dy: -0.5).contains(solid), "\(label): \(NSStringFromRect(solid)) is not inside \(NSStringFromRect(visible))",
                      file: file, line: line)
    }

    /// Above the word, the tail's tip 9 over it.
    private func assertAbove(_ window: NSWindow, _ word: CGRect, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(window.frame.minY + margin, word.maxY + CoachCardPanel.gap, accuracy: 0.5, "\(label): the tail's tip 9 above the word",
                       file: file, line: line)
    }

    /// The tail's tip (the drawn row furthest from the card's body), in points from the window's top left.
    private func tailTip(of window: NSWindow) -> CGPoint? {
        guard let view = window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds), let solid = solidBounds(of: window) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        // The tail points up when its tip is the top row of the drawing, down when it is the bottom one.
        let rows = [Int((solid.minY * scale).rounded()), Int((solid.maxY * scale).rounded()) - 1]
        let tips = rows.compactMap { y -> (y: Int, xs: [Int])? in
            let xs = (0 ..< rep.pixelsWide).filter { (rep.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.95 }
            return xs.isEmpty ? nil : (y, xs)
        }
        guard let tip = tips.min(by: { $0.xs.count < $1.xs.count }), let first = tip.xs.first, let last = tip.xs.last else { return nil }
        return CGPoint(x: CGFloat(first + last + 1) / 2 / scale, y: CGFloat(tip.y) / scale)
    }

    /// A borderless window that cannot be seen or clicked, ordered in.
    private func clearWindow(_ frame: NSRect) -> NSWindow {
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        window.orderFrontRegardless()
        return window
    }

    /// Where the card is drawn solid (its body, border and tail), in points from the window's top left.
    private func solidBounds(of window: NSWindow) -> CGRect? {
        drawnBounds(of: window, where: { $0.alphaComponent > 0.95 })
    }

    /// The bounds of the pixels that pass `test`, in points from the content's top left.
    private func drawnBounds(of window: NSWindow, where test: (NSColor) -> Bool) -> CGRect? {
        guard let view = window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        view.layoutSubtreeIfNeeded()
        guard view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in 0 ..< rep.pixelsHigh {
            for x in 0 ..< rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), test(color) else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }
}
