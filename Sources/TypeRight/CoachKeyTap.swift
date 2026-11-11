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

enum CoachKey: Equatable, Sendable {
    case tab
    case escape
    case other(printable: Bool)
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
        case let .other(printable):
            if printable { typedSinceShown += 1 }
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
        let key = Self.key(of: event)
        let swallowed = lock.withLock { gate.policy == nil ? nil : gate.swallows(key, at: ProcessInfo.processInfo.systemUptime) }
        guard let swallowed else { return Unmanaged.passUnretained(event) }
        DispatchQueue.main.async { [weak owner = self.owner] in
            MainActor.assumeIsolated { owner?.deliver(key, swallowed: swallowed) }
        }
        return swallowed ? nil : Unmanaged.passUnretained(event)
    }

    private static func key(of event: CGEvent) -> CoachKey {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        if keyCode == 48, flags.isEmpty { return .tab }
        if keyCode == 53, flags.isEmpty { return .escape }
        return .other(printable: flags.subtracting(.maskShift).isEmpty && !nonPrintable.contains(keyCode))
    }

    /// Arrows, return, delete, function keys and the like.
    private static let nonPrintable: Set<Int64> = [36, 48, 51, 53, 117, 76, 123, 124, 125, 126, 115, 119, 116, 121, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
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
