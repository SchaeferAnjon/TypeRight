// LanguageSelectorView.swift
// Shared searchable selector for detector-supported languages.

import SwiftUI

struct LanguageSelectorView: View {
    private static let emptyStateHeight: CGFloat = 64
    private static let estimatedRowHeight: CGFloat = 46
    private static let selectedListMaximumRows: CGFloat = 3

    @Binding var selectedLanguageCodes: Set<String>
    let maxHeight: CGFloat

    @State private var searchText = ""

    init(selectedLanguageCodes: Binding<Set<String>>, maxHeight: CGFloat = 260) {
        _selectedLanguageCodes = selectedLanguageCodes
        self.maxHeight = maxHeight
    }

    private var selectedLanguages: [SupportedLanguage] {
        UserPreferences.availableLanguages.filter { selectedLanguageCodes.contains($0.code) }
    }

    private var availableLanguages: [SupportedLanguage] {
        UserPreferences.availableLanguages.filter { !selectedLanguageCodes.contains($0.code) }
    }

    private var hasSearchQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var displayedAvailableLanguages: [SupportedLanguage] {
        guard hasSearchQuery else { return availableLanguages }
        return availableLanguages.filter { $0.matches(searchText) || Self.chineseName($0).contains(searchText.trimmingCharacters(in: .whitespaces)) }
    }

    private var selectedListMaximumHeight: CGFloat {
        min(maxHeight, Self.estimatedRowHeight * Self.selectedListMaximumRows)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            languageList(
                title: "已选的语言",
                languages: selectedLanguages,
                totalCount: selectedLanguages.count,
                maximumHeight: selectedListMaximumHeight,
                emptyTitle: "还没选",
                emptyDescription: "在下面勾一种语言，它就到这里来。",
                isSelectedList: true
            )

            SearchField(text: $searchText, placeholder: "按名字或代码找语言")
                .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
                .accessibilityLabel("找语言")

            languageList(
                title: "可选的语言",
                languages: displayedAvailableLanguages,
                totalCount: availableLanguages.count,
                maximumHeight: maxHeight,
                emptyTitle: availableListEmptyTitle,
                emptyDescription: availableListEmptyDescription,
                isSelectedList: false
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var availableListEmptyTitle: String {
        if availableLanguages.isEmpty {
            return "全都选了"
        }
        return "没找到"
    }

    private var availableListEmptyDescription: String {
        if availableLanguages.isEmpty {
            return "在上面取消勾选，语言就回到这里。"
        }
        return "换个名字或代码试试。"
    }

    private func languageList(
        title: String,
        languages: [SupportedLanguage],
        totalCount: Int,
        maximumHeight: CGFloat,
        emptyTitle: String,
        emptyDescription: String,
        isSelectedList: Bool
    ) -> some View {
        let listHeight = languageListHeight(for: languages, maximumHeight: maximumHeight)

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))

                Spacer()

                Text(languageCountLabel(
                    visibleCount: languages.count,
                    totalCount: totalCount,
                    isSelectedList: isSelectedList
                ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                if languageListNeedsScrolling(languages, maximumHeight: maximumHeight) {
                    Divider()
                        .frame(height: 12)

                    Label("可以滚动", systemImage: "arrow.up.arrow.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isSelectedList, totalCount > 0 {
                    Divider()
                        .frame(height: 12)

                    Button("清空") {
                        selectedLanguageCodes.removeAll()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .help("全部取消勾选")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if languages.isEmpty {
                        emptyListState(
                            title: emptyTitle,
                            description: emptyDescription,
                            height: listHeight
                        )
                    } else {
                        languageRows(languages, isSelectedList: isSelectedList)
                    }
                }
            }
            .frame(height: listHeight)
            .scrollIndicators(.visible)
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func languageListHeight(
        for languages: [SupportedLanguage],
        maximumHeight: CGFloat
    ) -> CGFloat {
        guard !languages.isEmpty else { return Self.emptyStateHeight }
        return min(maximumHeight, CGFloat(languages.count) * Self.estimatedRowHeight)
    }

    private func languageListNeedsScrolling(
        _ languages: [SupportedLanguage],
        maximumHeight: CGFloat
    ) -> Bool {
        CGFloat(languages.count) * Self.estimatedRowHeight > maximumHeight
    }

    private func languageCountLabel(
        visibleCount: Int,
        totalCount: Int,
        isSelectedList: Bool
    ) -> String {
        if !isSelectedList, hasSearchQuery, visibleCount != totalCount {
            return "\(visibleCount) / \(totalCount)"
        }
        return isSelectedList ? "已选 \(totalCount) 种" : "共 \(totalCount) 种"
    }

    private func emptyListState(
        title: String,
        description: String,
        height: CGFloat
    ) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.callout.weight(.medium))

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: height)
    }

    private func languageRows(
        _ languages: [SupportedLanguage],
        isSelectedList: Bool
    ) -> some View {
        ForEach(languages) { language in
            languageToggle(language, isSelectedList: isSelectedList)

            Divider()
                .padding(.leading, 38)
        }
    }

    private func languageToggle(
        _ language: SupportedLanguage,
        isSelectedList: Bool
    ) -> some View {
        Toggle(isOn: selectionBinding(for: language.code)) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.chineseName(language))
                        .font(.body)

                    Text(language.nativeName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text(language.code.uppercased())
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityLabel(accessibilityLabel(for: language))
        .accessibilityHint(isSelectedList ? "移回可选的语言" : "移到已选的语言")
    }

    private func selectionBinding(for code: String) -> Binding<Bool> {
        Binding(
            get: { selectedLanguageCodes.contains(code) },
            set: { isSelected in
                if isSelected {
                    selectedLanguageCodes.insert(code)
                } else {
                    selectedLanguageCodes.remove(code)
                }
            }
        )
    }

    private func accessibilityLabel(for language: SupportedLanguage) -> String {
        "\(Self.chineseName(language))，\(language.nativeName)，\(language.code.uppercased())"
    }

    /// The settings are in Chinese: languages are named in Chinese, with their own name below.
    static func chineseName(_ language: SupportedLanguage) -> String {
        Locale(identifier: "zh_CN").localizedString(forLanguageCode: language.code) ?? language.englishName
    }
}
