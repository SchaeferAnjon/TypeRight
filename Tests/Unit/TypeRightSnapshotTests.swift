//
//  TypeRightSnapshotTests.swift
//  TypeRight
//
//  Draws every TypeRight screen into off-screen windows and saves PNGs, light and dark, so the
//  interface can be reviewed without putting windows on the user's screen. Runs only when
//  TYPERIGHT_SNAPSHOT_DIR is set (xcodebuild: TEST_RUNNER_TYPERIGHT_SNAPSHOT_DIR=<folder>).
//

import SwiftUI
@testable import TextWarden
import XCTest

@MainActor
final class TypeRightSnapshotTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["TYPERIGHT_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TYPERIGHT_SNAPSHOT_DIR to draw the screens")
        }
        dir = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func testDrawScreens() throws {
        let notebook = try sampleNotebook()
        let main = TRMainWindowController.shared
        for page in TRPage.allCases {
            main.page = page
            draw(TRMainView(controller: main, notebook: notebook), NSSize(width: 1180, height: 760), "main-\(page.rawValue)")
        }
        let settings = TRSettingsWindowController.shared
        for page in TRSettingsPage.allCases where page != .advanced {
            settings.page = page
            draw(TRSettingsView(controller: settings), NSSize(width: 940, height: 680), "settings-\(page.rawValue)")
        }
        for step in TROnboardingStep.allCases {
            draw(TROnboardingView(start: step, onFinish: {}), NSSize(width: 980, height: 680), "onboarding-\(step.rawValue)-\(step.title)")
        }
        let cards: [(String, CoachCardContent)] = [
            ("spelling", .spelling(wrong: "tomorow", fixes: ["tomorrow", "tomorrows"])),
            ("translate", .translate(source: "预约", result: CoachTranslation(english: "book", ipa: "/bʊk/",
                                                                           note: "订会议室、餐厅用 book；约医生说 make an appointment。"))),
            ("sentence", .sentence(original: "I want to book a meeting room tomorrow because I has a question.",
                                   check: CoachSentenceCheck(ok: false,
                                                             corrected: "I want to book a meeting room tomorrow because I have a question.",
                                                             changes: [.init(from: "I has", to: "I have", why: "主语是 I，动词要用 have。", type: "agreement")]))),
            ("thinking", .thinking),
            ("failed", .failed("AI 没回上来：AI 服务返回 401：Authentication Fails")),
        ]
        for (name, content) in cards {
            draw(CoachCardView(content: content, tail: CoachTailPlacement(pointsUp: true, x: 30)).padding(20).background(Color.gray.opacity(0.15)),
                 nil, "card-\(name)")
        }
        draw(TRMenuHeader(notebook: notebook), NSSize(width: 300, height: 104), "menu-header")
    }

    // MARK: Helpers

    private func draw(_ view: some View, _ size: NSSize?, _ name: String) {
        for dark in [false, true] {
            let host = NSHostingView(rootView: AnyView(view))
            let fitting = size ?? host.fittingSize
            host.frame = NSRect(origin: .zero, size: fitting)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let file = dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
            try? rep.representation(using: .png, properties: [:])?.write(to: file)
        }
    }

    /// Two weeks of made-up use, written in the notebook's own file format.
    private func sampleNotebook() throws -> CoachNotebook {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("typeright-sample-\(UUID().uuidString).json")
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
        let days: [[String: Any]] = (0 ..< 14).map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: now)!
            let sentences = [12, 18, 9, 21, 16, 4, 3, 19, 22, 17, 20, 15, 8, 14][offset]
            return ["day": CoachNotebook.dayKey(date), "sentences": sentences, "clean": Int(Double(sentences) * (0.62 + 0.012 * Double(14 - offset))), "fixes": sentences / 4]
        }
        let data = try JSONSerialization.data(withJSONObject: ["entries": entries, "days": days])
        try data.write(to: url)
        return CoachNotebook(fileURL: url)
    }
}
