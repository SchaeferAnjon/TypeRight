//
//  TypeRightInterfaceTests.swift
//  TypeRight
//
//  Rules behind what the windows show: the order of the mistake categories, one way of writing
//  dates, names with a space between Chinese and Latin, the menu bar icon switch and how TypeRight
//  is found again with it off, and the shortcut key cap's states. Nothing here reads or writes the
//  user's settings or opens a window on screen.
//

import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI
@testable import TextWarden
import XCTest

@MainActor
final class TypeRightInterfaceTests: XCTestCase {
    // MARK: Categories (今天, 进步)

    private func mistake(_ category: MistakeCategory) -> NotebookEntry {
        NotebookEntry(kind: .mistake, category: category, from: "a", to: "b", why: "", ipa: "", context: "", app: "", date: Date())
    }

    func testEqualCountsKeepTheCategoriesOwnOrder() {
        // Shuffled input, ties at two: the order must not depend on the input or a dictionary.
        for _ in 0 ..< 20 {
            let entries = ([.preposition, .spelling, .agreement, .agreement, .spelling, .article, .preposition] as [MistakeCategory])
                .shuffled().map(mistake)
            let ranked = TRCategoryStats.ranked(entries).map(\.category)
            XCTAssertEqual(ranked, [.spelling, .preposition, .agreement, .article])
        }
    }

    func testMostCorrectedNeedsOneClearWinner() {
        XCTAssertEqual(TRCategoryStats.mostCorrected([.tense, .tense, .article].map(mistake)), .tense)
        XCTAssertEqual(TRCategoryStats.mostCorrected([.chinglish].map(mistake)), .chinglish)
        XCTAssertNil(TRCategoryStats.mostCorrected([.spelling, .preposition, .agreement].map(mistake)),
                     "every category corrected once: no 最常被改的是…")
        XCTAssertNil(TRCategoryStats.mostCorrected([.spelling, .spelling, .tense, .tense, .article].map(mistake)),
                     "a tie at the top is not a winner")
        XCTAssertNil(TRCategoryStats.mostCorrected([]))
    }

    // MARK: Dates

    func testDatesAreWrittenOneWay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 15, minute: 30)))
        let earlier = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 13, minute: 8)))
        let yesterday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 9, minute: 5)))
        XCTAssertEqual(TRDate.short(earlier, now: now, calendar: calendar), TRDate.time(earlier))
        XCTAssertEqual(TRDate.short(yesterday, now: now, calendar: calendar), TRDate.day(yesterday))
        XCTAssertTrue(TRDate.day(yesterday).hasSuffix("月10日"), TRDate.day(yesterday))
        XCTAssertFalse(TRDate.day(yesterday).contains(" "), "11月10日, not 11 月 10 日")
        XCTAssertEqual(TRDate.day(key: "2026-10-29"), "10月29日")
        XCTAssertEqual(TRDate.day(key: "not a day"), "")
    }

    func testMetaLineHasOneOrder() {
        var entry = mistake(.agreement)
        entry.app = "微信"
        entry.times = 2
        let line = TRMeta.line(entry)
        XCTAssertTrue(line.hasPrefix("主谓一致 · 微信 · "), line)
        XCTAssertTrue(line.hasSuffix(" · 被改过 2 次"), line)
    }

    // MARK: Names

    func testChineseAndLatinGetASpace() {
        XCTAssertEqual(TRText.autospaced("Safari浏览器"), "Safari 浏览器")
        XCTAssertEqual(TRText.autospaced("Safari 浏览器"), "Safari 浏览器")
        XCTAssertEqual(TRText.autospaced("QQ音乐2"), "QQ 音乐 2")
        XCTAssertEqual(TRText.autospaced("微信"), "微信")
        XCTAssertEqual(TRText.autospaced("Microsoft Word"), "Microsoft Word")
    }

    // MARK: Menu bar icon (设置 › 通用 › 在菜单栏显示图标)

    func testIconOffOpensTheMainWindowAtLaunch() {
        XCTAssertEqual(TRMenuBarIcon.atLaunch(iconShown: false), .mainWindow)
        XCTAssertEqual(TRMenuBarIcon.atLaunch(iconShown: true), .nothing)
    }

    func testOpeningAgainShowsAWindow() {
        XCTAssertEqual(TRMenuBarIcon.onReopen(hasVisibleWindows: false, needsSetup: false), .mainWindow)
        XCTAssertEqual(TRMenuBarIcon.onReopen(hasVisibleWindows: false, needsSetup: true), .setup)
        XCTAssertEqual(TRMenuBarIcon.onReopen(hasVisibleWindows: true, needsSetup: false), .nothing)
    }

    /// The real delegate method, with what it opens recorded instead of shown.
    func testIconOffLaunchingAgainOpensTheMainWindow() throws {
        let saved = CoachSettings.defaults
        let suiteName = "TypeRightInterfaceTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            CoachSettings.defaults = saved
            suite.removePersistentDomain(forName: suiteName)
        }
        CoachSettings.defaults = suite
        CoachSettings.menuBarIconShown = false
        XCTAssertFalse(CoachSettings.menuBarIconShown)

        let delegate = AppDelegate()
        var opened: [TRMenuBarIcon.Opens] = []
        delegate.needsSetup = { false }
        delegate.open = { opened.append($0) }

        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertEqual(opened, [.mainWindow])
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        XCTAssertEqual(opened, [.mainWindow, .nothing], "a window already on screen just comes forward")

        delegate.needsSetup = { true }
        _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        XCTAssertEqual(opened.last, .setup)
    }

    func testIconSettingDefaultsToShown() throws {
        let saved = CoachSettings.defaults
        let suiteName = "TypeRightInterfaceTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            CoachSettings.defaults = saved
            suite.removePersistentDomain(forName: suiteName)
        }
        CoachSettings.defaults = suite
        XCTAssertTrue(CoachSettings.menuBarIconShown)
    }

    // MARK: Shortcut key cap

    /// The real recorder in an off-screen window: clicking the cap makes the package's field first
    /// responder (green 按下新的组合键…), Esc stops it (dashed 选一个键 again). Esc saves nothing, so
    /// no shortcut is written anywhere.
    func testRecorderShowsRecordingAndEscStops() throws {
        let name = KeyboardShortcuts.Name("typeRightInterfaceTests.\(UUID().uuidString)")
        let host = NSHostingView(rootView: TRShortcutRecorder(name: name).padding(20))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 80)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        spin()

        XCTAssertEqual(greenPixels(host), 0, "not set: dashed grey cap")
        let field = try XCTUnwrap(find(KeyboardShortcuts.RecorderCocoa.self, in: host))
        XCTAssertEqual(field.alphaValue, 0, "the package's field records but never shows")
        XCTAssertGreaterThan(field.frame.width, 40, "the field covers the cap, so clicks outside it stop recording")

        XCTAssertTrue(window.makeFirstResponder(field))
        spin()
        XCTAssertGreaterThan(greenPixels(host), 30, "recording: green cap")

        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, characters: "\u{1B}",
                                                     charactersIgnoringModifiers: "\u{1B}", isARepeat: false,
                                                     keyCode: UInt16(kVK_Escape)))
        NSApp.sendEvent(escape)
        spin()
        XCTAssertEqual(greenPixels(host), 0, "Esc: back to the dashed cap")
        XCTAssertNil(KeyboardShortcuts.getShortcut(for: name))
    }

    private func spin() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        (NSApp.windows.last?.contentView ?? NSView()).layoutSubtreeIfNeeded()
    }

    private func find<T: NSView>(_: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews {
            if let match = find(T.self, in: sub) { return match }
        }
        return nil
    }

    /// Pixels where green clearly leads: only the `fix` color does that on this page.
    private func greenPixels(_ view: NSView) -> Int {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }
        view.cacheDisplay(in: view.bounds, to: rep)
        var count = 0
        for x in 0 ..< rep.pixelsWide {
            for y in 0 ..< rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.alphaComponent > 0.5, c.greenComponent > c.redComponent + 0.15, c.greenComponent > c.blueComponent + 0.1 {
                    count += 1
                }
            }
        }
        return count
    }
}
