//
//  TypeRightShellTests.swift
//  TextWardenTests
//
//  What TypeRight changes around TextWarden's shell: the status menu, the red error-count
//  indicator, default shortcuts, where files live, the menu bar while a window is open, and
//  going back to menu-bar only when the last window closes.
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

    // MARK: Back to menu-bar only

    /// SwiftUI's placeholder window is visible and titled from launch on; closing a TypeRight
    /// window used to count it as still open, so the Dock icon stayed.
    func testClosingTheLastWindowReturnsToMenuBarDespiteThePlaceholder() throws {
        XCTAssertTrue(NSApp.windows.contains { MenuBarOnlyMode.isPlaceholder($0) && $0.isVisible && $0.styleMask.contains(.titled) },
                      "The placeholder window is what made the old check fail: \(NSApp.windows.map { $0.identifier?.rawValue ?? "-" })")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        TRAppActivation.returnToMenuBarWhenClosed(window)
        defer { NSApp.setActivationPolicy(.accessory) }
        NSApp.setActivationPolicy(.regular)

        window.close()
        let deadline = Date().addingTimeInterval(2)
        while NSApp.activationPolicy() != .accessory, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
    }

    func testPlaceholderIsRecognisedByItsSceneID() {
        let placeholder = NSWindow()
        placeholder.identifier = NSUserInterfaceItemIdentifier(TextWardenApp.placeholderWindowID + "-AppWindow-1")
        let other = NSWindow()
        other.identifier = NSUserInterfaceItemIdentifier("TypeRightMain")
        XCTAssertTrue(MenuBarOnlyMode.isPlaceholder(placeholder))
        XCTAssertFalse(MenuBarOnlyMode.isPlaceholder(other))
    }

    // MARK: Menu bar while a TypeRight window is in front

    func testMainMenuHasNoSketchPadOrTutorialAndHelpOpensTheGuide() throws {
        let main = try XCTUnwrap(NSApp.mainMenu, "SwiftUI builds the main menu at launch")
        let menus = main.items.compactMap(\.submenu)
        let titles = menus.flatMap { $0.items.map(\.title) }
        for gone in ["New Sketch", "Save", "Bold", "Clear Formatting", "Replay Tutorial", "TextWarden Help", "New Window"] {
            XCTAssertFalse(titles.contains(gone), "\(gone) is still in the menu bar: \(titles)")
        }
        XCTAssertFalse(main.items.map(\.title).contains("Format"), "\(main.items.map(\.title))")
        XCTAssertFalse(titles.contains { $0.contains("TextWarden") }, "\(titles)")
        XCTAssertTrue(titles.contains(TextWardenApp.guideTitle), "\(titles)")
        let close = menus.flatMap(\.items).filter { $0.title == "关闭" || $0.keyEquivalent == "w" }
        XCTAssertEqual(close.map(\.title), ["关闭"], "One close item, and ⌘W must still close a TypeRight window: \(titles)")
        XCTAssertEqual(close.first?.keyEquivalent, "w")
        XCTAssertEqual(TextWardenApp.guideURL.absoluteString, "https://typeright.us-cloud.uk/#page=guide")
    }

    func testNoHelpBookShips() {
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "CFBundleHelpBookName"))
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "CFBundleHelpBookFolder"))
        XCTAssertNil(Bundle.main.url(forResource: "TextWarden", withExtension: "help"))
    }

    // MARK: Status menu

    func testMenuSaysWhenTheProviderTurnedTheKeyDown() throws {
        let line = TRMenuAILine.keyRejected(.deepseek)
        XCTAssertEqual(line.title, "AI：DeepSeek 的 Key 失效了")
        XCTAssertTrue(line.opensSettings)
        XCTAssertEqual(line.dotColor, TR.dangerNS)
        XCTAssertEqual(TRMenuAILine.ready(.deepseek).title, "AI：DeepSeek")
        XCTAssertFalse(TRMenuAILine.ready(.deepseek).opensSettings)
        XCTAssertEqual(TRMenuAILine.notSet.title, "AI：还没选，只查拼写")

        let notebook = CoachNotebook(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("tr-menu-\(UUID().uuidString).json"))
        let menu = TypeRightMenu.shared.build(state: TRMenuState(app: nil, allPaused: false, ai: line, needsAccess: false), notebook: notebook)
        let item = try XCTUnwrap(menu.items.first { $0.title == line.title })
        XCTAssertNotNil(item.action, "Clicking the line opens 设置 › AI 服务商")
    }

    /// The line follows the key store: a 401 / 403 marks the key, saving a new one clears it.
    func testAILineReadsTheRejectedKey() throws {
        let suite = "TypeRightTests.menu.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let savedDefaults = CoachSettings.defaults
        let savedKeys = CoachKeyStore.shared
        defer {
            CoachSettings.defaults = savedDefaults
            CoachKeyStore.shared = savedKeys
            defaults.removePersistentDomain(forName: suite)
        }
        CoachSettings.defaults = defaults
        CoachKeyStore.shared = CoachKeyStore(read: { _ in .found("sk-test-0000") }, write: { _, _ in true })
        CoachSettings.provider = .deepseek

        XCTAssertEqual(TRMenuAILine.current(), .ready(.deepseek))
        CoachKeyStore.shared.markRejected(.deepseek)
        XCTAssertEqual(TRMenuAILine.current(), .keyRejected(.deepseek))
        CoachKeyStore.shared.save("sk-test-1111", for: .deepseek)
        XCTAssertEqual(TRMenuAILine.current(), .ready(.deepseek))
    }

    // MARK: Words the user reads

    /// The privacy row names every field UsagePing sends, and still says why.
    func testPrivacyNoteMatchesThePingBody() throws {
        let body = UsagePing.Body(id: "x", version: "1", platform: "darwin", arch: "arm64", plan: "own", lang: "zh", product: "typeright")
        XCTAssertEqual(Mirror(reflecting: body).children.count, 7, "A new field in the ping needs a word in the privacy note")
        let note = TRPrivacySettings.pingNote
        for word in ["前 100 位用户", "随机", "版本号", "darwin", "arm64", "x64", "会员", "自带 Key", "只用本机", "系统语言", "产品名"] {
            XCTAssertTrue(note.contains(word), "missing \(word): \(note)")
        }
        XCTAssertFalse(note.contains("界面语言"))
    }

    func testDiagnosticsExportIsNamedTypeRight() throws {
        let name = DiagnosticsView.exportFileName(at: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(name.hasPrefix("TypeRight-Diagnostics-"), name)
        XCTAssertTrue(name.hasSuffix(".zip"), name)
    }
}
