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
        Form {
            // MARK: - About TypeRight

            Section {
                HStack(spacing: 16) {
                    Image("TextWardenLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 88, height: 88)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("TypeRight")
                            .font(.system(size: 26, weight: .bold))
                        Text("Mac 上的英文打字助手")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }
                .padding(.vertical, 2)
            }

            // Version & Updates subsection
            Section {
                // Version with copy button
                HStack {
                    Text("版本")
                    Spacer()
                    Button(action: copyVersionToClipboard) {
                        HStack(spacing: 6) {
                            Text(BuildInfo.appVersion)
                                .foregroundColor(.secondary)
                            Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
                                .font(.caption)
                                .foregroundColor(showCopiedFeedback ? .green : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("复制版本号")
                }

                Toggle("打开时自动检查更新", isOn: $updaterViewModel.automaticallyChecksForUpdates)

                Toggle("也接收试验版", isOn: $updaterViewModel.includeExperimentalUpdates)
                    .help("提前收到带新功能的测试版本")

                HStack(spacing: 12) {
                    Button {
                        updaterViewModel.checkForUpdates()
                    } label: {
                        HStack(spacing: 6) {
                            if updaterViewModel.isChecking {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text("检查更新")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    // Only disable based on our own isChecking state, not Sparkle's canCheckForUpdates
                    // canCheckForUpdates flickers during Sparkle's automatic background checks
                    .disabled(updaterViewModel.isChecking)

                    Spacer()

                    HStack(spacing: 6) {
                        // Status icon
                        switch updaterViewModel.checkStatus {
                        case .idle:
                            EmptyView()
                        case .checking:
                            EmptyView()
                        case .success:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                        case .error:
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                        }

                        Text(updaterViewModel.statusText)
                            .font(.caption)
                            .foregroundColor({
                                switch updaterViewModel.checkStatus {
                                case .idle, .checking:
                                    .secondary
                                case .success:
                                    .primary
                                case .error:
                                    .orange
                                }
                            }())
                    }
                }
            } header: {
                Text("更新")
                    .font(.headline)
            }

            // MARK: - Help and Resources

            Section {
                link("上手指南", "book", AppURLs.guide)
                link("源码（GitHub）", "chevron.left.forwardslash.chevron.right", AppURLs.github)
                Link(destination: AppURLs.license) {
                    HStack {
                        Label("许可证", systemImage: "doc.text")
                        Spacer()
                        Text("GPL-3.0")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                link("反馈问题", "exclamationmark.bubble", AppURLs.issues)
            } header: {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundColor(.accentColor)
                    Text("帮助")
                        .font(.headline)
                }
            }

            // MARK: - Attribution

            Section {
                Link(destination: AppURLs.upstream) {
                    HStack {
                        Label("基于 TextWarden（Apache-2.0）", systemImage: "arrow.triangle.branch")
                        Spacer()
                        Image(systemName: "arrow.up.forward")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Text("TextWarden 的名字和标志属于它的作者 Philip Schmid；TypeRight 不是 TextWarden 项目的一部分，也没有得到它的认可。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("致谢")
                    .font(.headline)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func link(_ title: String, _ icon: String, _ url: URL) -> some View {
        Link(destination: url) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}
