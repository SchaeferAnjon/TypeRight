//
//  TypeRightSnapshotTests.swift
//  TypeRight
//
//  Draws TypeRight screens into off-screen windows and saves PNGs, so the interface can be
//  reviewed without putting windows on the user's screen. Runs only when TYPERIGHT_SNAPSHOT_DIR
//  is set (xcodebuild: TEST_RUNNER_TYPERIGHT_SNAPSHOT_DIR=<folder>).
//
//  The test host has the same bundle id as the user's TypeRight, so nothing here reads the
//  user's settings, keychain or running apps: settings come from a throwaway suite, keys from a
//  made-up store, app lists and shortcut names are fixed samples.
//

import KeyboardShortcuts
import SwiftUI
@testable import TextWarden
import XCTest

@MainActor
final class TypeRightSnapshotTests: XCTestCase {
    private static let sampleKey = "sk-typeright-sample-0000000000000000"

    private var dir: URL!
    private var suites: [String] = []
    private var files: [URL] = []
    private var savedDefaults: UserDefaults?
    private var savedKeys: CoachKeyStore?

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["TYPERIGHT_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TYPERIGHT_SNAPSHOT_DIR to draw the screens")
        }
        dir = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedDefaults = CoachSettings.defaults
        savedKeys = CoachKeyStore.shared
        CoachSettings.defaults = try suite()
        CoachSettings.provider = .deepseek
        useKeys(deepseek: true)
    }

    override func tearDown() async throws {
        if let savedDefaults { CoachSettings.defaults = savedDefaults }
        if let savedKeys { CoachKeyStore.shared = savedKeys }
        for name in suites {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Every screen, light and dark

    func testDrawScreens() throws {
        let notebook = try sampleNotebook()
        let main = TRMainWindowController.shared
        let own = facts(.own, nil, registered: false)
        for page in TRPage.allCases {
            main.page = page
            draw(TRMainView(controller: main, notebook: notebook, sampleFacts: own), NSSize(width: 1180, height: 760), "main-\(page.rawValue)")
        }
        let settings = TRSettingsWindowController.shared
        let pages = try samplePages(facts: own)
        // Tall enough for the whole page (通用 ends with 启动, AI 服务商 with the Key box).
        let heights: [TRSettingsPage: CGFloat] = [.general: 1000, .ai: 880]
        for page in TRSettingsPage.allCases where page != .advanced {
            settings.page = page
            draw(TRSettingsView(controller: settings, samplePage: pages, sampleFacts: own), NSSize(width: 940, height: heights[page] ?? 680),
                 "settings-\(page.rawValue)")
        }
        for step in TROnboardingStep.allCases {
            draw(TROnboardingView(start: step, accessGranted: false, translateKey: unsetName(), sampleFacts: facts(.local, nil, registered: false), onFinish: {}),
                 NSSize(width: 980, height: 680), "onboarding-\(step.rawValue)-\(step.title)")
        }
        // Cards and the menu header are sized and placed by the app's own code, as on screen.
        let cards = try TypeRightCardSamples.cards() + [("failed-offline", .failed(try XCTUnwrap(CoachAIError.offline.errorDescription)))]
        let word = try TypeRightCardSamples.word()
        for (name, content) in cards {
            for dark in [false, true] {
                let window = CoachCardPanel().place(content, keys: .normal, anchor: word)
                save(window, dark: dark, backdrop: NSColor(white: 0.5, alpha: 0.15), to: dir.appendingPathComponent("card-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
        drawTypingAlong()
        for dark in [false, true] {
            let state = TRMenuState(app: nil, allPaused: false, ai: .of(own), needsAccess: false)
            let header = try XCTUnwrap(TypeRightMenu.shared.build(state: state, notebook: notebook).items.first?.view)
            let window = NSWindow(contentRect: header.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = header
            save(window, dark: dark, to: dir.appendingPathComponent("menu-header-\(dark ? "dark" : "light").png"))
        }
        draw(KeyCapSheet().padding(20).background(TR.bg), nil, "keycaps")
    }

    /// The card while the user types along with it, and the word layer (2026-11-13, direction B).
    private func drawTypingAlong() {
        let english = "a mix of wind and snow"
        let translation = CoachCardContent.translate(source: "风雪交加", result: CoachTranslation(
            english: english, ipa: "", note: "用来说风雪同时出现的天气；若只想说下大雪就用 “heavy snow”，只想说大风就用 “strong wind”。"
        ))
        let sentence = CoachCardContent.sentence(original: "Yesterday I go to the office because I has a question.", check: CoachSentenceCheck(
            ok: false, corrected: "Yesterday I went to the office because I had a question.",
            changes: [.init(from: "go", to: "went", why: "yesterday 说的是过去，动词都用过去式：go 变 went，has 变 had。", type: "tense"),
                      .init(from: "has", to: "had", why: "", type: "tense")]
        ))
        let spelling = CoachCardContent.spelling(wrong: "tomorow", fixes: ["tomorrow", "todorov", "tomaro"])
        // The spot of "mix" on the translation card: the mouse rests on it.
        let mixSpot = 10_000_002
        let states: [(String, CoachCardContent, CoachFollow?, Int?)] = [
            ("translate-hover", translation, nil, mixSpot),
            ("translate-typing", translation, CoachFollow(target: english, right: 6), nil),
            ("translate-wrong", translation, CoachFollow(target: english, right: 3, wrongAt: 3), nil),
            ("translate-composing", translation, CoachFollow(target: english, right: 2, composing: true), nil),
            ("translate-done", translation, CoachFollow(phase: .done(filled: false), target: english), nil),
            ("spelling-typing", spelling, CoachFollow(target: "tomorrow", right: 4), nil),
            ("spelling-filled", spelling, CoachFollow(phase: .done(filled: true), target: "tomorrow"), nil),
            ("sentence", sentence, nil, nil),
            ("sentence-typing", sentence, CoachFollow(target: "had", right: 1, step: 1), nil),
            ("sentence-done", sentence, CoachFollow(phase: .done(filled: false), target: "had", step: 1), nil),
        ]
        for (name, content, follow, hot) in states {
            draw(CoachCardView(content: content, tail: CoachTailPlacement(pointsUp: true, x: 20), follow: follow, hot: hot), nil, "follow-\(name)")
        }
        let mix = CoachWordInfo(word: "mix", ipa: "/mɪks/", senses: [.init(pos: "v.", meaning: "使…混合；调制"), .init(pos: "n.", meaning: "混合物；混合料")],
                                status: .found)
        let words: [(String, CoachWordLayerView.Mode)] = [
            ("mix", .word(mix)),
            ("went", .word(CoachWordInfo(word: "went", ipa: "/wɛnt/", senses: [.init(pos: "v.", meaning: "go 的过去式：去；进入某处")], status: .found))),
            ("not-found", .word(CoachWordInfo(word: "Huang", ipa: "", senses: [], status: .notFound))),
            ("no-dictionary", .word(CoachWordInfo(word: "mix", ipa: "", senses: [], status: .noDictionary))),
            ("list", .list([mix, CoachWordInfo(word: "wind", ipa: "/wɪnd/", senses: [.init(pos: "n.", meaning: "风；趋势")], status: .found),
                            CoachWordInfo(word: "snow", ipa: "/snoʊ/", senses: [.init(pos: "n.", meaning: "雪；“雪花”"), .init(pos: "v.", meaning: "下雪")],
                                          status: .found)], key: "⌥")),
        ]
        for (name, mode) in words {
            let tail: CoachTailPlacement? = if case .word = mode { CoachTailPlacement(pointsUp: true, x: 26) } else { nil }
            draw(CoachWordLayerView(mode: mode, tail: tail), nil, "word-\(name)")
        }
    }

    // MARK: What changed in this round (light)

    func testDrawReviewScreens() throws {
        let settings = TRSettingsWindowController.shared
        let preferences = try samplePreferences()
        let vocabulary = try sampleVocabulary()
        let sample = PreferencesView.Sample(
            appBundleIDs: ["com.apple.mail", "com.apple.Notes", "com.apple.Safari", "com.apple.TextEdit",
                           "com.apple.Terminal", "com.apple.keychainaccess", "com.apple.systempreferences"],
            health: RuntimeHealthSnapshot(state: .active, reason: nil, capabilities: [.textReading, .grammar, .safeReplacement],
                                          applicationName: "邮件", bundleIdentifier: "com.apple.mail",
                                          lastSuccessfulCheck: Date(), action: nil),
            fixAllName: unsetName(),
            rewriteName: unsetName()
        )
        settings.page = .advanced
        let tabs: [(SettingsTab, CGFloat)] = [(.general, 700), (.grammar, 3000), (.style, 480), (.applications, 760),
                                              (.websites, 380), (.diagnostics, 1840), (.about, 800)]
        for (tab, height) in tabs {
            PreferencesWindowController.shared.selectTab(tab)
            let view = TRSettingsView(controller: settings, samplePage: { page in
                page == .advanced ? AnyView(PreferencesView(preferences: preferences, vocabulary: vocabulary, sample: sample)) : nil
            })
            draw(view, NSSize(width: 940, height: height), "advanced-\(tab.rawValue)-\(tab)")
        }

        settings.page = .privacy
        draw(TRSettingsView(controller: settings, sampleFacts: facts(.own, nil, registered: false)), NSSize(width: 940, height: 680),
             "settings-privacy", appearances: [false])

        let notebook = try sampleNotebook()
        let rejected = TRMenuState(app: .init(id: "com.apple.mail", name: "邮件", paused: false), allPaused: false,
                                   ai: .of(facts(.own, nil, registered: false, own: .rejected(.deepseek))), needsAccess: false)
        draw(MenuReplica(menu: TypeRightMenu.shared.build(state: rejected, notebook: notebook), notebook: notebook),
             nil, "menu-key-rejected", appearances: [false, true])

        let mainMenu = try XCTUnwrap(NSApp.mainMenu)
        draw(MenuBarReplica(menu: mainMenu), nil, "menubar-front", appearances: [false])

        draw(SafeTrialPromptView(applicationName: "终端", applicationIcon: NSWorkspace.shared.icon(forFile: "/System/Applications/Utilities/Terminal.app"),
                                 showsPanelBackground: true, onTry: {}, onKeepPaused: {}).padding(16),
             nil, "safe-trial-prompt", appearances: [false, true])
    }

    // MARK: The five pictures in the website's guide (light only)

    func testDrawGuideShots() throws {
        let settings = TRSettingsWindowController.shared
        let own = facts(.own, nil, registered: false)
        let pages = try samplePages(aiTest: .ok("I have a question."), facts: own)

        useKeys(deepseek: false)
        drawGuide(TROnboardingView(start: .access, accessGranted: false, translateKey: unsetName(), sampleFacts: facts(.local, nil, registered: false), onFinish: {}),
                  NSSize(width: 980, height: 680), "guide-access")
        useKeys(deepseek: true)

        let notebook = try sampleNotebook()
        let state = TRMenuState(app: .init(id: "com.apple.mail", name: "邮件", paused: false), allPaused: false,
                                ai: .of(own), needsAccess: false)
        drawGuide(MenuReplica(menu: TypeRightMenu.shared.build(state: state, notebook: notebook), notebook: notebook, highlight: "设置…"),
                  nil, "guide-menu")

        for (page, name, height) in [(TRSettingsPage.ai, "guide-ai-provider", 800.0), (.keys, "guide-shortcuts", 680), (.apps, "guide-apps", 680)] {
            settings.page = page
            drawGuide(TRSettingsView(controller: settings, samplePage: pages, sampleFacts: own), NSSize(width: 940, height: height), name)
        }
    }

    // MARK: Membership, the icon and the notice cards (design/membership/redesign, direction B; design/icon/redesign, B)

    /// Every membership state on 账号与会员 with the sidebar's plan card, the price window, the AI
    /// provider page's note, the setup step, the menu's AI line, the notice card and capsule, the
    /// menu bar icon's looks and the About page with the app icon; light and dark.
    func testDrawMembership() throws {
        let settings = TRSettingsWindowController.shared
        settings.page = .account
        let states: [(String, TRAccountFacts)] = [
            ("no-member", facts(.member, status("none"))),
            ("month", facts(.member, status("month"))),
            ("year", facts(.member, status("year"))),
            ("pass", facts(.member, status("pass"))),
            ("daily-limit", facts(.member, status("limit"))),
            ("past-due", facts(.member, status("pastdue"))),
            ("payment-failed", facts(.member, status("paymentFailed"))),
            ("ended", facts(.member, status("ended"))),
            ("offline", facts(.member, status("month"), offline: true)),
            ("paying", facts(.member, status("none"), paying: true)),
            ("own", facts(.own, status("month"))),
            ("local", facts(.local, nil, registered: false)),
        ]
        for (name, sample) in states {
            let pages = try samplePages(facts: sample)
            draw(TRSettingsView(controller: settings, samplePage: pages, sampleFacts: sample), NSSize(width: 940, height: 680), "account-\(name)")
        }
        draw(TRAccountPage(facts: facts(.member, status("month")), justPaid: true, handler: .preview).padding(28).frame(width: 720).background(TR.bg),
             nil, "account-just-paid")

        for (name, sample) in [("no-member", facts(.member, status("none"))), ("month", facts(.member, status("month"))),
                               ("pass", facts(.member, status("pass"))), ("paying", facts(.member, status("none"), paying: true)),
                               ("offline", facts(.member, status("month"), offline: true))]
        {
            draw(TRPricingView(facts: sample, handler: .preview, onClose: {}), NSSize(width: 880, height: 1060), "pricing-\(name)")
        }

        settings.page = .ai
        let member = facts(.member, status("none"))
        draw(TRSettingsView(controller: settings, samplePage: try samplePages(facts: member), sampleFacts: member), NSSize(width: 940, height: 880),
             "ai-provider-member")

        for (name, sample) in [("local", facts(.local, nil, registered: false)), ("member", facts(.member, status("none"))),
                               ("own", facts(.own, nil, registered: false))]
        {
            draw(TROnboardingView(start: .ai, accessGranted: true, translateKey: unsetName(), sampleFacts: sample, onFinish: {}),
                 NSSize(width: 980, height: 680), "onboarding-ai-\(name)")
        }
        draw(TROnboardingView(start: .done, accessGranted: true, translateKey: unsetName(), sampleFacts: member, onFinish: {}),
             NSSize(width: 980, height: 680), "onboarding-done")

        let notebook = try sampleNotebook()
        for (name, sample) in [("no-member", facts(.member, status("none"))), ("month", facts(.member, status("month"))),
                               ("daily-limit", facts(.member, status("limit"))), ("offline", facts(.member, status("month"), offline: true)),
                               ("paying", facts(.member, status("none"), paying: true)), ("local", facts(.local, nil, registered: false))]
        {
            let state = TRMenuState(app: .init(id: "com.apple.mail", name: "邮件", paused: false), allPaused: false, ai: .of(sample), needsAccess: false)
            draw(MenuReplica(menu: TypeRightMenu.shared.build(state: state, notebook: notebook), notebook: notebook), nil, "menu-ai-\(name)")
        }
        draw(TRMainView(controller: TRMainWindowController.shared, notebook: notebook, sampleFacts: facts(.member, status("month"))),
             NSSize(width: 1180, height: 760), "main-plan-card")

        let word = try TypeRightCardSamples.word()
        let notices: [(String, CoachCardContent)] = [
            ("notice-no-member", .notice(.of(.noMember, word: "预约", facts: member))),
            ("notice-daily-limit", .notice(.of(.dailyLimit, word: "预约", facts: facts(.member, status("limit"))))),
            ("notice-offline", .notice(.of(.offline, word: "预约", facts: member))),
            ("notice-ended", .notice(.of(.ended, word: "预约", facts: facts(.member, status("ended"))))),
            ("pill-no-member", .pill(CoachNotice.of(.noMember, word: "会议室", facts: member).pill)),
        ]
        for (name, content) in notices {
            for dark in [false, true] {
                let window = CoachCardPanel().place(content, keys: .normal, anchor: word)
                save(window, dark: dark, backdrop: NSColor(white: 0.5, alpha: 0.15), to: dir.appendingPathComponent("card-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
        draw(CoachCardView(content: .translate(source: "预约", result: CoachTranslation(english: "book", ipa: "/bʊk/", note: "")),
                           tail: CoachTailPlacement(pointsUp: true, x: 20), follow: CoachFollow(target: "book", right: 2, inputMethodOn: true)),
             nil, "follow-input-method-on")

        draw(MenuBarIconSheet(), nil, "menubar-icons")
        settings.page = .advanced
        PreferencesWindowController.shared.selectTab(.about)
        let preferences = try samplePreferences()
        let vocabulary = try sampleVocabulary()
        let sample = PreferencesView.Sample(
            appBundleIDs: [],
            health: RuntimeHealthSnapshot(state: .active, reason: nil, capabilities: [.textReading, .grammar, .safeReplacement],
                                          applicationName: "邮件", bundleIdentifier: "com.apple.mail", lastSuccessfulCheck: Date(), action: nil),
            fixAllName: unsetName(), rewriteName: unsetName()
        )
        draw(TRSettingsView(controller: settings, samplePage: { page in
            page == .advanced ? AnyView(PreferencesView(preferences: preferences, vocabulary: vocabulary, sample: sample)) : nil
        }, sampleFacts: own(member)), NSSize(width: 940, height: 800), "about")
    }

    private func own(_ facts: TRAccountFacts) -> TRAccountFacts {
        var f = facts
        f.plan = .own
        return f
    }

    // MARK: Membership samples (11 November 2026, 15:42 in Berlin, as in the prototype)

    private static let now = Date(timeIntervalSince1970: 1_794_408_120)

    private func facts(_ plan: AIPlan, _ status: MemberStatus?, registered: Bool = true, offline: Bool = false, paying: Bool = false,
                       own: TRAccountFacts.OwnKey = .ready(.deepseek)) -> TRAccountFacts
    {
        let state = MemberState.of(status, available: true, failed: offline && status == nil, registered: registered, now: Self.now)
        var f = TRAccountFacts(plan: plan, state: state, status: status, offline: offline, checkedAt: Self.now.addingTimeInterval(-5 * 3600),
                               paying: paying, own: own, now: Self.now)
        f.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        return f
    }

    /// The backend's status for each sample (amounts in fen, times in milliseconds).
    private func status(_ kind: String) -> MemberStatus {
        var s = MemberStatus()
        s.prices = TRPrices.subscription
        s.passPrices = TRPrices.pass
        s.now = Self.now.timeIntervalSince1970 * 1000
        let reset = 1_794_441_600.0 * 1000
        func member(plan: String, amount: Int, periodEnd: Double, status: String = "active") {
            s.plan = "member"
            s.code = "TR-7KQ2-M9XD-4HPA"
            s.autoRenew = true
            s.subscription = .init(status: status, plan: plan, currency: "cny", amount: amount, periodEnd: periodEnd * 1000,
                                   cancelAtPeriodEnd: false, accessUntil: (periodEnd + 86400) * 1000)
            s.memberUntil = (periodEnd + 86400) * 1000
            s.today = .init(limit: 500, used: 37, left: 463, resetAt: reset)
        }
        switch kind {
        case "month": member(plan: "month", amount: 990, periodEnd: 1_796_947_200)
        case "year": member(plan: "year", amount: 9900, periodEnd: 1_803_945_600)
        case "limit":
            member(plan: "month", amount: 990, periodEnd: 1_796_947_200)
            s.today = .init(limit: 500, used: 500, left: 0, resetAt: reset)
            s.canUse = false
            s.reason = "daily-limit"
            s.limitBy = "uses"
            s.resetAt = reset
        case "pastdue":
            member(plan: "month", amount: 990, periodEnd: 1_794_408_120 - 3600, status: "past_due")
            s.memberUntil = 1_794_960_000 * 1000
        case "pass":
            s.plan = "member"
            s.code = "TR-7KQ2-M9XD-4HPA"
            s.pass = .init(plan: "month", currency: "cny", amount: 990, status: "paid", startAt: (1_796_860_800 - 30 * 86400) * 1000,
                           until: 1_796_860_800 * 1000)
            s.memberUntil = 1_796_860_800 * 1000
            s.today = .init(limit: 500, used: 37, left: 463, resetAt: reset)
        case "ended":
            s.plan = "none"
            s.code = "TR-7KQ2-M9XD-4HPA"
            s.canUse = false
            s.reason = "sub-ended"
            s.memberUntil = 1_794_182_400 * 1000
        case "paymentFailed":
            s.plan = "none"
            s.code = "TR-7KQ2-M9XD-4HPA"
            s.canUse = false
            s.reason = "payment-failed"
            s.memberUntil = 1_794_182_400 * 1000
        default:
            s.plan = "none"
            s.canUse = false
            s.reason = "trial-closed"
        }
        return s
    }

    // MARK: Sample data

    private func suite() throws -> UserDefaults {
        let name = "TypeRightSnapshots.\(UUID().uuidString)"
        suites.append(name)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    private func useKeys(deepseek: Bool) {
        CoachKeyStore.shared = CoachKeyStore(read: { account in
            deepseek && account.hasPrefix(CoachProvider.deepseek.rawValue) ? .found(Self.sampleKey) : .missing
        }, write: { _, _ in true })
    }

    /// A shortcut name nobody has set: the recorder shows its empty state, never the user's keys.
    private func unsetName() -> KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("typeRightSnapshot.\(UUID().uuidString)")
    }

    private func samplePreferences() throws -> UserPreferences {
        let preferences = try UserPreferences(defaults: suite())
        preferences.disableWebsite("github.com")
        preferences.disableWebsite("*.google.com")
        // Shows the style choices under 改写 (this Mac may not have Apple Intelligence).
        preferences.enableStyleChecking = true
        // Shows the language picker under 拼写 › 别的语言.
        preferences.enableLanguageDetection = true
        preferences.excludedLanguages = ["deu", "fra"]
        return preferences
    }

    private func sampleVocabulary() throws -> CustomVocabulary {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("typeright-vocabulary-\(UUID().uuidString).json")
        files.append(url)
        let vocabulary = CustomVocabulary(fileURL: url)
        for word in ["Kubernetes", "TypeRight", "Bürgeramt"] {
            try vocabulary.addWord(word)
        }
        return vocabulary
    }

    /// Settings pages that would otherwise show this Mac's apps, shortcuts or membership.
    private func samplePages(aiTest: TRAISettings.TestState = .idle, facts: TRAccountFacts) throws -> (TRSettingsPage) -> AnyView? {
        let preferences = try samplePreferences()
        let apps: [TRAppSettings.App] = [
            ("com.apple.mail", "邮件", "/System/Applications/Mail.app"),
            ("com.apple.Notes", "备忘录", "/System/Applications/Notes.app"),
            ("com.apple.Safari", "Safari 浏览器", "/Applications/Safari.app"),
            ("com.apple.TextEdit", "文本编辑", "/System/Applications/TextEdit.app"),
            ("com.apple.Terminal", "终端", "/System/Applications/Utilities/Terminal.app"),
        ].map { ($0.0, $0.1, NSWorkspace.shared.icon(forFile: $0.2)) }
        let translate = unsetName()
        let pause = unsetName()
        return { page in
            switch page {
            case .apps: AnyView(TRAppSettings(preferences: preferences, sampleApps: apps))
            case .keys: AnyView(TRKeySettings(translate: translate, pause: pause))
            case .ai: AnyView(TRAISettings(initialTest: aiTest, samplePlan: facts.plan))
            case .account: AnyView(TRAccountPage(facts: facts, handler: .preview))
            default: nil
            }
        }
    }

    /// Two weeks of made-up use, written in the notebook's own file format.
    private func sampleNotebook() throws -> CoachNotebook {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("typeright-sample-\(UUID().uuidString).json")
        files.append(url)
        let now = Date()
        func ago(_ minutes: Double) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(-minutes * 60)) }
        func entry(_ kind: String, _ cat: String, _ from: String, _ to: String, _ why: String, _ ipa: String, _ context: String,
                   _ app: String, _ minutes: Double, uses: Int = 0, mastered: Bool = false, times: Int = 1) -> [String: Any] {
            ["id": UUID().uuidString, "kind": kind, "category": cat, "from": from, "to": to, "why": why, "ipa": ipa,
             "context": context, "app": app, "date": ago(minutes), "times": times, "correctUses": uses, "mastered": mastered]
        }
        let entries: [[String: Any]] = [
            entry("mistake", "agreement", "I has", "I have", "主语是 I，动词要用 have。", "", "because I have a question.", "微信", 18, uses: 1),
            entry("mistake", "spelling", "tomorow", "tomorrow", "", "", "a meeting room tomorrow", "微信", 19, uses: 2),
            entry("word", "other", "预约", "book", "订会议室、餐厅用 book；约医生说 make an appointment。", "/bʊk/", "I want to book a meeting room", "微信", 20),
            entry("mistake", "preposition", "discuss about", "discuss", "discuss 后面直接跟宾语，不加 about。", "", "Let's discuss the schedule.", "邮件", 260, uses: 2),
            entry("mistake", "chinglish", "very like", "really like", "very 不能直接修饰动词，要用 really。", "", "I really like this idea.", "Slack", 330, uses: 3, mastered: true),
            entry("mistake", "article", "send me link", "send me the link", "特指的那个链接要加 the。", "", "Can you send me the link?", "邮件", 600, times: 2),
            entry("mistake", "tense", "Yesterday I go", "Yesterday I went", "说昨天的事用过去式。", "", "Yesterday I went to the Bürgeramt.", "微信", 2000),
            entry("word", "other", "押金", "deposit", "租房押金说 deposit。", "/dɪˈpɑːzɪt/", "How much is the deposit?", "微信", 2900),
            entry("word", "other", "报销", "reimburse", "公司报销说 get reimbursed。", "/ˌriːɪmˈbɜːrs/", "Can I get reimbursed for this?", "邮件", 4300),
            entry("word", "other", "居留许可", "residence permit", "", "/ˈrezɪdəns ˈpɜːrmɪt/", "My residence permit expires in May.", "邮件", 7000),
        ]
        let calendar = Calendar.current
        let days: [[String: Any]] = try (0 ..< 14).map { offset in
            let date = try XCTUnwrap(calendar.date(byAdding: .day, value: -offset, to: now))
            let sentences = [12, 18, 9, 21, 16, 4, 3, 19, 22, 17, 20, 15, 8, 14][offset]
            return ["day": CoachNotebook.dayKey(date), "sentences": sentences, "clean": Int(Double(sentences) * (0.62 + 0.012 * Double(14 - offset))), "fixes": sentences / 4]
        }
        let data = try JSONSerialization.data(withJSONObject: ["entries": entries, "days": days])
        try data.write(to: url)
        return CoachNotebook(fileURL: url)
    }

    // MARK: Drawing

    private func draw(_ view: some View, _ size: NSSize?, _ name: String, appearances dark: [Bool] = [false, true]) {
        for dark in dark {
            render(view, size, dark: dark, to: dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
    }

    private func drawGuide(_ view: some View, _ size: NSSize?, _ name: String) {
        render(view, size, dark: false, to: dir.appendingPathComponent("\(name).png"))
    }

    /// Views without a fixed size are measured the way the app measures its own windows.
    private func render(_ view: some View, _ size: NSSize?, dark: Bool, to file: URL) {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(origin: .zero, size: size ?? TRFitting.size(of: AnyView(view)))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        save(window, dark: dark, to: file)
    }

    /// Draws a window's content at the size it has. `backdrop` fills a sheet 20 wider all round
    /// behind it (cards are see-through outside the card).
    private func save(_ window: NSWindow, dark: Bool, backdrop: NSColor? = nil, to file: URL) {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        guard let view = window.contentView else {
            XCTFail("nothing to draw for \(file.lastPathComponent)")
            return
        }
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        view.layoutSubtreeIfNeeded()
        guard view.bounds.width > 0, view.bounds.height > 0, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("could not draw \(file.lastPathComponent): \(view.bounds.size)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        var image = rep
        if let backdrop {
            let pad = Int(20 * CGFloat(rep.pixelsWide) / view.bounds.width)
            guard let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide + 2 * pad, pixelsHigh: rep.pixelsHigh + 2 * pad,
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else {
                XCTFail("could not make a sheet for \(file.lastPathComponent)")
                return
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
            backdrop.setFill()
            NSRect(x: 0, y: 0, width: sheet.pixelsWide, height: sheet.pixelsHigh).fill()
            _ = rep.draw(in: NSRect(x: pad, y: pad, width: rep.pixelsWide, height: rep.pixelsHigh), from: .zero, operation: .sourceOver,
                         fraction: 1, respectFlipped: false, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            image = sheet
        }
        do {
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: file)
        } catch {
            XCTFail("could not save \(file.lastPathComponent): \(error)")
        }
    }
}

// MARK: - Key caps

/// Every look of the key cap side by side; settings only show the unset one, since a set shortcut
/// would have to be written into the user's own defaults.
private struct KeyCapSheet: View {
    var body: some View {
        HStack(spacing: 16) {
            KeyCap(label: "选一个键", look: .unset)
            KeyCap(label: "按下新的组合键…", look: .recording)
            KeyCap(label: "⌃⌥T", look: .set)
            KeyCap(label: "Tab", look: .fixed)
            KeyCap(label: "Esc")
        }
    }
}

// MARK: - Menus drawn from their real items

/// NSMenu cannot be drawn off-screen, so this lays out the real menu's items (titles, images,
/// separators, key equivalents, enabled state) the way the system menu does.
private struct MenuReplica: View {
    let menu: NSMenu
    var notebook: CoachNotebook?
    var highlight: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(menu.items.filter { !$0.isHidden && !$0.isAlternate }.enumerated()), id: \.offset) { _, item in
                row(item)
            }
        }
        .padding(.vertical, 5)
        .frame(width: notebook == nil ? nil : 300, alignment: .leading)
        .fixedSize(horizontal: notebook == nil, vertical: true)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(20)
    }

    @ViewBuilder private func row(_ item: NSMenuItem) -> some View {
        if item.isSeparatorItem {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1).padding(.horizontal, 12).padding(.vertical, 5)
        } else if item.view != nil, let notebook {
            TRMenuHeader(notebook: notebook)
        } else {
            let enabled = item.action != nil || item.submenu != nil
            HStack(spacing: 6) {
                if let image = item.image {
                    Image(nsImage: image)
                }
                Text(item.title).font(.system(size: 13)).foregroundStyle(enabled ? Color.primary : Color.secondary)
                Spacer(minLength: 24)
                if item.submenu != nil {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                } else if !item.keyEquivalent.isEmpty {
                    Text(keys(item)).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 22)
            .overlay {
                if item.title == highlight {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(TR.fix, lineWidth: 2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, -1)
                }
            }
        }
    }

    private func keys(_ item: NSMenuItem) -> String {
        let mask = item.keyEquivalentModifierMask
        var text = ""
        if mask.contains(.control) { text += "⌃" }
        if mask.contains(.option) { text += "⌥" }
        if mask.contains(.shift) || item.keyEquivalent != item.keyEquivalent.lowercased() { text += "⇧" }
        if mask.contains(.command) { text += "⌘" }
        return text + item.keyEquivalent.uppercased()
    }
}

/// The menu bar while a TypeRight window is in front: every top-level menu, opened side by side.
private struct MenuBarReplica: View {
    let menu: NSMenu

    var body: some View {
        let items = menu.items.filter { $0.submenu != nil && !$0.isHidden }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                Image(systemName: "apple.logo").font(.system(size: 14))
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    Text(index == 0 ? "TypeRight" : item.title).font(.system(size: 13, weight: index == 0 ? .bold : .regular))
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    if let submenu = item.submenu {
                        MenuReplica(menu: submenu)
                    }
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

// MARK: - The menu bar icon

/// Every look of the menu bar icon, at its size and 4×, on the menu bar of the drawing's appearance.
private struct MenuBarIconSheet: View {
    @Environment(\.colorScheme) private var scheme
    private let looks: [(String, MenuBarIcon.Look, Bool)] = [
        ("平时", .normal, false), ("要看一下", .normal, true), ("暂停", .paused, false),
        ("暂停且要看", .paused, true), ("出错", .error, false),
    ]

    var body: some View {
        let dark = scheme == .dark
        HStack(spacing: 28) {
            ForEach(looks.indices, id: \.self) { i in
                VStack(spacing: 8) {
                    HStack(spacing: 14) {
                        Image(nsImage: MenuBarIcon.image(looks[i].1, attention: looks[i].2))
                        Image(nsImage: MenuBarIcon.image(looks[i].1, attention: looks[i].2)).resizable().frame(width: 72, height: 72)
                    }
                    .foregroundStyle(dark ? Color.white : Color.black)
                    Text(looks[i].0).font(.system(size: 11)).foregroundStyle(dark ? Color.white.opacity(0.7) : Color.black.opacity(0.6))
                }
            }
        }
        .padding(20)
        .background(dark ? Color(white: 0.16) : Color(white: 0.93))
    }
}
