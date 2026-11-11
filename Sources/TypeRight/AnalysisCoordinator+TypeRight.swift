//
//  AnalysisCoordinator+TypeRight.swift
//  TypeRight
//
//  Lets TypingCoach use what TextWarden already does well: where a word is on screen, where
//  the caret is, and how to write a fix back into each kind of app.
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
        guard let element = textMonitor.monitoredElement else { return nil }
        let primary = NSScreen.screens.first { $0.frame.origin == .zero }
        guard let height = primary?.frame.height ?? NSScreen.main?.frame.height else { return nil }

        // First choice: the caret. Some apps report a field frame far bigger than the box the user sees.
        if let caret = Self.caretBounds(in: element), caret.width < 400, caret.height > 0, caret.height < 80 {
            return CGRect(x: caret.minX, y: height - caret.maxY, width: max(caret.width, 2), height: caret.height)
        }
        guard var frame = AccessibilityBridge.getElementFrame(element) else { return nil }
        frame.origin.y = height - frame.origin.y - frame.height
        return CGRect(x: frame.maxX - 40, y: frame.maxY - 30, width: 30, height: 30)
    }

    /// Bounds of the character before the caret, in AX (top-left origin) coordinates.
    private static func caretBounds(in element: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue as! AXValue, .cfRange, &range) else { return nil }
        var probe = CFRange(location: max(0, range.location - 1), length: range.location > 0 ? 1 : 0)
        guard let probeValue = AXValueCreate(.cfRange, &probe) else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         probeValue, &bounds) == .success,
              let boundsValue = bounds, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect), rect != .zero else { return nil }
        return rect
    }

    func coachCaret(in text: String) -> Int? {
        guard let element = textMonitor.monitoredElement else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue as! AXValue, .cfRange, &range), range.location >= 0 else { return nil }
        let utf16Offset = min(range.location + range.length, text.utf16.count)
        guard let index = TextIndexConverter.stringIndex(forUTF16Offset: utf16Offset, in: text) else { return nil }
        return TextIndexConverter.stringIndexToScalarIndex(index, in: text)
    }

    func coachReplace(range: Range<Int>, with replacement: String, analyzedText: String, harperError: GrammarErrorModel?) async -> Bool {
        if isCurrentAppInSafeTrial() {
            // Unverified app: never write into it, hand the text over instead.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(replacement, forType: .string)
            Logger.info("TypeRight: safe-trial app, fix copied instead of written", category: Logger.analysis)
            return false
        }
        if let harperError, currentErrors.contains(where: { $0 === harperError }) {
            await applyTextReplacementAsync(for: harperError, with: replacement)
            return true
        }
        let synthetic = GrammarErrorModel(
            start: range.lowerBound,
            end: range.upperBound,
            message: "TypeRight",
            severity: .error,
            category: "TypeRight",
            lintId: "TypeRight",
            suggestions: [replacement]
        )
        currentErrors.append(synthetic)
        currentErrorSourceStore.replace(errors: currentErrors, sourceText: analyzedText)
        await applyTextReplacementAsync(for: synthetic, with: replacement)
        currentErrors.removeAll { $0 === synthetic }
        return true
    }

    var coachAppName: String { monitoredContext?.applicationName ?? "" }
}
