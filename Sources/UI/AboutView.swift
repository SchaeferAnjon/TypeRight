//
//  AboutView.swift
//  TextWarden
//
//  About view showing app information and credits.
//

import SwiftUI

// MARK: - App URLs

/// Static URLs for external links - centralized for easy review
/// Force unwraps are safe here as these are hardcoded, syntactically valid URLs
enum AppURLs {
    static let github = URL(string: "https://github.com/SchaeferAnjon/TypeRight")!
    static let license = URL(string: "https://github.com/SchaeferAnjon/TypeRight/blob/main/LICENSE")!
    static let issues = URL(string: "https://github.com/SchaeferAnjon/TypeRight/issues")!
    static let guide = URL(string: "https://typeright.us-cloud.uk/#page=guide")!
    /// TypeRight is based on TextWarden; its name and logo belong to its author.
    static let upstream = URL(string: "https://github.com/PhilipSchmid/textwarden")!
}

// MARK: - About View

struct AboutView: View {
    /// Access the singleton updater - use ObservedObject for proper updates
    @ObservedObject private var updaterViewModel = UpdaterViewModel.shared

    /// State for copy feedback
    @State private var showCopiedFeedback = false

    /// Copy version to clipboard
    private func copyVersionToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(BuildInfo.appVersion, forType: .string)
        showCopiedFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + TimingConstants.feedbackDisplayDuration) {
            showCopiedFeedback = false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                // TypeRight's own icon, as in the main window: TextWarden's logo belongs to its author.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: 4) {
                    Text("TypeRight")
                        .font(.system(size: 22, weight: .semibold)).foregroundStyle(TR.text)
                    Text("Mac 上的英文打字助手")
                        .font(.system(size: 13)).foregroundStyle(TR.text2)
                }
            }

            TRGroup(title: "更新") {
                TRRow(title: "版本") {
                    Button(action: copyVersionToClipboard) {
                        HStack(spacing: 6) {
                            Text(BuildInfo.appVersion).font(.system(size: 13).monospacedDigit()).foregroundStyle(TR.text2)
                            Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11)).foregroundStyle(showCopiedFeedback ? TR.ok : TR.text2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("复制版本号")
                }
                TRRow(title: "打开时自动检查更新") {
                    Toggle("", isOn: $updaterViewModel.automaticallyChecksForUpdates).toggleStyle(SquareToggleStyle()).labelsHidden()
                }
                TRRow(title: "也接收试验版", note: "提前收到带新功能的测试版本") {
                    Toggle("", isOn: $updaterViewModel.includeExperimentalUpdates).toggleStyle(SquareToggleStyle()).labelsHidden()
                }
                TRRow(title: "检查更新", note: updateNote, last: true) {
                    HStack(spacing: 8) {
                        if updaterViewModel.isChecking {
                            ProgressView().controlSize(.small)
                        }
                        // Only our own isChecking, not Sparkle's canCheckForUpdates: that one
                        // flickers during Sparkle's background checks.
                        Button("检查更新") { updaterViewModel.checkForUpdates() }
                            .buttonStyle(TRPlainButtonStyle())
                            .disabled(updaterViewModel.isChecking)
                    }
                }
            }

            TRGroup(title: "帮助") {
                TRLinkRow(title: "上手指南", url: AppURLs.guide)
                TRLinkRow(title: "源码（GitHub）", url: AppURLs.github)
                TRLinkRow(title: "许可证", value: "GPL-3.0", url: AppURLs.license)
                TRLinkRow(title: "反馈问题", last: true, url: AppURLs.issues)
            }

            TRGroup(title: "致谢") {
                TRLinkRow(title: "基于 TextWarden（Apache-2.0）",
                          note: "TextWarden 的名字和标志属于它的作者 Philip Schmid；TypeRight 不是 TextWarden 项目的一部分，也没有得到它的认可。",
                          last: true, url: AppURLs.upstream)
            }
        }
    }

    /// What the last check found, in the row's small line.
    private var updateNote: String? {
        updaterViewModel.statusText.isEmpty ? nil : updaterViewModel.statusText
    }
}
