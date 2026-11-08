//
//  TRMenu.swift
//  TypeRight
//
//  The menu under the menu-bar feather: today's count with 14 small bars, pause here or
//  everywhere for an hour, open the main window or settings, which AI is in use, quit.
//

import AppKit
import SwiftUI

@MainActor
final class TypeRightMenu: NSObject {
    static let shared = TypeRightMenu()

    private var frontmost: NSRunningApplication?

    func build(frontmost: NSRunningApplication?) -> NSMenu {
        self.frontmost = frontmost
        let menu = NSMenu()
        let prefs = UserPreferences.shared

        let header = NSMenuItem()
        let host = NSHostingView(rootView: TRMenuHeader(notebook: CoachNotebook.shared))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 104)
        header.view = host
        menu.addItem(header)
        menu.addItem(.separator())

        if let app = frontmost, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier {
            let name = app.localizedName ?? id
            let paused = prefs.getPauseDuration(for: id) != .active
            let item = NSMenuItem(title: paused ? "在「\(name)」里继续" : "在「\(name)」里暂停",
                                  action: #selector(toggleApp(_:)), keyEquivalent: "")
            item.representedObject = id
            item.target = self
            menu.addItem(item)
        }
        if prefs.isEnabled {
            menu.addItem(item("全部暂停 1 小时", #selector(pauseHour)))
        } else {
            menu.addItem(item("全部继续", #selector(resumeAll)))
        }
        menu.addItem(.separator())
        menu.addItem(item("打开 TypeRight", #selector(openMain)))
        let settings = item("设置…", #selector(openSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(.separator())

        let ai = NSMenuItem(title: CoachSettings.isAIReady ? "AI：\(CoachSettings.provider.displayName)" : "AI：还没选，只查拼写",
                            action: CoachSettings.isAIReady ? nil : #selector(openAI), keyEquivalent: "")
        ai.target = self
        ai.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 6, weight: .regular)
                .applying(.init(paletteColors: [CoachSettings.isAIReady ? NSColor.systemGreen : NSColor.systemOrange])))
        menu.addItem(ai)
        if !PermissionManager.shared.isPermissionGranted {
            menu.addItem(item("还没给辅助功能权限…", #selector(openAccess)))
        }
        let quit = NSMenuItem(title: "退出 TypeRight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let prefs = UserPreferences.shared
        prefs.setPauseDuration(prefs.getPauseDuration(for: id) == .active ? .indefinite : .active, for: .application(id))
    }

    @objc private func pauseHour() {
        UserPreferences.shared.setPauseDuration(.oneHour, for: .global)
        TypingCoach.shared.reset()
    }

    @objc private func resumeAll() { UserPreferences.shared.resume(.global) }
    @objc private func openMain() { TRMainWindowController.shared.show() }
    @objc private func openSettings() { TRSettingsWindowController.shared.show() }
    @objc private func openAI() { TRSettingsWindowController.shared.show(.ai) }

    @objc private func openAccess() {
        NSApp.sendAction(Selector(("openOnboardingWindow")), to: nil, from: nil)
    }
}

struct TRMenuHeader: View {
    @ObservedObject var notebook: CoachNotebook

    var body: some View {
        let days = notebook.lastDays(14)
        let today = days.last ?? DayStat(day: "")
        let words = notebook.today.filter { $0.kind == .word }.count
        VStack(alignment: .leading, spacing: 6) {
            Text("今天改了 \(today.fixes) 处").font(.system(size: 14, weight: .semibold))
            Text(subtitle(today, words: words)).font(.system(size: 11.5)).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 3) {
                let peak = max(days.map(\.sentences).max() ?? 0, 1)
                ForEach(days, id: \.day) { d in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(TR.fix.opacity(d.day == today.day ? 1 : 0.55))
                        .frame(height: max(3, 22 * CGFloat(d.sentences) / CGFloat(peak)))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 24)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 300, height: 104, alignment: .topLeading)
    }

    private func subtitle(_ today: DayStat, words: Int) -> String {
        var parts: [String] = []
        if words > 0 { parts.append("\(words) 个中文词变成了英文") }
        if today.sentences > 0 { parts.append("\(today.sentences) 句里 \(today.clean) 句一次就对") }
        return parts.isEmpty ? "今天还没打英文" : parts.joined(separator: "，")
    }
}
