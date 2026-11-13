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
