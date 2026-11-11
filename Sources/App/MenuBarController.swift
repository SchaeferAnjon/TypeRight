//
//  MenuBarController.swift
//  TextWarden
//
//  Manages the NSStatusItem and menu bar icon for TextWarden
//

import Cocoa
import SwiftUI

@MainActor
class MenuBarController: NSObject, NSMenuDelegate {
    static var shared: MenuBarController?

    private var statusItem: NSStatusItem?
    private(set) var menu: NSMenu?
    private var previousIconState: IconState = .active

    /// The app to show in the menu - captured when button is clicked (BEFORE menu opens)
    private var menuTargetApp: NSRunningApplication?

    override init() {
        super.init()
        MenuBarController.shared = self

        // Initialize ApplicationTracker early to start tracking active app
        _ = ApplicationTracker.shared

        setupMenuBar()

        // NOTE: onApplicationChange callback is set by AnalysisCoordinator, which calls updateMenu()
        // This prevents the callback from being overwritten and ensures both monitoring and menu updates happen
    }

    deinit {
        // Intentionally empty - reserved for future cleanup if needed
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.isVisible = CoachSettings.menuBarIconShown

        guard let button = statusItem?.button else {
            Logger.error("Failed to create status item button", category: Logger.ui)
            return
        }

        // Set initial icon state based on whether grammar checking is enabled
        setIconState(UserPreferences.shared.isEnabled ? .active : .inactive)

        // IMPORTANT: Do NOT set statusItem.menu here, as it prevents button.action from firing
        // Instead, we handle the click manually and show the menu programmatically

        button.action = #selector(statusBarButtonClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp])

        createMenu()
    }

    /// Called when the status bar button is clicked
    /// Captures the frontmost app BEFORE the menu opens
    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        if SafeTrialPromptController.shared.handleStatusItemClick(sender) {
            return
        }
        SafeTrialPromptController.shared.dismiss()

        // Performance profiling for menu bar display
        let (profilingState, profilingStartTime) = PerformanceProfiler.shared.beginInterval(.menuBarDisplay, context: "click")

        let totalStart = CFAbsoluteTimeGetCurrent()
        var stepStart = totalStart

        // Capture the frontmost app before our app potentially becomes active
        menuTargetApp = NSWorkspace.shared.frontmostApplication
        let frontmostAppTime = (CFAbsoluteTimeGetCurrent() - stepStart) * 1000
        stepStart = CFAbsoluteTimeGetCurrent()

        // Rebuild menu with the captured app
        createMenu()
        let createMenuTime = (CFAbsoluteTimeGetCurrent() - stepStart) * 1000
        stepStart = CFAbsoluteTimeGetCurrent()

        guard let menu else { return }
        let buttonBounds = sender.bounds

        // Log timing BEFORE popUp (which blocks until menu dismissed)
        let prepTime = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000
        Logger.info("MenuBar timing: frontmostApp=\(String(format: "%.1f", frontmostAppTime))ms, createMenu=\(String(format: "%.1f", createMenuTime))ms, totalPrep=\(String(format: "%.1f", prepTime))ms", category: Logger.performance)

        // End profiling BEFORE popUp - don't measure how long user has menu open
        PerformanceProfiler.shared.endInterval(.menuBarDisplay, state: profilingState, startTime: profilingStartTime)

        // This call blocks until user dismisses menu - don't include in timing
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: buttonBounds.height), in: sender)
    }

    /// Asks whether TypeRight may look at an app that is off by default (terminals and the like).
    func showSafeTrialPrompt(for context: ApplicationContext) {
        guard let button = statusItem?.button else {
            Logger.warning("Cannot show safe-trial prompt: no status item button", category: Logger.ui)
            return
        }

        setIconState(.inactive)
        button.toolTip = "TypeRight 在「\(context.applicationName)」里暂停着，点一下选择"
        SafeTrialPromptController.shared.present(for: context, relativeTo: button)
    }

    private func createMenu() {
        // TypeRight: its own menu (today's count, pause, open, settings, AI, quit).
        // Shown manually in statusBarButtonClicked, not attached to statusItem.
        menu = TypeRightMenu.shared.build(frontmost: menuTargetApp)
    }

    /// 设置 › 通用 › 在菜单栏显示图标. A hidden item keeps working (the safe-trial question then
    /// shows beside the app instead of under the icon).
    func setIconVisible(_ visible: Bool) {
        statusItem?.isVisible = visible
        Logger.info("Menu bar icon \(visible ? "shown" : "hidden")", category: Logger.ui)
    }

    /// Update menu to reflect current pause state
    func updateMenu() {
        refreshIconForActiveApplication()
        createMenu()
    }

    /// Keep the status icon tied to the current app instead of whichever app last changed it.
    private func refreshIconForActiveApplication() {
        guard let context = ApplicationTracker.shared.activeApplication else {
            setIconState(UserPreferences.shared.isEnabled ? .active : .inactive)
            return
        }

        let preferences = UserPreferences.shared
        let isAwaitingConsent = AppRegistry.shared.requiresSafeTrialConsent(for: context.bundleIdentifier)
            && !preferences.safeTrialApplications.contains(context.bundleIdentifier)
        let snapshot = RuntimeHealthStore.shared.snapshot
        let matchingInactiveReason = snapshot.bundleIdentifier == context.bundleIdentifier
            && snapshot.state == .inactive ? snapshot.reason : nil

        setIconState(Self.iconState(
            isEnabledForActiveApplication: context.shouldCheck(),
            isAwaitingConsent: isAwaitingConsent,
            matchingInactiveReason: matchingInactiveReason
        ))
    }

    static func iconState(
        isEnabledForActiveApplication: Bool,
        isAwaitingConsent: Bool,
        matchingInactiveReason: InactiveReason?
    ) -> IconState {
        guard isEnabledForActiveApplication, !isAwaitingConsent else {
            return .inactive
        }

        switch matchingInactiveReason {
        case .permission, .siteDisabled, .consentRequired:
            return .inactive
        case .globalPause, .appPause, .secureField, .unsupportedField, .unsupportedApplication,
             .noEditableField, nil:
            return .active
        }
    }

    /// Update menu bar icon state (e.g., to show error/disabled state)
    func setIconState(_ state: IconState) {
        guard let button = statusItem?.button else { return }

        previousIconState = state

        // Keep the feather recognizable and add a compact pause badge when inactive.
        let icon: NSImage = switch state {
        case .inactive:
            TextWardenIcon.createPaused()
        case .active, .error, .restarting:
            TextWardenIcon.create()
        }
        button.image = icon

        switch state {
        case .active:
            button.toolTip = "TypeRight 英文打字助手"
        case .inactive:
            button.toolTip = "TypeRight 已暂停"
        case .error:
            button.toolTip = "TypeRight 出错了"
        case .restarting:
            button.toolTip = "TypeRight 正在重启…"
        }
    }

    /// Show restart indicator briefly
    func showRestartIndicator() {
        Logger.info("Showing restart indicator", category: Logger.ui)
        setIconState(.restarting)
    }

    /// Hide restart indicator and restore previous state
    func hideRestartIndicator() {
        Logger.info("Hiding restart indicator", category: Logger.ui)
        setIconState(previousIconState)
    }

    enum IconState: String {
        case active
        case inactive
        case error
        case restarting
    }
}
