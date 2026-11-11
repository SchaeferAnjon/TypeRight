//
//  GeneralPreferencesView.swift
//  TextWarden
//
//  设置 › 高级 › 通用: pause everywhere, the Accessibility permission, the window look and
//  TextWarden's own shortcuts.
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

    private var pauseNote: String {
        if preferences.pauseDuration == .oneHour || preferences.pauseDuration == .twentyFourHours,
           let until = preferences.pausedUntil
        {
            return "暂停的时候不弹框，也不读输入框。\(TRDate.time(until)) 自动恢复。"
        }
        return "暂停的时候不弹框，也不读输入框。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TRGroup(title: "检查") {
                TRRow(title: "所有 App", note: pauseNote, last: true) {
                    Picker("", selection: $preferences.pauseDuration) {
                        ForEach(PauseDuration.allCases, id: \.self) { duration in
                            Text(duration.label).tag(duration)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .help("在所有 App 里暂停一会儿，或者一直暂停")
                }
            }

            TRGroup(title: "权限") {
                TRRow(title: "辅助功能",
                      note: permissionManager.isPermissionGranted
                          ? "TypeRight 能读到你正在打的那一句，也能把改法写回去。"
                          : "没有这个权限，TypeRight 看不到你在打什么。",
                      last: true) {
                    if permissionManager.isPermissionGranted {
                        TRStatusDot(color: TR.ok, text: "已允许")
                    } else {
                        HStack(spacing: 8) {
                            TRStatusDot(color: TR.warn, text: "还没允许")
                            Button("请求权限") {
                                permissionManager.requestPermission()
                                showingPermissionDialog = true
                            }
                            .buttonStyle(TRPlainButtonStyle())
                            Button("打开系统设置") { permissionManager.openSystemSettings() }
                                .buttonStyle(TRPlainButtonStyle())
                        }
                    }
                }
            }

            TRGroup(title: "外观") {
                TRRow(title: "窗口外观", note: "TypeRight 的窗口和弹框用浅色还是深色", last: true) {
                    TRSegmented(options: UserPreferences.themeOptions.map { ($0, UserPreferences.themeLabel($0)) },
                                selection: $preferences.appTheme)
                }
            }

            TRGroup(title: "快捷键", note: "「整句翻译」和「暂停 / 继续」在设置的「快捷键」页里选。") {
                TRRow(title: "启用快捷键", note: "关掉后，下面两个键和「快捷键」页的「暂停 / 继续」都不响；「整句翻译」不受影响。", last: true) {
                    Toggle("", isOn: $preferences.keyboardShortcutsEnabled).toggleStyle(SquareToggleStyle()).labelsHidden()
                }
            }

            TRGroup(title: "更多快捷键", note: "两个键默认都没设，在任何 App 里都能用。") {
                TRRow(title: "一键改掉明显的错", note: "把只有一种改法的错一次改完，不记进错题本") {
                    TRShortcutRecorder(name: fixAllName)
                }
                TRRow(title: "改写选中的文字", note: "要用 Apple 智能，先在「改写」里打开", last: true) {
                    TRShortcutRecorder(name: rewriteName)
                }
            }
        }
        .alert("已请求权限", isPresented: $showingPermissionDialog) {
            Button("好") {
                showingPermissionDialog = false
            }
        } message: {
            Text("请在系统设置里给 TypeRight 打开辅助功能权限。")
        }
    }
}
