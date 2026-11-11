//
//  WebsiteSettingsView.swift
//  TextWarden
//
//  Per-website settings for disabling grammar checking.
//

import AppKit
import SwiftUI

// MARK: - Website Settings

struct WebsiteSettingsView: View {
    @ObservedObject var preferences: UserPreferences
    /// Screenshots leave out the button that names the site last open in a browser.
    var showsCurrentSite = true
    @State private var searchText = ""
    @State private var newWebsite = ""
    @State private var showingAddSheet = false

    /// Filtered websites based on search text
    private var filteredWebsites: [String] {
        let sorted = Array(preferences.disabledWebsites).sorted()
        if searchText.isEmpty {
            return sorted
        }
        return sorted.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 8) {
                TRTextField(placeholder: "找网站…", text: $searchText, search: true)

                // The site last open in a browser, if there is one.
                if showsCurrentSite, let currentDomain = AnalysisCoordinator.shared.browserDomain(),
                   !preferences.isWebsiteDisabled(currentDomain)
                {
                    Button("在 \(currentDomain) 上关掉") {
                        preferences.disableWebsite(currentDomain)
                    }
                    .buttonStyle(TRPlainButtonStyle())
                    .help("在刚才浏览的这个网站上不弹框")
                }

                Button("加一个网站…") {
                    showingAddSheet = true
                }
                .buttonStyle(TRPlainButtonStyle())
                .help("加一个不检查的网站")
            }

            TRGroup(title: "不检查的网站（\(preferences.disabledWebsites.count) 个）",
                    note: "在这些网站上 TypeRight 不弹框。可以写准确的域名，比如 github.com；写 *.google.com 就包括所有子域名。") {
                if preferences.disabledWebsites.isEmpty {
                    TRRow(title: "还没有关掉的网站", note: "加进来的网站上，TypeRight 不弹框", last: true) { EmptyView() }
                } else if filteredWebsites.isEmpty {
                    TRRow(title: "没找到", last: true) { EmptyView() }
                } else {
                    ForEach(Array(filteredWebsites.enumerated()), id: \.element) { index, website in
                        TRRow(title: website, note: note(for: website), last: index == filteredWebsites.count - 1) {
                            Image(systemName: "globe").font(.system(size: 15)).foregroundStyle(TR.text2)
                        } trailing: {
                            Button("移除") {
                                preferences.enableWebsite(website)
                            }
                            .buttonStyle(TRGhostButtonStyle())
                            .help("在这个网站上恢复弹框")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddWebsiteSheet(
                newWebsite: $newWebsite,
                isPresented: $showingAddSheet,
                onAdd: { website in
                    preferences.disableWebsite(website)
                    newWebsite = ""
                }
            )
        }
    }

    /// Off is the normal state of every site here, so only a wildcard or a pause with an end says more.
    private func note(for website: String) -> String? {
        let parts = [website.hasPrefix("*.") ? "包括所有子域名" : nil,
                     preferences.websitePausedUntil[website].map { "暂停到 \(TRDate.moment($0))" }]
        let text = parts.compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }
}

/// Sheet for adding a new website to the disabled list
private struct AddWebsiteSheet: View {
    @Binding var newWebsite: String
    @Binding var isPresented: Bool
    let onAdd: (String) -> Void
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("加一个网站")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(TR.text)
                Text("在这个网站上不弹框")
                    .font(.system(size: 12)).foregroundStyle(TR.text2)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("比如 github.com 或 *.google.com", text: $newWebsite)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isTextFieldFocused)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(TR.card, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(TR.line2, lineWidth: 0.5))
                Text("可以写域名、域名:端口或完整网址。*.example.com 包括所有子域名。")
                    .font(.system(size: 12)).foregroundStyle(TR.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("取消") {
                    newWebsite = ""
                    isPresented = false
                }
                .buttonStyle(TRPlainButtonStyle())
                .keyboardShortcut(.cancelAction)

                Button("加入") {
                    let trimmed = newWebsite.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onAdd(trimmed)
                    }
                    isPresented = false
                }
                .buttonStyle(TRInkButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(newWebsite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
        .background(TR.bg)
        .onAppear {
            isTextFieldFocused = true
        }
    }
}
