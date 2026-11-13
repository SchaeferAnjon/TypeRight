//
//  CoachNotice.swift
//  TypeRight
//
//  When the member plan cannot use the AI (no membership, ended, renewal not charged, today's 500
//  used, no network), a Chinese word typed gets no English. The first time, a notice card says so
//  next to the word, in the same place and look as any card: what happened, that spelling and some
//  common grammar mistakes are still checked on this Mac, and what to do. After that the same thing only gets a small capsule
//  under the word («没翻：…») that goes by itself (design/membership/redesign, «一件事只说一次»).
//  The notice takes no Tab (it has nothing to write); Esc closes it, typing on makes it step aside,
//  its buttons are for the mouse.
//

import Foundation

struct CoachNotice: Equatable {
    enum Issue: String, CaseIterable, Sendable {
        case noMember, ended, paymentFailed, dailyLimit, offline
    }

    /// What a notice card's button opens.
    enum Action: Equatable, Sendable {
        /// The 方案和价格 window.
        case pricing
        /// 设置 › AI 服务商.
        case ownKey
        /// 设置 › 账号与会员.
        case account
    }

    struct Link: Equatable {
        var action: Action
        var label: String
    }

    var issue: Issue
    var title: String
    var body: String
    var links: [Link]
    /// The capsule's words after the first time.
    var pill: String

    /// The notice for `word` (the Chinese that was not turned into English). `facts` gives the dates;
    /// without it (tests) the words leave them out.
    static func of(_ issue: Issue, word: String, facts: TRAccountFacts?) -> CoachNotice {
        let missed = "「\(word)」这次没翻成英文。"
        let reset = facts?.resetText
        switch issue {
        case .noMember:
            return CoachNotice(issue: issue, title: "还没开会员",
                               body: missed + "拼写和几类常见语法错照样在本机查；想用中文变英文和整句讲解，可以开会员，或填自己的 Key（永久免费）。",
                               links: [Link(action: .pricing, label: "看看会员"), Link(action: .ownKey, label: "填 Key")],
                               pill: "没翻：还没开会员")
        case .ended:
            let until = (facts?.status?.memberUntil).flatMap { MemberStatus.date($0) }
            return CoachNotice(issue: issue, title: until.flatMap { facts?.day($0) }.map { "会员 \($0)到期了" } ?? "会员到期了",
                               body: missed + "拼写和几类常见语法错照样查；续上会员或填自己的 Key，中文变英文就回来，授权码不变。",
                               links: [Link(action: .pricing, label: "续上会员"), Link(action: .ownKey, label: "填 Key")],
                               pill: "没翻：会员到期了")
        case .paymentFailed:
            return CoachNotice(issue: issue, title: "续费没扣成",
                               body: missed + "拼写和几类常见语法错照样查；在「管理订阅」里换一张卡，中文变英文就回来。",
                               links: [Link(action: .account, label: "换一张卡")],
                               pill: "没翻：续费没扣成")
        case .dailyLimit:
            let costCap = facts?.status?.limitBy == "cost"
            let back = reset.map { "\($0) 恢复" } ?? "明天恢复"
            return CoachNotice(issue: issue, title: costCap ? "今天的用量到上限了" : "今天的 500 次用完了",
                               body: "「\(word)」这次没翻成英文，\(back)。这之前拼写和几类常见语法错照样查。",
                               links: [], pill: "没翻：\(back)")
        case .offline:
            return CoachNotice(issue: issue, title: "没连上网",
                               body: missed + "拼写和几类常见语法错照样查；网好了自己接上，不用管它。",
                               links: [], pill: "没翻：没网")
        }
    }

    /// The issue a blocked member state stands for; nil when there is nothing to tell (a debug
    /// build without a backend).
    static func issue(for state: MemberState) -> Issue? {
        switch state {
        case .noMember: .noMember
        case .ended: .ended
        case .paymentFailed: .paymentFailed
        case .dailyLimit: .dailyLimit
        case .unavailable, .connecting, .offline, .member: nil
        }
    }

    /// The issue an AI card's member error stands for; nil for the ones that pass by themselves
    /// (busy, a token being renewed) and for bugs, which stay in the log.
    static func issue(for error: MemberError) -> Issue? {
        switch error.kind {
        case .noMember: .noMember
        case .ended: .ended
        case .paymentFailed: .paymentFailed
        case .dailyLimit: .dailyLimit
        case .offline: .offline
        case .tokenExpired, .busy, .unavailable, .other: nil
        }
    }
}

/// Which notices were already shown, kept on this Mac: no membership once; an ended membership or
/// a failed renewal once per end date; today's limit once per UTC day. Being offline is told once
/// per stretch without network and is not kept (see TypingCoach).
final class CoachNoticeLedger {
    private let load: () -> [String]
    private let save: ([String]) -> Void
    private let now: () -> Date

    init(load: @escaping () -> [String], save: @escaping ([String]) -> Void, now: @escaping () -> Date = Date.init) {
        self.load = load
        self.save = save
        self.now = now
    }

    static func defaults(_ defaults: UserDefaults) -> CoachNoticeLedger {
        let key = "typeright.noticesShown"
        return CoachNoticeLedger(load: { defaults.stringArray(forKey: key) ?? [] }, save: { defaults.set($0, forKey: key) })
    }

    /// Kept in memory only (tests, and nothing else).
    static func memory(now: @escaping () -> Date = Date.init) -> CoachNoticeLedger {
        final class Box: @unchecked Sendable { var told: [String] = [] }
        let box = Box()
        return CoachNoticeLedger(load: { box.told }, save: { box.told = $0 }, now: now)
    }

    func key(_ issue: CoachNotice.Issue, facts: TRAccountFacts?) -> String {
        switch issue {
        case .noMember, .offline:
            return issue.rawValue
        case .ended, .paymentFailed:
            return "\(issue.rawValue):\(facts?.status?.memberUntil.map { String(Int($0)) } ?? "-")"
        case .dailyLimit:
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            let d = utc.dateComponents([.year, .month, .day], from: now())
            return "dailyLimit:\(d.year ?? 0)-\(d.month ?? 0)-\(d.day ?? 0)"
        }
    }

    func wasTold(_ key: String) -> Bool { load().contains(key) }

    func told(_ key: String) {
        var keys = load()
        guard !keys.contains(key) else { return }
        keys.append(key)
        save(Array(keys.suffix(40)))
    }
}
