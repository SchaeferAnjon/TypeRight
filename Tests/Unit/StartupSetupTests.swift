import AppKit
import SwiftUI
@testable import TextWarden
import XCTest

final class StartupSetupTests: XCTestCase {
    func testFirstInstallAlwaysUsesFullOnboarding() {
        for hasPermission in [false, true] {
            XCTAssertEqual(StartupSetup.required(hasCompletedOnboarding: false, hasPermission: hasPermission), .onboarding)
        }
    }

    func testExistingUsersOnlyRecoverMissingAccess() {
        XCTAssertEqual(StartupSetup.required(hasCompletedOnboarding: true, hasPermission: false), .restoreAccessibility)
        XCTAssertNil(StartupSetup.required(hasCompletedOnboarding: true, hasPermission: true))
    }

    @MainActor
    func testGrantClosesRecoveryButKeepsFirstRunOpen() {
        let delegate = AppDelegate()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        delegate.onboardingWindow = window
        defer { window.close() }

        window.orderFront(nil)
        delegate.handlePermissionGranted(for: .onboarding)
        XCTAssertTrue(window.isVisible, "First-time users must still finish their setup")
        XCTAssertNotNil(delegate.analysisCoordinator)

        delegate.handlePermissionGranted(for: .restoreAccessibility)
        XCTAssertFalse(window.isVisible, "Existing users should return directly to the app")
        XCTAssertNotNil(delegate.analysisCoordinator)
    }

    @MainActor
    func testWindowCloseClearsSetupAndReturnsToMenuBar() async throws {
        let preferences = UserPreferences.shared
        let completed = preferences.hasCompletedOnboarding
        let activationPolicy = NSApp.activationPolicy()
        let delegate = AppDelegate()
        defer {
            preferences.hasCompletedOnboarding = completed
            NSApp.setActivationPolicy(activationPolicy)
            delegate.onboardingWindow?.close()
        }

        preferences.hasCompletedOnboarding = false
        delegate.openOnboardingWindow()
        let window = try XCTUnwrap(delegate.onboardingWindow)
        XCTAssertTrue(window.isVisible)
        window.close()
        try await Task.sleep(for: .seconds(TimingConstants.windowCleanupDelay + 0.1))

        XCTAssertNil(delegate.onboardingWindow)
        XCTAssertEqual(NSApp.activationPolicy(), .accessory, "open: \(openWindows())")
        XCTAssertFalse(preferences.hasCompletedOnboarding, "Dismissing setup must not mark it complete")
    }

    /// Finishing setup closes the setup window and opens the main window (TextWardenApp's
    /// onFinish). The main window must keep the Dock icon and Cmd-Tab until it closes too.
    @MainActor
    func testMainWindowKeepsDockAfterSetupUntilItCloses() async throws {
        // SwiftUI's placeholder window is visible and titled from launch on; it must not count.
        XCTAssertTrue(NSApp.windows.contains { MenuBarOnlyMode.isPlaceholder($0) && $0.isVisible }, "open: \(openWindows())")

        let preferences = UserPreferences.shared
        let completed = preferences.hasCompletedOnboarding
        let activationPolicy = NSApp.activationPolicy()
        let delegate = AppDelegate()
        var mainWindow: NSWindow?
        defer {
            preferences.hasCompletedOnboarding = completed
            delegate.onboardingWindow?.close()
            mainWindow?.close()
            NSApp.setActivationPolicy(activationPolicy)
        }

        preferences.hasCompletedOnboarding = false
        delegate.openOnboardingWindow()
        let setupWindow = try XCTUnwrap(delegate.onboardingWindow)
        delegate.closeOnboardingWindow()
        TRMainWindowController.shared.show()
        mainWindow = NSApp.windows.first { $0.isVisible && $0.contentView is NSHostingView<TRMainView> }
        let main = try XCTUnwrap(mainWindow, "Finishing setup opens the main window")
        XCTAssertFalse(setupWindow.isVisible)

        // The setup window's cleanup runs after windowCleanupDelay; it must leave the Dock alone.
        try await Task.sleep(for: .seconds(TimingConstants.windowCleanupDelay + 0.3))
        XCTAssertNil(delegate.onboardingWindow)
        XCTAssertTrue(main.isVisible)
        XCTAssertEqual(NSApp.activationPolicy(), .regular, "The main window must stay in the Dock and Cmd-Tab")

        // TRAppActivation hands back on close with its own check, which still counts the
        // placeholder; this checks the shared rule it should call.
        main.close()
        try await Task.sleep(for: .seconds(0.3))
        MenuBarOnlyMode.restoreIfNoWindowOpen()
        XCTAssertEqual(NSApp.activationPolicy(), .accessory, "Back to menu-bar only once no window is left; open: \(openWindows())")
    }

    @MainActor
    private func openWindows() -> [String] {
        NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }
            .map { "\(type(of: $0)) '\($0.title)' id \($0.identifier?.rawValue ?? "-") \($0.frame)" }
    }
}
