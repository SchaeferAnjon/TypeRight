//
//  AnalysisCoordinator+TypeRight.swift
//  TypeRight
//
//  Lets TypingCoach use what TextWarden already does well: where a word is on screen, where
//  the caret is, and how to write a fix back into each kind of app. Every Accessibility call
//  here goes through AXClient, so an app that hangs is skipped (AXWatchdog) instead of
//  holding up the main thread.
//

@preconcurrency import ApplicationServices
import AppKit

extension AnalysisCoordinator: TypingCoachHost {
    func coachAnchor(for range: Range<Int>, in text: String) -> CGRect? {
        guard let element = textMonitor.monitoredElement,
              let bundleID = monitoredContext?.bundleIdentifier else { return nil }
        let parser = contentParserFactory.parser(for: bundleID)
        let result = parser.resolvePosition(
            for: NSRange(location: range.lowerBound, length: max(1, range.count)),
            in: element,
            text: text,
            actualBundleID: bundleID
        )
        guard !result.isUnavailable, result.isUsable else { return nil }
        // A range over several lines: point at the first line.
        return result.allLineBounds.first ?? result.bounds
    }

    func coachFallbackAnchor() -> CGRect? {
        guard let element = textMonitor.monitoredElement, let bundleID = monitoredContext?.bundleIdentifier else { return nil }
        let primary = NSScreen.screens.first { $0.frame.origin == .zero }
        guard let height = primary?.frame.height ?? NSScreen.main?.frame.height else { return nil }

        // First choice: the caret. Some apps report a field frame far bigger than the box the user sees.
        if let caret = Self.caretBounds(in: element, bundleID: bundleID), caret.width < 400, caret.height > 0, caret.height < 80 {
            return CGRect(x: caret.minX, y: height - caret.maxY, width: max(caret.width, 2), height: caret.height)
        }
        guard var frame = AccessibilityBridge.getElementFrame(element) else { return nil }
        frame.origin.y = height - frame.origin.y - frame.height
        return CGRect(x: frame.maxX - 40, y: frame.maxY - 30, width: 30, height: 30)
    }

    /// Bounds of the character before the caret, in AX (top-left origin) coordinates.
    private static func caretBounds(in element: AXUIElement, bundleID: String) -> CGRect? {
        let call = AXClient.perform(bundleID: bundleID, attribute: "TypeRight.caretBounds") { () -> CGRect? in
            guard let range = AccessibilityBridge.getSelectedTextRange(element) else { return nil }
            var probe = CFRange(location: max(0, range.location - 1), length: range.location > 0 ? 1 : 0)
            guard let probeValue = AXValueCreate(.cfRange, &probe) else { return nil }
            var bounds: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                             probeValue, &bounds) == .success,
                let boundsValue = bounds, let rect = safeAXValueGetRect(boundsValue), rect != .zero else { return nil }
            return rect
        }
        return call?.value
    }

    /// The caret in the analysed text. Parsers that drop leading text before the analysis (Notion's
    /// page title and icons) report how much: the caret is read in the field's own text, then moved back by that.
    func coachCaret(in text: String) -> Int? {
        guard let element = textMonitor.monitoredElement, let bundleID = monitoredContext?.bundleIdentifier else { return nil }
        let offset = contentParserFactory.parser(for: bundleID).textReplacementOffset
        guard let call = AXClient.perform(bundleID: bundleID, attribute: "TypeRight.caret", operation: { () -> (CFRange?, String?) in
            let range = AccessibilityBridge.getSelectedTextRange(element)
            guard offset > 0 else { return (range, nil) }
            var value: CFTypeRef?
            let raw = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success ? value as? String : nil
            return (range, raw)
        }), let range = call.value.0, range.location >= 0 else { return nil }
        let fieldText: String
        if offset > 0 {
            guard let raw = call.value.1 else { return nil }
            fieldText = raw
        } else {
            fieldText = text
        }
        guard let scalar = Self.scalarOffset(utf16: range.location + range.length, in: fieldText) else { return nil }
        return min(max(scalar - offset, 0), text.unicodeScalars.count)
    }

    nonisolated static func scalarOffset(utf16: Int, in text: String) -> Int? {
        let clamped = min(max(utf16, 0), text.utf16.count)
        guard let index = TextIndexConverter.stringIndex(forUTF16Offset: clamped, in: text) else { return nil }
        return TextIndexConverter.stringIndexToScalarIndex(index, in: text)
    }

    /// The field's text the way TextMonitor reads it for the analysis.
    func coachReadText() -> String? {
        guard let element = textMonitor.monitoredElement, let bundleID = monitoredContext?.bundleIdentifier else { return nil }
        let parser = contentParserFactory.parser(for: bundleID)
        let call = AXClient.perform(bundleID: bundleID, attribute: "TypeRight.readText") { () -> String? in
            if let text = parser.extractText(from: element) {
                return parser.extractTextReturnsPreprocessed ? text : parser.preprocessText(text)
            }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
                  let raw = value as? String else { return nil }
            return parser.preprocessText(raw)
        }
        return call?.value
    }

    /// Writes the fix with TextWarden's per-app methods, then reads the field until it shows the fix
    /// (keyboard and paste methods land a moment later). Typing that follows the fix is allowed.
    func coachReplace(range: Range<Int>, with replacement: String, analyzedText: String, harperError: GrammarErrorModel?) async -> CoachWriteResult {
        let probe = harperError ?? GrammarErrorModel(start: range.lowerBound, end: range.upperBound, message: "TypeRight",
                                                     severity: .error, category: "TypeRight", lintId: "TypeRight", suggestions: [replacement])
        guard let before = coachReadText(),
              case let .matched(target) = ReplacementTextMatcher.resolveRange(in: before, analyzedText: analyzedText, for: probe)
        else {
            Logger.info("TypeRight: the text to fix is no longer where it was, not writing", category: Logger.analysis)
            return .notWritten
        }
        let expected = CoachText.replacing(target, in: before, with: replacement)

        if let harperError, currentErrors.contains(where: { $0 === harperError }) {
            await applyTextReplacementAsync(for: harperError, with: replacement)
        } else {
            currentErrors.append(probe)
            currentErrorSourceStore.replace(errors: currentErrors, sourceText: analyzedText)
            await applyTextReplacementAsync(for: probe, with: replacement)
            currentErrors.removeAll { $0 === probe }
        }

        var after: String?
        for wait in [0.0, 0.15, 0.3, 0.6, 1.0] {
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            after = coachReadText()
            if let after, Self.writeCheck(before: before, expected: expected, after: after) == .done {
                let start = target.lowerBound
                return .written(text: after, at: start ..< start + replacement.unicodeScalars.count)
            }
        }
        guard let after, Self.writeCheck(before: before, expected: expected, after: after) == .wrong else {
            Logger.info("TypeRight: the field did not change after the write", category: Logger.analysis)
            return .notWritten
        }
        Logger.warning("TypeRight: the field changed, but not into the fix", category: Logger.analysis)
        return .wrongResult
    }

    enum CoachWriteCheck: Equatable { case done, unchanged, wrong }

    /// Compares the field after a write with what it should read. Non-breaking spaces count as
    /// spaces and trailing white space is ignored; text typed after the fix is allowed.
    nonisolated static func writeCheck(before: String, expected: String, after: String) -> CoachWriteCheck {
        func normal(_ s: String) -> String {
            s.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let after = normal(after)
        if after == normal(before) { return .unchanged }
        return after.unicodeScalars.starts(with: normal(expected).unicodeScalars) ? .done : .wrong
    }

    var coachAppName: String { monitoredContext?.applicationName ?? "" }

    var coachAppID: String? { monitoredContext?.bundleIdentifier }

    var coachFieldID: String? {
        guard let element = textMonitor.monitoredElement, let bundleID = monitoredContext?.bundleIdentifier else { return nil }
        return "\(bundleID)#\(CFHash(element))"
    }

    var coachIsWatching: Bool {
        guard textMonitor.monitoredElement != nil, let bundleID = monitoredContext?.bundleIdentifier else { return false }
        return userPreferences.effectivePauseScope(for: bundleID) == nil
    }

    /// AppKit text views (and WebKit since 2023) report the input method's uncommitted text as
    /// AXTextInputMarkedRange; apps that do not report it count as not composing.
    var coachIsComposing: Bool {
        guard let element = textMonitor.monitoredElement, let bundleID = monitoredContext?.bundleIdentifier else { return false }
        let call = AXClient.perform(bundleID: bundleID, attribute: "AXTextInputMarkedRange") { () -> CFRange? in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, "AXTextInputMarkedRange" as CFString, &value) == .success,
                  let value else { return nil }
            return safeAXValueGetRange(value)
        }
        guard let marked = call?.value else { return false }
        return marked.location != kCFNotFound && marked.length > 0
    }
}
