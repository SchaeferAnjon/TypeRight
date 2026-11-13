//
//  TRAccountPage.swift
//  TypeRight
//
//  设置 › 账号与会员, the plan card at the bottom of the sidebars and the 方案和价格 window
//  (design/membership/redesign/proto-b.html). The words come from TRAccountFacts; what the
//  buttons do goes through TRAccountHandler, so screenshots draw every state with made-up data.
//

import AppKit
import SwiftUI

/// What the account surfaces' buttons do. `live` talks to MemberService and opens windows; the
/// screenshots use `preview`, which does nothing.
@MainActor
struct TRAccountHandler {
    var choose: (AIPlan) -> Void
    var openPricing: () -> Void
    var openAccount: () -> Void
    var openProviders: () -> Void
    var portal: () async throws -> Void
    var retry: () async -> Void
    var activate: (String) async throws -> Void
    var unbind: () async throws -> Void
    /// plan month / year, currency cny / usd, mode sub / pass
    var buy: (String, String, String) async throws -> Void
    var reopenCheckout: () -> Void
    var cancelPurchase: () -> Void
    var dismissPaid: () -> Void

    static func live(_ member: MemberService) -> TRAccountHandler {
        TRAccountHandler(
            choose: { member.choose($0) },
            openPricing: { TRPricingWindowController.shared.show() },
            openAccount: { TRSettingsWindowController.shared.show(.account) },
            openProviders: { TRSettingsWindowController.shared.show(.ai) },
            portal: { try await member.openPortal() },
            retry: { await member.refresh() },
            activate: { try await member.activate(code: $0) },
            unbind: { try await member.unbind() },
            buy: { try await member.buy(plan: $0, currency: $1, mode: $2) },
            reopenCheckout: { member.reopenCheckout() },
            cancelPurchase: { member.cancelPurchase() },
            dismissPaid: { member.justPaid = false }
        )
    }

    static let preview = TRAccountHandler(choose: { _ in }, openPricing: {}, openAccount: {}, openProviders: {}, portal: {}, retry: {},
                                          activate: { _ in }, unbind: {}, buy: { _, _, _ in }, reopenCheckout: {}, cancelPurchase: {},
                                          dismissPaid: {})
}

/// The words for an error from the backend, in one line.
@MainActor
enum TRAccountError {
    static func text(_ error: Error) -> String {
        guard let e = error as? MemberError else { return error.localizedDescription }
        let shown = MemberService.shared.explain(e)
        return "\(MemberText.title(shown))：\(MemberText.detail(shown))"
    }
}

// MARK: - Small parts

extension TRTone {
    var color: Color {
        switch self {
        case .ok: TR.ok
        case .warn: TR.warn
        case .danger: TR.danger
        case .off, .wait: TR.text3
        }
    }
}

/// A button's words with the opens-in-the-browser mark after them (管理订阅 ↗).
struct TRBrowserLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
            Image(systemName: "arrow.up.forward.square").font(.system(size: 11))
        }
    }
}

/// A thin bar for today's count (6 high in the status block, 4 in the plan card).
struct TRMeter: View {
    let value: Double
    var tone: TRTone = .ok
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2).fill(TR.fill)
                    .overlay(RoundedRectangle(cornerRadius: height / 2).strokeBorder(TR.line, lineWidth: 0.5))
                RoundedRectangle(cornerRadius: height / 2).fill(tone.color)
                    .frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
    }
}

/// The small grey tag (开源, 推荐 use the ink one).
struct TRTag: View {
    let text: String
    var ink = false
    var tone: TRTone?

    var body: some View {
        Text(text).font(.system(size: 12)).lineLimit(1)
            .foregroundStyle(ink ? TR.bg : tone == .ok ? TR.fix : TR.text2)
            .padding(.horizontal, 7).frame(height: 20)
            .background(ink ? TR.text : tone == .ok ? TR.fixSoft : TR.fill, in: RoundedRectangle(cornerRadius: 5))
    }
}

/// The plan card at the bottom of the settings and main window sidebars; a click opens 账号与会员.
struct TRPlanCard: View {
    let info: TRPlanCardInfo
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    if info.tone == .wait {
                        ProgressView().controlSize(.mini).frame(width: 16, height: 16)
                    } else {
                        Image(systemName: info.icon).font(.system(size: 12, weight: .medium)).frame(width: 16, height: 16)
                            .foregroundStyle(info.tone == .warn ? TR.warn : info.tone == .off ? TR.text2 : TR.fix)
                    }
                    Text(info.title).font(.system(size: 13, weight: .medium)).foregroundStyle(TR.text).lineLimit(1)
                    Spacer(minLength: 4)
                    if let count = info.count {
                        Text(count).font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(info.countWarn ? TR.warn : TR.text).lineLimit(1)
                    }
                }
                if let meter = info.meter {
                    TRMeter(value: meter, tone: info.meterTone, height: 4).padding(.top, 8)
                }
                Text(info.detail).font(.system(size: 12)).foregroundStyle(TR.text2)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TR.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TR.line, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("打开「账号与会员」")
    }
}

/// The plan card bound to MemberService.
struct TRLivePlanCard: View {
    @ObservedObject var member: MemberService = .shared
    var action: () -> Void = { TRSettingsWindowController.shared.show(.account) }

    var body: some View {
        TRPlanCard(info: TRAccountFacts.current(member).planCard, action: action)
    }
}

/// The membership's status block: icon, title, today's count, a thin bar, a sentence, buttons.
struct TRStatusBlock: View {
    let info: TRStatusInfo
    let handler: TRAccountHandler
    var onEnterCode: () -> Void = {}
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: info.icon.rawValue).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 28, height: 28)
                    .background(iconBackground, in: RoundedRectangle(cornerRadius: 8))
                Text(info.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(TR.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                if let num = info.num {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        if let label = info.numLabel { Text(label).font(.system(size: 12)).foregroundStyle(TR.text2) }
                        Text(num).font(.system(size: 22, weight: .semibold).monospacedDigit())
                            .foregroundStyle(info.numTone == .off ? TR.text2 : info.meterTone == .warn ? TR.warn : TR.text)
                        if let denom = info.denom { Text(denom).font(.system(size: 12).monospacedDigit()).foregroundStyle(TR.text2) }
                    }
                    .lineLimit(1).fixedSize()
                }
            }
            if let meter = info.meter {
                TRMeter(value: meter, tone: info.meterTone).padding(.top, 12)
            }
            Text(info.line).font(.system(size: 13)).foregroundStyle(TR.text).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            if let fine = info.fine {
                Text(fine).font(.system(size: 12)).foregroundStyle(TR.text2).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            if !info.actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(info.actions, id: \.self) { action in button(action) }
                    if let note = note { Text(note).font(.system(size: 12)).foregroundStyle(TR.text2).lineLimit(1) }
                }
                .padding(.top, 12)
            }
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(TR.warn)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var iconColor: Color {
        switch info.tone {
        case .warn?: TR.warn
        case .off?: TR.text2
        default: TR.fix
        }
    }

    private var iconBackground: Color {
        switch info.tone {
        case .warn?: TR.markSoft
        case .off?: TR.fill
        default: TR.fixSoft
        }
    }

    private var note: String? {
        if info.actions.contains(.portal) { return "换卡、取消自动续费、看发票，在浏览器里打开" }
        if info.actions.contains(.fixCard) { return "在「管理订阅」里换，换好就恢复，不用重新订阅" }
        if info.actions.contains(.passRenew) { return "续买的接在到期日后面" }
        return nil
    }

    @ViewBuilder private func button(_ action: TRAccountAction) -> some View {
        switch action {
        case .buy:
            Button("开会员…", action: handler.openPricing).buttonStyle(TRInkButtonStyle())
        case .renew:
            Button("续上会员…", action: handler.openPricing).buttonStyle(TRInkButtonStyle())
        case .passRenew:
            Button("续买…", action: handler.openPricing).buttonStyle(TRPlainButtonStyle())
        case .enterCode:
            Button("输入授权码", action: onEnterCode).buttonStyle(TRPlainButtonStyle())
        case .portal:
            Button { run { try await handler.portal() } } label: { TRBrowserLabel(text: "管理订阅") }
                .buttonStyle(TRPlainButtonStyle()).disabled(busy)
        case .fixCard:
            Button { run { try await handler.portal() } } label: { TRBrowserLabel(text: "换一张卡") }
                .buttonStyle(TRInkButtonStyle()).disabled(busy)
        case .retry:
            Button {
                busy = true
                Task {
                    await handler.retry()
                    busy = false
                }
            } label: {
                if busy {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("正在连…") }
                } else {
                    Label("再试一次", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(TRPlainButtonStyle()).disabled(busy)
        }
    }

    /// The portal does not open: the page says why, a click never just does nothing.
    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        message = nil
        Task {
            do { try await work() } catch { message = TRAccountError.text(error) }
            busy = false
        }
    }
}

/// 等你在浏览器里付款…
struct TRPayingBox: View {
    let handler: TRAccountHandler

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView().controlSize(.small).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("等你在浏览器里付款…").font(.system(size: 13, weight: .medium)).foregroundStyle(TR.text)
                Text("付完这里自动变成会员，不用回来点什么。浏览器关掉了就点「重新打开付款页」；微信付款到账可能要一两分钟。")
                    .font(.system(size: 12)).foregroundStyle(TR.text2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(action: handler.reopenCheckout) { Label("重新打开付款页", systemImage: "arrow.up.forward.square") }
                        .buttonStyle(TRPlainButtonStyle())
                    Button("不等了", action: handler.cancelPurchase).buttonStyle(TRGhostButtonStyle())
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(TR.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TR.line, lineWidth: 0.5))
    }
}

/// 付款成功，已经是会员了 …「好」
struct TRPaidLine: View {
    let facts: TRAccountFacts
    let handler: TRAccountHandler

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(TR.fix)
            Text(text).font(.system(size: 13)).foregroundStyle(TR.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("好", action: handler.dismissPaid).buttonStyle(TRPlainButtonStyle())
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(TR.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TR.line, lineWidth: 0.5))
    }

    private var text: String {
        if facts.onPass { return "付款成功，已经是会员了。这次买的不会自动续费，到期前 7 天提醒你。" }
        if let until = MemberStatus.date(facts.status?.subscription?.periodEnd) {
            return "付款成功，已经是会员了，下次续费 \(facts.day(until))。"
        }
        return "付款成功，已经是会员了。"
    }
}

/// The license code: the code, copy, which Mac, 解绑这台; or a box to paste one into.
struct TRLicenseBox: View {
    let facts: TRAccountFacts
    let handler: TRAccountHandler
    @Binding var focusCode: Bool
    @State private var typed = ""
    @State private var changing = false
    @State private var busy = false
    @State private var message: (ok: Bool, text: String)?
    @State private var askUnbind = false
    @State private var copied = false
    @FocusState private var fieldFocused: Bool

    private var code: String? { facts.status?.code }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let code, !changing {
                row("授权码") {
                    Text(code).font(.system(size: 13).monospacedDigit()).foregroundStyle(TR.text).textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        copied = true
                    } label: { Label(copied ? "复制好了" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(TRGhostButtonStyle())
                    Spacer(minLength: 0)
                }
                Rectangle().fill(TR.line).frame(height: 0.5)
                row("用在") {
                    Text("这台 Mac").font(.system(size: 13)).foregroundStyle(TR.text)
                    Text("这台").font(.system(size: 12)).foregroundStyle(TR.text2)
                    Spacer(minLength: 8)
                    Button("解绑这台") { askUnbind = true }.buttonStyle(TRPlainButtonStyle()).disabled(busy)
                }
                fine {
                    Text("一个授权码最多用在 \(facts.status?.maxDevices ?? 2) 台 Mac 上，现在用了 \(facts.status?.devices ?? 1) 台。在另一台 Mac 上输入它就能用。")
                    Button("换一个授权码") { changing = true }.buttonStyle(.plain).underline().foregroundStyle(TR.text2)
                }
            } else {
                row(code == nil ? "输入授权码" : "换授权码") {
                    TRTextField(placeholder: "在别的 Mac 上买过？把授权码粘贴到这里", text: $typed, onSubmit: activate)
                        .focused($fieldFocused)
                    Button("粘贴") { typed = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
                        .buttonStyle(TRPlainButtonStyle())
                    Button("激活", action: activate).buttonStyle(TRPlainButtonStyle())
                        .disabled(busy || typed.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let message {
                    Text(message.text).font(.system(size: 12)).foregroundStyle(message.ok ? TR.fix : TR.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 108).padding(.trailing, 14).padding(.bottom, 6)
                }
                fine {
                    Text("授权码在付款成功页和收据邮件里，一个最多用在 2 台 Mac 上。")
                    if code != nil {
                        Button("不换了") { changing = false }.buttonStyle(.plain).underline().foregroundStyle(TR.text2)
                    }
                }
            }
        }
        .background(TR.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TR.line, lineWidth: 0.5))
        .onChange(of: focusCode) { _, wants in
            guard wants else { return }
            changing = code != nil
            fieldFocused = true
            focusCode = false
        }
        .confirmationDialog("解绑这台 Mac？", isPresented: $askUnbind) {
            Button("解绑", role: .destructive) {
                busy = true
                Task {
                    do { try await handler.unbind() } catch { message = (false, TRAccountError.text(error)) }
                    busy = false
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这台 Mac 不再用授权码 \(code ?? "")，之后只在本机查拼写和几类常见语法错。授权码空出一个位置，可以在别的 Mac 上输入；会员本身不受影响。")
        }
    }

    private func row(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 13)).foregroundStyle(TR.text).frame(width: 84, alignment: .leading)
            content()
        }
        .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 44)
    }

    private func fine(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 6) { content() }
            .font(.system(size: 12)).foregroundStyle(TR.text2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 108).padding(.trailing, 14).padding(.bottom, 12)
    }

    private func activate() {
        let code = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, !busy else { return }
        busy = true
        message = nil
        Task {
            do {
                try await handler.activate(code)
                typed = ""
                changing = false
                message = (true, "激活了，这台 Mac 用上这个授权码。")
            } catch {
                message = (false, TRAccountError.text(error))
            }
            busy = false
        }
    }
}

/// The grey sentence under the account page and the price window.
struct TRAccountFootNote: View {
    var body: some View {
        Text("会员用 AI 时，那一句经我们的服务器转给 DeepSeek，只记次数，不存你打的字。不用注册、不用登录：会员跟着授权码走。")
            .font(.system(size: 12)).foregroundStyle(TR.text2).lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 640, alignment: .leading)
    }
}

/// A heading above a group, with an optional link on the right.
struct TRSubhead<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(TR.text2)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.leading, 2)
    }
}

extension TRSubhead where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

// MARK: - 设置 › 账号与会员

/// The page bound to MemberService.
struct TRAccountSettings: View {
    @ObservedObject var member: MemberService = .shared

    var body: some View {
        TRAccountPage(facts: .current(member), justPaid: member.justPaid, handler: .live(member))
    }
}

struct TRAccountPage: View {
    let facts: TRAccountFacts
    var justPaid = false
    let handler: TRAccountHandler
    @State private var focusCode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if justPaid {
                TRPaidLine(facts: facts, handler: handler).padding(.bottom, 12)
            }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("AI 用哪种").font(.system(size: 13)).foregroundStyle(TR.text)
                        Text("拼写和几类常见语法错一直在本机查，不算次数").font(.system(size: 12)).foregroundStyle(TR.text2)
                    }
                    Spacer(minLength: 12)
                    TRSegmented(options: [(AIPlan.member, "会员"), (.own, "自带 Key"), (.local, "只用本机")],
                                selection: Binding(get: { facts.plan }, set: { handler.choose($0) }))
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                Rectangle().fill(TR.line).frame(height: 0.5)
                switch facts.plan {
                case .member:
                    TRStatusBlock(info: facts.statusInfo, handler: handler, onEnterCode: { focusCode = true })
                case .own:
                    ownBlock
                case .local:
                    localBlock
                }
            }
            .background(TR.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TR.line, lineWidth: 0.5))
            if facts.paying {
                TRSubhead(title: "付款").padding(.top, 22).padding(.bottom, 8)
                TRPayingBox(handler: handler)
            }
            TRSubhead(title: "授权码") {
                Button("看各种用法的区别和价格", action: handler.openPricing)
                    .buttonStyle(.plain).font(.system(size: 12)).underline().foregroundStyle(TR.text2)
            }
            .padding(.top, 22).padding(.bottom, 8)
            TRLicenseBox(facts: facts, handler: handler, focusCode: $focusCode)
            TRAccountFootNote().padding(.top, 14)
        }
    }

    private var ownBlock: some View {
        let provider = facts.own.provider
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "key").font(.system(size: 14, weight: .medium)).foregroundStyle(TR.fix)
                    .frame(width: 28, height: 28).background(TR.fixSoft, in: RoundedRectangle(cornerRadius: 8))
                Text("自带 Key：\(provider.displayName)").font(.system(size: 15, weight: .semibold)).foregroundStyle(TR.text)
                Spacer(minLength: 12)
                switch facts.own {
                case .ready: TRTag(text: "已填 Key", tone: .ok)
                case .missing: TRStatusDot(color: TR.warn, text: "还没填 Key")
                case .rejected: TRStatusDot(color: TR.danger, text: "Key 用不了")
                }
            }
            Text("请求直接从这台 Mac 发给 \(provider.displayName)，不经过我们，费用走你自己的账户，不限次数。")
                .font(.system(size: 13)).foregroundStyle(TR.text).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            if let note = facts.memberNote {
                Text(note).font(.system(size: 12)).foregroundStyle(TR.text2).padding(.top, 4)
            }
            Button("去「AI 服务商」换 Key 或换一家", action: handler.openProviders)
                .buttonStyle(TRPlainButtonStyle()).padding(.top, 12)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var localBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer").font(.system(size: 14, weight: .medium)).foregroundStyle(TR.text2)
                    .frame(width: 28, height: 28).background(TR.fill, in: RoundedRectangle(cornerRadius: 8))
                Text("只用本机检查").font(.system(size: 15, weight: .semibold)).foregroundStyle(TR.text)
                Spacer()
            }
            Text("拼写和几类常见语法错（像 I has、a apple、have went）在这台 Mac 上查，什么都不发出去；没有中文变英文和 AI 的整句讲解。")
                .font(.system(size: 13)).foregroundStyle(TR.text).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            if let note = facts.memberNote {
                Text(note).font(.system(size: 12)).foregroundStyle(TR.text2).padding(.top, 4)
            }
            Button("看看会员和自带 Key…", action: handler.openPricing)
                .buttonStyle(TRPlainButtonStyle()).padding(.top, 12)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// On 设置 › AI 服务商 while the member plan or on-device checks are in use.
struct TRProviderCallout: View {
    let plan: AIPlan
    let choose: (AIPlan) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 13)).foregroundStyle(TR.text2).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(plan == .member ? "现在 AI 用的是会员，这里的 Key 先不用。" : "现在只用本机检查（不用 AI），这里的 Key 先不用。")
                    .font(.system(size: 13)).foregroundStyle(TR.text)
                Text("选好一家、粘贴 Key、点「试一下」连上以后，点右边就改用它。")
                    .font(.system(size: 12)).foregroundStyle(TR.text2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("改用自带 Key") { choose(.own) }.buttonStyle(TRPlainButtonStyle()).frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(TR.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TR.line, lineWidth: 0.5))
    }
}

// MARK: - 方案和价格

/// Prices in fen / cents. The backend's /status has the real ones; before this Mac ever asked
/// (it registers only when buying), these are what the website says.
enum TRPrices {
    static let subscription: MemberStatus.Prices = ["month": ["cny": 990, "usd": 199], "year": ["cny": 9900, "usd": 1990]]
    static let pass: MemberStatus.Prices = ["month": ["cny": 990], "year": ["cny": 9900]]
}

@MainActor
final class TRPricingWindowController {
    static let shared = TRPricingWindowController()
    static let size = NSSize(width: 880, height: 760)

    private var window: NSWindow?
    private var resignObserver: NSObjectProtocol?

    func show() {
        if window == nil {
            let host = NSHostingView(rootView: TRLivePricingView(onClose: { [weak self] in self?.close() }))
            host.sizingOptions = []
            let window = TREscClosingWindow(
                contentRect: NSRect(origin: .zero, size: Self.size),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "方案和价格"
            window.contentView = host
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
            // A click on another TypeRight window closes it, like clicking outside a sheet; the
            // browser coming to the front (paying) leaves it open.
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard NSApp.isActive, let key = NSApp.keyWindow, key !== window, !(key is NSPanel) else { return }
                        window.close()
                    }
                }
            }
        }
        TRAppActivation.bringForward(window)
    }

    func close() { window?.close() }
}

/// Esc closes it (DESIGN: the price window goes with Esc or a click outside).
final class TREscClosingWindow: NSWindow {
    override func cancelOperation(_: Any?) { close() }
}

struct TRLivePricingView: View {
    @ObservedObject var member: MemberService = .shared
    let onClose: () -> Void

    var body: some View {
        TRPricingView(facts: .current(member), justPaid: member.justPaid, handler: .live(member), onClose: onClose)
    }
}

struct TRPricingView: View {
    let facts: TRAccountFacts
    var justPaid = false
    let handler: TRAccountHandler
    let onClose: () -> Void

    @State private var period = "month"
    @State private var currency = "cny"
    @State private var busy = false
    @State private var error: String?
    @State private var focusCode = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text("按 Esc 关掉").font(.system(size: 12)).foregroundStyle(TR.text3)
            }
            .padding(.horizontal, 16).frame(height: 40)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    banner
                    HStack(alignment: .top, spacing: 12) {
                        memberColumn.frame(maxWidth: .infinity)
                        ownColumn.frame(maxWidth: .infinity)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    localRow.padding(.top, 12)
                    TRSubhead(title: "授权码").padding(.top, 22).padding(.bottom, 8)
                    TRLicenseBox(facts: facts, handler: handler, focusCode: $focusCode)
                    faq.padding(.top, 20)
                    TRAccountFootNote().padding(.top, 14)
                }
                .padding(.horizontal, 30).padding(.top, 4).padding(.bottom, 28)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(TR.bg)
        .ignoresSafeArea()
    }

    private var hero: some View {
        VStack(spacing: 6) {
            Text("TypeRight：放心用英文打字").font(.system(size: 22, weight: .semibold)).foregroundStyle(TR.text)
            HStack(spacing: 8) {
                TRTag(text: "开源", ink: true)
                Text("软件开源、永久免费；会员买的是不用配置的 AI").font(.system(size: 13)).foregroundStyle(TR.text2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 16)
    }

    @ViewBuilder private var banner: some View {
        if facts.paying {
            bannerBox {
                ProgressView().controlSize(.small)
                Text("在浏览器里付款，付完这里自动生效。微信付款到账可能要一两分钟。").font(.system(size: 13)).foregroundStyle(TR.text)
                Spacer(minLength: 8)
                Button("重新打开付款页", action: handler.reopenCheckout).buttonStyle(TRPlainButtonStyle())
                Button("不等了", action: handler.cancelPurchase).buttonStyle(TRPlainButtonStyle())
            }
        } else if justPaid {
            bannerBox {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(TR.fix)
                Text(facts.onPass ? "付款成功，已经是会员了。这次买的不会自动续费，到期前 7 天提醒你。" : "付款成功，已经是会员了。")
                    .font(.system(size: 13)).foregroundStyle(TR.text)
                Spacer(minLength: 8)
                Button("好", action: handler.dismissPaid).buttonStyle(TRPlainButtonStyle())
            }
        } else if let error {
            bannerBox {
                Image(systemName: "exclamationmark.circle").font(.system(size: 13)).foregroundStyle(TR.warn)
                Text(error).font(.system(size: 13)).foregroundStyle(TR.text).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        } else if facts.offline {
            bannerBox {
                Image(systemName: "wifi.slash").font(.system(size: 13)).foregroundStyle(TR.text2)
                Text("连不上会员服务器，下面是上次的状态；付款要等联网。").font(.system(size: 13)).foregroundStyle(TR.text)
                Spacer(minLength: 0)
            }
        }
    }

    private func bannerBox(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(TR.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TR.line, lineWidth: 0.5))
            .padding(.bottom, 14)
    }

    // MARK: Columns

    /// Buying is open: the backend gave prices, or this Mac never asked (it registers on the first purchase).
    private var canBuy: Bool { facts.status == nil || facts.status?.prices != nil }

    private func price(_ prices: MemberStatus.Prices?, _ fallback: MemberStatus.Prices, _ period: String, _ currency: String) -> String? {
        (prices?[period]?[currency] ?? fallback[period]?[currency]).map { MemberText.price($0, currency) }
    }

    private var subPrice: String { price(facts.status?.prices, TRPrices.subscription, period, currency) ?? "" }
    private var passPrice: String? { price(facts.status?.passPrices, TRPrices.pass, period, "cny") }
    private var per: String { period == "month" ? "/ 月" : "/ 年" }
    private var duration: String { period == "month" ? "1 个月" : "1 年" }

    private var memberColumn: some View {
        column(main: true) {
            HStack(spacing: 6) {
                Text("会员").font(.system(size: 13, weight: .medium)).foregroundStyle(TR.text)
                TRTag(text: "推荐", ink: true)
                Spacer(minLength: 8)
                TRSegmented(options: [("cny", "¥"), ("usd", "$")], selection: $currency)
            }
            if facts.isMember {
                Text("已是会员").font(.system(size: 22, weight: .semibold)).foregroundStyle(TR.text)
                Text(facts.statusInfo.line).font(.system(size: 12)).foregroundStyle(TR.text2).fixedSize(horizontal: false, vertical: true)
                if facts.onPass {
                    TRSegmented(options: [("month", "1 个月"), ("year", "1 年")], selection: $period)
                    Button("微信续买 \(duration) \(passPrice ?? "")") { buy("pass") }
                        .buttonStyle(TRInkButtonStyle()).frame(maxWidth: .infinity).disabled(busy || facts.offline)
                    Text("接在 \(facts.day(MemberStatus.date(facts.status?.memberUntil) ?? facts.now)) 后面，天数不白过")
                        .font(.system(size: 12)).foregroundStyle(TR.text2)
                    Button("改成刷卡自动续费") { buy("sub") }.buttonStyle(TRPlainButtonStyle()).disabled(busy || facts.offline)
                } else {
                    Button { portal() } label: { TRBrowserLabel(text: "管理订阅") }
                        .buttonStyle(TRPlainButtonStyle()).disabled(busy)
                }
            } else {
                TRSegmented(options: [("month", "月付"), ("year", "年付")], selection: $period)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(subPrice).font(.system(size: 22, weight: .semibold).monospacedDigit()).foregroundStyle(TR.text)
                    Text("\(per)，自动续费").font(.system(size: 12)).foregroundStyle(TR.text2)
                }
                Text(period == "month" ? "不用申请任何 Key，买了就能用" : "年付约等于 10 个月的钱").font(.system(size: 12)).foregroundStyle(TR.text2)
                if canBuy {
                    Button("刷卡订阅 \(subPrice) \(per)") { buy("sub") }
                        .buttonStyle(TRInkButtonStyle()).disabled(busy || facts.offline || facts.paying)
                    if currency == "cny", let passPrice {
                        Button("微信一次买 \(duration) \(passPrice)") { buy("pass") }
                            .buttonStyle(TRPlainButtonStyle()).disabled(busy || facts.offline || facts.paying)
                    }
                } else {
                    Text(MemberText.detail(MemberError(code: "not-ready"))).font(.system(size: 12)).foregroundStyle(TR.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            features(["每天 500 次，\(facts.resetText) 重置", "中文变英文、整句讲解、整句翻译", "不用注册：授权码一个用 2 台 Mac",
                      currency == "cny" ? "刷卡自动续费随时取消；也能微信一次买" : "刷卡自动续费，随时取消；想用微信，切到 ¥"])
        }
    }

    private var ownColumn: some View {
        column(main: false) {
            HStack(spacing: 6) {
                Text("自带 Key").font(.system(size: 13, weight: .medium)).foregroundStyle(TR.text)
                TRTag(text: "永久免费")
                Spacer()
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("免费").font(.system(size: 22, weight: .semibold)).foregroundStyle(TR.text)
                Text("不限次数").font(.system(size: 12)).foregroundStyle(TR.text2)
            }
            Text("填你自己的 AI 服务 Key").font(.system(size: 12)).foregroundStyle(TR.text2)
            Button {
                if case .ready = facts.own { handler.choose(.own) }
                handler.openProviders()
                onClose()
            } label: {
                HStack(spacing: 6) {
                    Text(facts.plan == .own ? "在用，去改 Key" : "改用自带 Key")
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(TRPlainButtonStyle())
            features(["DeepSeek、智谱、通义等 \(CoachProvider.allCases.count) 家", "请求直接发给那家，不经过我们", "费用走你自己的账户"])
        }
    }

    private func column(main: Bool, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TR.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(main ? TR.text : TR.line, lineWidth: main ? 1.5 : 0.5))
    }

    private func features(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(TR.text3)
                    Text(line).font(.system(size: 12)).foregroundStyle(TR.text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 2)
    }

    private var localRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer").font(.system(size: 13)).foregroundStyle(TR.text2)
            Text("不想用 AI 也行：只用本机检查，拼写和几类常见语法错在这台 Mac 上查，不联网。")
                .font(.system(size: 13)).foregroundStyle(TR.text2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(facts.plan == .local ? "在用" : "改成只用本机") { handler.choose(.local) }
                .buttonStyle(TRPlainButtonStyle()).disabled(facts.plan == .local)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TR.line2, style: StrokeStyle(lineWidth: 0.5, dash: [3, 2])))
    }

    private static let questions: [(String, String)] = [
        ("一次怎么算？", "一个用到 AI 的弹框算一次：中文变英文，或一句的整句检查。拼写和几类常见语法错在本机查，不算。"),
        ("不买会员能用吗？", "能。拼写和几类常见语法错（像 I has、a apple）在本机查，一直免费；中文变英文和整句讲解也可以填自己的 AI Key，永久免费。"),
        ("怎么付钱、怎么取消？", "刷卡（人民币或美元）按月或按年自动续费，随时在「管理订阅」里取消，用到当期结束。人民币也能微信一次买 1 个月或 1 年，不自动续费。"),
        ("会员和自带 Key 有什么区别？", "会员不用去各家申请 Key，费用我们出，每天 500 次；自带 Key 永久免费、不限次数，费用走你自己的账户。随时能换。"),
        ("我打的字会被存吗？", "会员的请求经我们的服务器转给 DeepSeek，只记次数，不存内容。错题本只在你的 Mac 上。"),
        ("换电脑怎么办？", "一个授权码最多 2 台：新电脑上输入授权码就行；不用的那台在「账号与会员」里解绑。"),
    ]

    private var faq: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 28, verticalSpacing: 0) {
            ForEach(0 ..< Self.questions.count / 2, id: \.self) { row in
                GridRow {
                    question(Self.questions[row * 2])
                    question(Self.questions[row * 2 + 1])
                }
            }
        }
    }

    private func question(_ qa: (String, String)) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(qa.0).font(.system(size: 13, weight: .medium)).foregroundStyle(TR.text)
            Text(qa.1).font(.system(size: 12)).foregroundStyle(TR.text2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 10).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(alignment: .top) { Rectangle().fill(TR.line).frame(height: 0.5) }
    }

    private func buy(_ mode: String) {
        busy = true
        error = nil
        let plan = period, currency = mode == "pass" ? "cny" : currency
        Task {
            do { try await handler.buy(plan, currency, mode) } catch { self.error = TRAccountError.text(error) }
            busy = false
        }
    }

    private func portal() {
        busy = true
        error = nil
        Task {
            do { try await handler.portal() } catch { self.error = TRAccountError.text(error) }
            busy = false
        }
    }
}
