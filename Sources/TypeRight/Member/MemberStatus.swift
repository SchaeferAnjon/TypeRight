//
//  MemberStatus.swift
//  TypeRight
//
//  What the membership backend says (meetcaption-server docs/multi-product.md §4, product `typeright`),
//  its errors in plain Chinese, and the state the settings page and the coach go by.
//  Ported from GetNewWord's MemberService.swift (same author, GPL-3.0); the sync parts are left out.
//

import Foundation

// MARK: - GET /v1/typeright/status

struct MemberStatus: Codable, Equatable, Sendable {
    struct Trial: Codable, Equatable, Sendable {
        var granted = false
        var total = 0
        var used = 0
        var left = 0
    }

    struct Subscription: Codable, Equatable, Sendable {
        var status: String
        var plan: String?
        var currency: String?
        var amount: Int?
        var periodEnd: Double?
        var cancelAtPeriodEnd: Bool?
        var accessUntil: Double?
    }

    struct Pass: Codable, Equatable, Sendable {
        var plan: String?
        var currency: String?
        var amount: Int?
        var status: String?
        var startAt: Double?
        var until: Double?
    }

    struct Today: Codable, Equatable, Sendable {
        var limit: Int
        var used: Int
        var left: Int
        var resetAt: Double
    }

    /// {"month": {"cny": 990, "usd": 199}, "year": {…}}; amounts in fen / cents.
    typealias Prices = [String: [String: Int]]

    /// trial (trial uses left) / member (subscription or one-time pass running) / none
    var plan = "none"
    /// The license code (TR-XXXX-XXXX-XXXX); nil while this Mac only has its own trial.
    var code: String?
    var devices = 1
    var maxDevices = 2
    var trialOnly = true
    var trial = Trial()
    var subscription: Subscription?
    var pass: Pass?
    /// Milliseconds; when membership (subscription and passes together) runs out.
    var memberUntil: Double?
    var autoRenew = false
    /// Member, not renewing by itself, less than 3 days left: offer to buy again.
    var expiring = false
    /// Members only: today's uses (UTC day, 500 a day).
    var today: Today?
    var canUse = true
    /// When canUse is false: trial-used-up / trial-closed / sub-ended / payment-failed / daily-limit
    var reason: String?
    /// With daily-limit: uses (today's count used up) or cost (this license's cost cap for today).
    var limitBy: String?
    /// With daily-limit: when it resets (milliseconds, next UTC midnight).
    var resetAt: Double?
    /// What this Mac got when it registered: granted / closed / ip-limit / daily-limit / none.
    var trialResult: String?
    var prices: Prices?
    var passPrices: Prices?
    var now: Double = 0

    init() {}

    /// Missing fields get defaults, so a backend that adds or drops a field does not lose the whole status.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
        func opt<T: Decodable>(_ key: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil }
        plan = get(.plan, "none")
        code = opt(.code)
        devices = get(.devices, 1)
        maxDevices = get(.maxDevices, 2)
        trialOnly = get(.trialOnly, true)
        trial = get(.trial, Trial())
        subscription = opt(.subscription)
        pass = opt(.pass)
        memberUntil = opt(.memberUntil)
        autoRenew = get(.autoRenew, false)
        expiring = get(.expiring, false)
        today = opt(.today)
        canUse = get(.canUse, true)
        reason = opt(.reason)
        limitBy = opt(.limitBy)
        resetAt = opt(.resetAt)
        trialResult = opt(.trialResult)
        prices = opt(.prices)
        passPrices = opt(.passPrices)
        now = get(.now, 0)
    }

    var isMember: Bool { plan == "member" }

    static func date(_ ms: Double?) -> Date? { ms.map { Date(timeIntervalSince1970: $0 / 1000) } }

    /// The registration reply: `trial` is what this registration got (granted / existing / closed /
    /// ip-limit / daily-limit); the counts are in `trialUses`.
    static func registration(from data: Data) throws -> (token: String, trial: String, status: MemberStatus) {
        guard var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String, !token.isEmpty else { throw MemberError.badReply }
        let result = obj["trial"] as? String ?? ""
        obj["trial"] = obj["trialUses"]
        guard let status = try? JSONDecoder().decode(MemberStatus.self, from: JSONSerialization.data(withJSONObject: obj)) else {
            throw MemberError.badReply
        }
        return (token, result, status)
    }
}

// MARK: - Errors

/// A backend error ({"error": {"code", "message", "resetAt"}}) or no answer at all. `code` is the
/// backend's code (§4.0); network, unavailable and bad-reply are ours.
struct MemberError: LocalizedError, Equatable, Sendable {
    var code: String
    /// The backend's own words, shown only for codes we have no text for.
    var message = ""
    var status = 0
    var resetAt: Date?
    var retryAfter: Double?
    /// Filled in from this Mac's status before showing (MemberService.explain): why no trial was
    /// granted, until when a one-time pass runs, and whether a daily limit is the cost cap.
    var miss: TrialMiss?
    var until: Date?
    var costCap = false

    static let network = MemberError(code: "network")
    static let unavailable = MemberError(code: "unavailable")
    static let badReply = MemberError(code: "bad-reply")

    /// What an AI card gets back when it cannot use the trial or membership; the coach logs it and,
    /// for now, shows nothing.
    enum Kind: Equatable, Sendable {
        /// No uses left: trial used up, no trial granted, or membership ended. Subscribe or use an own key.
        case usedUp
        /// Renewal could not be charged; fixing the card in the customer portal brings it back.
        case paymentFailed
        /// Today's 500 are used, or this license reached today's cost cap; `resetAt` says when it comes back.
        case dailyLimit
        /// Our backend could not be reached (no network, timeout).
        case offline
        /// The device token was rejected and could not be renewed this time.
        case tokenExpired
        /// Should pass by itself: the AI behind the backend, too many requests, a full day for everyone,
        /// or this card already used its requests.
        case busy
        /// A debug build not pointed at a backend.
        case unavailable
        /// Anything else (a bad request is a bug on our side).
        case other
    }

    var kind: Kind {
        switch code {
        case "trial-used-up", "trial-closed", "sub-ended": .usedUp
        case "payment-failed": .paymentFailed
        case "daily-limit": .dailyLimit
        case "network": .offline
        case "bad-device", "re-register-limit": .tokenExpired
        case "upstream", "busy", "rate", "too-fast", "use-limit", "use-expired": .busy
        case "unavailable": .unavailable
        default: code == "http" && status >= 500 ? .busy : .other
        }
    }

    static func from(status: Int, body: Data, headers: [String: String] = [:]) -> MemberError {
        let obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        let retry = headers.first { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame }.flatMap { Double($0.value) }
        // When the AI behind the backend answers 400, the backend passes its words on as the message.
        var message = obj?["message"] as? String ?? ""
        if let inner = ((try? JSONSerialization.jsonObject(with: Data(message.utf8))) as? [String: Any])?["error"] as? [String: Any],
           let text = inner["message"] as? String, !text.isEmpty
        {
            message = text
        }
        return MemberError(code: obj?["code"] as? String ?? "http", message: message,
                           status: status, resetAt: MemberStatus.date(obj?["resetAt"] as? Double), retryAfter: retry)
    }

    /// The AI provider's content review turned the text down (DeepSeek 400 "Content Exists Risk").
    var isContentRisk: Bool { code == "bad-request" && message.localizedCaseInsensitiveContains("content exists risk") }

    /// Sending the same card again soon (same use number) may work.
    var isRetryable: Bool {
        switch code {
        case "upstream", "rate", "too-fast": true
        default: code == "http" && status >= 500
        }
    }

    /// The trial or today's count changed: ask for the status again.
    var changesStatus: Bool {
        ["trial-used-up", "trial-closed", "sub-ended", "payment-failed", "daily-limit"].contains(code)
    }

    var errorDescription: String? { MemberText.detail(self) }
}

// MARK: - Words for people

enum MemberText {
    static func title(_ e: MemberError) -> String {
        switch e.code {
        case "trial-used-up": "免费次数用完了"
        case "trial-closed": e.miss == .full ? "免费名额已经发完了" : "这台 Mac 没领到免费次数"
        case "sub-ended": "会员到期了"
        case "payment-failed": "续费没扣成"
        case "daily-limit": e.costCap ? "今天的用量到上限了" : "今天的次数用完了"
        case "use-limit": "这次检查请求太多了"
        case "use-expired": "这次检查过期了"
        case "busy": "会员 AI 今天太忙"
        case "upstream": "会员 AI 暂时连不上"
        case "rate", "too-fast": "用得太快了"
        case "network": "连不上会员服务器"
        case "unavailable": "调试版没连会员服务器"
        case "bad-device": "这台 Mac 的登记失效了"
        case "re-register-limit": "这台 Mac 重新登记太多次了"
        case "bad-code": "授权码不对"
        case "too-many-devices": "授权码已经用在 2 台电脑上"
        case "already-subscribed": "已经开了自动续费"
        case "pass-active": "一次买的会员还没到期"
        case "already-paid": "上一个付款页已经付好了"
        case "payment-pending": "上一笔付款还在确认"
        case "not-ready": "购买还没开通"
        case "portal-not-ready", "portal-upstream": "管理订阅暂时打不开"
        case "pay-upstream": "付款页暂时打不开"
        case "no-customer": "还没有订阅过"
        case "bad-request" where e.isContentRisk: "AI 不肯看这句话"
        default: "会员服务这次出错了"
        }
    }

    static func detail(_ e: MemberError) -> String {
        switch e.code {
        case "trial-used-up": return "订阅会员接着用；也可以填自己的 AI Key，永久免费。拼写照样在本机查。"
        case "trial-closed":
            switch e.miss {
            case .full: return "前 100 台新 Mac 的免费次数已经发完，这台没领到。订阅会员，或者填自己的 AI Key 免费用。"
            case .network: return "登记那天同一个网络里领的人太多，这台 Mac 没领到。订阅会员，或者填自己的 AI Key 免费用。"
            case .dayFull: return "登记那天领的人太多，当天的份数发完了，这台 Mac 没领到。订阅会员，或者填自己的 AI Key 免费用。"
            default: return "这台 Mac 登记时没领到免费次数。订阅会员，或者填自己的 AI Key 免费用。"
            }
        case "sub-ended": return "续订或再买一段就能接着用；也可以填自己的 AI Key 免费用。"
        case "payment-failed": return "上一期的续费没扣成。打开「管理订阅」换一张卡，换好马上恢复。"
        case "daily-limit":
            let when = e.resetAt.map { "\($0.formatted(date: .omitted, time: .shortened)) 恢复（你这里的时间）" } ?? "北京时间早上 8 点恢复"
            return e.costCap ? "今天用的 AI 量到上限了（句子很长时会比次数先到）。\(when)。" : "\(when)，到时候接着用。"
        case "use-limit": return "这一句请求了太多次，跳过它，接着打下一句就行。"
        case "use-expired": return "这次检查等得太久了，接着打下一句就行。"
        case "busy": return "今天用的人太多，过一会儿再试。"
        case "upstream": return "我们这边的 AI 服务暂时不通，不是你的问题。过一会儿再试。"
        case "rate", "too-fast": return "等几秒再接着打。"
        case "network": return "检查一下网络。拼写照样在本机查。"
        case "unavailable": return "调试版要设环境变量 TYPERIGHT_API，或 defaults 里的 typeright.api，指到本机后台才连会员服务器；也可以先用自带 Key。"
        case "bad-device": return "会员服务器不认这台 Mac 的登记了，重新登记也没成功。过一会儿再试。"
        case "re-register-limit": return e.message.isEmpty ? "这台 Mac 24 小时里重新登记太多次了，过几个小时再试。" : e.message
        case "bad-code": return "不是 TypeRight 的授权码，核对一下再试（TR- 开头）。"
        case "too-many-devices": return "一个授权码最多用在 2 台电脑上。先在另一台上解绑，再在这台输入。"
        case "already-subscribed": return "要改月付年付、取消或换卡，打开「管理订阅」。一次买要先在那里取消自动续费。"
        case "pass-active":
            if let until = e.until { return "一次买的会员用到 \(day(until))。到期前 3 天再开自动续费，接着用不断档。" }
            return e.message.isEmpty ? "到期前 3 天再开自动续费，接着用不断档。" : e.message
        case "already-paid": return "会员已经开通，不用再付。"
        case "payment-pending": return "微信有时要等一两分钟，到账后会自动生效，不用再买。"
        case "not-ready": return "收款还没配好，过一阵再来；现在可以先用自带 Key。"
        case "portal-not-ready": return "付款服务这边还没配好，过一阵再试。会员照常能用。"
        case "portal-upstream": return "付款服务暂时连不上，过一会儿再试。会员照常能用。"
        case "pay-upstream": return "付款服务暂时连不上，过一会儿再点一次。"
        case "no-customer": return "这个授权还没有订阅过，没有可以管理的订阅。"
        case "bad-reply": return "会员服务器回的内容读不懂，过一会儿再试。"
        case "bad-request" where e.isContentRisk: return "这句话没过 AI 服务商的内容审核，跳过它就行。"
        default: return e.message.isEmpty ? "过一会儿再试。（HTTP \(e.status)）" : e.message
        }
    }

    /// Amount in fen / cents → ¥9.9 / $1.99
    static func price(_ amount: Int, _ currency: String) -> String {
        let value = Double(amount) / 100
        let text = value == value.rounded() ? String(Int(value)) : String(format: currency == "usd" ? "%.2f" : "%.1f", value)
        return (currency == "usd" ? "$" : "¥") + text
    }

    static func day(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }
}

// MARK: - The state the settings page and the coach go by

/// Why no trial was granted: what the backend said at registration (closed / ip-limit / daily-limit).
enum TrialMiss: Equatable, Sendable {
    /// The first 100 Macs already got theirs.
    case full
    /// Too many from the same network that day (ip-limit).
    case network
    /// Too many everywhere that day (daily-limit).
    case dayFull
    /// Not known, for example after registering again (the backend then only says existing).
    case unknown

    static func of(_ trialResult: String?) -> TrialMiss {
        switch trialResult {
        case "closed": .full
        case "ip-limit": .network
        case "daily-limit": .dayFull
        default: .unknown
        }
    }
}

enum MemberState: Equatable, Sendable {
    /// A debug build not pointed at a backend.
    case unavailable
    /// Not registered yet: the first AI card (or choosing the member plan, buying, entering a code) registers and claims the trial.
    case notClaimed
    /// Registered, no status yet, asking.
    case connecting
    /// Registered, no status yet, and the backend could not be reached.
    case offline
    case trial(left: Int, total: Int)
    case trialUsedUp
    /// No trial was granted.
    case trialClosed(TrialMiss)
    case member(until: Date?, autoRenew: Bool, expiring: Bool, pastDue: Bool, todayLeft: Int?, limit: Int?)
    case dailyLimit(reset: Date?)
    case paymentFailed
    case ended

    /// registered: this Mac has a device token (or is getting one). trialResult: what this Mac
    /// remembers from registering; the backend's own trialResult wins when /status has it.
    static func of(_ status: MemberStatus?, available: Bool, failed: Bool, trialResult: String?, registered: Bool = true, now: Date = Date()) -> MemberState {
        guard available else { return .unavailable }
        guard let s = status else { return !registered ? .notClaimed : failed ? .offline : .connecting }
        // Daily limits (members' 500, or this license's cost cap, which trials hit too) end at their reset time.
        let reset = MemberStatus.date(s.resetAt ?? s.today?.resetAt)
        if s.reason == "daily-limit", s.isMember || s.limitBy == "cost", (reset ?? .distantFuture) > now { return .dailyLimit(reset: reset) }
        if s.isMember {
            // Renewing: the next charge (end of the period). Otherwise: until when it runs (with the grace of a failed renewal).
            let until = s.autoRenew ? MemberStatus.date(s.subscription?.periodEnd ?? s.memberUntil) : MemberStatus.date(s.memberUntil)
            return .member(until: until, autoRenew: s.autoRenew, expiring: s.expiring,
                           pastDue: s.subscription?.status == "past_due", todayLeft: s.today?.left, limit: s.today?.limit)
        }
        if s.plan == "trial", s.trial.left > 0 { return .trial(left: s.trial.left, total: s.trial.total) }
        switch s.reason {
        case "payment-failed": return .paymentFailed
        case "sub-ended": return .ended
        case "trial-closed": return .trialClosed(.of(s.trialResult ?? trialResult))
        default: return s.trial.granted ? .trialUsedUp : .trialClosed(.of(s.trialResult ?? trialResult))
        }
    }

    /// AI cards cannot go through the backend now (the backend has the last word; this only avoids asking in vain).
    var blocked: Bool {
        switch self {
        case .trialUsedUp, .trialClosed, .dailyLimit, .paymentFailed, .ended, .unavailable: true
        case .notClaimed, .connecting, .offline, .trial, .member: false
        }
    }

    /// The error code a blocked state stands for (to show the same words as the backend's error).
    var blockCode: String? {
        switch self {
        case .trialUsedUp: "trial-used-up"
        case .trialClosed: "trial-closed"
        case .dailyLimit: "daily-limit"
        case .paymentFailed: "payment-failed"
        case .ended: "sub-ended"
        case .unavailable: "unavailable"
        case .notClaimed, .connecting, .offline, .trial, .member: nil
        }
    }
}
