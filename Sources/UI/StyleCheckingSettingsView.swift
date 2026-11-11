//
//  StyleCheckingSettingsView.swift
//  TextWarden
//
//  Settings for rewriting selected text with Apple Intelligence (Quick Rewrite).
//

import SwiftUI

#if canImport(FoundationModels)
    import FoundationModels
#endif

struct StyleCheckingSettingsView: View {
    @ObservedObject var preferences: UserPreferences

    /// Foundation Models engine status - wrapped for availability
    @State private var fmStatus: StyleEngineStatus = .unknown("")

    var body: some View {
        Form {
            // Availability status (small section with the header)
            Section {
                HStack(spacing: 12) {
                    Image(systemName: fmStatus.symbolName)
                        .font(.title3)
                        .foregroundColor(fmStatus.isAvailable ? .green : .orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(fmStatus.isAvailable ? "可以用" : "用不了")
                            .font(.system(size: 12, weight: .medium))

                        if !fmStatus.isAvailable {
                            Text(fmStatus.userMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    if fmStatus == .appleIntelligenceNotEnabled {
                        Button("打开系统设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.appleintelli") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    } else if fmStatus.canRetry {
                        Button("再看一次") {
                            checkFMAvailability()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.title2)
                            .foregroundColor(.purple)
                        Text("用 Apple 智能改写")
                            .font(.title3)
                            .fontWeight(.semibold)
                    }

                    Text("选中一段英文，按「通用」里设的「改写选中的文字」键，按下面的风格改写一遍，你看过再决定用不用。在这台 Mac 上处理，不发给任何服务商；要 macOS 26 和 Apple 智能。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onAppear {
                checkFMAvailability()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                checkFMAvailability()
            }
            .background {
                foundationModelsAvailabilityObserver
            }

            // Main toggle and options (no header, continues the section visually)
            Section {
                Toggle(isOn: $preferences.enableStyleChecking) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("打开改写")
                        Text("关着的时候，改写键不响")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!fmStatus.isAvailable)

                if preferences.enableStyleChecking {
                    // Writing Style segmented control
                    VStack(alignment: .leading, spacing: 8) {
                        Text("改成什么风格")
                            .font(.headline)

                        HStack(spacing: 0) {
                            ForEach(UserPreferences.writingStyles, id: \.self) { style in
                                Button {
                                    preferences.selectedWritingStyle = style
                                } label: {
                                    Text(styleLabel(for: style))
                                        .font(.system(size: 12, weight: preferences.selectedWritingStyle == style ? .semibold : .regular))
                                        .foregroundColor(preferences.selectedWritingStyle == style ? .white : .primary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .background(
                                            preferences.selectedWritingStyle == style
                                                ? Color.accentColor
                                                : Color.clear
                                        )
                                }
                                .buttonStyle(.plain)
                                .help(styleDescription(for: style))
                                .accessibilityAddTraits(preferences.selectedWritingStyle == style ? .isSelected : [])
                            }
                        }
                        .background(Color(.separatorColor).opacity(0.2))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(.separatorColor), lineWidth: 0.5)
                        )
                    }

                    // Creativity segmented control
                    VStack(alignment: .leading, spacing: 8) {
                        Text("变化多少")
                            .font(.headline)

                        HStack(spacing: 0) {
                            ForEach(StyleTemperaturePreset.allCases) { preset in
                                Button {
                                    preferences.styleTemperaturePreset = preset.rawValue
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(preset.label)
                                        Image(systemName: preset.symbolName)
                                            .font(.system(size: 10))
                                            .accessibilityHidden(true)
                                    }
                                    .font(.system(size: 12, weight: selectedTemperaturePreset == preset ? .semibold : .regular))
                                    .foregroundColor(selectedTemperaturePreset == preset ? .white : .primary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(
                                        selectedTemperaturePreset == preset
                                            ? Color.accentColor
                                            : Color.clear
                                    )
                                }
                                .buttonStyle(.plain)
                                .help(preset.description)
                                .accessibilityAddTraits(selectedTemperaturePreset == preset ? .isSelected : [])
                            }
                        }
                        .background(Color(.separatorColor).opacity(0.2))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(.separatorColor), lineWidth: 0.5)
                        )

                        Text(selectedTemperaturePreset.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Style Labels

    /// The stored value stays the English name; the settings show Chinese.
    private func styleLabel(for style: String) -> String {
        switch style {
        case "Concise": "简洁"
        case "Formal": "正式"
        case "Casual": "随意"
        case "Business": "商务"
        default: "默认"
        }
    }

    private func styleDescription(for style: String) -> String {
        switch style {
        case "Concise":
            "简短直接，去掉多余的词和重复的说法。"
        case "Formal":
            "正式的语气、完整的句子，适合工作邮件、报告和正式文件。"
        case "Casual":
            "轻松口语，适合私人消息和社交平台。"
        case "Business":
            "清楚、讲行动，适合工作往来和演示。"
        default:
            "不改你的语气，只让句子更清楚好读。"
        }
    }

    // MARK: - Temperature Preset Helpers

    /// Current selected temperature preset based on preferences
    private var selectedTemperaturePreset: StyleTemperaturePreset {
        StyleTemperaturePreset(rawValue: preferences.styleTemperaturePreset) ?? .balanced
    }

    // MARK: - Foundation Models Availability

    @ViewBuilder
    private var foundationModelsAvailabilityObserver: some View {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                FoundationModelsAvailabilityObserver(status: $fmStatus)
            }
        #endif
    }

    /// Check Foundation Models availability (requires macOS 26+)
    private func checkFMAvailability() {
        if #available(macOS 26.0, *) {
            fmStatus = FoundationModelsEngine().status
        } else {
            fmStatus = .deviceNotEligible
        }
    }
}

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private struct FoundationModelsAvailabilityObserver: View {
        @Binding var status: StyleEngineStatus
        @State private var model = SystemLanguageModel.default

        var body: some View {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .onChange(of: model.availability, initial: true) {
                    status = FoundationModelsEngine().status
                }
        }
    }
#endif
