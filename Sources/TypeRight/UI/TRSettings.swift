//
//  TRSettings.swift
//  TypeRight
//
//  Settings in a System Settings style window: 通用、App、快捷键、AI 服务商、隐私,
//  plus 高级 for TextWarden's own settings.
//

import AppKit
import Combine
import KeyboardShortcuts
import LaunchAtLogin
import SwiftUI

extension KeyboardShortcuts.Name {
    /// Translates a whole Chinese sentence. No default: the user picks the keys.
    static let typeRightTranslate = Self("typeRightTranslate")
}

enum TRSettingsPage: String, CaseIterable {
    case general, apps, keys, ai, privacy, advanced

    var title: String {
        switch self {
        case .general: "通用"
        case .apps: "App"
        case .keys: "快捷键"
        case .ai: "AI 服务商"
        case .privacy: "隐私"
        case .advanced: "高级"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .apps: "square.grid.2x2"
        case .keys: "keyboard"
        case .ai: "sparkles"
        case .privacy: "hand.raised"
        case .advanced: "slider.horizontal.3"
        }
    }
}

@MainActor
final class TRSettingsWindowController: ObservableObject {
    static let shared = TRSettingsWindowController()

    @Published var page: TRSettingsPage = .general
    private var window: NSWindow?

    func show(_ page: TRSettingsPage? = nil) {
        if let page { self.page = page }
        if window == nil {
            let host = NSHostingView(rootView: TRSettingsView(controller: self))
            host.sizingOptions = []
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "TypeRight 设置"
            window.contentView = host
            window.minSize = NSSize(width: 820, height: 560)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        TRAppActivation.bringForward(window)
    }
}

struct TRSettingsView: View {
    @ObservedObject var controller: TRSettingsWindowController

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TypeRight 设置").font(.system(size: 12)).foregroundStyle(TR.text2)
                    .padding(.top, 48).padding(.bottom, 10).padding(.leading, 6)
                ForEach(TRSettingsPage.allCases, id: \.self) { p in
                    TRSideItem(icon: p.icon, title: p.title, selected: controller.page == p) { controller.page = p }
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(width: 218)
            .background(TR.side)
            Rectangle().fill(TR.line).frame(width: 0.5)
            VStack(spacing: 0) {
                HStack {
                    Text(controller.page.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(TR.text)
                    Spacer()
                }
                .padding(.horizontal, 28).frame(height: 52)
                Rectangle().fill(TR.line).frame(height: 0.5)
                if controller.page == .advanced {
                    PreferencesView()
                } else {
                    ScrollView {
                        page.padding(.horizontal, 32).padding(.vertical, 24).frame(maxWidth: 720)
                    }
                }
            }
            .background(TR.bg)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private var page: some View {
        switch controller.page {
        case .general: TRGeneralSettings()
        case .apps: TRAppSettings()
        case .keys: TRKeySettings()
        case .ai: TRAISettings()
        case .privacy: TRPrivacySettings()
        case .advanced: EmptyView()
        }
    }
}

// MARK: - 通用

struct TRGeneralSettings: View {
    @State private var pause = CoachSettings.pauseSeconds
    @State private var cards = CoachSettings.cardsEnabled
    @State private var mixed = CoachSettings.autoTranslateMixed
    @State private var pinyin = CoachSettings.pinyinEnabled
    @State private var accent = CoachSettings.accent
    @State private var language = CoachSettings.explainLanguage

    private static let languages = ["简体中文", "繁體中文", "English", "Deutsch", "日本語", "한국어", "Français", "Español", "Italiano"]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TRCardPreview()
            TRGroup(title: "什么时候弹") {
                TRRow(title: "边打边弹框", note: "关掉后只在菜单栏里待着，什么都不弹") {
                    Toggle("", isOn: $cards).toggleStyle(SquareToggleStyle()).labelsHidden()
                        .onChange(of: cards) { CoachSettings.cardsEnabled = $0 }
                }
                TRRow(title: "停下多久后弹", note: "拼错的词不用等，打完这个词就弹；中文和整句等你停一下") {
                    TRSegmented(options: [(0.5, "0.5 秒"), (0.8, "0.8 秒"), (1.5, "1.5 秒")], selection: $pause)
                        .onChange(of: pause) { CoachSettings.pauseSeconds = $0 }
                }
                TRRow(title: "中英混打时，中文自动变英文", note: "整句都是中文时不弹，按「整句翻译」键才翻") {
                    Toggle("", isOn: $mixed).toggleStyle(SquareToggleStyle()).labelsHidden()
                        .onChange(of: mixed) { CoachSettings.autoTranslateMixed = $0 }
                }
                TRRow(title: "英文状态下打的拼音也认", note: "打 yuyue 也会提示 book") {
                    Toggle("", isOn: $pinyin).toggleStyle(SquareToggleStyle()).labelsHidden()
                        .onChange(of: pinyin) { CoachSettings.pinyinEnabled = $0 }
                }
                TRRow(title: "弹框放在哪", note: "贴在那个词下面，下面放不下就放上面", last: true) {
                    Text("贴词小卡").font(.system(size: 12)).foregroundStyle(TR.text2)
                        .padding(.horizontal, 8).frame(height: 22).background(TR.fill, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            TRGroup(title: "讲解和发音") {
                TRRow(title: "发音") {
                    TRSegmented(options: [("us", "美音"), ("uk", "英音")], selection: $accent)
                        .onChange(of: accent) { CoachSettings.accent = $0 }
                }
                TRRow(title: "讲解用", note: "一句话说清为什么这样改", last: true) {
                    Picker("", selection: $language) {
                        ForEach(Self.languages, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 130)
                    .onChange(of: language) { CoachSettings.explainLanguage = $0 }
                }
            }
            TRGroup(title: "启动") {
                TRRow(title: "开机时打开", last: true) {
                    LaunchAtLogin.Toggle { EmptyView() }.toggleStyle(SquareToggleStyle()).labelsHidden()
                }
            }
        }
    }
}

// MARK: - App

struct TRAppSettings: View {
    @ObservedObject private var preferences = UserPreferences.shared
    @State private var apps: [(id: String, name: String, icon: NSImage)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("关掉的 App 里 TypeRight 完全不看。终端和密码管理器默认就是关的。")
                .font(.system(size: 12.5)).foregroundStyle(TR.text2)
            TRGroup(title: "正在用的 App") {
                ForEach(Array(apps.enumerated()), id: \.element.id) { i, app in
                    HStack(spacing: 10) {
                        Image(nsImage: app.icon).resizable().frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name).font(.system(size: 13)).foregroundStyle(TR.text)
                            Text(supportText(app.id)).font(.system(size: 11.5)).foregroundStyle(TR.text2)
                        }
                        Spacer()
                        Toggle("", isOn: binding(for: app.id)).toggleStyle(SquareToggleStyle()).labelsHidden()
                            .disabled(AppRegistry.shared.policy(for: app.id) == .ignored)
                    }
                    .padding(.horizontal, 14).frame(minHeight: 48)
                    if i < apps.count - 1 { Rectangle().fill(TR.line).frame(height: 0.5).padding(.leading, 46) }
                }
            }
        }
        .onAppear(perform: loadApps)
    }

    private func supportText(_ id: String) -> String {
        switch AppRegistry.shared.policy(for: id) {
        case .supported: "支持，弹框贴在词旁边"
        case .safeTrial: "没试过的 App：先只给提示，改法要你自己粘贴"
        case .pausedByDefault: "默认关着"
        case .ignored: "这类 App 不用写字，不检查"
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { preferences.getPauseDuration(for: id) == .active && AppRegistry.shared.policy(for: id) != .ignored },
            set: { on in preferences.setPauseDuration(on ? .active : .indefinite, for: .application(id)) }
        )
    }

    private func loadApps() {
        var seen = Set<String>()
        var list: [(id: String, name: String, icon: NSImage)] = []
        let mine = Bundle.main.bundleIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != mine, !seen.contains(id) else { continue }
            seen.insert(id)
            list.append((id, app.localizedName ?? id, app.icon ?? NSImage()))
        }
        for id in preferences.appPauseDurations.keys where !seen.contains(id) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            seen.insert(id)
            list.append((id, FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                         NSWorkspace.shared.icon(forFile: url.path)))
        }
        apps = list.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
}

// MARK: - 快捷键

struct TRKeySettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TRGroup(title: "弹框出来时") {
                TRRow(title: "接受改法") { KeyCap(label: "Tab") }
                TRRow(title: "不改，关掉") { KeyCap(label: "Esc") }
                TRRow(title: "接着打字", note: "打两个字框就让开，不用按键", last: true) { EmptyView() }
            }
            TRGroup(title: "自己选的键") {
                TRRow(title: "整句翻译", note: "整句都是中文时，按这个键把这句变成英文") {
                    KeyboardShortcuts.Recorder("", name: .typeRightTranslate)
                }
                TRRow(title: "暂停 / 继续", note: "所有 App 里暂停或继续弹框", last: true) {
                    KeyboardShortcuts.Recorder("", name: .toggleTextWarden)
                }
            }
            Text("快捷键要带 ⌘、⌥、⌃ 或 ⇧ 里至少一个。没设的键不会响。")
                .font(.system(size: 12)).foregroundStyle(TR.text2)
        }
    }
}

// MARK: - AI 服务商

struct TRAISettings: View {
    @State private var provider = CoachSettings.provider
    @State private var key = ""
    @State private var model = ""
    @State private var baseURL = CoachSettings.customBaseURL
    @State private var test: TestState = .idle

    enum TestState: Equatable { case idle, running, ok(String), failed(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("中文变英文、整句检查要用 AI；拼写在这台 Mac 上查，不用 AI。Key 存在钥匙串里，请求从你的 Mac 直接发给你选的那家。")
                .font(.system(size: 12.5)).foregroundStyle(TR.text2).fixedSize(horizontal: false, vertical: true)
            TRProviderList(selection: $provider)
                .onChange(of: provider) { new in
                    CoachSettings.provider = new
                    load()
                }
            TRGroup(title: "\(provider.displayName) 的 Key") {
                VStack(alignment: .leading, spacing: 10) {
                    if provider == .custom {
                        TextField("接口地址（…/v1）", text: $baseURL)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: baseURL) { CoachSettings.customBaseURL = $0 }
                    }
                    HStack {
                        SecureField("粘贴 API Key", text: $key)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5, design: .monospaced))
                            .onChange(of: key) { CoachKeychain.setKey($0, for: provider) }
                        if let page = provider.keyPage { Link("去拿 Key", destination: page).font(.system(size: 12.5)) }
                    }
                    TextField("模型（留空用 \(provider.defaultModel)）", text: $model)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model) { CoachSettings.setModel($0, for: provider) }
                    HStack(spacing: 10) {
                        Button("试一下", action: runTest).buttonStyle(TRPlainButtonStyle()).disabled(test == .running)
                        switch test {
                        case .idle: EmptyView()
                        case .running: Text("正在问…").foregroundStyle(TR.text2)
                        case let .ok(text): Text("连上了：\(text)").foregroundStyle(TR.fix)
                        case let .failed(text): Text(text).foregroundStyle(TR.text2).lineLimit(2)
                        }
                    }
                    .font(.system(size: 12.5))
                }
                .padding(14)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        key = CoachKeychain.key(for: provider) ?? ""
        model = UserDefaults.standard.string(forKey: "typeright.model.\(provider.rawValue)") ?? ""
        test = .idle
    }

    private func runTest() {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else {
            test = .failed("先把 Key 粘贴进来")
            return
        }
        test = .running
        Task {
            do {
                let result = try await CoachAI.check(sentence: "I has a question.")
                test = .ok(result.ok ? "I has a question." : result.corrected)
            } catch {
                test = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}

/// Radio list of providers, Chinese ones first.
struct TRProviderList: View {
    @Binding var selection: CoachProvider

    var body: some View {
        TRGroup {
            ForEach(Array(CoachProvider.allCases.enumerated()), id: \.element) { i, p in
                Button { selection = p } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().strokeBorder(selection == p ? TR.fix : TR.line2, lineWidth: 1.2).frame(width: 15, height: 15)
                            if selection == p { Circle().fill(TR.fix).frame(width: 7, height: 7) }
                        }
                        Text(p.displayName).font(.system(size: 13)).foregroundStyle(TR.text)
                        Text(p.blurb).font(.system(size: 12)).foregroundStyle(TR.text2)
                        Spacer()
                        if !(CoachKeychain.key(for: p) ?? "").isEmpty {
                            Text("已填 Key").font(.system(size: 11.5)).foregroundStyle(TR.fix)
                        }
                    }
                    .padding(.horizontal, 14).frame(height: 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < CoachProvider.allCases.count - 1 { Rectangle().fill(TR.line).frame(height: 0.5).padding(.leading, 39) }
            }
        }
    }
}

// MARK: - 隐私

struct TRPrivacySettings: View {
    @State private var report = CoachSettings.anonymousReport
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TRGroup(title: "你打的字去了哪里") {
                TRRow(title: "拼写和基础语法", note: "在这台 Mac 上查，不联网") { EmptyView() }
                TRRow(title: "中文变英文、整句检查", note: "只把当前这一句发给你选的 AI，不发前后文、不发聊天记录") { EmptyView() }
                TRRow(title: "密码框", note: "系统不让读，TypeRight 也不读") { EmptyView() }
                TRRow(title: "错题本、生词本、Key", note: "只存在这台 Mac 上", last: true) { EmptyView() }
            }
            TRGroup(title: "匿名报到") {
                TRRow(title: "每天匿名报到一次",
                      note: "我们会给前 100 位用户免费额度，所以需要知道有多少人在用。只发一个随机编号、版本号、系统版本和界面语言，不含你打的字、Key、名字或邮箱。",
                      last: true) {
                    Toggle("", isOn: $report).toggleStyle(SquareToggleStyle()).labelsHidden()
                        .onChange(of: report) { CoachSettings.anonymousReport = $0 }
                }
            }
            TRGroup(title: "数据") {
                TRRow(title: "清空错题本和生词本", note: "删掉这台 Mac 上记下的全部改动和生词，删了找不回来", last: true) {
                    Button("清空…") { confirmClear = true }
                        .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(TR.danger)
                }
            }
        }
        .confirmationDialog("清空错题本和生词本？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { CoachNotebook.shared.clearAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删了找不回来。")
        }
    }
}
