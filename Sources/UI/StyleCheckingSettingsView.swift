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
        VStack(alignment: .leading, spacing: 22) {
            Text("选中一段英文，按「通用」里设的「改写选中的文字」键，按下面的风格改写一遍，你看过再决定用不用。在这台 Mac 上处理，不发给任何服务商；要 macOS 26 和 Apple 智能。")
                .font(.system(size: 12)).foregroundStyle(TR.text2)
                .fixedSize(horizontal: false, vertical: true)

            TRGroup(title: "用 Apple 智能改写") {
                TRRow(title: "Apple 智能", note: fmStatus.isAvailable ? nil : fmStatus.userMessage) {
                    HStack(spacing: 8) {
                        TRStatusDot(color: fmStatus.isAvailable ? TR.ok : TR.warn, text: fmStatus.isAvailable ? "可以用" : "用不了")
                        if fmStatus == .appleIntelligenceNotEnabled {
                            Button("打开系统设置") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.appleintelli") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(TRPlainButtonStyle())
                        } else if fmStatus.canRetry {
                            Button("再看一次") { checkFMAvailability() }
                                .buttonStyle(TRPlainButtonStyle())
                        }
                    }
                }
                TRRow(title: "打开改写", note: "关着的时候，改写键不响", last: true) {
                    Toggle("", isOn: $preferences.enableStyleChecking).toggleStyle(SquareToggleStyle()).labelsHidden()
                }
                .disabled(!fmStatus.isAvailable)
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

            if preferences.enableStyleChecking {
                // While Apple Intelligence cannot be used these grey out with the switch above.
                TRGroup(title: "改成什么样") {
                    TRRow(title: "风格", note: styleDescription(for: preferences.selectedWritingStyle)) {
                        TRSegmented(options: UserPreferences.writingStyles.map { ($0, styleLabel(for: $0)) },
                                    selection: $preferences.selectedWritingStyle)
                    }
                    TRRow(title: "变化多少", note: selectedTemperaturePreset.description, last: true) {
                        TRSegmented(options: StyleTemperaturePreset.allCases.map { ($0.rawValue, $0.label) },
                                    selection: $preferences.styleTemperaturePreset)
                    }
                }
                .disabled(!fmStatus.isAvailable)
            }
        }
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
