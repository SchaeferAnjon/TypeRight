//
//  ApplicationSettingsView.swift
//  TextWarden
//
//  Per-application settings for grammar checking.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Application Settings

struct ApplicationSettingsView: View {
    @ObservedObject var preferences: UserPreferences
    /// Screenshots list these apps instead of the ones on this Mac.
    var sampleBundleIDs: Set<String>?
    @State private var searchText = ""
    @State private var supportedApps: [ApplicationInfo] = []
    @State private var otherApps: [ApplicationInfo] = []
    @State private var excludedApps: [ApplicationInfo] = []
    @State private var isOtherSectionExpanded = false
    @State private var isExcludedSectionExpanded = false
    @State private var applicationError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("找 App…", text: $searchText)
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
            .padding()

            HStack {
                Text("不想让 TypeRight 看某个 App，选「一直暂停」。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("暂停一个没在列表里的 App…", action: chooseApplicationToPause)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            // Application list
            List {
                // MARK: - Supported Applications Section

                if !filteredSupportedApps.isEmpty {
                    Section {
                        ForEach(filteredSupportedApps, id: \.bundleIdentifier) { app in
                            ApplicationRow(
                                app: app,
                                preferences: preferences
                            )
                        }
                    } header: {
                        HStack {
                            Text("一般 App")
                                .font(.headline)
                            Spacer()
                            Text("\(filteredSupportedApps.count) 个")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } footer: {
                        Text("这些 App 默认边打边弹框，可以单独暂停。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .headerProminence(.increased)
                }

                // MARK: - Other Applications Section

                if !filteredOtherApps.isEmpty {
                    Section {
                        DisclosureGroup(
                            isExpanded: $isOtherSectionExpanded,
                            content: {
                                ForEach(filteredOtherApps, id: \.bundleIdentifier) { app in
                                    ApplicationRow(
                                        app: app,
                                        preferences: preferences
                                    )
                                }
                            },
                            label: {
                                HStack {
                                    Text("默认关着的 App")
                                        .font(.headline)
                                    Spacer()
                                    Text("\(filteredOtherApps.count) 个")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        )

                        if !isOtherSectionExpanded {
                            Text("终端这类 App 里常打命令，默认不看；点「开启」才开始看。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .headerProminence(.increased)
                }

                if !filteredExcludedApps.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $isExcludedSectionExpanded) {
                            ForEach(filteredExcludedApps, id: \.bundleIdentifier) { app in
                                ApplicationRow(app: app, preferences: preferences)
                            }
                        } label: {
                            Text("TypeRight 不看的 App")
                                .font(.headline)
                        }
                    } footer: {
                        Text("系统工具和密码类 App 一直不看，也不能打开。")
                            .font(.caption)
                    }
                }

                if filteredSupportedApps.isEmpty, filteredOtherApps.isEmpty, filteredExcludedApps.isEmpty {
                    Text("没找到。用上面的「暂停一个没在列表里的 App…」选一个。")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)

        }
        .onAppear {
            loadApplications()
        }
        .onChange(of: preferences.appPauseDurations) {
            loadApplications()
        }
        .onChange(of: preferences.discoveredApplications) {
            loadApplications()
        }
        .onChange(of: searchText) {
            if !searchText.isEmpty {
                isOtherSectionExpanded = true
                isExcludedSectionExpanded = true
            }
        }
        .alert("没能暂停这个 App", isPresented: Binding(
            get: { applicationError != nil },
            set: { if !$0 { applicationError = nil } }
        )) {
            Button("好") { applicationError = nil }
        } message: {
            Text(applicationError ?? "")
        }
    }

    // MARK: - Filtered Apps

    /// Get filtered supported applications based on search text
    private var filteredSupportedApps: [ApplicationInfo] {
        if searchText.isEmpty {
            return supportedApps
        }
        return supportedApps.filter { app in
            app.name.localizedCaseInsensitiveContains(searchText) ||
                app.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Get filtered other applications based on search text
    private var filteredOtherApps: [ApplicationInfo] {
        if searchText.isEmpty {
            return otherApps
        }
        return otherApps.filter { app in
            app.name.localizedCaseInsensitiveContains(searchText) ||
                app.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredExcludedApps: [ApplicationInfo] {
        excludedApps.filter {
            searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func chooseApplicationToPause() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "暂停这个 App"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let bundleID = Bundle(url: url)?.bundleIdentifier, !bundleID.isEmpty else {
                applicationError = "选中的不是一个 Mac App（没有 bundle id），换一个试试。"
                return
            }
            preferences.discoveredApplications.insert(bundleID)
            if !AppRegistry.shared.isIntentionallyDisabled(bundleID) {
                preferences.setPauseDuration(for: bundleID, duration: .indefinite)
            }
            searchText = bundleID
            loadApplications()
        }
    }

    // MARK: - Load Applications

    /// Load all applications and split into supported/other
    private func loadApplications() {
        var allBundleIDs = Set<String>()
        if let sampleBundleIDs {
            allBundleIDs = sampleBundleIDs
        } else {
            collectBundleIDs(into: &allBundleIDs)
        }

        // Convert to ApplicationInfo and split by support status

        var supported: [ApplicationInfo] = []
        var other: [ApplicationInfo] = []
        var excluded: [ApplicationInfo] = []

        for bundleID in allBundleIDs {
            if let app = getApplicationInfo(for: bundleID) {
                switch app.policy {
                case .supported:
                    supported.append(app)
                case .safeTrial, .pausedByDefault:
                    other.append(app)
                case .ignored:
                    excluded.append(app)
                }
            }
        }

        // Sort alphabetically
        supportedApps = supported.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        otherApps = other.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        excludedApps = excluded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Every app worth listing: registered, used before, running now, paused, or excluded.
    private func collectBundleIDs(into allBundleIDs: inout Set<String>) {
        // 1. Add all registered/supported apps from AppRegistry
        for config in AppRegistry.shared.allConfigurations {
            for bundleID in config.bundleIDs {
                allBundleIDs.insert(bundleID)
            }
        }

        // 2. Add discovered applications (apps that have been used)
        for bundleID in preferences.discoveredApplications {
            allBundleIDs.insert(bundleID)
        }

        // 3. Add currently running applications with GUI
        let workspace = NSWorkspace.shared
        for app in workspace.runningApplications {
            if let bundleID = app.bundleIdentifier,
               app.activationPolicy == .regular
            {
                allBundleIDs.insert(bundleID)
            }
        }

        // 4. Add apps from pause durations (in case they have custom settings)
        for bundleID in preferences.appPauseDurations.keys {
            allBundleIDs.insert(bundleID)
        }

        // Include installed built-in exclusions, even before their first activation.
        allBundleIDs.formUnion(ApplicationPolicy.defaults.keys)
    }

    /// Get application info from bundle ID
    private func getApplicationInfo(for bundleID: String) -> ApplicationInfo? {
        let workspace = NSWorkspace.shared
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID),
              FileManager.default.fileExists(atPath: appURL.path)
        else {
            // Launch Services can retain a registration after the app has been removed.
            return nil
        }

        let appName = FileManager.default.displayName(atPath: appURL.path)
        let icon = workspace.icon(forFile: appURL.path)

        return ApplicationInfo(
            name: appName,
            bundleIdentifier: bundleID,
            icon: icon,
            policy: AppRegistry.shared.policy(for: bundleID)
        )
    }
}

// MARK: - Application Row

private struct ApplicationRow: View {
    let app: ApplicationInfo
    @ObservedObject var preferences: UserPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // App icon
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "app")
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.body)
                    HStack(spacing: 4) {
                        Text(app.bundleIdentifier)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button {
                            copyToClipboard(app.bundleIdentifier)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("复制 bundle id")
                    }

                    if let statusDescription {
                        Text(statusDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if app.policy == .ignored {
                    Text("一直不看")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if needsSafeTrialConsent {
                    if preferences.getPauseDuration(for: app.bundleIdentifier) == .indefinite {
                        Text("暂停着")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button("开启") {
                        preferences.allowSafeTrial(for: app.bundleIdentifier)
                        preferences.setPauseDuration(for: app.bundleIdentifier, duration: .active)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("让 TypeRight 在「\(app.name)」里边打边弹框")
                } else {
                    Picker("", selection: Binding(
                        get: {
                            preferences.getPauseDuration(for: app.bundleIdentifier)
                        },
                        set: { duration in
                            preferences.setPauseDuration(for: app.bundleIdentifier, duration: duration)
                        }
                    )) {
                        ForEach(PauseDuration.allCases, id: \.self) { duration in
                            Text(duration.label).tag(duration)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 200)
                    .help("在「\(app.name)」里看还是暂停")
                }


            }

            // Resume time if paused
            if let until = preferences.getPausedUntil(for: app.bundleIdentifier) {
                let pauseState = preferences.getPauseDuration(for: app.bundleIdentifier)
                if pauseState == .oneHour || pauseState == .twentyFourHours {
                    HStack {
                        Spacer()
                        Text("\(formatTime(until)) 自动恢复")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.trailing, 4)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
    }

    private var needsSafeTrialConsent: Bool {
        app.policy.requiresSafeTrialConsent
            && !preferences.safeTrialApplications.contains(app.bundleIdentifier)
    }

    private var statusDescription: String? {
        if needsSafeTrialConsent,
           app.policy == .pausedByDefault,
           preferences.getPauseDuration(for: app.bundleIdentifier) != .active
        {
            return "默认关着"
        }
        if needsSafeTrialConsent {
            return "点「开启」后才开始看"
        }
        return nil
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - Application Info

private struct ApplicationInfo {
    let name: String
    let bundleIdentifier: String
    let icon: NSImage?
    let policy: ApplicationPolicy
}
