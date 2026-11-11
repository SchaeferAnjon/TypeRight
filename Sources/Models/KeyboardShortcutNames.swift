//
//  KeyboardShortcutNames.swift
//  TextWarden
//
//  Defines global keyboard shortcuts for the application
//

import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // MARK: - Global Controls

    // TypeRight: global shortcuts start unset; the user picks keys in settings (DESIGN.md).

    /// Pause or resume checking everywhere (TypeRight's 快捷键 › 暂停 / 继续)
    static let toggleTextWarden = Self("toggleTextWarden")

    /// Fix all grammar errors that have exactly one suggestion (obvious fixes)
    static let fixAllObvious = Self("fixAllObvious")

    // MARK: - Popover Shortcuts

    /// Show grammar suggestions popover
    static let showGrammarSuggestions = Self("showGrammarSuggestions")

    /// Show style suggestions popover
    static let showStyleSuggestions = Self("showStyleSuggestions")

    /// Show AI Compose popover
    static let showAICompose = Self("showAICompose")

    /// Show Readability popover
    static let showReadability = Self("showReadability")

    /// Toggle Sketch Pad window
    static let toggleSketchPad = Self("toggleSketchPad")

    /// Trigger style check on current text
    static let runStyleCheck = Self("runStyleCheck")

    /// Rewrite the current selection in place using the configured writing style.
    static let quickRewrite = Self("quickRewrite")

    // MARK: - Legacy Alias (for backwards compatibility with saved shortcuts)

    /// @available(*, deprecated, renamed: "showGrammarSuggestions")
    static let showSuggestionPopover = showGrammarSuggestions

    /// Accept the currently selected suggestion
    static let acceptSuggestion = Self("acceptSuggestion", default: .init(.tab))

    /// Dismiss/close the suggestion popover (Option+Escape to avoid conflicts with other apps)
    static let dismissSuggestion = Self("dismissSuggestion", default: .init(.escape, modifiers: .option))

    /// Navigate to previous error/suggestion (Option + Left Arrow)
    static let previousSuggestion = Self("previousSuggestion", default: .init(.leftArrow, modifiers: .option))

    /// Navigate to next error/suggestion (Option + Right Arrow)
    static let nextSuggestion = Self("nextSuggestion", default: .init(.rightArrow, modifiers: .option))

    // MARK: - Quick Actions

    /// Apply first suggestion (⌥1)
    static let applySuggestion1 = Self("applySuggestion1", default: .init(.one, modifiers: .option))

    /// Apply second suggestion (⌥2)
    static let applySuggestion2 = Self("applySuggestion2", default: .init(.two, modifiers: .option))

    /// Apply third suggestion (⌥3)
    static let applySuggestion3 = Self("applySuggestion3", default: .init(.three, modifiers: .option))

    static let quickApplyShortcuts: [KeyboardShortcuts.Name] = [
        .applySuggestion1,
        .applySuggestion2,
        .applySuggestion3,
    ]

    // MARK: - Popover Shortcuts Management

    /// All shortcuts that should only be active when the popover is visible
    /// These are disabled at startup and enabled/disabled dynamically
    static let popoverShortcuts: [KeyboardShortcuts.Name] = [
        .acceptSuggestion,
        .dismissSuggestion,
        .previousSuggestion,
        .nextSuggestion,
    ] + quickApplyShortcuts

    /// Enable all popover-specific shortcuts
    static func enablePopoverShortcuts() {
        for shortcut in popoverShortcuts {
            KeyboardShortcuts.enable(shortcut)
        }
    }

    /// Disable all popover-specific shortcuts
    static func disablePopoverShortcuts() {
        for shortcut in popoverShortcuts {
            KeyboardShortcuts.disable(shortcut)
        }
    }
}
