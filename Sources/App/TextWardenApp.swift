//
//  TextWardenApp.swift
//  TextWarden
//
//  Created by phisch on 09.11.2025.
//
//  Main entry point for TextWarden menu bar application.
//

import KeyboardShortcuts
import os.log
import SwiftUI

enum StartupSetup: Equatable {
    case onboarding
    case restoreAccessibility

    static func required(hasCompletedOnboarding: Bool, hasPermission: Bool) -> StartupSetup? {
        if !hasCompletedOnboarding {
            return .onboarding
        }
        return hasPermission ? nil : .restoreAccessibility
    }
}

/// TypeRight lives in the menu bar and shows in the Dock and Cmd-Tab only while one of its
/// windows is open. Windows that switch the app to .regular hand back through here after they
/// close, so it returns to menu-bar only once no titled window is left on screen.
@MainActor
enum MenuBarOnlyMode {
    static func restoreIfNoWindowOpen() {
        if !hasOpenWindow { NSApp.setActivationPolicy(.accessory) }
    }

    /// A TypeRight window the user can see (main window, settings, setup), the placeholder not counted.
    static var hasOpenWindow: Bool {
        NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && !isPlaceholder($0) }
    }

    /// The placeholder scene's window is zero-sized but visible and titled from launch on, so
    /// it would otherwise always count as open. SwiftUI names it "<scene id>-AppWindow-<n>".
    static func isPlaceholder(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(TextWardenApp.placeholderWindowID + "-") == true
    }
}

@main
struct TextWardenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var permissionManager = PermissionManager.shared

    /// SwiftUI needs one window scene to carry the menu commands; its window stays empty.
    static let placeholderWindowID = "hidden-placeholder"

    var body: some Scene {
        // Menu bar app - hidden placeholder scene (no visible window)
        WindowGroup(id: Self.placeholderWindowID) {
            EmptyView()
                .frame(width: 0, height: 0)
                .hidden()
        }
        .defaultSize(width: 0, height: 0)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 TypeRight") {
                    PreferencesWindowController.shared.selectTab(.about)
                    TRSettingsWindowController.shared.show(.advanced)
                }
            }

            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    UpdaterViewModel.shared.checkForUpdates()
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    TRSettingsWindowController.shared.show()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // The placeholder scene must not offer "New Window" (its window is empty). File keeps
            // one item: ⌘W closes the main window or settings, as in any Mac app.
            CommandGroup(replacing: .newItem) {
                Button("关闭") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {}

            // Standard Edit menu commands (Undo, Redo, Cut, Copy, Paste, Select All)
            TextEditingCommands()

            // The first release ships without a help book: Help opens the guide on the website.
            CommandGroup(replacing: .help) {
                Button(Self.guideTitle) {
                    NSWorkspace.shared.open(Self.guideURL)
                }
            }
        }
    }

    static let guideTitle = "TypeRight 上手指南"
    static let guideURL = URL(string: "https://typeright.us-cloud.uk/#page=guide")!
}

/// AppDelegate handles menu bar controller initialization
class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarController: MenuBarController?
    var analysisCoordinator: AnalysisCoordinator?
    var onboardingWindow: NSWindow? // Keep strong reference to onboarding window

    /// Shared updater view model for Sparkle auto-updates
    /// Uses singleton to ensure only ONE SPUStandardUpdaterController exists
    @MainActor var updaterViewModel: UpdaterViewModel {
        UpdaterViewModel.shared
    }

    func applicationDidFinishLaunching(_: Notification) {
        Logger.info("Application launched", category: Logger.lifecycle)

        // Initialize crash tracking at launch so the previous session can be assessed before
        // TextWarden starts Accessibility work. The manager stores only heartbeat metadata.
        _ = CrashRecoveryManager.shared

        // Enable key repeat instead of showing accent picker when holding keys
        // This is the expected behavior for text editors - users can still access
        // accents via Option+key combinations
        UserDefaults.standard.set(false, forKey: "ApplePressAndHoldEnabled")

        // Log build information for debugging
        Logger.info("Build Info - Version: \(BuildInfo.fullVersion), Built: \(BuildInfo.buildTimestamp) (\(BuildInfo.buildAge))", category: Logger.lifecycle)

        // CRITICAL: Set global timeout for Accessibility API calls
        // The default is 6 seconds which causes severe freezing with apps that have slow AX implementations
        // (e.g., Microsoft Office overlays). Setting to 1.0s is the industry standard and
        // provides a reasonable upper bound while preventing severe freezes.
        // When timeout expires, AX calls return kAXErrorCannotComplete instead of blocking indefinitely.
        // Reference: https://github.com/lwouis/alt-tab-macos uses this same approach.
        // NOTE: For apps with slow AX (Outlook), we also use deferred text extraction
        // to reduce the frequency of AX calls during typing - see defersTextExtraction flag.
        let axTimeout: Float = 1.0
        let timeoutResult = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), axTimeout)
        if timeoutResult == .success {
            Logger.info("Set global AX messaging timeout to \(axTimeout)s", category: Logger.accessibility)
        } else {
            Logger.warning("Failed to set AX messaging timeout: \(timeoutResult.rawValue)", category: Logger.accessibility)
        }

        // Initialize unified logging (Rust → Swift bridge)
        Logger.registerRustLogCallback()

        // TypeRight ships without TextWarden's browser extension: browsers are read through
        // Accessibility like every other app, so the extension bridge is never started.

        // Initialize Rust logging (with Swift callback now registered)
        let logLevel = Logger.minimumLogLevel
        initialize_logging(logLevel.rawValue)
        Logger.info("Rust logging initialized with level: \(logLevel.rawValue) (unified)", category: Logger.ffi)

        // Record app session for statistics
        UserStatistics.shared.recordSession()

        // Set app launch timestamp for "This Session" filtering
        UserStatistics.shared.appLaunchTimestamp = Date()

        // Perform periodic cleanup of old statistics data
        UserStatistics.shared.performPeriodicCleanup()

        // Start resource monitoring
        ResourceMonitor.shared.startMonitoring()
        Logger.info("Resource monitoring started", category: Logger.lifecycle)

        NSApp.setActivationPolicy(.accessory)

        Logger.info("Set as menu bar app (no dock icon)", category: Logger.lifecycle)

        // Applies the 外观 setting (设置 › 高级 › 通用) from launch on, not only once settings open.
        _ = PreferencesWindowController.shared

        // CRITICAL: LSUIElement apps don't receive activation events, so the main run loop
        // doesn't fully "spin" until something creates a Cocoa event. This causes timers,
        // GCD on main queue, and NSWorkspace notifications to be delayed by 30+ seconds.
        // Calling activate() manually kick-starts the event loop, but it must be delayed
        // until after the app infrastructure is fully initialized (research shows calling it
        // too early can cause it to fail silently).
        DispatchQueue.main.asyncAfter(deadline: .now() + TimingConstants.shortDelay) {
            Logger.debug("Calling NSApp.activate() to kick-start event loop", category: Logger.lifecycle)
            NSApp.activate(ignoringOtherApps: false)
            Logger.debug("NSApp.activate() completed", category: Logger.lifecycle)
        }

        // Initialize menu bar controller
        menuBarController = MenuBarController()
        Logger.info("Menu bar controller initialized", category: Logger.lifecycle)

        // Note: Menus are configured via SwiftUI Commands in TextWardenApp.body.commands
        Logger.info("SwiftUI Commands will handle menu setup", category: Logger.lifecycle)

        // Setup keyboard shortcuts
        setupKeyboardShortcuts()

        // CRITICAL: Disable popover-specific shortcuts at startup
        // These shortcuts (Tab, Option+Escape, etc.) must only be active when the popover is visible
        // Otherwise they intercept keypresses globally and break normal app behavior
        KeyboardShortcuts.Name.disablePopoverShortcuts()
        Logger.info("Keyboard shortcuts initialized (popover shortcuts disabled until needed)", category: Logger.lifecycle)

        // Sparkle handles automatic update checks based on user preference (automaticallyChecksForUpdates)
        // Do NOT manually call checkForUpdatesInBackground() - this interferes with Sparkle's scheduler
        // See: https://sparkle-project.org/documentation/programmatic-setup/
        Logger.info("Sparkle auto-update: \(updaterViewModel.automaticallyChecksForUpdates ? "enabled" : "disabled")", category: Logger.lifecycle)

        // Check permissions and onboarding status
        let permissionManager = PermissionManager.shared
        let hasPermission = permissionManager.isPermissionGranted
        let hasCompletedOnboarding = UserPreferences.shared.hasCompletedOnboarding
        Logger.info("Accessibility permission check: \(hasPermission ? "Granted" : "Not granted")", category: Logger.permissions)
        Logger.info("Onboarding completed: \(hasCompletedOnboarding)", category: Logger.lifecycle)

        let setup = StartupSetup.required(hasCompletedOnboarding: hasCompletedOnboarding, hasPermission: hasPermission)

        if let setup {
            // Show onboarding (either first launch or permission not granted)
            if !hasCompletedOnboarding {
                Logger.info("First launch or reset - showing onboarding", category: Logger.lifecycle)
            } else {
                Logger.warning("Accessibility permission not granted - showing access recovery", category: Logger.permissions)
            }

            // If permission already granted, start analysis coordinator immediately
            if hasPermission {
                analysisCoordinator = AnalysisCoordinator.shared
                Logger.info("Analysis coordinator initialized (permission already granted)", category: Logger.lifecycle)
            } else {
                Logger.debug("Setting up onPermissionGranted callback on PermissionManager.shared", category: Logger.permissions)
                permissionManager.onPermissionGranted = { [weak self] in
                    guard let self else {
                        Logger.error("onPermissionGranted callback: self (AppDelegate) is nil! Cannot initialize AnalysisCoordinator.", category: Logger.permissions)
                        return
                    }
                    handlePermissionGranted(for: setup)
                }
                if setup == .restoreAccessibility {
                    // Keep watching even if the user dismisses recovery and grants access later.
                    permissionManager.startPolling()
                }
                Logger.debug("onPermissionGranted callback is now set (callback != nil: \(permissionManager.onPermissionGranted != nil))", category: Logger.permissions)
            }

            // Open onboarding window. Unit tests run inside the app; never put a setup window
            // on the user's screen then.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + TimingConstants.longDelay) { [weak self] in
                    self?.openOnboardingWindow()
                }
            }
        } else {
            // Permission granted and onboarding completed - start grammar checking immediately
            Logger.info("Starting grammar checking - enabled: \(UserPreferences.shared.isEnabled)", category: Logger.lifecycle)

            // Log paused applications (excluding .active state)
            let pausedApps = UserPreferences.shared.appPauseDurations.filter { $0.value != .active }
            let pausedAppBundleIDs = pausedApps.keys.sorted()
            Logger.info("Paused applications (\(pausedApps.count)): \(pausedAppBundleIDs)", category: Logger.lifecycle)

            analysisCoordinator = AnalysisCoordinator.shared
            Logger.info("Analysis coordinator initialized", category: Logger.lifecycle)

            // Without the menu bar icon nothing on screen says TypeRight is running: open the main window.
            if TRMenuBarIcon.atLaunch(iconShown: CoachSettings.menuBarIconShown) == .mainWindow,
               ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            {
                DispatchQueue.main.asyncAfter(deadline: .now() + TimingConstants.longDelay) {
                    MainActor.assumeIsolated { TRMainWindowController.shared.show() }
                }
            }

            // Check if user wants to open settings window in foreground
            if UserPreferences.shared.openInForeground {
                Logger.info("Opening settings window in foreground (user preference)", category: Logger.ui)
                DispatchQueue.main.asyncAfter(deadline: .now() + TimingConstants.hoverDelay) { [weak self] in
                    self?.openSettingsWindow()
                }
            }
        }
    }

    @MainActor
    func handlePermissionGranted(for setup: StartupSetup) {
        analysisCoordinator = AnalysisCoordinator.shared
        if setup == .restoreAccessibility {
            closeOnboardingWindow()
        }
        Logger.info("Analysis coordinator initialized after Accessibility access was granted", category: Logger.lifecycle)
    }

    @MainActor
    @objc func openOnboardingWindow() {
        guard let setup = StartupSetup.required(
            hasCompletedOnboarding: UserPreferences.shared.hasCompletedOnboarding,
            hasPermission: PermissionManager.shared.isPermissionGranted
        ) else { return }

        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        Logger.info("Creating setup window: \(setup)", category: Logger.ui)
        let content = Group {
            switch setup {
            // TypeRight: its own five-step setup replaces TextWarden's onboarding and recovery views.
            case .onboarding:
                TROnboardingView(onFinish: { [weak self] in
                    self?.closeOnboardingWindow()
                    TRMainWindowController.shared.show()
                })
            case .restoreAccessibility:
                TROnboardingView(start: .access, onFinish: { [weak self] in self?.closeOnboardingWindow() })
            }
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = "TypeRight"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false // We manage the lifecycle manually
        window.setContentSize(NSSize(width: 980, height: 680))
        window.center()

        // Store strong reference to prevent premature deallocation
        onboardingWindow = window

        // Clean up reference after window closes (with delay for animations)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            // Delay cleanup to let window animations complete (macOS 26 fix)
            DispatchQueue.main.asyncAfter(deadline: .now() + TimingConstants.windowCleanupDelay) {
                MainActor.assumeIsolated {
                    self?.onboardingWindow = nil
                    // Finishing setup opens the main window, which must keep the Dock icon.
                    MenuBarOnlyMode.restoreIfNoWindowOpen()
                    Logger.debug("Setup window closed", category: Logger.ui)
                }
            }
        }

        // Temporarily switch to regular mode to show window
        NSApp.setActivationPolicy(.regular)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Logger.info("Onboarding window displayed", category: Logger.ui)
    }

    /// Close the onboarding window and return to menu bar mode
    @objc func closeOnboardingWindow() {
        Logger.info("Closing onboarding window", category: Logger.ui)

        // Close the window (triggers willCloseNotification which cleans up the reference)
        onboardingWindow?.close()
    }

    /// Prevent app from quitting when all windows close (menu bar app)
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    /// Tests swap these, so nothing opens on the user's screen and nothing reads this Mac's state.
    var needsSetup: @MainActor () -> Bool = {
        StartupSetup.required(hasCompletedOnboarding: UserPreferences.shared.hasCompletedOnboarding,
                              hasPermission: PermissionManager.shared.isPermissionGranted) != nil
    }

    lazy var open: @MainActor (TRMenuBarIcon.Opens) -> Void = { [weak self] opens in
        switch opens {
        case .mainWindow: TRMainWindowController.shared.show()
        case .setup: self?.openOnboardingWindow()
        case .nothing: break
        }
    }

    /// Opening TypeRight again (Finder, Spotlight, Launchpad) while it runs. With the menu bar icon
    /// switched off this is the only way back in, so it always shows a window.
    ///
    /// AppKit's `hasVisibleWindows` counts SwiftUI's empty placeholder window, so TypeRight looks for
    /// a real window itself. It answers false: on true SwiftUI goes on to open another empty
    /// placeholder window, and from then on every reopen looked like one with a window open.
    @MainActor
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        let opens = TRMenuBarIcon.onReopen(hasVisibleWindows: MenuBarOnlyMode.hasOpenWindow, needsSetup: needsSetup())
        Logger.info("Reopened while running: \(opens)", category: Logger.lifecycle)
        open(opens)
        return false
    }

    func applicationWillTerminate(_: Notification) {
        Logger.info("Application will terminate - cleaning up", category: Logger.lifecycle)

        // Stop crash recovery heartbeat for clean shutdown detection
        CrashRecoveryManager.shared.stopHeartbeat()

        // Stop resource monitoring
        ResourceMonitor.shared.stopMonitoring()

        // Flush and persist log volume statistics
        UserStatistics.shared.flushLogSample()
        UserStatistics.shared.forceLogVolumePersist()

        // Clean up AnalysisCoordinator (timers, event monitors)
        analysisCoordinator?.cleanup()

        // Clean up TypingDetector (keyboard monitor, timers)
        TypingDetector.shared.cleanup()

        Logger.info("Cleanup complete", category: Logger.lifecycle)
    }

    /// Opens TypeRight's settings window (TextWarden's settings live on under 设置 › 高级).
    @objc func openSettingsWindow(selectedTab _: Int = 0) {
        MainActor.assumeIsolated { TRSettingsWindowController.shared.show() }
    }
}

// MARK: - Keyboard Shortcuts

extension AppDelegate {
    /// Setup global keyboard shortcuts using KeyboardShortcuts package
    private func setupKeyboardShortcuts() {
        // Pause / resume everywhere (no default key; set in 设置 › 快捷键)
        KeyboardShortcuts.onKeyUp(for: .toggleTextWarden) {
            Task { @MainActor in
                let preferences = UserPreferences.shared
                guard preferences.keyboardShortcutsEnabled else { return }

                Logger.debug("Keyboard shortcut: Toggle TextWarden", category: Logger.ui)

                // Toggle pause duration between active and indefinite
                if preferences.pauseDuration == .active {
                    // Disabling - hide all overlays immediately
                    preferences.setPauseDuration(.indefinite, for: .global)

                    // Hide error underlines, indicator, and popover
                    FloatingErrorIndicator.shared.hide()
                    SuggestionPopover.shared.hide()
                    AnalysisCoordinator.shared.hideAllOverlays()

                    Logger.debug("Grammar checking disabled - hid all overlays", category: Logger.ui)
                } else {
                    // Enabling - trigger re-analysis to show errors
                    preferences.resume(.global)

                    // Trigger re-analysis of current text to show errors immediately
                    AnalysisCoordinator.shared.triggerReanalysis()

                    Logger.debug("Grammar checking enabled - triggered re-analysis", category: Logger.ui)
                }
            }
        }

        // Fix all obvious errors (no default key; set in 设置 › 高级 › 通用)
        // Applies all single-suggestion fixes at once
        KeyboardShortcuts.onKeyUp(for: .fixAllObvious) {
            Task { @MainActor in
                let preferences = UserPreferences.shared
                guard preferences.keyboardShortcutsEnabled else { return }

                Logger.debug("Keyboard shortcut: Fix all obvious errors", category: Logger.ui)

                let fixCount = await AnalysisCoordinator.shared.applyAllSingleSuggestionFixes()
                if fixCount > 0 {
                    Logger.info("Fixed \(fixCount) obvious error(s)", category: Logger.ui)
                }
            }
        }

        // Rewrite selection directly, independently of indicator visibility.
        KeyboardShortcuts.onKeyUp(for: .quickRewrite) {
            Task { @MainActor in
                guard UserPreferences.shared.keyboardShortcutsEnabled else { return }
                AnalysisCoordinator.shared.quickRewriteSelection()
            }
        }

        // Accept current suggestion (Tab by default)
        KeyboardShortcuts.onKeyUp(for: .acceptSuggestion) {
            Task { @MainActor in
                let preferences = UserPreferences.shared
                guard preferences.keyboardShortcutsEnabled else { return }
                guard SuggestionPopover.keyboardTarget.isVisible else { return }

                // Handle grammar errors
                if SuggestionPopover.keyboardTarget.currentError != nil {
                    Logger.debug("Keyboard shortcut: Accept grammar suggestion", category: Logger.ui)
                    SuggestionPopover.keyboardTarget.applySuggestion(at: 0)
                    return
                }

                // Handle style suggestions
                if SuggestionPopover.keyboardTarget.currentStyleSuggestion != nil {
                    SuggestionPopover.keyboardTarget.acceptStyleSuggestion()
                    return
                }
            }
        }

        // Dismiss suggestion popover (Escape by default)
        KeyboardShortcuts.onKeyUp(for: .dismissSuggestion) {
            Task { @MainActor in
                let preferences = UserPreferences.shared
                guard preferences.keyboardShortcutsEnabled else { return }
                guard SuggestionPopover.keyboardTarget.isVisible else { return }

                Logger.debug("Keyboard shortcut: Dismiss suggestion", category: Logger.ui)

                SuggestionPopover.keyboardTarget.hide()
            }
        }

        // Navigate to previous suggestion (Option + Left arrow by default)
        KeyboardShortcuts.onKeyUp(for: .previousSuggestion) {
            Task { @MainActor in
                let preferences = UserPreferences.shared
                guard preferences.keyboardShortcutsEnabled else { return }
                guard SuggestionPopover.keyboardTarget.isVisible else { return }

                Logger.debug("Keyboard shortcut: Previous suggestion", category: Logger.ui)

                // Use unified navigation to cycle through both grammar errors and style suggestions
                SuggestionPopover.keyboardTarget.previousUnifiedItem()
            }
        }

        // Navigate to next suggestion (Option + Right arrow by default)
        KeyboardShortcuts.onKeyUp(for: .nextSuggestion) {
            Task { @MainActor in
                let preferences = UserPreferences.shared
                guard preferences.keyboardShortcutsEnabled else { return }
                guard SuggestionPopover.keyboardTarget.isVisible else { return }

                Logger.debug("Keyboard shortcut: Next suggestion", category: Logger.ui)

                // Use unified navigation to cycle through both grammar errors and style suggestions
                SuggestionPopover.keyboardTarget.nextUnifiedItem()
            }
        }

        // Quick apply shortcuts (configurable in Settings)
        KeyboardShortcuts.onKeyUp(for: .applySuggestion1) {
            Task { @MainActor in
                let preferences = UserPreferences.shared
                guard preferences.keyboardShortcutsEnabled else { return }
                guard SuggestionPopover.keyboardTarget.isVisible else { return }
                Logger.debug("Keyboard shortcut: Apply suggestion 1", category: Logger.ui)
                SuggestionPopover.keyboardTarget.applySuggestion(at: 0)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .applySuggestion2) {
            Task { @MainActor in
                let preferences = UserPreferences.shared
                guard preferences.keyboardShortcutsEnabled else { return }
                guard SuggestionPopover.keyboardTarget.isVisible else { return }
                Logger.debug("Keyboard shortcut: Apply suggestion 2", category: Logger.ui)
                SuggestionPopover.keyboardTarget.applySuggestion(at: 1)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .applySuggestion3) {
            Task { @MainActor in
                let preferences = UserPreferences.shared
                guard preferences.keyboardShortcutsEnabled else { return }
                guard SuggestionPopover.keyboardTarget.isVisible else { return }
                Logger.debug("Keyboard shortcut: Apply suggestion 3", category: Logger.ui)
                SuggestionPopover.keyboardTarget.applySuggestion(at: 2)
            }
        }
    }
}
