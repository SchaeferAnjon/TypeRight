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
        VStack(spacing: 0) {
            // Search field and add button row
            HStack {
                // Search field (matching Applications style)
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("找网站…", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)

                // Current website button (if in browser)
                if showsCurrentSite, let currentDomain = AnalysisCoordinator.shared.browserDomain() {
                    if !preferences.isWebsiteDisabled(currentDomain) {
                        Button {
                            preferences.disableWebsite(currentDomain)
                        } label: {
                            Label("在 \(currentDomain) 上关掉", systemImage: "minus.circle")
                        }
                        .buttonStyle(.bordered)
                        .help("在刚才浏览的这个网站上不弹框")
                    }
                }

                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .help("加一个不检查的网站")
            }
            .padding()

            // Website list
            List {
                Section {
                    if filteredWebsites.isEmpty, !preferences.disabledWebsites.isEmpty {
                        // Search returned no results
                        HStack {
                            Spacer()
                            Text("没找到")
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    } else if preferences.disabledWebsites.isEmpty {
                        // No websites added yet
                        VStack(spacing: 12) {
                            Image(systemName: "globe")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary.opacity(0.5))
                            Text("还没有关掉的网站")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Text("加进来的网站上，TypeRight 不弹框")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    } else {
                        ForEach(filteredWebsites, id: \.self) { website in
                            HStack {
                                // Website icon
                                Image(systemName: website.hasPrefix("*.") ? "globe.badge.chevron.backward" : "globe")
                                    .foregroundColor(.accentColor)
                                    .frame(width: 24, height: 24)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(website)
                                        .font(.body)
                                    if website.hasPrefix("*.") {
                                        Text("包括所有子域名")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }

                                Spacer()

                                // Status indicator
                                Text(preferences.websitePausedUntil[website].map { "暂停到 " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "已关掉")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.15))
                                    .cornerRadius(4)

                                // Remove button
                                Button {
                                    preferences.enableWebsite(website)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("在这个网站上恢复弹框")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    HStack {
                        Text("不检查的网站")
                            .font(.headline)
                        Spacer()
                        Text("\(preferences.disabledWebsites.count) 个")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .headerProminence(.increased)
            }
            .listStyle(.inset)

            // Info text (matching Applications style)
            Text("在这些网站上 TypeRight 不弹框。可以写准确的域名，比如 github.com；写 *.google.com 就包括所有子域名。刚在浏览器里看的网站，可以用上面的按钮直接关掉。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding()
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
}

/// Sheet for adding a new website to the disabled list
private struct AddWebsiteSheet: View {
    @Binding var newWebsite: String
    @Binding var isPresented: Bool
    let onAdd: (String) -> Void
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 4) {
                Image(systemName: "globe.badge.chevron.backward")
                    .font(.system(size: 32))
                    .foregroundColor(.accentColor)
                Text("加一个网站")
                    .font(.headline)
                Text("在这个网站上不弹框")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Input field
            VStack(alignment: .leading, spacing: 6) {
                Text("域名")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("比如 github.com 或 *.google.com", text: $newWebsite)
                    .textFieldStyle(.roundedBorder)
                    .focused($isTextFieldFocused)
                Text("可以写域名、域名:端口或完整网址。*.example.com 包括所有子域名。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Buttons
            HStack {
                Button("取消") {
                    newWebsite = ""
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("加入") {
                    let trimmed = newWebsite.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onAdd(trimmed)
                    }
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(newWebsite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear {
            isTextFieldFocused = true
        }
    }
}
