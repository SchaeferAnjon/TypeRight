//
//  PreferencesView.swift
//  TextWarden
//
//  TextWarden's settings, shown in TypeRight under 设置 › 高级: a row of tabs drawn with
//  TypeRight's own segmented control under the page header, and each tab built from the same
//  groups and rows as the other settings pages.
//

import AppKit
import KeyboardShortcuts
import SwiftUI

struct PreferencesView: View {
    /// Made-up data for screenshots, so nothing from this Mac shows up in them.
    struct Sample {
        var appBundleIDs: Set<String>
        var health: RuntimeHealthSnapshot
        var fixAllName: KeyboardShortcuts.Name
        var rewriteName: KeyboardShortcuts.Name
    }

    static let tabs: [(SettingsTab, String)] = [
        (.general, "通用"), (.grammar, "拼写"), (.style, "改写"), (.applications, "全部 App"),
        (.websites, "网站"), (.diagnostics, "诊断"), (.about, "关于"),
    ]

    /// The settings shown; screenshots pass a throwaway store instead of the user's.
    @ObservedObject var preferences: UserPreferences = .shared
    var vocabulary: CustomVocabulary = .shared
    var sample: Sample?
    @ObservedObject private var windowController = PreferencesWindowController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TRSegmented(options: Self.tabs.map { ($0.0.rawValue, $0.1) }, selection: $windowController.selectedTab)
                .padding(.horizontal, TRSettingsView.gutter)
                .padding(.top, 16)
                .padding(.bottom, 4)
            ScrollView {
                page
                    .padding(.horizontal, TRSettingsView.gutter).padding(.top, 16).padding(.bottom, 24)
                    .frame(maxWidth: TRSettingsView.columnWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var page: some View {
        switch SettingsTab(rawValue: windowController.selectedTab) ?? .general {
        case .general, .statistics, .browser:
            GeneralPreferencesView(preferences: preferences,
                                   fixAllName: sample?.fixAllName ?? .fixAllObvious,
                                   rewriteName: sample?.rewriteName ?? .quickRewrite)
        case .grammar: SpellCheckingView(preferences: preferences, vocabulary: vocabulary)
        case .style: StyleCheckingSettingsView(preferences: preferences)
        case .applications: ApplicationSettingsView(preferences: preferences, sampleBundleIDs: sample?.appBundleIDs)
        case .websites: WebsiteSettingsView(preferences: preferences, showsCurrentSite: sample == nil)
        case .diagnostics: DiagnosticsView(preferences: preferences, vocabulary: vocabulary, sampleHealth: sample?.health)
        case .about: AboutView()
        }
    }
}

// MARK: - Spelling (categories, language and dictionary)

struct SpellCheckingView: View {
    @ObservedObject var preferences: UserPreferences
    @ObservedObject var vocabulary: CustomVocabulary

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            FilteringPreferencesContent(preferences: preferences)

            TRGroup(title: "英语") {
                TRRow(title: "拼法按", note: "比如 color 和 colour：美式英语算 colour 拼错，英式英语反过来。", last: true) {
                    Picker("", selection: $preferences.selectedDialect) {
                        ForEach(UserPreferences.availableDialects, id: \.self) { dialect in
                            Text(UserPreferences.dialectLabel(dialect)).tag(dialect)
                        }
                    }
                    .labelsHidden().frame(width: 130)
                }
            }

            CustomVocabularyContent(vocabulary: vocabulary, preferences: preferences)
        }
    }
}

// MARK: - Categories

private struct FilteringPreferencesContent: View {
    @ObservedObject var preferences: UserPreferences

    private func categoryBinding(_ category: String) -> Binding<Bool> {
        Binding(
            get: { preferences.enabledCategories.contains(category) },
            set: { enabled in
                var categories = preferences.enabledCategories
                if enabled {
                    categories.insert(category)
                } else {
                    categories.remove(category)
                }
                preferences.enabledCategories = categories
            }
        )
    }

    private func row(_ title: String, _ note: String, _ category: String, last: Bool = false) -> some View {
        TRRow(title: title, note: note, last: last) {
            Toggle("", isOn: categoryBinding(category)).toggleStyle(SquareToggleStyle()).labelsHidden()
        }
    }

    private func option(_ title: String, _ note: String, _ isOn: Binding<Bool>, last: Bool = false) -> some View {
        TRRow(title: title, note: note, last: last) {
            Toggle("", isOn: isOn).toggleStyle(SquareToggleStyle()).labelsHidden()
        }
        .padding(.leading, 20)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 16) {
                Text("在这台 Mac 上查，不联网。拼错的词弹框只用「拼写」和「手误」；「一键改掉明显的错」会用到所有打开的类别。")
                    .font(.system(size: 12)).foregroundStyle(TR.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("全部打开") { preferences.enabledCategories = UserPreferences.allCategories }
                    .buttonStyle(TRPlainButtonStyle())
                Button("全部关掉") { preferences.enabledCategories = [] }
                    .buttonStyle(TRPlainButtonStyle())
            }

            TRGroup(title: "基础") {
                row("拼写", "不知道这个词怎么拼", "Spelling")
                row("手误", "知道怎么拼，手打错了", "Typo")
                row("语法", "句子结构和语法错误", "Grammar")
                row("主谓一致", "比如 he go → he goes", "Agreement")
                row("标点", "标点用法，包括复合形容词里的连字符", "Punctuation")
                if preferences.enabledCategories.contains("Punctuation") {
                    option("牛津逗号", "列三样以上时，and 前面也要逗号", $preferences.enforceOxfordComma)
                    option("省略号", "三个句点换成省略号（…）", $preferences.checkEllipsis)
                    option("引号没配对", "引号开了没关", $preferences.checkUnclosedQuotes)
                    option("横线用法", "em dash、en dash 和连字符用得对不对", $preferences.checkDashes)
                }
                row("大小写", "句首和专有名词的大写", "Capitalization", last: true)
            }

            // Harper's own Readability category stays off: TextWarden measures readability itself.
            TRGroup(title: "风格和清楚") {
                row("风格", "几种说法都对，但有一种更常用", "Style")
                row("说得更好", "不是错，但能说得更清楚", "Enhancement")
                row("意思重复", "比如 return back", "Redundancy")
                row("用词重复", "挨着的句子里用了同一个词", "Repetition", last: true)
            }

            TRGroup(title: "用词") {
                row("选词", "这个场合换一个词更合适", "WordChoice")
                row("惯用法", "常见搭配和习惯说法", "Usage")
                row("近音误用（短语）", "比如 for all intensive purposes → for all intents and purposes", "Eggcorn")
                row("近音误用（单词）", "比如 escape goat → scapegoat", "Malapropism", last: true)
            }

            TRGroup(title: "更多") {
                row("格式", "空格和特殊字符", "Formatting")
                row("分写和连写", "比如 each and everyone → each and every one", "BoundaryError")
                row("地区说法", "只在某些地区这么说", "Regionalism")
                row("不规范用法", "口语或不规范的说法", "Nonstandard")
                row("其他", "不属于上面几类的问题", "Miscellaneous", last: true)
            }
        }
    }
}

// MARK: - Dictionary

private struct CustomVocabularyContent: View {
    @ObservedObject var vocabulary: CustomVocabulary
    @ObservedObject var preferences: UserPreferences
    @State private var newWord = ""
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var showClearDictionaryAlert = false

    private var filteredWords: [String] {
        let allWords = Array(vocabulary.words).sorted()
        if searchText.isEmpty {
            return allWords
        }
        return allWords.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TRGroup(title: "内置词表", note: "这些词不算拼错，不分大小写。") {
                wordlist("网络缩写", $preferences.enableInternetAbbreviations, "3,200 多个缩写（BTW、FYI、LOL、ASAP、AFAICT 等）")
                wordlist("新潮说法", $preferences.enableGenZSlang, "270 多个新词（ghosting、sus、slay、vibe 等）")
                wordlist("IT 和技术词", $preferences.enableITTerminology, "1 万多个技术词（kubernetes、docker、nginx、API、JSON 等）")
                wordlist("品牌和公司名", $preferences.enableBrandNames, "2,400 多个品牌和公司名（财富 500 强、福布斯 2000 强等）")
                wordlist("人名（名）", $preferences.enablePersonNames, "10 万多个各国常见的名")
                wordlist("人名（姓）", $preferences.enableLastNames, "15 万多个姓（来自美国人口普查）", last: true)
            }

            TRGroup(title: "别的语言") {
                TRRow(title: "跳过选中的语言", note: "一段话能确定是下面选的语言时，不按英文查拼写和语法。",
                      last: !preferences.enableLanguageDetection) {
                    Toggle("", isOn: $preferences.enableLanguageDetection).toggleStyle(SquareToggleStyle()).labelsHidden()
                }
                if preferences.enableLanguageDetection {
                    LanguageSelectorView(selectedLanguageCodes: $preferences.excludedLanguages)
                        .padding(14)
                }
            }

            TRGroup(title: "系统词典") {
                TRRow(title: "用 macOS「学习拼写」学过的词", note: "在 Safari、邮件、Pages 等 App 里学过的词，这里也不算拼错。", last: true) {
                    Toggle("", isOn: $preferences.enableMacOSDictionary).toggleStyle(SquareToggleStyle()).labelsHidden()
                }
            }

            TRGroup(title: "自定义词典", note: "加进来的词不再算拼错，大小写要一致。") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TRTextField(placeholder: "加一个词", text: $newWord, onSubmit: addWord)
                        Button("加入", action: addWord)
                            .buttonStyle(TRPlainButtonStyle())
                            .disabled(newWord.isEmpty)
                            .help("加进词典")
                    }
                    if let errorMessage {
                        TRStatusDot(color: TR.warn, text: errorMessage)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Rectangle().fill(TR.line).frame(height: 0.5).padding(.leading, 14)

                if vocabulary.words.isEmpty {
                    TRRow(title: "还没有加词", last: true) { EmptyView() }
                } else {
                    TRTextField(placeholder: "在 \(vocabulary.words.count) 个词里找…", text: $searchText, search: true)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                    Rectangle().fill(TR.line).frame(height: 0.5).padding(.leading, 14)
                    if filteredWords.isEmpty {
                        TRRow(title: "没找到") { EmptyView() }
                    }
                    ForEach(filteredWords, id: \.self) { word in
                        TRRow(title: word) {
                            Button { removeWord(word) } label: {
                                Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).foregroundStyle(TR.text2)
                                    .frame(width: 24, height: 24).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("从词典里删掉")
                        }
                    }
                    TRRow(title: "清空自定义词典", note: "删掉词典里的全部 \(vocabulary.words.count) 个词，删了找不回来", last: true) {
                        Button("清空…") { showClearDictionaryAlert = true }
                            .buttonStyle(TRPlainButtonStyle(tint: TR.danger))
                    }
                }
            }
        }
        .alert("清空自定义词典？", isPresented: $showClearDictionaryAlert) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                clearAll()
            }
        } message: {
            Text("会删掉词典里的全部 \(vocabulary.words.count) 个词，删了找不回来。")
        }
    }

    private func wordlist(_ title: String, _ isOn: Binding<Bool>, _ note: String, last: Bool = false) -> some View {
        TRRow(title: title, note: note, last: last) {
            Toggle("", isOn: isOn).toggleStyle(SquareToggleStyle()).labelsHidden()
        }
    }

    private func addWord() {
        guard !newWord.isEmpty else { return }

        do {
            try vocabulary.addWord(newWord)
            newWord = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeWord(_ word: String) {
        do {
            try vocabulary.removeWord(word)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearAll() {
        do {
            try vocabulary.clearAll()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
