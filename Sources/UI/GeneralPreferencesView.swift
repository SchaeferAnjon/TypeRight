//
//  GeneralPreferencesView.swift
//  TextWarden
//
//  General preferences including appearance, permissions, and keyboard shortcuts.
//

import AppKit
import KeyboardShortcuts
import SwiftUI

// MARK: - General Preferences

struct GeneralPreferencesView: View {
    @ObservedObject var preferences: UserPreferences
    /// Screenshots pass names nobody has set, so they never show the user's own keys.
    var fixAllName: KeyboardShortcuts.Name = .fixAllObvious
    var rewriteName: KeyboardShortcuts.Name = .quickRewrite
    @ObservedObject private var permissionManager = PermissionManager.shared
    @State private var showingPermissionDialog = false

    var body: some View {
        Form {
            // MARK: Checking

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("所有 App：", selection: $preferences.pauseDuration) {
                        ForEach(PauseDuration.allCases, id: \.self) { duration in
                            Text(duration.label).tag(duration)
                        }
                    }
                    .help("在所有 App 里暂停一会儿，或者一直暂停")

                    if preferences.pauseDuration == .oneHour || preferences.pauseDuration == .twentyFourHours,
                       let until = preferences.pausedUntil
                    {
                        Text("\(until.formatted(date: .omitted, time: .shortened)) 自动恢复")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                        Text("检查")
                            .font(.title3)
                            .fontWeight(.semibold)
                    }

                    Text("暂停的时候不弹框，也不读输入框。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Accessibility Permission Section
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: permissionManager.isPermissionGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(permissionManager.isPermissionGranted ? .green : .orange)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("辅助功能权限")
                                .font(.headline)
                            Text(permissionManager.isPermissionGranted ? "已允许" : "还没允许")
                                .font(.subheadline)
                                .foregroundColor(permissionManager.isPermissionGranted ? .green : .orange)
                        }

                        Spacer()
                    }

                    Text(permissionManager.isPermissionGranted ?
                        "TypeRight 能读到你正在打的那一句，也能把改法写回去。" :
                        "没有这个权限，TypeRight 看不到你在打什么。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if !permissionManager.isPermissionGranted {
                        HStack(spacing: 12) {
                            Button {
                                permissionManager.requestPermission()
                                showingPermissionDialog = true
                            } label: {
                                HStack {
                                    Image(systemName: "lock.open")
                                    Text("请求权限")
                                }
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                permissionManager.openSystemSettings()
                            } label: {
                                HStack {
                                    Image(systemName: "gearshape")
                                    Text("打开系统设置")
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            } header: {
                Text("权限")
                    .font(.headline)
            }

            // MARK: Appearance

            Section {
                Picker("窗口外观：", selection: $preferences.appTheme) {
                    ForEach(UserPreferences.themeOptions, id: \.self) { theme in
                        Text(UserPreferences.themeLabel(theme)).tag(theme)
                    }
                }
                .help("TypeRight 的窗口和弹框用浅色还是深色")
            } header: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "paintbrush.fill")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                        Text("外观")
                            .font(.title3)
                            .fontWeight(.semibold)
                    }
                }
            }

            // MARK: Keyboard Shortcuts

            Section {
                Toggle("启用快捷键", isOn: $preferences.keyboardShortcutsEnabled)
                    .help("打开或关掉下面的键和「暂停 / 继续」键")

                Text("关掉后，下面两个键和「快捷键」页的「暂停 / 继续」都不响；「整句翻译」不受影响。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            } header: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "keyboard.fill")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                        Text("快捷键")
                            .font(.title3)
                            .fontWeight(.semibold)
                    }

                    Text("「整句翻译」和「暂停 / 继续」在设置的「快捷键」页里选。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                KeyboardShortcuts.Recorder("一键改掉明显的错：", name: fixAllName)
                KeyboardShortcuts.Recorder("改写选中的文字：", name: rewriteName)

                Text("两个键默认都没设，在任何 App 里都能用。「一键改掉明显的错」把只有一种改法的错一次改完，不记进错题本；「改写选中的文字」要用 Apple 智能，先在「改写」里打开。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            } header: {
                Text("更多快捷键")
                    .font(.headline)
            }
        }
        .formStyle(.grouped)
        .padding()
        .alert("已请求权限", isPresented: $showingPermissionDialog) {
            Button("好") {
                showingPermissionDialog = false
            }
        } message: {
            Text("请在系统设置里给 TypeRight 打开辅助功能权限。")
        }
    }
}
