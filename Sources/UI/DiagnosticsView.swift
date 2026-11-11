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
        Form {
            Section {
                let snapshot = sampleHealth ?? runtimeHealth.snapshot
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: statusIcon(for: snapshot.state))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(statusColor(for: snapshot.state))
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(statusColor(for: snapshot.state).opacity(0.12))
                        )

                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(snapshot.applicationName ?? "TypeRight")
                                .font(.headline)

                            Spacer()

                            Text(Self.stateLabel(snapshot.state))
                                .font(.caption.weight(.semibold))
                                .foregroundColor(statusColor(for: snapshot.state))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(statusColor(for: snapshot.state).opacity(0.12))
                                )
                        }

                        Text(Self.healthTitle(snapshot))
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        if let lastCheck = snapshot.lastSuccessfulCheck {
                            Label(
                                "上次查是 \(lastCheck.formatted(date: .omitted, time: .shortened))",
                                systemImage: "clock"
                            )
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }

                        if snapshot.capabilities.rawValue != 0 {
                            Text(Self.capabilityLabel(snapshot.capabilities))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if let bundleID = snapshot.bundleIdentifier {
                            Text(bundleID)
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }

                        runtimeHealthAction(for: snapshot)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .padding(.top, 2)
                    }
                }
                .padding(.vertical, 6)
            } header: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                        Text("现在的状态")
                            .font(.title3)
                            .fontWeight(.semibold)
                    }

                    Text("TypeRight 在当前 App 里能不能用，不能用时可以怎么办")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // MARK: - Session Information

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("启动于：")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(BuildInfo.launchDate.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: "zh_CN"))))
                            .font(.caption)
                            .fontWeight(.medium)
                    }

                    HStack {
                        Text("已运行：")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(Self.uptimeLabel(since: BuildInfo.launchDate))
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "clock")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                        Text("这次运行")
                            .font(.title3)
                            .fontWeight(.semibold)
                    }

                    Text("TypeRight 这次开了多久")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // MARK: - Resource Monitoring Section

            ResourceMonitoringView()

            // MARK: - Logging Configuration

            LoggingConfigurationView(preferences: preferences)

            // MARK: - Export System Diagnostics

            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Text("出问题时，导出一个诊断包发给我们：里面有日志、崩溃记录、系统信息和性能数据。")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 8)

                    Button(action: exportDiagnosticsToFile) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("导出诊断包")
                        }
                        .font(.body)
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isExporting)

                    if isExporting {
                        HStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.small)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("正在准备诊断包…")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text("正在清理日志里的文字、收集数据")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
                    }

                    Divider()
                        .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("ZIP 里有：")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Group {
                            Label("diagnostic_overview.json：系统信息、权限、设置", systemImage: "doc.text")
                            Label("性能数据：各时间段的耗时（平均、中位、P90、P95、P99）", systemImage: "chart.xyaxis.line")
                            Label("使用统计：各时间段查到的错和类别", systemImage: "chart.bar")
                            Label("全部日志文件（当前的和轮换下来的）", systemImage: "doc.on.doc")
                            Label("crash_reports/：崩溃记录（有的话）", systemImage: "exclamationmark.triangle")
                            Label("App 状态（哪些暂停、哪些在看）", systemImage: "app.dashed")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }

                    Text("隐私：默认的日志级别不记你打的字；调到「调试」或「追踪」后，日志里可能有你打的字，发出去之前先看一眼。")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.top, 4)
                }
            } header: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                        Text("导出诊断包")
                            .font(.title3)
                            .fontWeight(.semibold)
                    }

                    Text("排查问题用")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // MARK: - Reset Options

            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Text("把下面的东西恢复成默认。恢复了就回不去。")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 8)

                    HStack(spacing: 12) {
                        Button {
                            pendingResetAction = .allSettings
                        } label: {
                            HStack {
                                Image(systemName: "arrow.counterclockwise.circle.fill")
                                Text("恢复全部高级设置")
                            }
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .help("「高级」里的设置都回到默认，然后重新打开 TypeRight")

                        Button {
                            pendingResetAction = .customDictionary
                        } label: {
                            HStack {
                                Image(systemName: "book.closed.fill")
                                Text("清空自定义词典")
                            }
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .help("删掉「拼写」里自定义词典的全部词")
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise.circle")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                        Text("恢复默认")
                            .font(.title3)
                            .fontWeight(.semibold)
                    }

                    Text("错题本、生词本和 Key 不受影响")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
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

    private func statusIcon(for state: CheckingState) -> String {
        switch state {
        case .active: "checkmark.circle.fill"
        case .limited: "exclamationmark.circle.fill"
        case .recovering: "arrow.triangle.2.circlepath.circle.fill"
        case .inactive: "pause.circle.fill"
        }
    }

    private func statusColor(for state: CheckingState) -> Color {
        switch state {
        case .active: .green
        case .limited, .recovering: .orange
        case .inactive: .secondary
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
        Section {
            VStack(alignment: .leading, spacing: 16) {
                Text("日志记多细、存在哪里，排查问题用")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 8)

                // Log Level Picker
                HStack {
                    Text("日志级别：")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Spacer()

                    Picker("日志级别", selection: $selectedLogLevel) {
                        ForEach(LogLevel.allCases, id: \.self) { level in
                            Text(level.label).tag(level)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
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

                Text("「调试」记下所有消息，「严重」只记最严重的问题")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()
                    .padding(.vertical, 4)

                // File Logging Toggle
                Toggle("把日志写进文件", isOn: $fileLoggingEnabled)
                    .onChange(of: fileLoggingEnabled) { _, newValue in
                        Logger.fileLoggingEnabled = newValue
                    }
                    .help("排查问题时用")

                if fileLoggingEnabled {
                    VStack(alignment: .leading, spacing: 12) {
                        // Log File Path Configuration
                        VStack(alignment: .leading, spacing: 8) {
                            Text("日志文件在：")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            // Path displayed in a styled text field
                            HStack {
                                Text((logFilePath as NSString).abbreviatingWithTildeInPath)
                                    .font(.caption.monospaced())
                                    .foregroundColor(.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .help("现在的日志文件。点「换个位置…」能换")
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )

                            Text("可以用下面的按钮换个位置，也可以用默认位置")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack(spacing: 8) {
                                Button("换个位置…") {
                                    chooseLogFilePath()
                                }
                                .buttonStyle(.bordered)
                                .help("选一个地方存日志")

                                if Logger.customLogFilePath != nil {
                                    Button("用默认位置") {
                                        resetLogFilePathToDefault()
                                    }
                                    .buttonStyle(.bordered)
                                    .help("默认位置：~/Library/Logs/TypeRight/")
                                }

                                Button("在访达中显示") {
                                    NSWorkspace.shared.selectFile(logFilePath, inFileViewerRootedAtPath: "")
                                }
                                .buttonStyle(.bordered)
                                .help("在访达里找到日志文件")
                            }

                            Text("默认：~/Library/Logs/TypeRight/typeright.log")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, 20)
                    }
                }
            }
        } header: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.fill")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                    Text("日志")
                        .font(.title3)
                        .fontWeight(.semibold)
                }

                Text("日志级别和写到哪个文件")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
        VStack(spacing: 0) {
            // Header with success icon
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)

                Text("导出好了")
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            .padding(.top, 24)
            .padding(.bottom, 20)

            // File info card
            VStack(alignment: .leading, spacing: 12) {
                // File name with icon
                HStack(spacing: 10) {
                    Image(systemName: "doc.zipper")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(fileName)
                            .font(.body)
                            .fontWeight(.medium)

                        Text(fileSize)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                Divider()

                // Path display
                VStack(alignment: .leading, spacing: 4) {
                    Text("位置")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text((directoryPath as NSString).abbreviatingWithTildeInPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            .padding(16)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 24)

            // Action buttons
            HStack(spacing: 12) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(filePath, forType: .string)
                    showCopiedFeedback = true

                    // Hide feedback after delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        showCopiedFeedback = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
                        Text(showCopiedFeedback ? "已复制" : "复制路径")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(showCopiedFeedback ? .green : nil)

                Button {
                    NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: "")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text("在访达中显示")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            // Done button
            Button {
                isPresented = false
            } label: {
                Text("完成")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .frame(width: 420)
        .background(.regularMaterial)
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
        VStack(spacing: 0) {
            // Header with warning icon
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)

                Text("详细日志会记下你打的字")
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            // Warning message
            VStack(alignment: .leading, spacing: 16) {
                Text("「调试」和「追踪」级别为了排查问题，可能把查过的文字写进日志文件。")
                    .font(.body)

                VStack(alignment: .leading, spacing: 8) {
                    Text("留意：")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "doc.text")
                                .frame(width: 16, alignment: .center)
                            Text("开着详细日志时你都打了什么")
                        }
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "person.2")
                                .frame(width: 16, alignment: .center)
                            Text("日志文件发给了谁")
                        }
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "lock.shield")
                                .frame(width: 16, alignment: .center)
                            Text("日志里可能有敏感信息")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            // Log file path card
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("日志文件在")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text((logFilePath as NSString).abbreviatingWithTildeInPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }

                    Spacer()
                }

                // Path action buttons
                HStack(spacing: 8) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(logFilePath, forType: .string)
                        showCopiedFeedback = true

                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showCopiedFeedback = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
                                .frame(width: 12)
                            Text(showCopiedFeedback ? "已复制" : "复制路径")
                        }
                        .font(.caption)
                        .frame(height: 16)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(showCopiedFeedback ? .green : nil)

                    Button {
                        NSWorkspace.shared.selectFile(logFilePath, inFileViewerRootedAtPath: "")
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .frame(width: 12)
                            Text("在访达中显示")
                        }
                        .font(.caption)
                        .frame(height: 16)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()
                }
            }
            .padding(16)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 24)

            // Action buttons
            HStack(spacing: 12) {
                Button {
                    isPresented = false
                    onCancel()
                } label: {
                    Text("取消")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button {
                    isPresented = false
                    onConfirm()
                } label: {
                    Text("改成「\((pendingLogLevel ?? .debug).label)」")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .frame(width: 460)
        .background(.regularMaterial)
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
