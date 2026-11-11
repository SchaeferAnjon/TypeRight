//
//  ResourceMonitoringView.swift
//  TextWarden
//
//  Resource monitoring view showing CPU and memory usage.
//

import Charts
import SwiftUI

// MARK: - Resource Monitoring View

struct ResourceMonitoringView: View {
    @ObservedObject private var statistics = UserStatistics.shared
    @State private var selectedTimeRange: ResourceTimeRange = .oneHour
    @State private var selectedCPUDate: Date?
    @State private var selectedMemoryDate: Date?

    enum ResourceTimeRange: String, CaseIterable {
        case fifteenMin = "15 分钟"
        case oneHour = "1 小时"
        case oneDay = "1 天"
        case sevenDays = "7 天"
        case thirtyDays = "30 天"

        var minutes: Int {
            switch self {
            case .fifteenMin: 15
            case .oneHour: 60
            case .oneDay: 24 * 60
            case .sevenDays: 7 * 24 * 60
            case .thirtyDays: 30 * 24 * 60
            }
        }
    }

    var body: some View {
        TRGroup(title: "资源占用") {
            TRRow(title: "CPU 和内存",
                  note: "TypeRight 自己用了多少。CPU 负载 1.0 表示占满一个核；这台 Mac 有 \(ProcessInfo.processInfo.activeProcessorCount) 个核，全部占满是 \(ProcessInfo.processInfo.activeProcessorCount).0。") {
                TRSegmented(options: ResourceTimeRange.allCases.map { ($0, $0.rawValue) }, selection: $selectedTimeRange)
            }

            let samples = filteredSamples()
            VStack(alignment: .leading, spacing: 24) {
                if samples.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("这段时间还没有数据").font(.system(size: 13)).foregroundStyle(TR.text)
                        Text("TypeRight 启动时开始记录。").font(.system(size: 12)).foregroundStyle(TR.text2)
                    }
                } else {
                    cpuMetricsView(samples: samples)
                    memoryMetricsView(samples: samples)
                    logVolumeMetricsView()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Shared chart pieces

    /// Numbers in the charts: two decimals with a point, whatever the system's decimal separator.
    static func load(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private func chartTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(TR.text)
    }

    private func summary(_ values: [(String, String)], count: Int) -> some View {
        HStack(alignment: .bottom, spacing: 24) {
            ForEach(values, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 12)).foregroundStyle(TR.text2)
                    Text(value).font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(TR.text)
                }
            }
            Spacer()
            Text("\(count) 个采样点").font(.system(size: 12)).foregroundStyle(TR.text2)
        }
    }

    private var restartLegend: some View {
        HStack(spacing: 6) {
            Circle().fill(TR.text3).frame(width: 7, height: 7)
            Text("灰点是 TypeRight 重启的时刻").font(.system(size: 12)).foregroundStyle(TR.text2)
        }
    }

    private func peakLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(TR.text2)
            .padding(.horizontal, 4)
            .background(TR.card.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
    }

    private func tooltip(_ time: Date, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(time, format: .dateTime.hour().minute().second()).font(.system(size: 11).monospacedDigit()).foregroundStyle(TR.text2)
            ForEach(lines, id: \.self) { line in
                Text(line).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(TR.text)
            }
        }
        .padding(8)
        .background(TR.pop, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TR.line2, lineWidth: 0.5))
    }

    // MARK: - CPU Metrics View

    private func cpuMetricsView(samples: [ResourceMetricSample]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            chartTitle("CPU 负载")

            let peakLoad = samples.map(\.processLoad).max() ?? 0.0
            let maxLoad = max(peakLoad * 1.2, 0.05) // 20% headroom, and never a flat zero-high scale

            // Extend the time domain a little so the first and last points are not on the edge
            let rawTimeRange = (samples.first?.timestamp ?? Date()) ... (samples.last?.timestamp ?? Date())
            let duration = rawTimeRange.upperBound.timeIntervalSince(rawTimeRange.lowerBound)
            let padding = duration * 0.045
            let timeRange = rawTimeRange.lowerBound.addingTimeInterval(-padding) ... rawTimeRange.upperBound.addingTimeInterval(padding)

            let visibleLaunches = statistics.appLaunchHistory.filter {
                $0 >= rawTimeRange.lowerBound && $0 <= rawTimeRange.upperBound
            }

            Chart {
                ForEach(samples) { sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Load", sample.processLoad)
                    )
                    .foregroundStyle(TR.text2)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
                }

                RuleMark(y: .value("Peak", peakLoad))
                    .foregroundStyle(TR.text3)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        peakLabel("最高 \(Self.load(peakLoad))")
                    }

                ForEach(visibleLaunches, id: \.self) { launchTime in
                    PointMark(
                        x: .value("Launch", launchTime),
                        y: .value("Load", 0)
                    )
                    .foregroundStyle(TR.text3)
                    .symbolSize(30)
                }

                if let selectedCPUDate,
                   let selectedSample = samples.min(by: { abs($0.timestamp.timeIntervalSince(selectedCPUDate)) < abs($1.timestamp.timeIntervalSince(selectedCPUDate)) })
                {
                    RuleMark(x: .value("Selected", selectedSample.timestamp))
                        .foregroundStyle(TR.line2)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .center) {
                            tooltip(selectedSample.timestamp,
                                    ["负载 \(Self.load(selectedSample.processLoad))"]
                                        + (selectedSample.systemLoad1m.map { ["系统 \(Self.load($0))"] } ?? []))
                        }
                }
            }
            .chartXSelection(value: $selectedCPUDate)
            .chartXScale(domain: timeRange)
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(TR.line)
                    AxisValueLabel().font(.system(size: 11).monospacedDigit()).foregroundStyle(TR.text2)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let load = value.as(Double.self) {
                            Text(Self.load(load)).font(.system(size: 11).monospacedDigit()).foregroundStyle(TR.text2)
                        }
                    }
                    AxisGridLine().foregroundStyle(TR.line)
                }
            }
            .chartYScale(domain: 0 ... maxLoad)
            .frame(height: 180)

            let loadValues = samples.map(\.processLoad)
            let avgLoad = loadValues.reduce(0, +) / Double(loadValues.count)
            summary([("最低", Self.load(loadValues.min() ?? 0)), ("最高", Self.load(loadValues.max() ?? 0)),
                     ("平均", Self.load(avgLoad)), ("中位", Self.load(median(loadValues)))], count: samples.count)

            if !visibleLaunches.isEmpty { restartLegend }
        }
    }

    // MARK: - Memory Metrics View

    private func memoryMetricsView(samples: [ResourceMetricSample]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            chartTitle("内存")

            let maxMemoryMB = Double(samples.map(\.memoryBytes).max() ?? 0) / 1_048_576
            let minMemoryMB = Double(samples.map(\.memoryBytes).min() ?? 0) / 1_048_576

            let rawTimeRange = (samples.first?.timestamp ?? Date()) ... (samples.last?.timestamp ?? Date())
            let duration = rawTimeRange.upperBound.timeIntervalSince(rawTimeRange.lowerBound)
            let padding = duration * 0.045
            let timeRange = rawTimeRange.lowerBound.addingTimeInterval(-padding) ... rawTimeRange.upperBound.addingTimeInterval(padding)

            let visibleLaunches = statistics.appLaunchHistory.filter {
                $0 >= rawTimeRange.lowerBound && $0 <= rawTimeRange.upperBound
            }

            Chart {
                ForEach(samples) { sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Memory", Double(sample.memoryBytes) / 1_048_576)
                    )
                    .foregroundStyle(TR.text2)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
                }

                RuleMark(y: .value("Peak", maxMemoryMB))
                    .foregroundStyle(TR.text3)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        peakLabel("最高 \(String(format: "%.1f MB", maxMemoryMB))")
                    }

                ForEach(visibleLaunches, id: \.self) { launchTime in
                    PointMark(
                        x: .value("Launch", launchTime),
                        y: .value("Memory", minMemoryMB)
                    )
                    .foregroundStyle(TR.text3)
                    .symbolSize(30)
                }

                if let selectedMemoryDate,
                   let selectedSample = samples.min(by: { abs($0.timestamp.timeIntervalSince(selectedMemoryDate)) < abs($1.timestamp.timeIntervalSince(selectedMemoryDate)) })
                {
                    RuleMark(x: .value("Selected", selectedSample.timestamp))
                        .foregroundStyle(TR.line2)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .center) {
                            tooltip(selectedSample.timestamp, [Self.megabytes(selectedSample.memoryBytes)])
                        }
                }
            }
            .chartXSelection(value: $selectedMemoryDate)
            .chartXScale(domain: timeRange)
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(TR.line)
                    AxisValueLabel().font(.system(size: 11).monospacedDigit()).foregroundStyle(TR.text2)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let mb = value.as(Double.self) {
                            Text("\(Int(mb)) MB").font(.system(size: 11).monospacedDigit()).foregroundStyle(TR.text2)
                        }
                    }
                    AxisGridLine().foregroundStyle(TR.line)
                }
            }
            .chartYScale(domain: (minMemoryMB * 0.9) ... (maxMemoryMB * 1.1))
            .frame(height: 180)

            let memoryValues = samples.map(\.memoryBytes)
            let avgBytes = memoryValues.reduce(0, +) / UInt64(memoryValues.count)
            summary([("最低", Self.megabytes(memoryValues.min() ?? 0)), ("最高", Self.megabytes(memoryValues.max() ?? 0)),
                     ("平均", Self.megabytes(avgBytes)), ("中位", Self.megabytes(medianUInt64(memoryValues)))], count: samples.count)

            if !visibleLaunches.isEmpty { restartLegend }
        }
    }

    // MARK: - Log Volume Metrics View

    @ViewBuilder
    private func logVolumeMetricsView() -> some View {
        let counts = statistics.logCountBySeverity(inMinutes: selectedTimeRange.minutes)
        let totalLogs = counts.trace + counts.debug + counts.info + counts.warning + counts.error + counts.critical
        let minLevel = Logger.minimumLogLevel

        VStack(alignment: .leading, spacing: 12) {
            chartTitle("日志条数")

            if totalLogs == 0 {
                Text("还没有日志").font(.system(size: 12)).foregroundStyle(TR.text2)
            } else {
                // Only levels that are written count toward the longest bar
                let enabledCounts = [
                    minLevel <= .critical ? counts.critical : 0,
                    minLevel <= .error ? counts.error : 0,
                    minLevel <= .warning ? counts.warning : 0,
                    minLevel <= .info ? counts.info : 0,
                    minLevel <= .debug ? counts.debug : 0,
                    minLevel <= .trace ? counts.trace : 0,
                ]
                let maxCount = max(enabledCounts.max() ?? 1, 1)

                VStack(alignment: .leading, spacing: 8) {
                    if minLevel <= .critical {
                        LogVolumeRow(label: "严重", count: counts.critical, maxCount: maxCount)
                            .help("没法恢复、要马上处理的错误")
                    }
                    if minLevel <= .error {
                        LogVolumeRow(label: "错误", count: counts.error, maxCount: maxCount)
                            .help("影响功能的失败")
                    }
                    if minLevel <= .warning {
                        LogVolumeRow(label: "警告", count: counts.warning, maxCount: maxCount)
                            .help("能恢复的问题，比如换了备用接口或超时")
                    }
                    if minLevel <= .info {
                        LogVolumeRow(label: "信息", count: counts.info, maxCount: maxCount)
                            .help("重要的节点，比如启动、查完一段")
                    }
                    if minLevel <= .debug {
                        LogVolumeRow(label: "调试", count: counts.debug, maxCount: maxCount)
                            .help("排查问题用的日常记录")
                    }
                    if minLevel <= .trace {
                        LogVolumeRow(label: "追踪", count: counts.trace, maxCount: maxCount)
                            .help("鼠标移动这类很频繁的事件")
                    }
                }

                Text("一共 \(totalLogs) 条").font(.system(size: 12)).foregroundStyle(TR.text2)
            }
        }
    }

    // MARK: - Helper Methods

    private func filteredSamples() -> [ResourceMetricSample] {
        let cutoffDate = Calendar.current.date(byAdding: .minute, value: -selectedTimeRange.minutes, to: Date()) ?? Date.distantPast

        let allSamples = statistics.resourceSamples
            .filter { $0.component == .swiftApp }
            .filter { $0.timestamp >= cutoffDate }
            .sorted { $0.timestamp < $1.timestamp }

        // Downsample for longer time ranges to keep charts smooth
        // Target ~180 points for optimal visual appearance
        let targetPoints = 180
        guard allSamples.count > targetPoints else { return allSamples }

        // For 15m, keep all samples (usually ~180 at 5s intervals)
        // For longer ranges, downsample by averaging windows
        let step = max(1, allSamples.count / targetPoints)
        var downsampled: [ResourceMetricSample] = []

        for i in stride(from: 0, to: allSamples.count, by: step) {
            let windowEnd = min(i + step, allSamples.count)
            let window = Array(allSamples[i ..< windowEnd])

            guard !window.isEmpty else { continue }

            // Use the middle sample's timestamp for accurate positioning
            let midIndex = window.count / 2
            let timestamp = window[midIndex].timestamp

            // Average the values in the window
            let avgLoad = window.map(\.processLoad).reduce(0, +) / Double(window.count)
            let avgMemory = UInt64(window.map { Double($0.memoryBytes) }.reduce(0, +) / Double(window.count))

            // Take system load from middle sample (or nil if any is nil)
            let sys1m = window[midIndex].systemLoad1m
            let sys5m = window[midIndex].systemLoad5m
            let sys15m = window[midIndex].systemLoad15m

            downsampled.append(ResourceMetricSample(
                timestamp: timestamp,
                component: .swiftApp,
                processLoad: avgLoad,
                memoryBytes: avgMemory,
                systemLoad1m: sys1m,
                systemLoad5m: sys5m,
                systemLoad15m: sys15m
            ))
        }

        return downsampled
    }

    /// Calculate median of Double values
    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.0 }
        let sorted = values.sorted()
        if sorted.count % 2 == 0 {
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2.0
        } else {
            return sorted[sorted.count / 2]
        }
    }

    /// Calculate median of UInt64 values
    private func medianUInt64(_ values: [UInt64]) -> UInt64 {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        if sorted.count % 2 == 0 {
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        } else {
            return sorted[sorted.count / 2]
        }
    }
}

// MARK: - Log Volume Helper Views

/// One bar per log level, all in one neutral color: the levels are not a traffic light.
private struct LogVolumeRow: View {
    let label: String
    let count: Int
    let maxCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(TR.text2)
                .frame(width: 40, alignment: .leading)

            GeometryReader { geometry in
                let share = maxCount > 0 ? Double(count) / Double(maxCount) : 0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(TR.fill)
                    RoundedRectangle(cornerRadius: 3).fill(TR.line2)
                        .frame(width: geometry.size.width * share)
                }
                .accessibilityHidden(true)
            }
            .frame(height: 6)

            Text("\(count)")
                .font(.system(size: 12).monospacedDigit())
                // swiftlint:disable:next empty_count
                .foregroundStyle(count > 0 ? TR.text : TR.text2) // count is Int, not collection
                .frame(width: 56, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)：\(count) 条")
    }
}
