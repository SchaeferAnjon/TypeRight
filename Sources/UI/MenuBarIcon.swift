//
//  MenuBarIcon.swift
//  TypeRight
//
//  The menu bar icon: the app icon's checkmark as a one-colour line drawing (design/icon/redesign,
//  direction B «羽毛成勾»), 18 pt, line width 1.5, round caps, as a template image so macOS gives
//  it the menu bar's contrast. Paused and error are the same drawing faded with a badge at the
//  bottom right; when the AI line in the menu wants a look (no membership, a key turned down …),
//  an amber dot sits at the top left, the icon's only colour.
//

import AppKit

enum MenuBarIcon {
    enum Look: Equatable {
        case normal, paused, error
    }

    static let size = NSSize(width: 18, height: 18)

    static func image(_ look: Look, attention: Bool) -> NSImage {
        let name = switch look {
        case .normal: "MenuBarNormal"
        case .paused: "MenuBarPaused"
        case .error: "MenuBarError"
        }
        guard let glyph = NSImage(named: name) else {
            Logger.error("Menu bar icon \(name) missing from the asset catalog", category: Logger.ui)
            return NSImage(size: size)
        }
        let image = NSImage(size: size, flipped: true) { rect in
            draw(glyph, in: rect, attention: attention)
            return true
        }
        // A template cannot carry the amber dot: with it, the glyph is drawn in the label colour
        // of the menu bar it is drawn in.
        image.isTemplate = !attention
        image.accessibilityDescription = "TypeRight"
        return image
    }

    /// In the glyph's own coordinates (18 × 18, origin top left), like the SVG sources.
    private static func draw(_ glyph: NSImage, in rect: NSRect, attention: Bool) {
        guard attention, let context = NSGraphicsContext.current?.cgContext else {
            glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSColor.labelColor.set()
        rect.fill(using: .sourceAtop)
        // Clear room around the dot so it reads at menu bar size.
        context.setBlendMode(.clear)
        context.fillEllipse(in: CGRect(x: 3 - 3.9, y: 3 - 3.9, width: 7.8, height: 7.8))
        context.setBlendMode(.normal)
        context.endTransparencyLayer()
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? TRMenuBarDot.dark : TRMenuBarDot.light }.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0.4, y: 0.4, width: 5.2, height: 5.2)).fill()
    }
}

/// The `warn` amber of DESIGN.md on a light and a dark menu bar.
enum TRMenuBarDot {
    static let light = NSColor(srgbRed: 0xC9 / 255, green: 0x8A / 255, blue: 0x12 / 255, alpha: 1)
    static let dark = NSColor(srgbRed: 0xE2 / 255, green: 0xA8 / 255, blue: 0x4A / 255, alpha: 1)
}

extension Notification.Name {
    /// The own key was saved or turned down: the menu bar's dot may change.
    static let typeRightAIChanged = Notification.Name("TypeRightAIChanged")
}
