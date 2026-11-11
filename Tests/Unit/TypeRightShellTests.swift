//
//  TypeRightShellTests.swift
//  TextWardenTests
//
//  What TypeRight changes around TextWarden's shell: the status menu, the red error-count
//  indicator, default shortcuts and where files live.
//

import AppKit
import KeyboardShortcuts
@testable import TextWarden
import XCTest

@MainActor
final class TypeRightShellTests: XCTestCase {
    func testStatusMenuIsTypeRightsMenu() throws {
        let controller = try XCTUnwrap(MenuBarController.shared, "The app delegate creates the menu bar controller at launch")
        controller.updateMenu()
        let titles = try XCTUnwrap(controller.menu).items.map(\.title)
        XCTAssertTrue(titles.contains("打开 TypeRight"), "Menu items: \(titles)")
        XCTAssertTrue(titles.contains("退出 TypeRight"), "Menu items: \(titles)")
    }

    func testErrorCountIndicatorNeverComesOnScreen() {
        let indicator = FloatingErrorIndicator.shared
        defer { indicator.hide() }
        let context = ApplicationContext(bundleIdentifier: "com.apple.TextEdit",
                                         processID: ProcessInfo.processInfo.processIdentifier,
                                         applicationName: "TextEdit")
        let error = GrammarErrorModel(start: 0, end: 3, message: "Spelling", severity: .warning,
                                      category: "Spelling", lintId: "Spelling", suggestions: ["the"])

        // This path never looked at the cards switch, so it used to show the red count.
        indicator.updateWithContext(errors: [error], context: context, sourceText: "teh cat")
        XCTAssertFalse(indicator.isVisible)

        indicator.orderFrontRegardless()
        XCTAssertFalse(indicator.isVisible)
    }

    func testGlobalShortcutsStartUnset() {
        let names: [KeyboardShortcuts.Name] = [
            .toggleTextWarden, .fixAllObvious, .showGrammarSuggestions, .showStyleSuggestions,
            .showAICompose, .showReadability, .toggleSketchPad, .runStyleCheck, .quickRewrite,
        ]
        for name in names {
            XCTAssertNil(name.defaultShortcut, "\(name.rawValue) must not come with a default key")
        }
    }

    func testFilesLiveInTypeRightsOwnFolder() {
        XCTAssertEqual(AppSupportFolder.name, Bundle.main.bundleIdentifier)
        for path in [BrowserWire.socketPath, StrategyProfileCache.shared.cacheFileURL.path] {
            XCTAssertTrue(path.contains("/Application Support/\(AppSupportFolder.name)/"), path)
            XCTAssertFalse(path.contains("TextWarden"), path)
        }
        if Logger.customLogFilePath == nil {
            XCTAssertTrue(Logger.logFilePath.hasSuffix("/Library/Logs/TypeRight/typeright.log"), Logger.logFilePath)
        }
    }
}
