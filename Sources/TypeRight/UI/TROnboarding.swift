//
//  TROnboarding.swift
//  TypeRight
//
//  First run in five side-bar steps: 欢迎、辅助功能、怎么用 AI、整句翻译键、好了.
//  Accessibility is granted by dragging the app icon into System Settings' list. Step 3 picks how
//  the AI cards work (membership, own key, or on-device only); nothing is asked of our backend
//  there, and not picking means on-device only.
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
        case .ai: "怎么用 AI"
        case .key: "整句翻译键"
        case .done: "好了"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: "看它做什么"
        case .access: "把图标拖进列表"
        case .ai: "三种选一种"
        case .key: "自己选一个"
        case .done: "去打一句试试"
        }
    }
}

struct TROnboardingView: View {
    var start: TROnboardingStep = .welcome
    /// Screenshots fix these instead of reading this Mac's permission and shortcut.
    var accessGranted: Bool?
    var translateKey: KeyboardShortcuts.Name = .typeRightTranslate
    /// Screenshots: the membership step 3 goes by.
    var sampleFacts: TRAccountFacts?
    let onFinish: () -> Void

    @State private var step: TROnboardingStep = .welcome
    @ObservedObject private var permission = PermissionManager.shared
    @ObservedObject private var member = MemberService.shared

    private var facts: TRAccountFacts { sampleFacts ?? .current(member) }

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
            // On the last step 完成 does the same, so 跳过 would only be a second way out.
            if step != .done {
                Button("跳过，以后在菜单栏图标里接着设", action: finish)
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(TR.text2)
                    .padding(.bottom, 18).padding(.horizontal, 6)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 230)
        .background(TR.side)
    }

    private var isAccessGranted: Bool { accessGranted ?? permission.isPermissionGranted }

    private func isDone(_ s: TROnboardingStep) -> Bool {
        switch s {
        case .access: isAccessGranted
        case .ai: member.planChosen || CoachSettings.isAIReady
        case .key: KeyboardShortcuts.getShortcut(for: translateKey) != nil
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

    /// Lead paragraphs stop at 560 wide, so no line ends with two lonely characters.
    static let leadWidth: CGFloat = 560

    private func heading(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 22, weight: .semibold)).foregroundStyle(TR.text)
            Text(text).font(.system(size: 13)).foregroundStyle(TR.text2).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Self.leadWidth, alignment: .leading)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 26) {
            TRCardPreview()
            heading("放心用英文打字，打错了有人兜着",
                    "在任何 App 里照常打英文。下面三种时刻，TypeRight 会在旁边弹一个小框，按 Tab 就改好；不想改就接着打，框自己走开。")
            VStack(alignment: .leading, spacing: 16) {
                // Not textformat.abc / character.*: those symbols turn into Chinese characters on a Chinese system.
                feature("pencil.line", "拼错一个词", "tomorow → tomorrow，打完这个词就弹，在本机查，不用等")
                feature("text.bubble", "不会说，先打中文或拼音", "预约 / yuyue → book /bʊk/，带发音")
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
                Text(text).font(.system(size: 12)).foregroundStyle(TR.text2)
            }
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("给 TypeRight 辅助功能权限",
                    "有了这个权限，TypeRight 才能看到你正在打的那一句，并在你按 Tab 时把改法写回去。密码框系统不让读，TypeRight 也不读；你关掉的 App 它完全不看。")
            if isAccessGranted {
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
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Self.leadWidth, alignment: .leading)
        }
    }

    private var ai: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("中文变英文、整句讲解要用 AI",
                    "拼写和几类常见语法错（像 I has、a apple）在这台 Mac 上查，不花钱，也不算次数。中文变英文和整句讲解要用 AI：选一种，以后在 设置 › 账号与会员 里随时换；不选就先只在本机查。")
            memberChoice.padding(.top, 6)
            VStack(spacing: 0) {
                choiceRow(.own, "我有自己的 AI Key", "永久免费、不限次数，\(CoachProvider.allCases.count) 家可选", opens: true)
                if facts.plan == .own {
                    TRAISettings(showsIntro: false).padding(.horizontal, 12).padding(.bottom, 12)
                }
                Rectangle().fill(TR.line).frame(height: 0.5)
                choiceRow(.local, "先不用 AI，只在本机查", "打中文时不弹，拼写和几类常见语法错照样查", opens: false)
            }
            .background(TR.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TR.line, lineWidth: 0.5))
        }
    }

    /// The membership as the big card: picking it chooses the plan; 看看会员… opens the price window.
    private var memberChoice: some View {
        let picked = facts.plan == .member
        return HStack(spacing: 16) {
            Image(systemName: "sparkles").font(.system(size: 17)).foregroundStyle(TR.fix)
                .frame(width: 40, height: 40).background(TR.fixSoft, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("会员：¥9.9 / 月起").font(.system(size: 15, weight: .semibold)).foregroundStyle(TR.text)
                Text("不用申请 Key，每天 500 次，一次 = 一个用到 AI 的弹框；在浏览器里付款，付完自动生效")
                    .font(.system(size: 12)).foregroundStyle(TR.text2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if picked {
                TRStatusDot(color: facts.isMember ? TR.ok : TR.text3, text: facts.isMember ? "已是会员" : "还没开")
            }
            Button("看看会员…") {
                member.choose(.member)
                TRPricingWindowController.shared.show()
            }
            .buttonStyle(TRPlainButtonStyle())
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .background(TR.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(picked ? TR.text : TR.line, lineWidth: picked ? 1.5 : 0.5))
        .contentShape(Rectangle())
        .onTapGesture { member.choose(.member) }
    }

    private func choiceRow(_ plan: AIPlan, _ title: String, _ note: String, opens: Bool) -> some View {
        let on = facts.plan == plan
        return Button { member.choose(plan) } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().strokeBorder(on ? TR.text : TR.line2, lineWidth: 1).frame(width: 16, height: 16)
                    if on { Circle().fill(TR.text).frame(width: 16, height: 16).overlay(Circle().fill(TR.card).frame(width: 7, height: 7)) }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13)).foregroundStyle(TR.text)
                    Text(note).font(.system(size: 12)).foregroundStyle(TR.text2)
                }
                Spacer()
                if opens {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)).foregroundStyle(TR.text3)
                        .rotationEffect(.degrees(on ? 90 : 0))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var key: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("整句翻译键",
                    "中英混打时，中文会自己变成英文。整句都是中文时（比如和朋友聊天）不会弹；想把这句变成英文，按你选的这个键。")
            TRGroup {
                TRRow(title: "整句翻译", note: "点键帽，按下你顺手的组合键，要带 ⌘、⌥、⌃ 或 ⇧；不设也行，以后在设置里改", last: true) {
                    TRShortcutRecorder(name: translateKey)
                }
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("好了，去打一句试试",
                    "打开微信、邮件或者备忘录，照常打英文。拼错一个词、打一个中文词、打完一句，都会弹出来。TypeRight 平时只在菜单栏里，点右上角那个勾形图标（长的一笔是一支羽毛）能打开错题本和设置。")
            VStack(alignment: .leading, spacing: 8) {
                Text("可以先打这句，标出来的三处都会弹：").font(.system(size: 12)).foregroundStyle(TR.text2)
                Text(TRMarked.text([("I want to ", false), ("预约", true), (" a meeting room ", false), ("tomorow", true),
                                    (" because ", false), ("I has", true), (" a question.", false)]))
                    .font(.system(size: 15)).foregroundStyle(TR.text)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(TR.card, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TR.line, lineWidth: 0.5))
            }
            if !isAccessGranted {
                HStack(spacing: 10) {
                    TRStatusDot(color: TR.warn, text: "辅助功能还没开，弹框不会出来")
                    Button("回去开") { step = .access }
                        .buttonStyle(TRPlainButtonStyle())
                }
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
            // One solid button per screen: while access is not given, 打开系统设置 is the solid one.
            if step == .access, !isAccessGranted {
                Button(nextTitle, action: next).buttonStyle(TRPlainButtonStyle())
            } else {
                Button(nextTitle, action: next).buttonStyle(TRInkButtonStyle())
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 60)
    }

    private func next() {
        if step == .done { finish() } else { step = TROnboardingStep(rawValue: step.rawValue + 1) ?? .done }
    }

    private var footerNote: String {
        switch step {
        case .welcome: "接下来 3 步，大约 2 分钟"
        case .access: isAccessGranted ? "这一步好了" : "没给权限也能先往下走，弹框要等开好才出来"
        case .ai: aiNote
        case .key: "不设也行"
        case .done: ""
        }
    }

    private var aiNote: String {
        switch facts.plan {
        case .member: facts.isMember ? "已是会员" : "开会员在浏览器里付款，付完自动生效；以后在 设置 › 账号与会员 里换"
        case .own: CoachSettings.isAIReady ? "用你自己的 Key" : "填好 Key 才有中文变英文和整句讲解"
        case .local: "先只用本机检查，以后在 设置 › 账号与会员 里换"
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
