//
//  TRPages.swift
//  TypeRight
//
//  The four pages of the main window.
//

import SwiftUI

// MARK: - Shared pieces

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
        .frame(maxWidth: .infinity, alignment: .topLeading)
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

struct TREmpty: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
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
                Text(Self.label(days.first?.day))
                Spacer()
                Text("今天")
            }
            .font(.system(size: 12)).foregroundStyle(TR.text3)
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

    private static func label(_ day: String?) -> String {
        guard let day, day.count == 10 else { return "" }
        let month = Int(day.dropFirst(5).prefix(2)) ?? 0
        let date = Int(day.suffix(2)) ?? 0
        return "\(month) 月 \(date) 日"
    }
}

private func timeText(_ date: Date) -> String {
    date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
}

private func dayText(_ date: Date) -> String {
    Calendar.current.isDateInToday(date) ? timeText(date) : date.formatted(.dateTime.month(.defaultDigits).day().locale(Locale(identifier: "zh_CN")))
}

// MARK: - 今天

struct TRTodayPage: View {
    @ObservedObject var notebook: CoachNotebook
    let open: (TRPage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            hero
            HStack(alignment: .top, spacing: 16) {
                TRCard(title: "今天帮你改的", more: "错题本", onMore: { open(.mistakes) }) { todayList }
                TRCard(title: "错题本", more: "全部", onMore: { open(.mistakes) }) { categorySummary }
                TRCard(title: "生词本", more: "\(notebook.words.count) 个", onMore: { open(.words) }) { wordList }
            }
            if !notebook.almostLearned.isEmpty {
                TRCard(title: "快掌握了") {
                    HStack(spacing: 8) {
                        ForEach(notebook.almostLearned.prefix(4)) { e in
                            HStack(spacing: 6) {
                                TRDiffText(from: e.from, to: e.to, size: 12.5)
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
        let counts = Dictionary(grouping: notebook.mistakes, by: \.category).mapValues(\.count)
        if let top = counts.max(by: { $0.value < $1.value })?.key {
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
                ForEach(Array(notebook.today.prefix(6).enumerated()), id: \.element.id) { i, e in
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
                        Text([timeText(e.date), e.app, e.kind == .word ? "生词" : e.category.title].filter { !$0.isEmpty }.joined(separator: "  "))
                            .font(.system(size: 12)).foregroundStyle(TR.text3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    if i < min(notebook.today.count, 6) - 1 { Rectangle().fill(TR.line).frame(height: 0.5) }
                }
            }
        }
    }

    @ViewBuilder private var categorySummary: some View {
        let groups = Dictionary(grouping: notebook.mistakes, by: \.category)
            .sorted { $0.value.count > $1.value.count }
        if groups.isEmpty {
            TREmpty(text: "还没有错题。")
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(groups.prefix(5), id: \.key) { category, items in
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

    @ViewBuilder private var wordList: some View {
        if notebook.words.isEmpty {
            TREmpty(text: "还没有生词。不会说的词先打中文，它会帮你变成英文并记在这里。")
        } else {
            VStack(spacing: 0) {
                ForEach(Array(notebook.words.prefix(6).enumerated()), id: \.element.id) { i, w in
                    HStack(spacing: 10) {
                        Text(w.from).font(.system(size: 12.5)).foregroundStyle(TR.text2).frame(width: 64, alignment: .leading)
                        Text(w.to).font(.system(size: 13.5, weight: .medium)).foregroundStyle(TR.text)
                            .lineLimit(1).fixedSize().layoutPriority(1)
                        Text(w.ipa).font(.system(size: 12)).foregroundStyle(TR.text2).lineLimit(1).truncationMode(.tail)
                        Spacer()
                        TRSpeakButton(text: w.to)
                    }
                    .padding(.horizontal, 16).frame(height: 42)
                    if i < min(notebook.words.count, 6) - 1 { Rectangle().fill(TR.line).frame(height: 0.5) }
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
            .font(.system(size: 12.5))
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
                if !e.why.isEmpty { Text(e.why).font(.system(size: 12.5)).foregroundStyle(TR.text2) }
                if !e.context.isEmpty { Text(e.context).font(.system(size: 12.5)).foregroundStyle(TR.text2).italic() }
                Text([e.category.title, e.app, dayText(e.date), e.times > 1 ? "被改过 \(e.times) 次" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(TR.text3)
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
                                    Text(w.ipa).font(.system(size: 12.5)).foregroundStyle(TR.text2)
                                    TRSpeakButton(text: w.to)
                                }
                                if !w.why.isEmpty { Text(w.why).font(.system(size: 12.5)).foregroundStyle(TR.text2) }
                                if !w.context.isEmpty { Text(w.context).font(.system(size: 12.5)).foregroundStyle(TR.text3).italic() }
                            }
                            Spacer()
                            Text([w.app, dayText(w.date)].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 12)).foregroundStyle(TR.text3)
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
                let groups = Dictionary(grouping: notebook.mistakes, by: \.category).sorted { $0.value.count > $1.value.count }
                if groups.isEmpty {
                    TREmpty(text: "还没有错题。")
                } else {
                    VStack(spacing: 10) {
                        ForEach(groups, id: \.key) { category, items in
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
