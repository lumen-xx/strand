import Foundation
import StrandCore
import SwiftUI
import Charts

struct UsagePoint: Identifiable {
    var id: TimeInterval { time }
    var time: TimeInterval
    var value: Double
    var segment: Int
}
struct UsageHistory {
    private(set) var points: [UsagePoint] = []
    private var segment = 0
    /// Read a measured sample, never interpolate across missing readings.
    func sample(near time: TimeInterval) -> UsagePoint? {
        guard let first = points.first, let last = points.last,
              time >= first.time, time <= last.time,
              let nearest = points.min(by: { abs($0.time - time) < abs($1.time - time) }),
              abs(nearest.time - time) <= 3 else { return nil }
        return nearest
    }
    mutating func append(_ value: Double?, at time: TimeInterval) {
        points.removeAll { $0.time < time - 120 }
        guard let value, value.isFinite, value >= 0 else { segment += 1; return }
        points.append(UsagePoint(time: time, value: value, segment: segment))
        if points.count > 60 { points.removeFirst(points.count - 60) }
    }
}
struct UsageGraph: View {
    var title: String
    var history: UsageHistory
    var color: Color
    var bytes = false
    var help: String
    @State private var hoverTime: TimeInterval?
    private var hovered: UsagePoint? { hoverTime.flatMap { history.sample(near: $0) } }
    private func formatted(_ value: Double) -> String {
        bytes ? StorageUsage.formatted(value) : number(value) + " W"
    }
    var body: some View {
        if let latest = history.points.last {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(Style.title)
                    InfoHint(text: help)
                    Spacer()
                    if let hovered {
                        Text(formatted(hovered.value)).font(Style.title).monospacedDigit().foregroundStyle(color)
                            .accessibilityLabel("Hovered sample, \(formatted(hovered.value)), \(Date(timeIntervalSince1970: hovered.time).formatted(date: .omitted, time: .standard))")
                    }
                    Text(formatted(latest.value)).font(Style.title).monospacedDigit()
                        .accessibilityLabel("Latest reading, \(formatted(latest.value))")
                }
                Chart {
                    ForEach(history.points) { point in
                    LineMark(x: .value("Time", Date(timeIntervalSince1970: point.time)), y: .value(bytes ? "MB/s" : "W", bytes ? point.value / 1_000_000 : point.value), series: .value("Segment", point.segment))
                        .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("Time", Date(timeIntervalSince1970: point.time)), y: .value(bytes ? "MB/s" : "W", bytes ? point.value / 1_000_000 : point.value))
                        .foregroundStyle(color).symbolSize(history.points.count == 1 ? 18 : 0)
                    }
                    if let hovered {
                        RuleMark(x: .value("Selected time", Date(timeIntervalSince1970: hovered.time)))
                            .foregroundStyle(Color.secondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        PointMark(x: .value("Selected time", Date(timeIntervalSince1970: hovered.time)), y: .value(bytes ? "MB/s" : "W", bytes ? hovered.value / 1_000_000 : hovered.value))
                            .foregroundStyle(color).symbolSize(35)
                    }
                }.chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard let anchor = proxy.plotFrame else { hoverTime = nil; return }
                                    let plot = geometry[anchor]
                                    guard plot.contains(location), let date: Date = proxy.value(atX: location.x - plot.minX) else { hoverTime = nil; return }
                                    hoverTime = date.timeIntervalSince1970
                                case .ended: hoverTime = nil
                                }
                            }
                    }
                }.chartYScale(domain: 0...max(bytes ? latest.value / 1_000_000 : latest.value, history.points.map { bytes ? $0.value / 1_000_000 : $0.value }.max() ?? 0, 1))
                    .chartXScale(domain: Date(timeIntervalSince1970: latest.time - 120)...Date(timeIntervalSince1970: latest.time)).chartLegend(.hidden).chartXAxis(.hidden).chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in AxisValueLabel().font(Style.caption) } }
                    .frame(height: 100)
                Text("Last 2 minutes").font(Style.caption).foregroundStyle(.tertiary)
            }.onAppear {
                // Deterministic fixture preview of the hover layout; live runs always use pointer input.
                if CommandLine.arguments.contains("--fixture"), CommandLine.arguments.contains("--hover-graphs") {
                    hoverTime = history.points[history.points.count / 2].time
                }
            }.accessibilityElement(children: .contain)
                .accessibilityLabel("\(title), \(bytes ? StorageUsage.formatted(latest.value) : number(latest.value) + " watts"), history over the last two minutes")
        }
    }
}

/// Two measured rates on one chart, such as received/sent traffic or storage read/write.
struct RateChart: View {
    var received: UsageHistory
    var sent: UsageHistory
    var compact = false
    var title = "Traffic"
    var names = (first: "Received", second: "Sent")
    /// Network traffic can be shown in bits per second; storage rates always use bytes.
    var bits = false
    var help = "Total Wi-Fi and Ethernet traffic, including local-network traffic. Virtual interfaces are excluded to avoid counting copies. Hover to read measured samples from both series."
    @State private var hoverTime: TimeInterval?
    private var points: [UsagePoint] { received.points + sent.points }
    private var peak: Double { points.map(\.value).max() ?? 0 }
    private var scale: Double { bits ? 8 : 1 }
    private var divisor: Double { peak * scale >= 1_000_000 ? 1_000_000 / scale : 1_000 / scale }
    private var unit: String { bits ? (divisor * scale == 1_000 ? "kbit/s" : "Mbit/s") : (divisor == 1_000 ? "KB/s" : "MB/s") }
    private func format(_ value: Double) -> String { bits ? Setting.bits(value) : StorageUsage.formatted(value) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !compact { HStack {
                Text(title).font(Style.title)
                InfoHint(text: help)
                Spacer()
                Text(unit).font(Style.caption).foregroundStyle(.secondary)
            } }
            HStack(spacing: 16) {
                legend(names.first, icon: "arrow.down", color: .cyan, history: received)
                legend(names.second, icon: "arrow.up", color: .purple, history: sent)
            }
            if let latest = points.map(\.time).max(), let earliest = points.map(\.time).min() {
                Chart {
                    ForEach(received.points) { point in
                        LineMark(x: .value("Time", Date(timeIntervalSince1970: point.time)), y: .value(unit, point.value / divisor), series: .value("Series", "First \(point.segment)"))
                            .foregroundStyle(Color.cyan).lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    ForEach(sent.points) { point in
                        LineMark(x: .value("Time", Date(timeIntervalSince1970: point.time)), y: .value(unit, point.value / divisor), series: .value("Series", "Second \(point.segment)"))
                            .foregroundStyle(Color.purple).lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    }
                    if received.points.count == 1, let point = received.points.first {
                        PointMark(x: .value("Time", Date(timeIntervalSince1970: point.time)), y: .value(unit, point.value / divisor)).foregroundStyle(Color.cyan).symbolSize(18)
                    }
                    if sent.points.count == 1, let point = sent.points.first {
                        PointMark(x: .value("Time", Date(timeIntervalSince1970: point.time)), y: .value(unit, point.value / divisor)).foregroundStyle(Color.purple).symbolSize(18)
                    }
                    if let time = hoverTime {
                        RuleMark(x: .value("Hover", Date(timeIntervalSince1970: time))).foregroundStyle(Color.secondary.opacity(0.5))
                    }
                }.chartYScale(domain: 0...max(peak / divisor * 1.15, 0.1))
                    .chartXScale(domain: Date(timeIntervalSince1970: min(earliest, latest - 3))...Date(timeIntervalSince1970: latest))
                    .chartLegend(.hidden).chartXAxis(.hidden)
                    .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in AxisValueLabel().font(Style.caption) } }
                    .frame(height: compact ? 64 : 160)
                    .chartOverlay { proxy in
                        GeometryReader { geometry in
                            Rectangle().fill(.clear).contentShape(Rectangle()).onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard let anchor = proxy.plotFrame else { hoverTime = nil; return }
                                    let frame = geometry[anchor]
                                    guard frame.contains(location), let date: Date = proxy.value(atX: location.x - frame.minX) else { hoverTime = nil; return }
                                    hoverTime = date.timeIntervalSince1970
                                case .ended: hoverTime = nil
                                }
                            }
                        }
                    }
                if !compact { HStack { Text("\(Int(latest - earliest)) seconds of readings"); Spacer(); Text("Now") }.font(Style.caption).foregroundStyle(.secondary) }
            } else { Text("Waiting for readings…").font(Style.caption).foregroundStyle(.secondary).frame(height: compact ? 64 : 160) }
        }.accessibilityElement(children: .contain).accessibilityLabel("\(title), \(names.first.lowercased()) and \(names.second.lowercased())")
    }
    func legend(_ name: String, icon: String, color: Color, history: UsageHistory) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(name)
            if let time = hoverTime, let sample = history.sample(near: time) { Text(format(sample.value)).monospacedDigit() }
            else if compact, let sample = history.points.last { Text(format(sample.value)).monospacedDigit() }
        }.font(Style.caption)
    }
}
