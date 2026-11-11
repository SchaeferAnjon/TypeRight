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
    @State private var applicationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                TRTextField(placeholder: "找 App…", text: $searchText, search: true)
                HStack(spacing: 12) {
                    Text("不想让 TypeRight 看某个 App，选「一直暂停」。")
                        .font(.system(size: 12)).foregroundStyle(TR.text2)
                    Spacer()
                    Button("暂停一个没在列表里的 App…", action: chooseApplicationToPause)
                        .buttonStyle(TRPlainButtonStyle())
                }
            }

            if !filteredSupportedApps.isEmpty {
                TRGroup(title: "一般 App（\(filteredSupportedApps.count) 个）", note: "这些 App 默认边打边弹框，可以单独暂停。") {
                    rows(filteredSupportedApps)
                }
            }

            if !filteredOtherApps.isEmpty {
                TRGroup(title: "默认关着的 App（\(filteredOtherApps.count) 个）", note: "终端这类 App 里常打命令，默认不看；点「开启」才开始看。") {
                    rows(filteredOtherApps)
                }
            }

            if !filteredExcludedApps.isEmpty {
                TRGroup(title: "TypeRight 不看的 App（\(filteredExcludedApps.count) 个）", note: "系统工具和密码类 App 一直不看，也不能打开。") {
                    rows(filteredExcludedApps)
                }
            }

            if filteredSupportedApps.isEmpty, filteredOtherApps.isEmpty, filteredExcludedApps.isEmpty {
                Text("没找到。用上面的「暂停一个没在列表里的 App…」选一个。")
                    .font(.system(size: 12)).foregroundStyle(TR.text2)
            }
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
        .alert("没能暂停这个 App", isPresented: Binding(
            get: { applicationError != nil },
            set: { if !$0 { applicationError = nil } }
        )) {
            Button("好") { applicationError = nil }
        } message: {
            Text(applicationError ?? "")
        }
    }

    private func rows(_ apps: [ApplicationInfo]) -> some View {
        ForEach(Array(apps.enumerated()), id: \.element.bundleIdentifier) { index, app in
            ApplicationRow(app: app, preferences: preferences, last: index == apps.count - 1)
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
    var last = false

    var body: some View {
        TRRow(title: TRText.autospaced(app.name), note: statusDescription, last: last) {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "app").font(.system(size: 16)).foregroundStyle(TR.text2)
            }
        } trailing: {
            if app.policy == .ignored {
                Text("一直不看").font(.system(size: 13)).foregroundStyle(TR.text2)
            } else if needsSafeTrialConsent {
                Button("开启") {
                    preferences.allowSafeTrial(for: app.bundleIdentifier)
                    preferences.setPauseDuration(for: app.bundleIdentifier, duration: .active)
                }
                .buttonStyle(TRPlainButtonStyle())
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
                .labelsHidden()
                .fixedSize()
                .help("在「\(app.name)」里看还是暂停")
            }
        }
    }

    private var needsSafeTrialConsent: Bool {
        app.policy.requiresSafeTrialConsent
            && !preferences.safeTrialApplications.contains(app.bundleIdentifier)
    }

    /// The line under the name: why it is off, or when a pause ends.
    private var statusDescription: String? {
        if needsSafeTrialConsent {
            return app.policy == .pausedByDefault ? "默认关着" : "点「开启」后才开始看"
        }
        let pauseState = preferences.getPauseDuration(for: app.bundleIdentifier)
        if pauseState == .oneHour || pauseState == .twentyFourHours,
           let until = preferences.getPausedUntil(for: app.bundleIdentifier)
        {
            return "\(TRDate.time(until)) 自动恢复"
        }
        return nil
    }
}

// MARK: - Application Info

private struct ApplicationInfo {
    let name: String
    let bundleIdentifier: String
    let icon: NSImage?
    let policy: ApplicationPolicy
}
