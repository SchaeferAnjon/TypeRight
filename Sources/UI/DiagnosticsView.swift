//
//  DiagnosticsView.swift
//  TextWarden
//
//  Diagnostics view showing debugging information and system monitoring.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Diagnostics View

struct DiagnosticsView: View {
    @ObservedObject var preferences: UserPreferences
    let vocabulary: CustomVocabulary
    /// Screenshots show a made-up status instead of the app in front right now.
    var sampleHealth: RuntimeHealthSnapshot?
    @ObservedObject private var permissionManager = PermissionManager.shared
    @ObservedObject private var runtimeHealth = RuntimeHealthStore.shared
    @State private var isExporting: Bool = false
    @State private var showingExportSuccess: Bool = false
    @State private var showingExportError: Bool = false
    @State private var exportedFilePath: String = ""
    @State private var exportedFileSize: String = ""
    @State private var pendingResetAction: ResetAction?
    @State private var resetError: String?

    var body: some View {
        let snapshot = sampleHealth ?? runtimeHealth.snapshot
        VStack(alignment: .leading, spacing: 22) {
            TRGroup(title: "现在的状态", note: "TypeRight 在当前 App 里能不能用，不能用时可以怎么办。") {
                TRRow(title: snapshot.applicationName ?? "TypeRight", note: Self.healthNote(snapshot), last: true) {
                    HStack(spacing: 8) {
                        TRStatusDot(color: statusColor(for: snapshot.state), text: Self.stateLabel(snapshot.state))
                        runtimeHealthAction(for: snapshot)
                            .buttonStyle(TRPlainButtonStyle())
                    }
                }
            }

            TRGroup(title: "这次运行") {
                TRRow(title: "启动于") {
                    Text(TRDate.moment(BuildInfo.launchDate)).font(.system(size: 13).monospacedDigit()).foregroundStyle(TR.text2)
                }
                TRRow(title: "已运行", last: true) {
                    Text(Self.uptimeLabel(since: BuildInfo.launchDate)).font(.system(size: 13)).foregroundStyle(TR.text2)
                }
            }

            ResourceMonitoringView()

            LoggingConfigurationView(preferences: preferences)

            TRGroup(title: "导出诊断包", note: "隐私：默认的日志级别不记你打的字；调到「调试」或「追踪」后，日志里可能有你打的字，发出去之前先看一眼。") {
                TRRow(title: "导出诊断包", note: "出问题时，导出一个诊断包发给我们：里面有日志、崩溃记录、系统信息和性能数据。") {
                    Button("导出…", action: exportDiagnosticsToFile)
                        .buttonStyle(TRInkButtonStyle())
                        .disabled(isExporting)
                }
                if isExporting {
                    TRRow(title: "正在准备诊断包…", note: "正在清理日志里的文字、收集数据") {
                        ProgressView().controlSize(.small)
                    }
                }
                TRRow(title: "ZIP 里有",
                      note: ["diagnostic_overview.json：系统信息、权限、设置",
                             "性能数据：各时间段的耗时（平均、中位、P90、P95、P99）",
                             "使用统计：各时间段查到的错和类别",
                             "全部日志文件（当前的和轮换下来的）",
                             "crash_reports/：崩溃记录（有的话）",
                             "App 状态（哪些暂停、哪些在看）"].joined(separator: "\n"),
                      last: true) { EmptyView() }
            }

            TRGroup(title: "恢复默认", note: "错题本、生词本和 Key 不受影响。") {
                TRRow(title: "恢复全部高级设置", note: "「高级」里的设置都回到默认，然后重新打开 TypeRight。恢复了就回不去。") {
                    Button("恢复…") { pendingResetAction = .allSettings }
                        .buttonStyle(TRPlainButtonStyle(tint: TR.danger))
                }
                TRRow(title: "清空自定义词典", note: "删掉「拼写」里自定义词典的全部词，删了找不回来。", last: true) {
                    Button("清空…") { pendingResetAction = .customDictionary }
                        .buttonStyle(TRPlainButtonStyle(tint: TR.danger))
                }
            }
        }
        .sheet(isPresented: $showingExportSuccess) {
            ExportSuccessSheet(
                filePath: exportedFilePath,
                fileSize: exportedFileSize,
                isPresented: $showingExportSuccess
            )
        }
        .alert("没导出来", isPresented: $showingExportError) {
            Button("好", role: .cancel) {}
        } message: {
            Text("诊断包没导出来，详情在日志里。")
        }
        .alert("没清空", isPresented: Binding(get: { resetError != nil }, set: { if !$0 { resetError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(resetError ?? "")
        }
        .alert(item: $pendingResetAction) { action in
            Alert(
                title: Text(action.title),
                message: Text(action.message),
                primaryButton: .destructive(Text(action.confirmationTitle)) {
                    performReset(action)
                },
                secondaryButton: .cancel()
            )
        }
    }

    /// Why, what it can do here, when it last checked and which app, in the status row's note.
    static func healthNote(_ snapshot: RuntimeHealthSnapshot) -> String {
        var lines = [healthTitle(snapshot)]
        if snapshot.capabilities.rawValue != 0 { lines.append(capabilityLabel(snapshot.capabilities)) }
        if let lastCheck = snapshot.lastSuccessfulCheck { lines.append("上次查是 \(TRDate.moment(lastCheck))") }
        if let bundleID = snapshot.bundleIdentifier { lines.append(bundleID) }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func runtimeHealthAction(for snapshot: RuntimeHealthSnapshot) -> some View {
        switch snapshot.action {
        case .grantPermission:
            Button("打开辅助功能设置") {
                permissionManager.openSystemSettings()
            }
        case .resume:
            let title = snapshot.resumeScope.flatMap { scope -> String? in
                guard case .application = scope else { return nil }
                return snapshot.applicationName.map { "在「\($0)」里继续" }
            } ?? "继续"
            Button(title) {
                if let scope = snapshot.resumeScope {
                    preferences.resume(scope)
                }
            }
        case .trySafely:
            Button("开启") {
                if let bundleID = snapshot.bundleIdentifier {
                    AnalysisCoordinator.shared.startSafeTrial(for: bundleID)
                }
            }
        case .retry:
            Button("再试一次") {
                AnalysisCoordinator.shared.retryCurrentCheck()
            }
        case .none, .enable, .resetIndicatorPosition, .openSettings, .copyDiagnostics, .reportCompatibility, .keepPaused:
            EmptyView()
        }
    }

    static func uptimeLabel(since launch: Date, now: Date = Date()) -> String {
        let minutes = Int(now.timeIntervalSince(launch) / 60)
        if minutes < 1 { return "不到 1 分钟" }
        if minutes < 60 { return "\(minutes) 分钟" }
        if minutes < 24 * 60 { return "\(minutes / 60) 小时" }
        return "\(minutes / (24 * 60)) 天"
    }

    static func stateLabel(_ state: CheckingState) -> String {
        switch state {
        case .active: "正在看"
        case .limited: "部分能用"
        case .recovering: "正在恢复"
        case .inactive: "没在看"
        }
    }

    static func healthTitle(_ snapshot: RuntimeHealthSnapshot) -> String {
        switch snapshot.state {
        case .active: return "TypeRight 在这个 App 里正常工作。"
        case .limited: return "TypeRight 在这个 App 里只能部分工作。"
        case .recovering: return "这个 App 刚才没回应，正在重新连上。"
        case .inactive: break
        }
        switch snapshot.reason {
        case .permission: return "要先给辅助功能权限，TypeRight 才能看别的 App 里的字。"
        case .globalPause, nil: return "TypeRight 暂停着。"
        case .appPause: return "TypeRight 在这个 App 里暂停着。"
        case .siteDisabled: return "这个网站设成了不检查。"
        case .consentRequired: return "这个 App 默认关着，点「开启」才开始看。"
        case .secureField: return "密码框和受保护的输入框，TypeRight 一律不读。"
        case .unsupportedField: return "这个输入框读不到 TypeRight 需要的信息。"
        case .unsupportedApplication: return "TypeRight 不在这个 App 里用。"
        case .noEditableField: return "把光标放进一个能打字的输入框，就开始看。"
        }
    }

    static func capabilityLabel(_ capabilities: CapabilitySet) -> String {
        guard capabilities.contains(.textReading) else { return "读不到这里的字" }
        return capabilities.contains(.safeReplacement) ? "能读这里的字，也能把改法写回去" : "能读这里的字"
    }

    private func statusColor(for state: CheckingState) -> Color {
        switch state {
        case .active: TR.ok
        case .limited, .recovering: TR.warn
        case .inactive: TR.text3
        }
    }

    // MARK: - Export Methods

    private func performReset(_ action: ResetAction) {
        switch action {
        case .allSettings:
            preferences.resetToDefaults()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                Self.relaunchApp()
            }
        case .customDictionary:
            do {
                try vocabulary.clearAll()
            } catch {
                Logger.error("Clearing the custom dictionary failed", error: error, category: Logger.general)
                resetError = error.localizedDescription
            }
        }
    }

    private func exportDiagnosticsToFile() {
        isExporting = true

        // Show save panel first
        let savePanel = NSSavePanel()
        savePanel.title = "导出诊断包"
        savePanel.message = "选一个地方存诊断包"
        savePanel.nameFieldStringValue = Self.exportFileName(at: Date())
        savePanel.allowedContentTypes = [.zip]
        savePanel.canCreateDirectories = true

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else {
                isExporting = false
                return
            }

            // CRITICAL: Collect shortcuts on main thread BEFORE dispatching to background
            // KeyboardShortcuts.Shortcut.description requires main thread access
            let shortcuts = SettingsDump.collectShortcuts()

            // Generate and export ZIP package (heavy I/O runs in background)
            Task { @MainActor in
                let success = await DiagnosticReport.exportAsZIP(
                    to: url,
                    preferences: preferences,
                    shortcuts: shortcuts
                )

                isExporting = false

                if success {
                    exportedFilePath = url.path

                    // Get file size
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                       let fileSize = attrs[.size] as? Int64
                    {
                        let formatter = ByteCountFormatter()
                        formatter.allowedUnits = [.useMB, .useKB]
                        formatter.countStyle = .file
                        exportedFileSize = formatter.string(fromByteCount: fileSize)
                    } else {
                        exportedFileSize = "大小未知"
                    }

                    showingExportSuccess = true
                    Logger.info("Diagnostic package exported to: \(url.path)", category: Logger.general)
                } else {
                    showingExportError = true
                    Logger.error("Failed to export diagnostic package", category: Logger.general)
                }
            }
        }
    }

    static func exportFileName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "TypeRight-Diagnostics-\(formatter.string(from: date)).zip"
    }

    // MARK: - App Relaunch

    /// Relaunch the app to apply reset settings and show onboarding
    private static func relaunchApp() {
        guard let appURL = Bundle.main.bundleURL as URL? else {
            Logger.error("Failed to get app bundle URL for relaunch", category: Logger.general)
            return
        }

        Logger.info("Relaunching TypeRight after settings reset", category: Logger.general)

        // Launch a new instance of the app
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                Logger.error("Failed to relaunch app: \(error.localizedDescription)", category: Logger.general)
            } else {
                // Terminate current instance after new one starts
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

private enum ResetAction: Identifiable {
    case allSettings
    case customDictionary

    var id: String {
        title
    }

    var title: String {
        switch self {
        case .allSettings: "恢复全部高级设置？"
        case .customDictionary: "清空自定义词典？"
        }
    }

    var message: String {
        switch self {
        case .allSettings: "「高级」里的设置都回到默认，TypeRight 会重新打开并再走一遍第一次设置。错题本、生词本和 Key 不动。"
        case .customDictionary: "删掉自定义词典里的全部词，删了找不回来。"
        }
    }

    var confirmationTitle: String {
        switch self {
        case .allSettings: "恢复"
        case .customDictionary: "清空"
        }
    }
}

// MARK: - Logging Configuration View

struct LoggingConfigurationView: View {
    @ObservedObject var preferences: UserPreferences
    @State private var selectedLogLevel: LogLevel = Logger.minimumLogLevel
    @State private var fileLoggingEnabled: Bool = Logger.fileLoggingEnabled
    @State private var logFilePath: String = Logger.logFilePath
    @State private var showVerboseLoggingWarning: Bool = false
    @State private var pendingLogLevel: LogLevel?
    @State private var isConfirmingVerboseLevel: Bool = false

    var body: some View {
        TRGroup(title: "日志", note: "日志记多细、存在哪里，排查问题用。") {
            TRRow(title: "日志级别", note: "「调试」记下所有消息，「严重」只记最严重的问题") {
                Picker("", selection: $selectedLogLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.label).tag(level)
                    }
                }
                .labelsHidden().fixedSize()
                .onChange(of: selectedLogLevel) { oldValue, newValue in
                    // Skip onChange if we're confirming a verbose level (prevents re-triggering warning)
                    if isConfirmingVerboseLevel {
                        isConfirmingVerboseLevel = false
                        Logger.minimumLogLevel = newValue
                        return
                    }
                    // Show warning when switching to verbose levels that may log user text
                    if newValue == .debug || newValue == .trace, oldValue != .debug, oldValue != .trace {
                        pendingLogLevel = newValue
                        selectedLogLevel = oldValue // Revert until confirmed
                        showVerboseLoggingWarning = true
                    } else {
                        Logger.minimumLogLevel = newValue
                    }
                }
            }
            TRRow(title: "把日志写进文件", note: "排查问题时用", last: !fileLoggingEnabled) {
                Toggle("", isOn: $fileLoggingEnabled).toggleStyle(SquareToggleStyle()).labelsHidden()
                    .onChange(of: fileLoggingEnabled) { _, newValue in
                        Logger.fileLoggingEnabled = newValue
                    }
            }
            if fileLoggingEnabled {
                TRRow(title: "日志文件在", note: (logFilePath as NSString).abbreviatingWithTildeInPath + "\n默认：~/Library/Logs/TypeRight/typeright.log",
                      last: true) {
                    HStack(spacing: 8) {
                        Button("换个位置…") { chooseLogFilePath() }
                            .buttonStyle(TRPlainButtonStyle())
                            .help("选一个地方存日志")
                        if Logger.customLogFilePath != nil {
                            Button("用默认位置") { resetLogFilePathToDefault() }
                                .buttonStyle(TRPlainButtonStyle())
                                .help("默认位置：~/Library/Logs/TypeRight/")
                        }
                        Button("在访达中显示") {
                            NSWorkspace.shared.selectFile(logFilePath, inFileViewerRootedAtPath: "")
                        }
                        .buttonStyle(TRPlainButtonStyle())
                    }
                }
            }
        }
        .sheet(isPresented: $showVerboseLoggingWarning) {
            VerboseLoggingWarningSheet(
                pendingLogLevel: pendingLogLevel,
                isPresented: $showVerboseLoggingWarning,
                onConfirm: {
                    if let level = pendingLogLevel {
                        isConfirmingVerboseLevel = true
                        selectedLogLevel = level
                    }
                    pendingLogLevel = nil
                },
                onCancel: {
                    pendingLogLevel = nil
                }
            )
        }
    }

    private func chooseLogFilePath() {
        let savePanel = NSSavePanel()
        savePanel.title = "日志存到哪里"
        savePanel.message = "选一个地方存日志文件"
        savePanel.nameFieldStringValue = "typeright.log"
        savePanel.canCreateDirectories = true
        savePanel.showsTagField = false

        // Set default directory to ~/Library/Logs/TypeRight
        let defaultLogDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TypeRight")
        savePanel.directoryURL = defaultLogDir

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            // Save the custom path
            Logger.customLogFilePath = url.path
            logFilePath = url.path

            Logger.info("Log file path changed to: \(url.path)", category: Logger.general)
        }
    }

    private func resetLogFilePathToDefault() {
        Logger.resetLogFilePathToDefault()
        logFilePath = Logger.logFilePath

        Logger.info("Log file path reset to default", category: Logger.general)
    }
}

// MARK: - Export Success Sheet

struct ExportSuccessSheet: View {
    let filePath: String
    let fileSize: String
    @Binding var isPresented: Bool
    @State private var showCopiedFeedback: Bool = false

    private var fileName: String {
        (filePath as NSString).lastPathComponent
    }

    private var directoryPath: String {
        (filePath as NSString).deletingLastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                TRStatusDot(color: TR.ok, text: "导出好了")
                Text(fileName).font(.system(size: 15, weight: .semibold)).foregroundStyle(TR.text)
                    .lineLimit(2).textSelection(.enabled)
                Text("\(fileSize) · \((directoryPath as NSString).abbreviatingWithTildeInPath)")
                    .font(.system(size: 12)).foregroundStyle(TR.text2)
                    .lineLimit(2).textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Button(showCopiedFeedback ? "已复制" : "复制路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(filePath, forType: .string)
                    showCopiedFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        showCopiedFeedback = false
                    }
                }
                .buttonStyle(TRPlainButtonStyle())
                Button("在访达中显示") {
                    NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: "")
                }
                .buttonStyle(TRPlainButtonStyle())
                Spacer()
                Button("完成") { isPresented = false }
                    .buttonStyle(TRInkButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(TR.bg)
    }
}

// MARK: - Verbose Logging Warning Sheet

struct VerboseLoggingWarningSheet: View {
    let pendingLogLevel: LogLevel?
    @Binding var isPresented: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @State private var showCopiedFeedback: Bool = false

    private var logFilePath: String {
        Logger.logFilePath
    }

    private var directoryPath: String {
        (logFilePath as NSString).deletingLastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("详细日志会记下你打的字")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(TR.text)
                Text("「调试」和「追踪」级别为了排查问题，可能把查过的文字写进日志文件。留意开着详细日志时你都打了什么、日志文件发给了谁：里面可能有敏感信息。")
                    .font(.system(size: 13)).foregroundStyle(TR.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TRGroup {
                TRRow(title: "日志文件在", note: (logFilePath as NSString).abbreviatingWithTildeInPath, last: true) {
                    HStack(spacing: 8) {
                        Button(showCopiedFeedback ? "已复制" : "复制路径") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(logFilePath, forType: .string)
                            showCopiedFeedback = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                showCopiedFeedback = false
                            }
                        }
                        .buttonStyle(TRPlainButtonStyle())
                        Button("在访达中显示") {
                            NSWorkspace.shared.selectFile(logFilePath, inFileViewerRootedAtPath: "")
                        }
                        .buttonStyle(TRPlainButtonStyle())
                    }
                }
            }

            HStack(spacing: 8) {
                Spacer()
                Button("取消") {
                    isPresented = false
                    onCancel()
                }
                .buttonStyle(TRPlainButtonStyle())
                .keyboardShortcut(.cancelAction)
                Button("改成「\((pendingLogLevel ?? .debug).label)」") {
                    isPresented = false
                    onConfirm()
                }
                .buttonStyle(TRInkButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(TR.bg)
    }
}

private extension LogLevel {
    var label: String {
        switch self {
        case .trace: "追踪"
        case .debug: "调试"
        case .info: "信息"
        case .warning: "警告"
        case .error: "错误"
        case .critical: "严重"
        }
    }
}
