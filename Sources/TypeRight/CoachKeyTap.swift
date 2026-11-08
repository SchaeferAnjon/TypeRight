//
//  CoachKeyTap.swift
//  TypeRight
//
//  While a card is on screen, Tab and Esc belong to the card: they are taken out of the key
//  stream so the app being typed in never sees them. Every other key passes through and is
//  reported, so the card can step aside once the user keeps typing.
//

import AppKit
import CoreGraphics

@MainActor
final class CoachKeyTap {
    enum Key {
        case tab
        case escape
        case other(printable: Bool)
    }

    /// Called on the main actor for each key while the tap is on. Return true to swallow the key.
    var onKey: ((Key) -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isOn: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func turnOn() {
        if tap == nil { install() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func turnOff() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    private func install() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: coachKeyTapCallback,
            userInfo: me
        ) else {
            Logger.warning("TypeRight: could not create key tap (Accessibility permission?)", category: Logger.ui)
            return
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    /// Runs on the main run loop (the source is added there).
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        let key: Key
        if keyCode == 48, flags.isEmpty {
            key = .tab
        } else if keyCode == 53, flags.isEmpty {
            key = .escape
        } else {
            let printable = flags.subtracting(.maskShift).isEmpty && !Self.nonPrintable.contains(keyCode)
            key = .other(printable: printable)
        }
        let swallow = onKey?(key) ?? false
        return swallow ? nil : Unmanaged.passUnretained(event)
    }

    /// Arrows, return, delete, function keys and the like.
    private static let nonPrintable: Set<Int64> = [36, 51, 117, 76, 123, 124, 125, 126, 115, 119, 116, 121, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
}

private func coachKeyTapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<CoachKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated { tap.handle(type: type, event: event) }
}
