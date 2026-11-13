//
//  TRPages.swift
//  TypeRight
//
//  The four pages of the main window.
//

import SwiftUI

// MARK: - Shared pieces

/// Dates on the main window, one way everywhere: today as the time (13:08), other days as
/// 11月10日 (the page header keeps its 11月11日 星期三).
enum TRDate {
    static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now) ? time(date) : day(date)
    }

    /// A moment that may be on another day: 13:08 today, 11月12日 13:08 otherwise.
    static func moment(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now) ? time(date) : "\(day(date)) \(time(date))"
    }

    static func time(_ date: Date) -> String {
        formatter("HH:mm").string(from: date)
    }

    static func day(_ date: Date) -> String {
        formatter("M月d日").string(from: date)
    }

    /// A notebook day key (yyyy-MM-dd) as 10月29日.
    static func day(key: String) -> String {
        formatter("yyyy-MM-dd").date(from: key).map(day) ?? ""
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = format
        return formatter
    }
}

/// Mistakes grouped by category, most corrected first. Equal counts keep the categories' own
/// order, so the cards and 最常被改的是… do not change from one opening to the next.
enum TRCategoryStats {
    static func ranked(_ mistakes: [NotebookEntry]) -> [(category: MistakeCategory, items: [NotebookEntry])] {
        let groups = Dictionary(grouping: mistakes, by: \.category)
        return MistakeCategory.allCases.compactMap { category in
            groups[category].map { (category, $0) }
        }
        .enumerated()
        .sorted { a, b in
            a.element.items.count != b.element.items.count ? a.element.items.count > b.element.items.count : a.offset < b.offset
        }
        .map(\.element)
    }

    /// The one category corrected more often than any other; nil when the top counts tie.
    static func mostCorrected(_ mistakes: [NotebookEntry]) -> MistakeCategory? {
        let ranked = ranked(mistakes)
        guard let first = ranked.first else { return nil }
        if ranked.count > 1, ranked[1].items.count == first.items.count { return nil }
        return first.category
    }
}

/// The small grey line under a notebook entry: category, app, date, how often it was corrected.
/// The same order on 今天 and in 错题本 / 生词本.
enum TRMeta {
    /// `kind`: say 生词 / the category first; the 生词本 page leaves it out, every line there is a word.
    static func line(_ entry: NotebookEntry, kind: Bool = true, now: Date = Date()) -> String {
        [kind ? (entry.kind == .word ? "生词" : entry.category.title) : "", entry.app, TRDate.short(entry.date, now: now),
         entry.times > 1 ? "被改过 \(entry.times) 次" : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct TRCard<Content: View>: View {
    var title: String?
    var more: String?
    var onMore: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(TR.text)
                    Spacer()
                    if let more, let onMore {
                        Button(action: onMore) { Text(more + " ›").font(.system(size: 12)).foregroundStyle(TR.text2) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TR.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(TR.line, lineWidth: 0.5))
    }
}

struct TRDots: View {
    let filled: Int
    var total = CoachNotebook.usesToMaster

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0 ..< total, id: \.self) { i in
                Circle()
                    .strokeBorder(TR.fix, lineWidth: 1)
                    .background(Circle().fill(i < filled ? TR.fix : Color.clear))
                    .frame(width: 7, height: 7)
            }
        }
        .help("用对 \(min(filled, total)) 次，\(total) 次算会了")
    }
}

struct TRSpeakButton: View {
    let text: String

    var body: some View {
        Button { CoachSpeaker.speak(text) } label: {
            Image(systemName: "speaker.wave.2").font(.system(size: 12)).foregroundStyle(TR.text2)
        }
        .buttonStyle(.plain)
        .help("听发音")
    }
}

/// 自己打的 / 帮你换的 after a notebook line: how the English got into the field.
struct TRHowTag: View {
    let how: NotebookEntry.Help

    var body: some View {
        Text(how.title)
            .font(.system(size: 12))
            .foregroundStyle(TR.text2)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(TR.fill, in: RoundedRectangle(cornerRadius: 5))
    }
}

struct TREmpty: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(TR.text2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
    }
}

/// 14 bars: green part right the first time, grey part fixed.
struct TRDayBars: View {
    let days: [DayStat]
    var height: CGFloat = 96

    var body: some View {
        let peak = max(days.map(\.sentences).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(days, id: \.day) { d in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle().fill(TR.line2)
                            .frame(height: height * CGFloat(d.sentences - d.clean) / CGFloat(peak))
                        Rectangle().fill(TR.fix)
                            .frame(height: height * CGFloat(d.clean) / CGFloat(peak))
                    }
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
                    .help("\(d.day)：\(d.sentences) 句，\(d.clean) 句一次就对")
                }
            }
            HStack {
                Text(days.first.map { TRDate.day(key: $0.day) } ?? "")
                Spacer()
                Text("今天")
            }
            .font(.system(size: 12)).foregroundStyle(TR.text2)
            HStack(spacing: 12) {
                legend(TR.fix, "一次就对")
                legend(TR.line2, "帮你改过")
            }
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(text).font(.system(size: 12)).foregroundStyle(TR.text2)
        }
    }

}

// MARK: - 今天

struct TRTodayPage: View {
    @ObservedObject var notebook: CoachNotebook
    let open: (TRPage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            hero
            // Three cards of one height, at most four lines each; the rest is behind 全部 ›.
            HStack(alignment: .top, spacing: 16) {
                TRCard(title: "今天帮你改的", more: "全部", onMore: { open(.mistakes) }) { todayList }
                TRCard(title: "错题本", more: "全部", onMore: { open(.mistakes) }) { categorySummary }
                TRCard(title: "生词本", more: "全部", onMore: { open(.words) }) { wordList }
            }
            .fixedSize(horizontal: false, vertical: true)
            if !notebook.almostLearned.isEmpty {
                TRCard(title: "快掌握了") {
                    HStack(spacing: 8) {
                        ForEach(notebook.almostLearned.prefix(4)) { e in
                            HStack(spacing: 6) {
                                TRDiffText(from: e.from, to: e.to, size: 13)
                                TRDots(filled: e.correctUses)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(TR.fill, in: RoundedRectangle(cornerRadius: 6))
                        }
                        Spacer()
                        Text("下次写对就算会了").font(.system(size: 12)).foregroundStyle(TR.text2)
                    }
                    .padding(.horizontal, 16).padding(.bottom, 14)
                }
            }
        }
    }

    private var hero: some View {
        let days = notebook.lastDays(14)
        let total = days.reduce(0) { $0 + $1.sentences }
        let clean = days.reduce(0) { $0 + $1.clean }
        return TRCard {
            HStack(alignment: .center, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    if total == 0 {
                        Text("还没开始。").font(.system(size: 22, weight: .semibold)).foregroundStyle(TR.text)
                        Text("在任何 App 里打几句英文：拼错了、不会说先打中文、一句打完，TypeRight 都会在旁边弹出来。改过的地方会记在这里。")
                            .font(.system(size: 13)).foregroundStyle(TR.text2).fixedSize(horizontal: false, vertical: true)
                    } else {
                        (Text("这两周你写了 ") + Text("\(total)").foregroundColor(TR.fix) + Text(" 句英文，\(clean) 句一次就对。"))
                            .font(.system(size: 22, weight: .semibold)).foregroundStyle(TR.text)
                        Text(heroNote(days))
                            .font(.system(size: 13)).foregroundStyle(TR.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                TRDayBars(days: days).frame(width: 360)
            }
            .padding(28)
        }
    }

    private func heroNote(_ days: [DayStat]) -> String {
        func rate(_ slice: ArraySlice<DayStat>) -> Int? {
            let s = slice.reduce(0) { $0 + $1.sentences }
            return s == 0 ? nil : Int((Double(slice.reduce(0) { $0 + $1.clean }) / Double(s) * 100).rounded())
        }
        var parts: [String] = []
        if let first = rate(days.prefix(7)), let last = rate(days.suffix(7)) {
            parts.append("一次就对的从上周的 \(first)% 到这周的 \(last)%。")
        }
        if let top = TRCategoryStats.mostCorrected(notebook.mistakes) {
            parts.append("最常被改的是\(top.title)，")
        }
        parts.append("被改过的地方都在错题本里，再用对 \(CoachNotebook.usesToMaster) 次就算会了。")
        return parts.joined()
    }

    @ViewBuilder private var todayList: some View {
        if notebook.today.isEmpty {
            TREmpty(text: "今天还没改过。")
        } else {
            VStack(spacing: 0) {
                ForEach(Array(notebook.today.prefix(Self.cardLines).enumerated()), id: \.element.id) { i, e in
                    VStack(alignment: .leading, spacing: 4) {
                        if e.kind == .word {
                            HStack(spacing: 5) {
                                Text(e.from).foregroundStyle(TR.text)
                                Text("→").foregroundStyle(TR.text3)
                                TRDiffText(from: "", to: e.to)
                                Text(e.ipa).foregroundStyle(TR.text2)
                            }
                            .font(.system(size: 13))
                        } else {
                            TRDiffText(from: e.from, to: e.to)
                        }
                        HStack(spacing: 8) {
                            Text(TRMeta.line(e)).font(.system(size: 12)).foregroundStyle(TR.text2).lineLimit(1)
                            TRHowTag(how: e.how)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    if i < min(notebook.today.count, Self.cardLines) - 1 { Rectangle().fill(TR.line).frame(height: 0.5) }
                }
            }
        }
    }

    @ViewBuilder private var categorySummary: some View {
        let groups = TRCategoryStats.ranked(notebook.mistakes)
        if groups.isEmpty {
            TREmpty(text: "还没有错题。")
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(groups.prefix(Self.cardLines), id: \.category) { category, items in
                    let learned = items.filter(\.mastered).count
                    HStack(alignment: .top, spacing: 12) {
                        Text(category.title).font(.system(size: 13)).foregroundStyle(TR.text).frame(width: 64, alignment: .leading)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(TR.fill)
                                        Capsule().fill(TR.fix).frame(width: geo.size.width * CGFloat(learned) / CGFloat(max(items.count, 1)))
                                    }
                                }
                                .frame(height: 4)
                                Text("\(learned) / \(items.count) 会了").font(.system(size: 12).monospacedDigit()).foregroundStyle(TR.text2)
                            }
                            if let example = items.first {
                                TRDiffText(from: example.from, to: example.to, size: 12)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private static let cardLines = 4

    private func wordText(_ word: String) -> some View {
        Text(word).font(.system(size: 14, weight: .medium)).foregroundStyle(TR.text).lineLimit(1)
    }

    @ViewBuilder private var wordList: some View {
        if notebook.words.isEmpty {
            TREmpty(text: "还没有生词。不会说的词先打中文，它会帮你变成英文并记在这里。")
        } else {
            VStack(spacing: 0) {
                ForEach(Array(notebook.words.prefix(Self.cardLines).enumerated()), id: \.element.id) { i, w in
                    HStack(spacing: 8) {
                        Text(w.from).font(.system(size: 12)).foregroundStyle(TR.text2)
                            .lineLimit(1).frame(width: 56, alignment: .leading)
                        // The IPA shows whole or not at all: never cut to "/'…".
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                wordText(w.to)
                                Text(w.ipa).font(.system(size: 12)).foregroundStyle(TR.text2).lineLimit(1).fixedSize()
                            }
                            wordText(w.to)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        TRSpeakButton(text: w.to)
                    }
                    .padding(.horizontal, 16).frame(height: 42)
                    if i < min(notebook.words.count, Self.cardLines) - 1 { Rectangle().fill(TR.line).frame(height: 0.5) }
                }
            }
        }
    }
}

// MARK: - 错题本

struct TRMistakesPage: View {
    @ObservedObject var notebook: CoachNotebook
    @State private var category: MistakeCategory?

    var body: some View {
        let all = notebook.mistakes
        let present = MistakeCategory.allCases.filter { c in all.contains { $0.category == c } }
        let shown = all.filter { category == nil || $0.category == category }
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                chip("全部", all.count, selected: category == nil) { category = nil }
                ForEach(present) { c in
                    chip(c.title, all.filter { $0.category == c }.count, selected: category == c) { category = c }
                }
            }
            TRCard {
                if shown.isEmpty {
                    TREmpty(text: "还没有错题。被 TypeRight 改过的地方会记在这里，按错误类型分好。")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, e in
                            row(e)
                            if i < shown.count - 1 { Rectangle().fill(TR.line).frame(height: 0.5) }
                        }
                    }
                }
            }
        }
    }

    private func chip(_ title: String, _ count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count)").foregroundStyle(TR.text3).monospacedDigit()
            }
            .font(.system(size: 12))
            .foregroundStyle(TR.text)
            .padding(.horizontal, 10).frame(height: 26)
            .background(selected ? TR.sel : TR.fill, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func row(_ e: NotebookEntry) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                TRDiffText(from: e.from, to: e.to, size: 14)
                if !e.why.isEmpty { Text(e.why).font(.system(size: 12)).foregroundStyle(TR.text2) }
                if !e.context.isEmpty { Text(e.context).font(.system(size: 12)).foregroundStyle(TR.text2).italic() }
                HStack(spacing: 8) {
                    Text(TRMeta.line(e)).font(.system(size: 12)).foregroundStyle(TR.text2)
                    TRHowTag(how: e.how)
                }
            }
            Spacer()
            if e.mastered {
                Text("会了").font(.system(size: 12, weight: .medium)).foregroundStyle(TR.fix)
            } else {
                TRDots(filled: e.correctUses)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
        .contextMenu {
            Button(e.mastered ? "标为没会" : "标为会了") { notebook.setMastered(e.id, !e.mastered) }
            Divider()
            Button("删除", role: .destructive) { notebook.delete(e.id) }
        }
    }
}

// MARK: - 生词本

struct TRWordsPage: View {
    @ObservedObject var notebook: CoachNotebook

    var body: some View {
        TRCard {
            if notebook.words.isEmpty {
                TREmpty(text: "还没有生词。不会说的词先打中文或拼音，TypeRight 会把它变成英文，并记在这里。")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(notebook.words.enumerated()), id: \.element.id) { i, w in
                        HStack(alignment: .top, spacing: 14) {
                            Text(w.from).font(.system(size: 13)).foregroundStyle(TR.text2).frame(width: 90, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(w.to).font(.system(size: 15, weight: .semibold)).foregroundStyle(TR.text)
                                    Text(w.ipa).font(.system(size: 13)).foregroundStyle(TR.text2)
                                    TRSpeakButton(text: w.to)
                                }
                                if !w.why.isEmpty { Text(w.why).font(.system(size: 12)).foregroundStyle(TR.text2) }
                                if !w.context.isEmpty { Text(w.context).font(.system(size: 12)).foregroundStyle(TR.text2).italic() }
                            }
                            Spacer()
                            HStack(spacing: 8) {
                                Text(TRMeta.line(w, kind: false)).font(.system(size: 12)).foregroundStyle(TR.text2)
                                TRHowTag(how: w.how)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .contentShape(Rectangle())
                        .contextMenu { Button("删除", role: .destructive) { notebook.delete(w.id) } }
                        if i < notebook.words.count - 1 { Rectangle().fill(TR.line).frame(height: 0.5) }
                    }
                }
            }
        }
    }
}

// MARK: - 进步

struct TRProgressPage: View {
    @ObservedObject var notebook: CoachNotebook

    var body: some View {
        let days = notebook.lastDays(14)
        let sentences = days.reduce(0) { $0 + $1.sentences }
        let clean = days.reduce(0) { $0 + $1.clean }
        let learned = notebook.mistakes.filter(\.mastered).count
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                stat("两周写的句子", "\(sentences)")
                stat("一次就对", sentences == 0 ? "—" : "\(Int((Double(clean) / Double(sentences) * 100).rounded()))%")
                stat("错题", "\(notebook.mistakes.count)")
                stat("学会了", "\(learned)")
                stat("生词", "\(notebook.words.count)")
            }
            TRCard(title: "最近 14 天") {
                TRDayBars(days: days, height: 160).padding(16)
            }
            TRCard(title: "每类错误学会了多少") {
                let groups = TRCategoryStats.ranked(notebook.mistakes)
                if groups.isEmpty {
                    TREmpty(text: "还没有错题。")
                } else {
                    VStack(spacing: 10) {
                        ForEach(groups, id: \.category) { category, items in
                            let done = items.filter(\.mastered).count
                            HStack(spacing: 12) {
                                Text(category.title).font(.system(size: 13)).foregroundStyle(TR.text).frame(width: 80, alignment: .leading)
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(TR.fill)
                                        Capsule().fill(TR.fix).frame(width: geo.size.width * CGFloat(done) / CGFloat(max(items.count, 1)))
                                    }
                                }
                                .frame(height: 6)
                                Text("\(done) / \(items.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(TR.text2).frame(width: 60, alignment: .trailing)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12)).foregroundStyle(TR.text2)
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit()).foregroundStyle(TR.text)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TR.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(TR.line, lineWidth: 0.5))
    }
}
