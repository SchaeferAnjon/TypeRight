//
//  TypeRightAccountTests.swift
//  TypeRight
//
//  What the membership surfaces say (direction B «单开价格页», without a trial): the menu's AI line
//  and its dot, the page header, the sidebar's plan card and the status block with its buttons, for
//  every state; the notice cards' words and which of them were told; the menu bar icon's looks.
//  No backend, no window: the facts are made up, dated 11 November 2026, 15:42 in Berlin.
//

@testable import TextWarden
import XCTest

final class TypeRightAccountTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_794_408_120)
    private static let reset = 1_794_441_600.0 * 1000

    private func facts(_ plan: AIPlan, _ state: MemberState, _ status: MemberStatus? = nil, offline: Bool = false, paying: Bool = false,
                       own: TRAccountFacts.OwnKey = .ready(.deepseek)) -> TRAccountFacts
    {
        var f = TRAccountFacts(plan: plan, state: state, status: status, offline: offline,
                               checkedAt: Self.now.addingTimeInterval(-5 * 3600), paying: paying, own: own, now: Self.now)
        f.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        return f
    }

    /// A member's status: renewing monthly (or yearly), today 37 of 500 used.
    private func member(year: Bool = false, autoRenew: Bool = true, pastDue: Bool = false, cancelled: Bool = false) -> MemberStatus {
        var s = MemberStatus()
        s.plan = "member"
        s.code = "TR-7KQ2-M9XD-4HPA"
        s.autoRenew = autoRenew
        let periodEnd = year ? 1_803_945_600.0 : 1_796_947_200.0
        if autoRenew || cancelled {
            s.subscription = .init(status: pastDue ? "past_due" : "active", plan: year ? "year" : "month", currency: "cny",
                                   amount: year ? 9900 : 990, periodEnd: periodEnd * 1000, cancelAtPeriodEnd: cancelled, accessUntil: nil)
        }
        s.memberUntil = (autoRenew || cancelled ? periodEnd : 1_796_860_800) * 1000
        if pastDue { s.memberUntil = 1_794_960_000 * 1000 }
        s.today = .init(limit: 500, used: 37, left: 463, resetAt: Self.reset)
        return s
    }

    private func state(_ s: MemberStatus) -> MemberState { MemberState.of(s, available: true, failed: false, now: Self.now) }

    private func everyFacts() -> [TRAccountFacts] {
        var limit = member()
        limit.today = .init(limit: 500, used: 500, left: 0, resetAt: Self.reset)
        limit.reason = "daily-limit"
        var ended = MemberStatus()
        ended.reason = "sub-ended"
        ended.memberUntil = 1_794_182_400 * 1000
        let pass = member(autoRenew: false)
        return [
            facts(.member, .noMember), facts(.member, .unavailable), facts(.member, .connecting), facts(.member, .offline),
            facts(.member, state(member()), member()), facts(.member, state(member(year: true)), member(year: true)),
            facts(.member, state(pass), pass), facts(.member, state(limit), limit),
            facts(.member, state(member(pastDue: true)), member(pastDue: true)), facts(.member, .paymentFailed),
            facts(.member, .ended, ended), facts(.member, state(member()), member(), offline: true),
            facts(.member, .noMember, paying: true), facts(.own, .noMember), facts(.own, .noMember, own: .missing(.deepseek)),
            facts(.own, .noMember, own: .rejected(.deepseek)), facts(.local, .noMember),
        ]
    }

    // MARK: No trial anywhere

    func testNoStateTalksAboutFreeUses() {
        for f in everyFacts() {
            let card = f.planCard
            let info = f.statusInfo
            let words = [f.menuLine.text, f.nowLine, card.title, card.detail, card.count ?? "", info.title, info.line, info.fine ?? ""]
            for text in words {
                XCTAssertFalse(text.contains("试用") || text.contains("免费次数") || text.contains("300"), "\(f.state): \(text)")
            }
        }
    }

    // MARK: The menu's AI line and the dot

    func testMenuLineForEveryState() {
        XCTAssertEqual(facts(.member, .noMember).menuLine.text, "AI：还没开会员，只查拼写语法")
        XCTAssertEqual(facts(.member, .noMember).menuLine.tone, .warn)
        XCTAssertEqual(facts(.member, state(member()), member()).menuLine.text, "AI：会员，今天 37 / 500 次")
        XCTAssertEqual(facts(.member, state(member()), member()).menuLine.tone, .ok)
        XCTAssertEqual(facts(.member, state(member()), member(), offline: true).menuLine.text, "AI：没连上网，先只查拼写语法")
        let pass = member(autoRenew: false)
        XCTAssertEqual(facts(.member, state(pass), pass).menuLine.text, "AI：会员，今天 37 / 500 次", "20 days left: not expiring yet")
        var soon = pass
        soon.memberUntil = Self.now.addingTimeInterval(5 * 86400).timeIntervalSince1970 * 1000
        XCTAssertEqual(facts(.member, state(soon), soon).menuLine.text, "AI：会员 11 月 16 日到期")
        XCTAssertEqual(facts(.member, state(soon), soon).menuLine.tone, .warn)
        XCTAssertEqual(facts(.member, state(member(pastDue: true)), member(pastDue: true)).menuLine.text, "AI：续费没扣成，11 月 18 日前换卡")
        XCTAssertEqual(facts(.member, .dailyLimit(reset: MemberStatus.date(Self.reset))).menuLine.text, "AI：今天 500 次用完了，01:00 恢复")
        XCTAssertEqual(facts(.member, .ended).menuLine.text, "AI：会员到期了，只查拼写语法")
        XCTAssertEqual(facts(.member, .paymentFailed).menuLine.text, "AI：续费没扣成，只查拼写语法")
        XCTAssertEqual(facts(.member, .noMember, paying: true).menuLine.tone, .wait)
        XCTAssertEqual(facts(.member, .noMember, paying: true).menuLine.text, "AI：等你在浏览器里付款…")
        XCTAssertEqual(facts(.own, .noMember).menuLine.text, "AI：自带 Key（DeepSeek）")
        XCTAssertEqual(facts(.own, .noMember, own: .rejected(.deepseek)).menuLine.tone, .danger)
        XCTAssertEqual(facts(.own, .noMember, own: .missing(.deepseek)).menuLine.tone, .warn)
        XCTAssertEqual(facts(.local, .noMember).menuLine.text, "AI：没开，只在本机查拼写语法")
        XCTAssertEqual(facts(.local, .noMember).menuLine.tone, .off)
        XCTAssertEqual(facts(.member, .unavailable).menuLine.tone, .off)
    }

    /// The amber dot (menu bar icon, the 账号与会员 row) comes for amber and red lines only.
    func testAttentionOnlyWhenSomethingWaits() {
        XCTAssertTrue(facts(.member, .noMember).needsAttention)
        XCTAssertTrue(facts(.own, .noMember, own: .rejected(.deepseek)).needsAttention)
        XCTAssertTrue(facts(.member, state(member()), member(), offline: true).needsAttention)
        XCTAssertFalse(facts(.member, state(member()), member()).needsAttention)
        XCTAssertFalse(facts(.own, .noMember).needsAttention)
        XCTAssertFalse(facts(.local, .noMember).needsAttention, "on-device only is a choice, not a problem")
        XCTAssertFalse(facts(.member, .noMember, paying: true).needsAttention)
        XCTAssertFalse(facts(.member, .unavailable).needsAttention)
    }

    /// A choice of plan never looks at the membership: own key and on-device only stay quiet when it ended.
    func testOtherPlansIgnoreTheMembership() {
        XCTAssertEqual(facts(.own, .ended).menuLine.tone, .ok)
        XCTAssertEqual(facts(.local, .dailyLimit(reset: nil)).menuLine.tone, .off)
        XCTAssertEqual(facts(.own, state(member()), member()).memberNote, "你的会员还在，选回「会员」就用会员的次数。")
        XCTAssertNil(facts(.own, .noMember).memberNote)
    }

    // MARK: Page header, plan card, status block

    func testHeaderAndPlanCard() {
        let month = facts(.member, state(member()), member())
        XCTAssertEqual(month.nowLine, "会员（月付），今天用了 37 / 500 次")
        XCTAssertEqual(month.planCard.title, "会员")
        XCTAssertEqual(month.planCard.count, "今天 37 / 500")
        XCTAssertEqual(month.planCard.detail, "自动续费，下次 12 月 11 日")
        XCTAssertEqual(month.planCard.meter ?? 0, 37.0 / 500, accuracy: 0.001)
        let year = facts(.member, state(member(year: true)), member(year: true))
        XCTAssertEqual(year.planCard.detail, "自动续费，下次 2027 年 3 月 2 日")
        let pass = member(autoRenew: false)
        XCTAssertEqual(facts(.member, state(pass), pass).planCard.detail, "用到 12 月 10 日，不续费")
        XCTAssertEqual(facts(.member, state(pass), pass).nowLine, "会员，用到 12 月 10 日")
        let cancelled = member(autoRenew: false, cancelled: true)
        XCTAssertEqual(facts(.member, state(cancelled), cancelled).planCard.detail, "已取消续费，用到 12 月 11 日")
        let none = facts(.member, .noMember)
        XCTAssertEqual(none.planCard.title, "还没开会员")
        XCTAssertEqual(none.planCard.tone, .warn)
        XCTAssertNil(none.planCard.count)
        XCTAssertEqual(facts(.local, .noMember).planCard.title, "只用本机检查")
        XCTAssertEqual(facts(.own, .noMember).planCard.detail, "DeepSeek，永久免费")
        XCTAssertEqual(facts(.member, .noMember, paying: true).planCard.tone, .wait)
        let offline = facts(.member, state(member()), member(), offline: true)
        XCTAssertEqual(offline.planCard.detail, "没连上，联网后自己接上")
        XCTAssertEqual(offline.planCard.count, "今天 37 / 500", "the last numbers stay")
    }

    func testStatusBlockButtons() {
        let none = facts(.member, .noMember).statusInfo
        XCTAssertEqual(none.title, "还没开会员")
        XCTAssertEqual(none.actions, [.buy, .enterCode])
        let month = facts(.member, state(member()), member()).statusInfo
        XCTAssertEqual(month.title, "会员，月付")
        XCTAssertEqual(month.num, "37")
        XCTAssertEqual(month.denom, "/ 500 次")
        XCTAssertEqual(month.line, "自动续费，下次 12 月 11 日扣 ¥9.9。每天 500 次，01:00 重置。")
        XCTAssertEqual(month.actions, [.portal])
        let pass = member(autoRenew: false)
        XCTAssertEqual(facts(.member, state(pass), pass).statusInfo.actions, [.passRenew])
        let pastDue = facts(.member, state(member(pastDue: true)), member(pastDue: true)).statusInfo
        XCTAssertEqual(pastDue.actions, [.fixCard])
        XCTAssertEqual(pastDue.line, "这一期 ¥9.9 没扣成，会员先照常用。11 月 18 日前在「管理订阅」里换一张卡就不会断。")
        XCTAssertEqual(facts(.member, .ended).statusInfo.actions, [.renew, .enterCode])
        XCTAssertEqual(facts(.member, .paymentFailed).statusInfo.actions, [.fixCard])
        let offline = facts(.member, state(member()), member(), offline: true).statusInfo
        XCTAssertEqual(offline.title, "没连上会员服务器")
        XCTAssertEqual(offline.numLabel, "上次 10:42")
        XCTAssertEqual(offline.actions, [.retry])
        XCTAssertEqual(facts(.member, .noMember, paying: true).statusInfo.actions, [], "while paying, the waiting box has the buttons")
        var limit = member()
        limit.today = .init(limit: 500, used: 500, left: 0, resetAt: Self.reset)
        limit.reason = "daily-limit"
        limit.limitBy = "cost"
        let cap = facts(.member, state(limit), limit).statusInfo
        XCTAssertEqual(cap.meterTone, .warn)
        XCTAssertTrue(cap.line.hasPrefix("今天用的 AI 量到上限了"))
    }

    /// The price window: a member sees 已是会员; a pass gets 微信续买.
    func testPriceWindowFacts() {
        XCTAssertFalse(facts(.member, .noMember).isMember)
        XCTAssertTrue(facts(.member, state(member()), member()).isMember)
        XCTAssertFalse(facts(.member, state(member()), member()).onPass)
        let pass = member(autoRenew: false)
        XCTAssertTrue(facts(.member, state(pass), pass).onPass)
        XCTAssertFalse(facts(.member, state(member(autoRenew: false, cancelled: true)), member(autoRenew: false, cancelled: true)).onPass)
    }

    /// 01:00 is the next UTC midnight in Berlin (winter); without a status it is still worked out.
    func testResetTimeIsTheNextUTCMidnightHere() {
        XCTAssertEqual(facts(.member, state(member()), member()).resetText, "01:00")
        XCTAssertEqual(facts(.member, .noMember).resetText, "01:00")
        var beijing = facts(.member, .noMember)
        beijing.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        XCTAssertEqual(beijing.resetText, "08:00")
    }

    // MARK: Notice cards

    func testNoticeWords() {
        let none = CoachNotice.of(.noMember, word: "预约", facts: nil)
        XCTAssertEqual(none.title, "还没开会员")
        XCTAssertTrue(none.body.hasPrefix("「预约」这次没翻成英文。拼写和基础语法照样在本机查"))
        XCTAssertEqual(none.links.map(\.action), [.pricing, .ownKey])
        XCTAssertEqual(none.pill, "没翻：还没开会员")
        let limit = CoachNotice.of(.dailyLimit, word: "预约", facts: facts(.member, .dailyLimit(reset: MemberStatus.date(Self.reset))))
        XCTAssertEqual(limit.title, "今天的 500 次用完了")
        XCTAssertTrue(limit.links.isEmpty, "a member at today's limit is not sold anything")
        XCTAssertEqual(limit.pill, "没翻：01:00 恢复")
        var ended = MemberStatus()
        ended.memberUntil = 1_794_182_400 * 1000
        XCTAssertEqual(CoachNotice.of(.ended, word: "预约", facts: facts(.member, .ended, ended)).title, "会员 11 月 9 日到期了")
        XCTAssertEqual(CoachNotice.of(.offline, word: "预约", facts: nil).links, [])
        for issue in CoachNotice.Issue.allCases {
            let n = CoachNotice.of(issue, word: "预约", facts: nil)
            XCTAssertFalse((n.title + n.body + n.pill).contains("试用"), "\(issue)")
        }
    }

    func testIssuesForStatesAndErrors() {
        XCTAssertEqual(CoachNotice.issue(for: .noMember), .noMember)
        XCTAssertEqual(CoachNotice.issue(for: .ended), .ended)
        XCTAssertEqual(CoachNotice.issue(for: .dailyLimit(reset: nil)), .dailyLimit)
        XCTAssertNil(CoachNotice.issue(for: MemberState.unavailable))
        XCTAssertEqual(CoachNotice.issue(for: MemberError(code: "trial-closed", status: 402)), .noMember)
        XCTAssertEqual(CoachNotice.issue(for: MemberError.network), .offline)
        XCTAssertEqual(CoachNotice.issue(for: MemberError(code: "payment-failed", status: 402)), .paymentFailed)
        XCTAssertNil(CoachNotice.issue(for: MemberError(code: "upstream", status: 503)))
        XCTAssertNil(CoachNotice.issue(for: MemberError(code: "bad-device", status: 401)))
    }

    /// No membership once; an ended membership once per end date; today's limit once per UTC day.
    func testLedgerKeys() {
        var day = Self.now
        let ledger = CoachNoticeLedger.memory(now: { day })
        let none = ledger.key(.noMember, facts: nil)
        XCTAssertFalse(ledger.wasTold(none))
        ledger.told(none)
        XCTAssertTrue(ledger.wasTold(none))
        let today = ledger.key(.dailyLimit, facts: nil)
        ledger.told(today)
        day = Self.now.addingTimeInterval(9.5 * 3600) // past midnight UTC
        XCTAssertNotEqual(ledger.key(.dailyLimit, facts: nil), today)
        XCTAssertFalse(ledger.wasTold(ledger.key(.dailyLimit, facts: nil)))
        var first = MemberStatus()
        first.memberUntil = 1_794_182_400 * 1000
        var second = first
        second.memberUntil = 1_796_860_800 * 1000
        XCTAssertNotEqual(ledger.key(.ended, facts: facts(.member, .ended, first)), ledger.key(.ended, facts: facts(.member, .ended, second)))
    }

    func testLedgerKeepsWhatWasToldInDefaults() throws {
        let suite = "TypeRightTests.notices.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        CoachNoticeLedger.defaults(defaults).told("noMember")
        XCTAssertTrue(CoachNoticeLedger.defaults(defaults).wasTold("noMember"))
    }

    // MARK: The menu bar icon

    @MainActor
    func testMenuBarIconLooks() throws {
        for look in [MenuBarIcon.Look.normal, .paused, .error] {
            let plain = MenuBarIcon.image(look, attention: false)
            XCTAssertTrue(plain.isTemplate, "\(look)")
            XCTAssertEqual(plain.size, NSSize(width: 18, height: 18))
            XCTAssertFalse(MenuBarIcon.image(look, attention: true).isTemplate, "the amber dot needs colour")
        }
        XCTAssertNotNil(NSImage(named: "MenuBarNormal"))
        XCTAssertNil(NSImage(named: "FeatherLogo"))
        XCTAssertNil(NSImage(named: "TextWardenLogo"))
        XCTAssertEqual(MenuBarController.look(for: .inactive), .paused)
        XCTAssertEqual(MenuBarController.look(for: .error), .error)
        XCTAssertEqual(MenuBarController.look(for: .restarting), .normal)
        // The app's own icon is TypeRight's, not TextWarden's quill (no textwarden_logo icon in the bundle).
        XCTAssertNil(Bundle.main.url(forResource: "textwarden_logo", withExtension: "icns"))
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String, "AppIcon")
    }
}
