//
//  AccessibilityHelpers.swift
//  TextWarden
//
//  Accessibility helpers and extensions for VoiceOver and assistive technology support
//

import SwiftUI

// MARK: - Accessibility View Modifiers

extension View {
    /// Makes a decorative element invisible to assistive technologies
    func accessibilityDecorative() -> some View {
        accessibilityHidden(true)
    }

    /// Creates an accessible button with proper label and hint
    func accessibleButton(label: String, hint: String? = nil) -> some View {
        accessibilityLabel(label)
            .accessibilityHint(hint ?? "")
            .accessibilityAddTraits(.isButton)
    }

    /// Creates an accessible header
    func accessibleHeader(_ text: String) -> some View {
        accessibilityLabel(text)
            .accessibilityAddTraits(.isHeader)
    }

    /// Creates an accessible toggle with state description
    func accessibleToggle(label: String, isOn: Bool, hint: String? = nil) -> some View {
        accessibilityLabel(label)
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityHint(hint ?? "Double tap to toggle")
    }

    /// Creates an accessible picker with current selection
    func accessiblePicker(label: String, selection: String, hint: String? = nil) -> some View {
        accessibilityLabel(label)
            .accessibilityValue(selection)
            .accessibilityHint(hint ?? "Double tap to change")
    }

    /// Creates an accessible text field
    func accessibleTextField(label: String, hint: String? = nil) -> some View {
        accessibilityLabel(label)
            .accessibilityHint(hint ?? "Double tap to edit")
            .accessibilityAddTraits(.isKeyboardKey)
    }

    /// Creates an accessible link
    func accessibleLink(label: String, hint: String? = nil) -> some View {
        accessibilityLabel(label)
            .accessibilityHint(hint ?? "Double tap to open")
            .accessibilityAddTraits(.isLink)
    }

    /// Creates an accessible image with description
    func accessibleImage(label: String) -> some View {
        accessibilityLabel(label)
            .accessibilityAddTraits(.isImage)
    }

    /// Groups child elements into a single accessible element
    func accessibleGroup(label: String, hint: String? = nil) -> some View {
        accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityHint(hint ?? "")
    }

    /// Makes a static text element accessible
    func accessibleStaticText(_ text: String) -> some View {
        accessibilityLabel(text)
            .accessibilityAddTraits(.isStaticText)
    }

    /// Creates an accessible progress indicator
    func accessibleProgress(label: String, value: Double, total: Double = 1.0) -> some View {
        accessibilityLabel(label)
            .accessibilityValue("\(Int(value / total * 100)) percent")
    }

    /// Announces a change to VoiceOver users
    func accessibilityAnnounce(_ message: String, priority _: AccessibilityAnnouncementPriority = .high) -> some View {
        onChange(of: message) { _, newValue in
            AccessibilityNotification.Announcement(newValue).post()
        }
    }
}

// MARK: - Accessibility Announcement Helper

enum AccessibilityAnnouncement {
    /// Post an accessibility announcement for screen readers
    static func post(_ message: String, priority _: AccessibilityAnnouncementPriority = .high) {
        AccessibilityNotification.Announcement(message).post()
    }

    /// Post an announcement after a delay (useful for state changes)
    static func postDelayed(_ message: String, delay: TimeInterval = TimingConstants.accessibilityAnnounce) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            AccessibilityNotification.Announcement(message).post()
        }
    }
}

// MARK: - Accessibility Priority

enum AccessibilityAnnouncementPriority {
    case low
    case medium
    case high
}
