//
//  TROnboarding.swift
//  TypeRight
//
//  First run in five side-bar steps: 欢迎、辅助功能、选一个 AI、整句翻译键、好了.
//  Accessibility is granted by dragging the app icon into System Settings' list.
//

import AppKit
import KeyboardShortcuts
import SwiftUI

enum TROnboardingStep: Int, CaseIterable {
    case welcome, access, ai, key, done

    var title: String {
        switch self {
        case .welcome: "欢迎"
        case .access: "辅助功能"
        case .ai: "选一个 AI"
        case .key: "整句翻译键"
        case .done: "好了"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: "看它做什么"
        case .access: "把图标拖进列表"
        case .ai: "填 Key"
        case .key: "自己选一个"
        case .done: "去打一句试试"
        }
    }
}

struct TROnboardingView: View {
    var start: TROnboardingStep = .welcome
    let onFinish: () -> Void

    @State private var step: TROnboardingStep = .welcome
    @ObservedObject private var permission = PermissionManager.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(TR.line).frame(width: 0.5)
            VStack(spacing: 0) {
                ScrollView {
                    content.padding(.horizontal, 44).padding(.top, 36).padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Rectangle().fill(TR.line).frame(height: 0.5)
                footer
            }
            .background(TR.bg)
        }
        .frame(width: 980, height: 680)
        .ignoresSafeArea()
        .onAppear { step = start }
        .onChange(of: step) { new in
            if new == .access { permission.startPolling() }
        }
    }

    // MARK: Side bar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("TypeRight").font(.system(size: 15, weight: .semibold)).foregroundStyle(TR.text)
                    Text("第一次设置").font(.system(size: 12)).foregroundStyle(TR.text2)
                }
            }
            .padding(.top, 48).padding(.bottom, 18).padding(.horizontal, 6)
            ForEach(TROnboardingStep.allCases, id: \.self) { s in
                Button { step = s } label: {
                    HStack(alignment: .top, spacing: 10) {
                        ZStack {
                            Circle().strokeBorder(isDone(s) ? TR.fix : (s == step ? TR.text : TR.line2), lineWidth: 1)
                                .background(Circle().fill(isDone(s) ? TR.fix : Color.clear))
                                .frame(width: 20, height: 20)
                            if isDone(s) {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            } else {
                                Text("\(s.rawValue + 1)").font(.system(size: 11)).foregroundStyle(s == step ? TR.text : TR.text2)
                            }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title).font(.system(size: 13, weight: s == step ? .medium : .regular)).foregroundStyle(TR.text)
                            Text(s.subtitle).font(.system(size: 12)).foregroundStyle(TR.text2)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(s == step ? TR.card : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(s == step ? TR.line : Color.clear, lineWidth: 0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button("跳过，以后在菜单栏图标里接着设", action: finish)
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(TR.text3)
                .padding(.bottom, 18).padding(.horizontal, 6)
        }
        .padding(.horizontal, 10)
        .frame(width: 230)
        .background(TR.side)
    }

    private func isDone(_ s: TROnboardingStep) -> Bool {
        switch s {
        case .access: permission.isPermissionGranted
        case .ai: CoachSettings.isAIReady
        case .key: KeyboardShortcuts.getShortcut(for: .typeRightTranslate) != nil
        default: s.rawValue < step.rawValue
        }
    }

    // MARK: Pages

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .access: access
        case .ai: ai
        case .key: key
        case .done: done
        }
    }

    private func heading(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 22, weight: .semibold)).foregroundStyle(TR.text)
            Text(text).font(.system(size: 13)).foregroundStyle(TR.text2).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 26) {
            TRCardPreview()
            heading("放心用英文打字，打错了有人兜着",
                    "在任何 App 里照常打英文。下面三种时刻，TypeRight 会在旁边弹一个小框，按 Tab 就改好；不想改就接着打，框自己走开。")
            VStack(alignment: .leading, spacing: 16) {
                feature("textformat.abc", "拼错一个词", "tomorow → tomorrow，打完这个词就弹，在本机查，不用等")
                feature("character.bubble", "不会说，先打中文或拼音", "预约 / yuyue → book /bʊk/，带发音")
                feature("text.badge.checkmark", "一句打完", "查整句语法，改动处标出来，配一句中文讲解")
            }
        }
    }

    private func feature(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(TR.fix)
                .frame(width: 32, height: 32).background(TR.fixSoft, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(TR.text)
                Text(text).font(.system(size: 12.5)).foregroundStyle(TR.text2)
            }
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("给 TypeRight 辅助功能权限",
                    "有了这个权限，TypeRight 才能看到你正在打的那一句，并在你按 Tab 时把改法写回去。密码框系统不让读，TypeRight 也不读；你关掉的 App 它完全不看。")
            if permission.isPermissionGranted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(TR.fix)
                    Text("已经开好了。").font(.system(size: 14, weight: .medium)).foregroundStyle(TR.text)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    stepLine(1, "点下面的按钮，系统设置会打开「辅助功能」那一页。")
                    stepLine(2, "把旁边浮出来的 TypeRight 图标往左拖进列表，开关就打开了。")
                    stepLine(3, "回到这里，这一步会自己打勾。")
                    HStack(spacing: 16) {
                        Button("打开系统设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                            PermissionDragHelper.shared.show()
                        }
                        .buttonStyle(TRInkButtonStyle())
                        HStack(spacing: 10) {
                            DraggableAppIcon(size: 36)
                            Text("也可以从这里直接拖").font(.system(size: 12)).foregroundStyle(TR.text2)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .onChange(of: permission.isPermissionGranted) { granted in
            if granted { PermissionDragHelper.shared.hide() }
        }
    }

    private func stepLine(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 11, weight: .medium)).foregroundStyle(TR.text2)
                .frame(width: 20, height: 20).overlay(Circle().strokeBorder(TR.line2, lineWidth: 1))
            Text(text).font(.system(size: 13)).foregroundStyle(TR.text).padding(.top, 1)
        }
    }

    private var ai: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("选一个 AI",
                    "中文变英文、整句检查要用 AI。自带 Key 永久免费，请求从你的 Mac 直接发给你选的那家。不填也能用：拼写照样查。")
            TRAISettings()
        }
    }

    private var key: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("整句翻译键",
                    "中英混打时，中文会自己变成英文。整句都是中文时（比如和朋友聊天）不会弹；想把这句变成英文，按你选的这个键。")
            TRGroup {
                TRRow(title: "整句翻译", note: "要带 ⌘、⌥、⌃ 或 ⇧；不设也行，以后在设置里改", last: true) {
                    KeyboardShortcuts.Recorder("", name: .typeRightTranslate)
                }
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("好了，去打一句试试",
                    "打开微信、邮件或者备忘录，照常打英文。拼错一个词、打一个中文词、打完一句，都会弹出来。TypeRight 平时只在菜单栏里，点羽毛图标能打开错题本和设置。")
            VStack(alignment: .leading, spacing: 8) {
                Text("可以先打这句：").font(.system(size: 12.5)).foregroundStyle(TR.text2)
                Text("I want to 预约 a meeting room tomorow because I has a question.")
                    .font(.system(size: 14, design: .monospaced)).foregroundStyle(TR.text)
                    .textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(TR.card, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TR.line, lineWidth: 0.5))
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(footerNote).font(.system(size: 12)).foregroundStyle(TR.text2)
            Spacer()
            if step != .welcome {
                Button("上一步") { step = TROnboardingStep(rawValue: step.rawValue - 1) ?? .welcome }
                    .buttonStyle(TRPlainButtonStyle())
            }
            Button(nextTitle) {
                if step == .done { finish() } else { step = TROnboardingStep(rawValue: step.rawValue + 1) ?? .done }
            }
            .buttonStyle(TRInkButtonStyle())
        }
        .padding(.horizontal, 24)
        .frame(height: 60)
    }

    private var footerNote: String {
        switch step {
        case .welcome: "接下来 3 步，大约 2 分钟"
        case .access: permission.isPermissionGranted ? "这一步好了" : "没给权限也能先往下走，弹框要等开好才出来"
        case .ai: CoachSettings.isAIReady ? "AI 连上了" : "不填也行，只查拼写"
        case .key: "不设也行"
        case .done: ""
        }
    }

    private var nextTitle: String {
        switch step {
        case .welcome: "开始"
        case .done: "完成"
        default: "下一步"
        }
    }

    private func finish() {
        PermissionDragHelper.shared.hide()
        CoachSettings.onboarded = true
        UserPreferences.shared.hasCompletedOnboarding = true
        onFinish()
    }
}
