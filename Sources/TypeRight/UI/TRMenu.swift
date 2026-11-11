//
//  TRMenu.swift
//  TypeRight
//
//  The menu under the menu-bar feather: today's count with 14 small bars, pause here or
//  everywhere for an hour, open the main window or settings, which AI is in use, quit.
//

import AppKit
import SwiftUI

/// 设置 › 通用 › 在菜单栏显示图标. TypeRight has no Dock icon, so with the menu bar icon off it
/// keeps one way in, as GetNewWord does: opening the app again (Finder, Spotlight, Launchpad)
/// shows the main window, and so does a launch while the icon is off, since nothing else on
/// screen would say TypeRight is running.
@MainActor
enum TRMenuBarIcon {
    enum Opens: Equatable {
        case nothing, mainWindow, setup
    }

    static func setShown(_ shown: Bool) {
        CoachSettings.menuBarIconShown = shown
        MenuBarController.shared?.setIconVisible(shown)
    }

    /// At launch, once the first setup is done.
    static func atLaunch(iconShown: Bool) -> Opens {
        iconShown ? .nothing : .mainWindow
    }

    /// Opening TypeRight again while it runs. Windows already on screen just come forward.
    static func onReopen(hasVisibleWindows: Bool, needsSetup: Bool) -> Opens {
        if hasVisibleWindows { return .nothing }
        return needsSetup ? .setup : .mainWindow
    }
}

/// The "AI" line near the bottom of the menu.
enum TRMenuAILine: Equatable {
    case ready(CoachProvider)
    /// The provider answered 401 / 403 to the saved key.
    case keyRejected(CoachProvider)
    case notSet

    static func current() -> TRMenuAILine {
        guard CoachSettings.isAIReady else { return .notSet }
        let provider = CoachSettings.provider
        return CoachKeyStore.shared.isRejected(provider) ? .keyRejected(provider) : .ready(provider)
    }

    var title: String {
        switch self {
        case let .ready(provider): "AI：\(provider.displayName)"
        case let .keyRejected(provider): "AI：\(provider.displayName) 的 Key 失效了"
        case .notSet: "AI：还没选，只查拼写"
        }
    }

    /// Status dot (DESIGN.md: ok usable, warn one step left, danger key rejected).
    var dotColor: NSColor {
        switch self {
        case .ready: TR.fixNS
        case .keyRejected: TR.dangerNS
        case .notSet: TR.markNS
        }
    }

    /// Clicking the line opens 设置 › AI 服务商 whenever there is something to fix.
    var opensSettings: Bool {
        if case .ready = self { return false }
        return true
    }
}

/// What the menu shows, read from the app (or made up for screenshots).
struct TRMenuState {
    struct App: Equatable {
        var id: String
        var name: String
        var paused: Bool
    }

    var app: App?
    var allPaused: Bool
    var ai: TRMenuAILine
    var needsAccess: Bool

    @MainActor
    static func current(frontmost: NSRunningApplication?) -> TRMenuState {
        let prefs = UserPreferences.shared
        var app: App?
        if let running = frontmost, let id = running.bundleIdentifier, id != Bundle.main.bundleIdentifier {
            app = App(id: id, name: running.localizedName ?? id, paused: prefs.getPauseDuration(for: id) != .active)
        }
        return TRMenuState(app: app, allPaused: !prefs.isEnabled, ai: .current(),
                           needsAccess: !PermissionManager.shared.isPermissionGranted)
    }
}

@MainActor
final class TypeRightMenu: NSObject {
    static let shared = TypeRightMenu()

    func build(frontmost: NSRunningApplication?) -> NSMenu {
        build(state: .current(frontmost: frontmost), notebook: .shared)
    }

    func build(state: TRMenuState, notebook: CoachNotebook) -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem()
        let host = NSHostingView(rootView: TRMenuHeader(notebook: notebook))
        host.sizingOptions = []
        // As tall as the header's own content: a fixed height left empty space under the bars.
        host.frame = NSRect(x: 0, y: 0, width: TRMenuHeader.width, height: host.fittingSize.height)
        header.view = host
        menu.addItem(header)
        menu.addItem(.separator())

        if let app = state.app {
            let item = NSMenuItem(title: app.paused ? "在「\(app.name)」里继续" : "在「\(app.name)」里暂停",
                                  action: #selector(toggleApp(_:)), keyEquivalent: "")
            item.representedObject = app.id
            item.target = self
            menu.addItem(item)
        }
        if state.allPaused {
            menu.addItem(item("全部继续", #selector(resumeAll)))
        } else {
            menu.addItem(item("全部暂停 1 小时", #selector(pauseHour)))
        }
        menu.addItem(.separator())
        menu.addItem(item("打开 TypeRight", #selector(openMain)))
        let settings = item("设置…", #selector(openSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(.separator())

        let ai = NSMenuItem(title: state.ai.title, action: state.ai.opensSettings ? #selector(openAI) : nil, keyEquivalent: "")
        ai.target = self
        ai.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 6, weight: .regular)
                .applying(.init(paletteColors: [state.ai.dotColor])))
        menu.addItem(ai)
        if state.needsAccess {
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
    static let width: CGFloat = 300

    @ObservedObject var notebook: CoachNotebook

    var body: some View {
        let days = notebook.lastDays(14)
        let today = days.last ?? DayStat(day: "")
        let words = notebook.today.filter { $0.kind == .word }.count
        VStack(alignment: .leading, spacing: 0) {
            Text("今天改了 \(today.fixes) 处").font(.system(size: 15, weight: .semibold)).foregroundStyle(TR.text)
            Text(subtitle(today, words: words)).font(.system(size: 12)).foregroundStyle(TR.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
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
            .padding(.top, 12)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: Self.width, alignment: .topLeading)
    }

    private func subtitle(_ today: DayStat, words: Int) -> String {
        var parts: [String] = []
        if words > 0 { parts.append("\(words) 个中文词变成了英文") }
        if today.sentences > 0 { parts.append("\(today.sentences) 句里 \(today.clean) 句一次就对") }
        return parts.isEmpty ? "今天还没打英文" : parts.joined(separator: "，")
    }
}
