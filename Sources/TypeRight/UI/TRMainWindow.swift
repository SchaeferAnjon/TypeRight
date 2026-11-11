//
//  TRMainWindow.swift
//  TypeRight
//
//  The main window: one sidebar (今天、错题本、生词本、进步) and the page on the right.
//  "今天" shows all three books at once, so the first screen is the whole product.
//

import AppKit
import Combine
import SwiftUI

enum TRPage: String, CaseIterable {
    case today, mistakes, words, progress

    var title: String {
        switch self {
        case .today: "今天"
        case .mistakes: "错题本"
        case .words: "生词本"
        case .progress: "进步"
        }
    }

    var icon: String {
        switch self {
        case .today: "sun.max"
        case .mistakes: "book.closed"
        case .words: "textformat"
        case .progress: "chart.bar"
        }
    }
}

@MainActor
final class TRMainWindowController: ObservableObject {
    static let shared = TRMainWindowController()

    @Published var page: TRPage = .today
    private var window: NSWindow?

    func show(_ page: TRPage? = nil) {
        if let page { self.page = page }
        if window == nil {
            let host = NSHostingView(rootView: TRMainView(controller: self))
            host.sizingOptions = []
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "TypeRight"
            window.contentView = host
            window.minSize = NSSize(width: 900, height: 600)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("TypeRightMain")
            if window.frame.origin == .zero { window.center() }
            self.window = window
        }
        TRAppActivation.bringForward(window)
    }
}

/// A menu bar app shows its windows by turning into a regular app while one is open.
@MainActor
enum TRAppActivation {
    /// One close observer per window (windows are kept and shown again, not rebuilt).
    private static var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    static func bringForward(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard observers[ObjectIdentifier(window)] == nil else { return }
        observers[ObjectIdentifier(window)] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                // Back to menu-bar only once no titled window of ours is left on screen.
                DispatchQueue.main.async {
                    let open = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && $0 !== window }
                    if !open { NSApp.setActivationPolicy(.accessory) }
                }
            }
        }
    }
}

struct TRMainView: View {
    @ObservedObject var controller: TRMainWindowController
    @ObservedObject var notebook: CoachNotebook = .shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(TR.line).frame(width: 0.5)
            VStack(spacing: 0) {
                header
                Rectangle().fill(TR.line).frame(height: 0.5)
                ScrollView {
                    page.padding(28)
                }
            }
            .background(TR.bg)
        }
        .frame(minWidth: 900, minHeight: 600)
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text("TypeRight").font(.system(size: 15, weight: .semibold)).foregroundStyle(TR.text)
                    Text("放心打英文").font(.system(size: 12)).foregroundStyle(TR.text2)
                }
            }
            .padding(.top, 44)
            .padding(.bottom, 14)
            .padding(.horizontal, 6)

            ForEach(TRPage.allCases, id: \.self) { p in
                TRSideItem(icon: p.icon, title: p.title, count: count(for: p), selected: controller.page == p) {
                    controller.page = p
                }
            }
            Spacer()
            TRStatusCard()
            TRSideItem(icon: "gearshape", title: "设置", selected: false) { TRSettingsWindowController.shared.show() }
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 10)
        .frame(width: 222)
        .background(TR.side)
    }

    private func count(for page: TRPage) -> Int? {
        switch page {
        case .mistakes: notebook.mistakes.count
        case .words: notebook.words.count
        default: nil
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(controller.page.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(TR.text)
            if controller.page == .today {
                Text(Date().formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "zh_CN"))))
                    .font(.system(size: 12)).foregroundStyle(TR.text2)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(height: 52)
        .padding(.top, 0)
    }

    @ViewBuilder private var page: some View {
        switch controller.page {
        case .today: TRTodayPage(notebook: notebook) { controller.page = $0 }
        case .mistakes: TRMistakesPage(notebook: notebook)
        case .words: TRWordsPage(notebook: notebook)
        case .progress: TRProgressPage(notebook: notebook)
        }
    }
}

/// Bottom of the sidebar: is TypeRight watching, and which AI it uses.
struct TRStatusCard: View {
    @ObservedObject private var preferences = UserPreferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(preferences.isEnabled ? TR.ok : TR.warn).frame(width: 7, height: 7)
                Text(preferences.isEnabled ? "正在帮你看" : "已暂停").font(.system(size: 12, weight: .medium)).foregroundStyle(TR.text)
            }
            Text(aiLine).font(.system(size: 12)).foregroundStyle(TR.text2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TR.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TR.line, lineWidth: 0.5))
        .padding(.bottom, 8)
    }

    private var aiLine: String {
        CoachSettings.isAIReady
            ? "拼写在本机查 · AI 用 \(CoachSettings.provider.displayName)"
            : "只查拼写；选好 AI 后，中文变英文和整句检查才会出来"
    }
}
