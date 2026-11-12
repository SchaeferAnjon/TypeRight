//
//  CoachKeyTap.swift
//  TypeRight
//
//  While a card is on screen, Tab and Esc can belong to the card: they are taken out of the key
//  stream so the app being typed in never sees them. Every other key passes through and is
//  reported, so the card can step aside once the user keeps typing.
//
//  The tap runs on its own thread and decides from a small policy the coach hands it, so no key
//  anywhere on the Mac waits for TypeRight's main thread. What to do with a key happens afterwards
//  on the main thread.
//

import AppKit
import Carbon
import CoreGraphics

/// What a key means for the card on screen.
enum CoachKey: Equatable, Sendable {
    case tab
    case escape
    /// A character typed on: a letter, digit, punctuation or space, with or without Shift.
    case typed
    /// Return, the arrows, the page keys, Home, End and the delete keys (with any modifier), and
    /// Shift-Tab: the caret went elsewhere or the text next to it changed.
    case moves
    /// Types nothing: function keys, modifier and input mode keys on their own, and shortcuts with
    /// ⌘, ⌃ or ⌥ (a screenshot, copy, switching the input source).
    case typesNothing

    static func of(keyCode: Int64, flags: CGEventFlags) -> CoachKey {
        if movingKeys.contains(keyCode) { return .moves }
        // Every key that types a character has a code below 128; the codes above are the system
        // keys of Apple keyboards (Mission Control, Spotlight, dictation, Globe and the like).
        if !flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate]) || silentKeys.contains(keyCode) || keyCode > 127 {
            return .typesNothing
        }
        switch keyCode {
        case 48: return flags.contains(.maskShift) ? .moves : .tab
        case 53: return flags.contains(.maskShift) ? .typesNothing : .escape
        default: return .typed
        }
    }

    /// Return, keypad Enter, ← → ↓ ↑, Page Up, Page Down, Home, End, Delete, Forward Delete.
    private static let movingKeys: Set<Int64> = [36, 76, 123, 124, 125, 126, 116, 121, 115, 119, 51, 117]
    /// F1 to F20; Command, Shift, Caps Lock, Option, Control and fn (left and right); volume up,
    /// volume down, mute; Help; the JIS 英数 and かな keys.
    private static let silentKeys: Set<Int64> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
        54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
        72, 73, 74, 114, 102, 104,
    ]
}

/// Which keys the card on screen takes. `tabFrom` is an uptime: a Tab before it passes through.
struct CoachKeyPolicy: Equatable, Sendable {
    var tab: Bool
    var tabFrom: TimeInterval
    var esc: Bool
}

/// The decision itself, kept on the tap thread.
struct CoachKeyGate: Equatable, Sendable {
    private(set) var policy: CoachKeyPolicy?
    /// An input method (Pinyin and the like) is the current input source.
    private(set) var inputMethod = false
    private(set) var typedSinceShown = 0

    mutating func reset(_ policy: CoachKeyPolicy?, inputMethod: Bool) {
        self.policy = policy
        self.inputMethod = inputMethod
        typedSinceShown = 0
    }

    /// True to swallow `key`. Once something was typed with an input method after the card came up,
    /// Tab and Esc may be the input method's (picking or cancelling a candidate), so they pass.
    mutating func swallows(_ key: CoachKey, at now: TimeInterval) -> Bool {
        guard let policy else { return false }
        let composing = inputMethod && typedSinceShown > 0
        switch key {
        case .tab: return policy.tab && now >= policy.tabFrom && !composing
        case .escape: return policy.esc && !composing
        case .typed:
            typedSinceShown += 1
            return false
        case .moves, .typesNothing:
            return false
        }
    }
}

/// Where the coach gets keys from (a fake in unit tests).
@MainActor
protocol CoachKeyInput: AnyObject {
    /// Each key while a policy is set, after the tap decided; `swallowed` says what it decided.
    var onKey: ((CoachKey, _ swallowed: Bool) -> Void)? { get set }
    /// Keys can be taken now: the tap exists and no password field holds Secure Event Input.
    var canIntercept: Bool { get }
    /// nil turns the tap off.
    func set(_ policy: CoachKeyPolicy?)
}

@MainActor
final class CoachKeyTap: CoachKeyInput {
    var onKey: ((CoachKey, Bool) -> Void)?

    private let box = CoachKeyTapBox()
    private var installed = false

    var canIntercept: Bool {
        install()
        return box.port != nil && !IsSecureEventInputEnabled()
    }

    func set(_ policy: CoachKeyPolicy?) {
        install()
        let inputMethod = policy != nil && Self.inputMethodIsCurrent()
        box.update { $0.reset(policy, inputMethod: inputMethod) }
        if let port = box.port { CGEvent.tapEnable(tap: port, enable: policy != nil) }
    }

    fileprivate func deliver(_ key: CoachKey, swallowed: Bool) {
        onKey?(key, swallowed)
    }

    /// Creates the tap on its own thread once; the thread then runs its run loop for good.
    private func install() {
        guard !installed else { return }
        installed = true
        box.owner = self
        let box = box
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                callback: coachKeyTapCallback,
                userInfo: Unmanaged.passUnretained(box).toOpaque()
            )
            box.port = port
            if let port {
                CGEvent.tapEnable(tap: port, enable: false)
                let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            ready.signal()
            if port != nil { CFRunLoopRun() }
        }
        thread.name = "TypeRight key tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        if ready.wait(timeout: .now() + 1) == .timedOut || box.port == nil {
            Logger.warning("TypeRight: could not create key tap (Accessibility permission?)", category: Logger.ui)
        }
    }

    private static func inputMethodIsCurrent() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return false }
        let type = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        return type == (kTISTypeKeyboardInputMode as String) || type == (kTISTypeKeyboardInputMethodWithoutModes as String)
    }
}

/// What the tap thread touches: the port and the gate behind a lock.
private final class CoachKeyTapBox: @unchecked Sendable {
    private let lock = NSLock()
    private var gate = CoachKeyGate()
    /// Written once on the tap thread before the main thread reads it (after the semaphore).
    var port: CFMachPort?
    weak var owner: CoachKeyTap?

    func update(_ change: (inout CoachKeyGate) -> Void) {
        lock.withLock { change(&gate) }
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port, lock.withLock({ gate.policy != nil }) { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let key = CoachKey.of(keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags)
        let swallowed = lock.withLock { gate.policy == nil ? nil : gate.swallows(key, at: ProcessInfo.processInfo.systemUptime) }
        guard let swallowed else { return Unmanaged.passUnretained(event) }
        DispatchQueue.main.async { [weak owner = self.owner] in
            MainActor.assumeIsolated { owner?.deliver(key, swallowed: swallowed) }
        }
        return swallowed ? nil : Unmanaged.passUnretained(event)
    }
}

private func coachKeyTapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<CoachKeyTapBox>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
}
