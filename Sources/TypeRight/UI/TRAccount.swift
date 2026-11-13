//
//  TRAccount.swift
//  TypeRight
//
//  What the membership surfaces say (design/membership/redesign, direction B «单开价格页»): the
//  page header of 账号与会员, its status block, the plan card at the bottom of the settings and
//  main window sidebars, the menu's AI line and its dot. All of it is worked out here from the plan
//  and MemberService's state, so every state is tested without a window or a backend. There is no
//  trial: without a membership the member plan only checks spelling and grammar on this Mac.
//

import Foundation

/// How a status reads: green in use, amber something to look at, grey off, red a key turned down,
/// a spinner while waiting for a payment.
enum TRTone: Equatable {
    case ok, warn, off, danger, wait
}

/// The buttons the status block can carry.
enum TRAccountAction: Equatable {
    /// 开会员…: opens the price window (the one solid button).
    case buy
    /// 续上会员…: the membership ended; opens the price window (solid).
    case renew
    /// 续买…: a one-time pass; opens the price window.
    case passRenew
    /// 输入授权码: moves to the license code box.
    case enterCode
    /// 管理订阅: Stripe's customer portal in the browser.
    case portal
    /// 换一张卡: the renewal was not charged; the portal, as the solid button.
    case fixCard
    /// 再试一次: ask the backend again.
    case retry
}

/// The block at the top of 账号与会员 while the member plan is chosen.
struct TRStatusInfo: Equatable {
    enum Icon: String {
        case spark = "sparkles"
        case seal = "checkmark.seal"
        case alert = "exclamationmark.circle"
        case card = "creditcard"
        case offline = "wifi.slash"
    }

    var icon: Icon
    /// nil: the usual green; warn or off otherwise.
    var tone: TRTone?
    var title: String
    /// 今天 / 上次 10:42, the count and what it counts.
    var numLabel: String?
    var num: String?
    var denom: String?
    var numTone: TRTone?
    /// 0…1 for the thin bar, nil for none.
    var meter: Double?
    var meterTone: TRTone = .ok
    var line: String
    var fine: String?
    var actions: [TRAccountAction] = []
}

/// The card at the bottom of the sidebars: which way TypeRight works now, in two lines.
struct TRPlanCardInfo: Equatable {
    var icon: String
    var tone: TRTone
    var title: String
    var count: String?
    var countWarn = false
    var meter: Double?
    var meterTone: TRTone = .ok
    var detail: String
}

struct TRAccountFacts: Equatable {
    enum OwnKey: Equatable {
        case ready(CoachProvider)
        case missing(CoachProvider)
        case rejected(CoachProvider)

        var provider: CoachProvider {
            switch self {
            case let .ready(p), let .missing(p), let .rejected(p): p
            }
        }
    }

    var plan: AIPlan
    var state: MemberState
    var status: MemberStatus?
    /// The last request to the backend found no network.
    var offline = false
    /// When the status was last read (the offline block says 上次 10:42).
    var checkedAt: Date?
    var paying = false
    var own: OwnKey
    var now = Date()
    var calendar = Calendar.current
    var timeZone = TimeZone.current

    @MainActor
    static func current(_ member: MemberService = .shared, now: Date = Date()) -> TRAccountFacts {
        let provider = CoachSettings.provider
        let own: OwnKey = member.keyRejected(provider) ? .rejected(provider) : member.ownKey() != nil ? .ready(provider) : .missing(provider)
        return TRAccountFacts(plan: member.plan, state: member.state, status: member.status, offline: member.offline,
                              checkedAt: member.checkedAt, paying: member.purchase != nil, own: own, now: now)
    }

    // MARK: Pieces of text

    private var limit: Int { status?.today?.limit ?? 500 }

    private var todayUsed: Int? {
        guard let today = status?.today else { return nil }
        return max(0, today.limit - today.left)
    }

    /// When today's count comes back, in this Mac's time (the next UTC midnight).
    var resetText: String {
        var reset: Date?
        if case let .dailyLimit(at) = state { reset = at }
        reset = reset ?? MemberStatus.date(status?.resetAt ?? status?.today?.resetAt)
        if reset == nil || (reset ?? now) <= now {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            reset = utc.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)
        }
        return clock(reset ?? now)
    }

    func clock(_ date: Date) -> String {
        let parts = calendar.dateComponents(in: timeZone, from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// 12 月 11 日, with the year when it is not this year.
    func day(_ date: Date) -> String {
        let d = calendar.dateComponents(in: timeZone, from: date)
        let thisYear = calendar.dateComponents(in: timeZone, from: now).year
        let md = "\(d.month ?? 1) 月 \(d.day ?? 1) 日"
        return d.year == thisYear ? md : "\(d.year ?? 0) 年 \(md)"
    }

    private var untilDate: Date? {
        if case let .member(until, _, _, _, _, _) = state { return until }
        return MemberStatus.date(status?.memberUntil)
    }

    private var untilText: String { untilDate.map(day) ?? "到期日" }

    /// A renewal not charged: until when the membership still runs (the grace, not the next period).
    private var graceText: String { MemberStatus.date(status?.memberUntil).map(day) ?? untilText }

    /// What the next renewal charges: ¥9.9, $19.90.
    private var renewalPrice: String? {
        guard let sub = status?.subscription, let amount = sub.amount, let currency = sub.currency else { return nil }
        return MemberText.price(amount, currency)
    }

    private enum Kind { case month, year, pass, cancelled }

    private var kind: Kind {
        if case let .member(_, autoRenew, _, _, _, _) = state, !autoRenew {
            return status?.subscription?.cancelAtPeriodEnd == true ? .cancelled : .pass
        }
        return status?.subscription?.plan == "year" ? .year : .month
    }

    private var kindTitle: String {
        switch kind {
        case .month: "会员，月付"
        case .year: "会员，年付"
        case .pass: "会员，微信一次买"
        case .cancelled: status?.subscription?.plan == "year" ? "会员，年付" : "会员，月付"
        }
    }

    private var costCap: Bool { status?.reason == "daily-limit" && status?.limitBy == "cost" }

    private var isOffline: Bool {
        guard plan == .member, state != .unavailable else { return false }
        return offline || state == .offline
    }

    /// Something is waiting for the user: the menu bar icon gets its amber dot, the sidebar's
    /// 账号与会员 row a dot, the plan card an amber icon.
    var needsAttention: Bool {
        let tone = menuLine.tone
        return tone == .warn || tone == .danger
    }

    // MARK: The menu's AI line

    var menuLine: (tone: TRTone, text: String) {
        if paying { return (.wait, "AI：等你在浏览器里付款…") }
        switch plan {
        case .local:
            return (.off, "AI：没开，只在本机查拼写语法")
        case .own:
            switch own {
            case let .ready(p): return (.ok, "AI：自带 Key（\(p.displayName)）")
            case let .missing(p): return (.warn, "AI：还没填 \(p.displayName) 的 Key，只查拼写语法")
            case let .rejected(p): return (.danger, "AI：\(p.displayName) 的 Key 用不了")
            }
        case .member:
            if isOffline { return (.warn, "AI：没连上网，先只查拼写语法") }
            switch state {
            case .unavailable: return (.off, "AI：调试版没连会员服务器")
            case .noMember: return (.warn, "AI：还没开会员，只查拼写语法")
            case .connecting, .offline: return (.off, "AI：会员，正在连…")
            case let .member(_, _, expiring, pastDue, _, _):
                if pastDue { return (.warn, "AI：续费没扣成，\(graceText)前换卡") }
                if expiring { return (.warn, "AI：会员 \(untilText)到期") }
                return (.ok, todayUsed.map { "AI：会员，今天 \($0) / \(limit) 次" } ?? "AI：会员")
            case .dailyLimit:
                return (.warn, costCap ? "AI：今天的用量到上限了，\(resetText) 恢复" : "AI：今天 \(limit) 次用完了，\(resetText) 恢复")
            case .paymentFailed: return (.warn, "AI：续费没扣成，只查拼写语法")
            case .ended: return (.warn, "AI：会员到期了，只查拼写语法")
            }
        }
    }

    // MARK: 现在：… (the page header)

    var nowLine: String {
        if paying { return "等你在浏览器里付款" }
        switch plan {
        case .local:
            return "只用本机检查，不联网"
        case .own:
            switch own {
            case let .ready(p): return "自带 Key，用 \(p.displayName)"
            case let .missing(p): return "自带 Key，还没填 \(p.displayName) 的 Key"
            case let .rejected(p): return "自带 Key，\(p.displayName) 的 Key 用不了"
            }
        case .member:
            if isOffline {
                return todayUsed.map { "会员（没连上，上次今天用了 \($0) / \(limit) 次）" } ?? "会员（没连上会员服务器）"
            }
            switch state {
            case .unavailable: return "调试版没连会员服务器"
            case .noMember: return "还没开会员，现在只查拼写语法"
            case .connecting, .offline: return "会员，正在连…"
            case let .member(_, _, _, pastDue, _, _):
                if pastDue { return "会员，续费没扣成" }
                switch kind {
                case .pass, .cancelled: return "会员，用到 \(untilText)"
                case .month: return todayUsed.map { "会员（月付），今天用了 \($0) / \(limit) 次" } ?? "会员（月付）"
                case .year: return todayUsed.map { "会员（年付），今天用了 \($0) / \(limit) 次" } ?? "会员（年付）"
                }
            case .dailyLimit: return "会员，今天 \(limit) 次用完了，\(resetText) 恢复"
            case .paymentFailed: return "续费没扣成，现在只查拼写语法"
            case .ended: return "会员到期了，现在只查拼写语法"
            }
        }
    }

    // MARK: The plan card

    var planCard: TRPlanCardInfo {
        if paying { return TRPlanCardInfo(icon: "", tone: .wait, title: "等你付款…", detail: "付完自动生效") }
        switch plan {
        case .local:
            return TRPlanCardInfo(icon: "laptopcomputer", tone: .off, title: "只用本机检查", detail: "不联网，只查拼写语法")
        case .own:
            switch own {
            case let .ready(p): return TRPlanCardInfo(icon: "key", tone: .off, title: "自带 Key", detail: "\(p.displayName)，永久免费")
            case let .missing(p): return TRPlanCardInfo(icon: "key", tone: .warn, title: "自带 Key", detail: "还没填 \(p.displayName) 的 Key")
            case let .rejected(p): return TRPlanCardInfo(icon: "key", tone: .warn, title: "自带 Key", detail: "\(p.displayName) 的 Key 用不了")
            }
        case .member:
            let count = todayUsed.map { "今天 \($0) / \(limit)" }
            let meter = todayUsed.map { Double($0) / Double(max(limit, 1)) }
            if isOffline {
                return TRPlanCardInfo(icon: "wifi.slash", tone: .off, title: "会员", count: count, meter: meter, meterTone: .off,
                                      detail: "没连上，联网后自己接上")
            }
            switch state {
            case .unavailable:
                return TRPlanCardInfo(icon: "sparkles", tone: .off, title: "会员", detail: "调试版没连会员服务器")
            case .noMember:
                return TRPlanCardInfo(icon: "exclamationmark.circle", tone: .warn, title: "还没开会员", detail: "开会员，或改用自带 Key")
            case .connecting, .offline:
                return TRPlanCardInfo(icon: "sparkles", tone: .ok, title: "会员", detail: "正在连…")
            case let .member(_, _, expiring, pastDue, _, _):
                if pastDue {
                    return TRPlanCardInfo(icon: "creditcard", tone: .warn, title: "续费没扣成", detail: "\(graceText)前换一张卡")
                }
                let detail = switch kind {
                case .month, .year: "自动续费，下次 \(untilText)"
                case .pass: "用到 \(untilText)，不续费"
                case .cancelled: "已取消续费，用到 \(untilText)"
                }
                return TRPlanCardInfo(icon: "checkmark.seal", tone: expiring ? .warn : .ok, title: "会员", count: count, meter: meter, detail: detail)
            case .dailyLimit:
                return TRPlanCardInfo(icon: "checkmark.seal", tone: .warn, title: "今天用完了", count: "\(limit) / \(limit)", countWarn: true,
                                      meter: 1, meterTone: .warn, detail: "\(resetText) 恢复")
            case .paymentFailed:
                return TRPlanCardInfo(icon: "creditcard", tone: .warn, title: "续费没扣成", detail: "换一张卡就恢复")
            case .ended:
                return TRPlanCardInfo(icon: "exclamationmark.circle", tone: .warn, title: "会员到期了", detail: "续上，或改用自带 Key")
            }
        }
    }

    // MARK: The status block (member plan)

    static let perUse = "一次 = 一个用到 AI 的弹框：中文变英文，或查一整句。拼写和几类常见语法错在本机查，不算次数。"

    var statusInfo: TRStatusInfo {
        var info = baseStatus
        if paying { info.actions = [] }
        return info
    }

    private var baseStatus: TRStatusInfo {
        let used = todayUsed
        let meter = used.map { Double($0) / Double(max(limit, 1)) }
        if isOffline {
            return TRStatusInfo(icon: .offline, tone: .off, title: "没连上会员服务器",
                                numLabel: used == nil ? nil : checkedAt.map { "上次 \(clock($0))" } ?? "上次",
                                num: used.map(String.init), denom: used == nil ? nil : "/ \(limit) 次", numTone: .off,
                                meter: meter, meterTone: .off,
                                line: "联网后自己接上。这之前 AI 先停，拼写和几类常见语法错照样在本机查。", actions: [.retry])
        }
        switch state {
        case .unavailable:
            return TRStatusInfo(icon: .alert, tone: .off, title: "调试版没连会员服务器", line: MemberText.detail(.unavailable))
        case .noMember:
            return TRStatusInfo(icon: .alert, tone: .warn, title: "还没开会员",
                                line: "开会员就能用中文变英文和整句讲解：不用申请 Key，每天 \(limit) 次。也可以改用自带 Key，永久免费。现在只在本机查拼写和几类常见语法错。",
                                fine: Self.perUse, actions: [.buy, .enterCode])
        case .connecting, .offline:
            return TRStatusInfo(icon: .spark, title: "会员", line: "正在连会员服务器…")
        case let .member(_, _, expiring, pastDue, _, _):
            let num = used.map(String.init)
            let denom = used == nil ? nil : "/ \(limit) 次"
            if pastDue {
                let price = renewalPrice.map { "这一期 \($0)" } ?? "这一期"
                return TRStatusInfo(icon: .card, tone: .warn, title: "续费没扣成", numLabel: used == nil ? nil : "今天", num: num, denom: denom,
                                    meter: meter, line: "\(price) 没扣成，会员先照常用。\(graceText)前在「管理订阅」里换一张卡就不会断。",
                                    actions: [.fixCard])
            }
            let line: String
            var actions: [TRAccountAction]
            switch kind {
            case .month, .year:
                let price = renewalPrice.map { "扣 \($0)" } ?? "续费"
                line = "自动续费，下次 \(untilText)\(price)。每天 \(limit) 次，\(resetText) 重置。"
                actions = [.portal]
            case .cancelled:
                line = "已取消自动续费，用到 \(untilText)，之后不再扣钱。每天 \(limit) 次，\(resetText) 重置。"
                actions = [.portal]
            case .pass:
                line = expiring ? "用到 \(untilText)，不会自动续费。续买的接在后面，天数不白过。"
                    : "用到 \(untilText)，不会自动续费；到期前 7 天提醒你续买。"
                actions = [.passRenew]
            }
            return TRStatusInfo(icon: .seal, tone: expiring ? .warn : nil, title: kindTitle, numLabel: used == nil ? nil : "今天", num: num, denom: denom,
                                meter: meter, line: line, actions: actions)
        case .dailyLimit:
            let line = costCap
                ? "今天用的 AI 量到上限了（句子很长时会比次数先到），\(resetText) 恢复。这之前拼写和几类常见语法错照样查。"
                : "今天的 \(limit) 次用完了，\(resetText) 恢复。这之前拼写和几类常见语法错照样查。"
            return TRStatusInfo(icon: .seal, title: kindTitle, numLabel: "今天", num: String(used ?? limit), denom: "/ \(limit) 次",
                                meter: 1, meterTone: .warn, line: line, actions: status?.autoRenew == true ? [.portal] : [])
        case .paymentFailed:
            return TRStatusInfo(icon: .card, tone: .warn, title: "续费没扣成，会员停了",
                                line: "上一期没扣成，现在只在本机查拼写和几类常见语法错。在「管理订阅」里换一张卡就恢复，授权码不变。",
                                actions: [.fixCard])
        case .ended:
            let title = MemberStatus.date(status?.memberUntil).map { "会员 \(day($0))到期了" } ?? "会员到期了"
            return TRStatusInfo(icon: .alert, tone: .warn, title: title,
                                line: "现在只在本机查拼写和几类常见语法错。续上会员就回来，授权码不变。", actions: [.renew, .enterCode])
        }
    }

    /// Under 自带 Key and 只用本机 on the account page: what the membership is doing meanwhile.
    var memberNote: String? {
        switch state {
        case .member, .dailyLimit: "你的会员还在，选回「会员」就用会员的次数。"
        default: nil
        }
    }

    /// The membership is running (the price window shows 已是会员 instead of the prices).
    var isMember: Bool {
        switch state {
        case .member, .dailyLimit: true
        default: false
        }
    }

    /// A one-time pass is what keeps the membership going (the price window offers 微信续买).
    var onPass: Bool { isMember && status?.autoRenew != true && status?.subscription?.cancelAtPeriodEnd != true }
}
