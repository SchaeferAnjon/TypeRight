//
//  PreferencesView.swift
//  TextWarden
//
//  TextWarden's settings, shown in TypeRight under 设置 › 高级.
//

import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

struct PreferencesView: View {
    /// Made-up data for screenshots, so nothing from this Mac shows up in them.
    struct Sample {
        var appBundleIDs: Set<String>
        var health: RuntimeHealthSnapshot
        var fixAllName: KeyboardShortcuts.Name
        var rewriteName: KeyboardShortcuts.Name
    }

    /// The settings shown; screenshots pass a throwaway store instead of the user's.
    @ObservedObject var preferences: UserPreferences = .shared
    var vocabulary: CustomVocabulary = .shared
    var sample: Sample?
    @ObservedObject private var windowController = PreferencesWindowController.shared

    var body: some View {
        TabView(selection: $windowController.selectedTab) {
            GeneralPreferencesView(preferences: preferences,
                                   fixAllName: sample?.fixAllName ?? .fixAllObvious,
                                   rewriteName: sample?.rewriteName ?? .quickRewrite)
                .tabItem {
                    Label("通用", systemImage: "gearshape")
                }
                .tag(SettingsTab.general.rawValue)
                .accessibilityLabel("通用")

            SpellCheckingView(preferences: preferences, vocabulary: vocabulary)
                .tabItem {
                    Label("拼写", systemImage: "text.badge.checkmark")
                }
                .tag(SettingsTab.grammar.rawValue)
                .accessibilityLabel("拼写和语法")

            StyleCheckingSettingsView(preferences: preferences)
                .tabItem {
                    Label("改写", systemImage: "sparkles")
                }
                .tag(SettingsTab.style.rawValue)
                .accessibilityLabel("用 Apple 智能改写")

            ApplicationSettingsView(preferences: preferences, sampleBundleIDs: sample?.appBundleIDs)
                .tabItem {
                    Label("全部 App", systemImage: "app.badge")
                }
                .tag(SettingsTab.applications.rawValue)
                .accessibilityLabel("全部 App")

            WebsiteSettingsView(preferences: preferences, showsCurrentSite: sample == nil)
                .tabItem {
                    Label("网站", systemImage: "globe")
                }
                .tag(SettingsTab.websites.rawValue)
                .accessibilityLabel("网站")

            DiagnosticsView(preferences: preferences, vocabulary: vocabulary, sampleHealth: sample?.health)
                .tabItem {
                    Label("诊断", systemImage: "wrench.and.screwdriver")
                }
                .tag(SettingsTab.diagnostics.rawValue)
                .accessibilityLabel("诊断")

            AboutView()
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
                .tag(SettingsTab.about.rawValue)
                .accessibilityLabel("关于 TypeRight")
        }
        .frame(minWidth: 750, minHeight: 600)
        // Theme is managed via NSApp.appearance in PreferencesWindowController
        // This provides seamless theme switching without view recreation or scroll position reset
    }
}

// MARK: - Spelling (categories, language and dictionary)

struct SpellCheckingView: View {
    @ObservedObject var preferences: UserPreferences
    @ObservedObject var vocabulary: CustomVocabulary
    @State private var newWord = ""
    @State private var searchText = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            // MARK: Categories

            FilteringPreferencesContent(preferences: preferences)

            // MARK: Language Settings

            Section {
                Picker("拼法按：", selection: $preferences.selectedDialect) {
                    ForEach(UserPreferences.availableDialects, id: \.self) { dialect in
                        Text(UserPreferences.dialectLabel(dialect)).tag(dialect)
                    }
                }
                .help("按哪种英语的拼法和用法检查")

                Text("比如 color 和 colour：美式英语算 colour 拼错，英式英语反过来。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "globe")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                        Text("英语")
                            .font(.title3)
                            .fontWeight(.semibold)
                    }

                    Text("按哪种英语检查")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // MARK: Vocabulary Group Header

            Section {
                EmptyView()
            } header: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "text.book.closed.fill")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                        Text("词典")
                            .font(.title3)
                            .fontWeight(.semibold)
                    }

                    Text("这些词不算拼错；别的语言的段落可以整段跳过")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            CustomVocabularyContent(
                vocabulary: vocabulary,
                preferences: preferences,
                newWord: $newWord,
                searchText: $searchText,
                errorMessage: $errorMessage
            )
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Categories

private struct FilteringPreferencesContent: View {
    @ObservedObject var preferences: UserPreferences

    /// Helper to create toggle binding for a category
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

    var body: some View {
        Group {
            // Quick Actions
            Section {
                HStack {
                    Button("全部打开") {
                        preferences.enabledCategories = UserPreferences.allCategories
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("全部关掉") {
                        preferences.enabledCategories = []
                    }
                    .buttonStyle(.bordered)
                }
            } header: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                        Text("查哪些错")
                            .font(.title3)
                            .fontWeight(.semibold)
                    }

                    Text("在这台 Mac 上查，不联网。拼错的词弹框只用「拼写」和「手误」；「一键改掉明显的错」会用到所有打开的类别。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Core Grammar Checks
            Section {
                Toggle("拼写", isOn: categoryBinding("Spelling"))
                    .help("不知道这个词怎么拼")

                Toggle("手误", isOn: categoryBinding("Typo"))
                    .help("知道怎么拼，手打错了")

                Toggle("语法", isOn: categoryBinding("Grammar"))
                    .help("句子结构和语法错误")

                Toggle("主谓一致", isOn: categoryBinding("Agreement"))
                    .help("比如 he go → he goes")

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("标点", isOn: categoryBinding("Punctuation"))
                        .help("标点用法，包括复合形容词里的连字符")

                    if preferences.enabledCategories.contains("Punctuation") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("牛津逗号", isOn: $preferences.enforceOxfordComma)
                                .help("列三样以上时，and 前面也要逗号")

                            Toggle("省略号", isOn: $preferences.checkEllipsis)
                                .help("三个句点换成省略号（…）")

                            Toggle("引号没配对", isOn: $preferences.checkUnclosedQuotes)
                                .help("引号开了没关")

                            Toggle("横线用法", isOn: $preferences.checkDashes)
                                .help("em dash、en dash 和连字符用得对不对")
                        }
                        .padding(.leading, 20)
                        .font(.callout)
                    }
                }

                Toggle("大小写", isOn: categoryBinding("Capitalization"))
                    .help("句首和专有名词的大写")
            } header: {
                Text("基础")
                    .font(.headline)
            }

            // Writing Style
            Section {
                Toggle("风格", isOn: categoryBinding("Style"))
                    .help("几种说法都对，但有一种更常用")

                // Note: Harper's "Readability" category is disabled - we use our own
                // ReadabilityCalculator with Flesch Reading Ease and AI simplification

                Toggle("说得更好", isOn: categoryBinding("Enhancement"))
                    .help("不是错，但能说得更清楚")

                Toggle("意思重复", isOn: categoryBinding("Redundancy"))
                    .help("比如 return back")

                Toggle("用词重复", isOn: categoryBinding("Repetition"))
                    .help("挨着的句子里用了同一个词")
            } header: {
                Text("风格和清楚")
                    .font(.headline)
            }

            // Word Usage
            Section {
                Toggle("选词", isOn: categoryBinding("WordChoice"))
                    .help("这个场合换一个词更合适")

                Toggle("惯用法", isOn: categoryBinding("Usage"))
                    .help("常见搭配和习惯说法")

                Toggle("近音误用（短语）", isOn: categoryBinding("Eggcorn"))
                    .help("比如 for all intensive purposes → for all intents and purposes")

                Toggle("近音误用（单词）", isOn: categoryBinding("Malapropism"))
                    .help("比如 escape goat → scapegoat")
            } header: {
                Text("用词")
                    .font(.headline)
            }

            // Advanced
            Section {
                Toggle("格式", isOn: categoryBinding("Formatting"))
                    .help("空格和特殊字符")

                Toggle("分写和连写", isOn: categoryBinding("BoundaryError"))
                    .help("比如 each and everyone → each and every one")

                Toggle("地区说法", isOn: categoryBinding("Regionalism"))
                    .help("只在某些地区这么说")

                Toggle("不规范用法", isOn: categoryBinding("Nonstandard"))
                    .help("口语或不规范的说法")

                Toggle("其他", isOn: categoryBinding("Miscellaneous"))
                    .help("不属于上面几类的问题")
            } header: {
                Text("更多")
                    .font(.headline)
            }
        }
    }
}

// MARK: - Dictionary

private struct CustomVocabularyContent: View {
    @ObservedObject var vocabulary: CustomVocabulary
    @ObservedObject var preferences: UserPreferences
    @Binding var newWord: String
    @Binding var searchText: String
    @Binding var errorMessage: String?
    @State private var showClearDictionaryAlert: Bool = false

    private var filteredWords: [String] {
        let allWords = Array(vocabulary.words).sorted()
        if searchText.isEmpty {
            return allWords
        }
        return allWords.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        Group {
            // MARK: - Predefined Wordlists Section

            Section {
                wordlist("网络缩写", $preferences.enableInternetAbbreviations,
                         "3,200 多个缩写（BTW、FYI、LOL、ASAP、AFAICT 等），不分大小写")
                wordlist("新潮说法", $preferences.enableGenZSlang,
                         "270 多个新词（ghosting、sus、slay、vibe 等），不分大小写")
                wordlist("IT 和技术词", $preferences.enableITTerminology,
                         "1 万多个技术词（kubernetes、docker、nginx、API、JSON 等），不分大小写")
                wordlist("品牌和公司名", $preferences.enableBrandNames,
                         "2,400 多个品牌和公司名（财富 500 强、福布斯 2000 强等），不分大小写")
                wordlist("人名（名）", $preferences.enablePersonNames,
                         "10 万多个各国常见的名，不分大小写")
                wordlist("人名（姓）", $preferences.enableLastNames,
                         "15 万多个姓（来自美国人口普查），不分大小写")
            } header: {
                Text("内置词表")
                    .font(.headline)
            }

            // MARK: - Language Detection Section

            Section {
                Toggle("跳过选中的语言", isOn: $preferences.enableLanguageDetection)
                    .help("认出是这些语言的段落，就不按英文查")

                Text("一段话能确定是下面选的语言时，不按英文查拼写和语法。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if preferences.enableLanguageDetection {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("要跳过的语言")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)

                        LanguageSelectorView(selectedLanguageCodes: $preferences.excludedLanguages)
                    }
                }
            } header: {
                Text("别的语言")
                    .font(.headline)
            }

            // MARK: - System Dictionary Section

            Section {
                Toggle("用 macOS「学习拼写」学过的词", isOn: $preferences.enableMacOSDictionary)
                    .help("在别的 App 里点过「学习拼写」的词，这里也不算错")

                Text("在 Safari、邮件、Pages 等 App 里学过的词，这里也不算拼错。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("系统词典")
                    .font(.headline)
            }

            // MARK: - Custom Dictionary Section

            Section {
                // Add word input row
                HStack(spacing: 8) {
                    Text("加一个词：")
                        .foregroundColor(.secondary)

                    LeftAlignedTextField(
                        text: $newWord,
                        placeholder: "",
                        onSubmit: { addWord() }
                    )
                    .frame(minHeight: 22, maxHeight: 22)

                    Button("加入") {
                        addWord()
                    }
                    .buttonStyle(.bordered)
                    .disabled(newWord.isEmpty)
                    .help("加进词典")

                    // Error message inline
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                // Search field (only show when there are words)
                if !vocabulary.words.isEmpty {
                    SearchField(text: $searchText, placeholder: "在 \(vocabulary.words.count) 个词里找…")
                        .frame(height: 22)
                }

                // Word list
                if vocabulary.words.isEmpty {
                    Text("还没有加词")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                        .padding(.vertical, 8)
                } else if filteredWords.isEmpty, !searchText.isEmpty {
                    Text("没找到")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                        .padding(.vertical, 8)
                } else {
                    ForEach(filteredWords, id: \.self) { word in
                        HStack {
                            Text(word)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                removeWord(word)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("从词典里删掉")
                        }
                    }
                }
            } header: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("自定义词典")
                            .font(.headline)
                        Text("加进来的词不再算拼错，大小写要一致")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if !vocabulary.words.isEmpty {
                        Button {
                            showClearDictionaryAlert = true
                        } label: {
                            Label("清空", systemImage: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
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
    }

    private func wordlist(_ title: String, _ isOn: Binding<Bool>, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn)
            Text(note)
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.leading, 20)
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
