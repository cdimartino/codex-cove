import Foundation
import SwiftUI
import CoveCore

/// Expanded-window profile statistics backed only by the public Codex
/// app-server `account/usage/read` response.
struct CoveProfileTokenUsageView: View {
    let usage: CoveUsageSnapshot?
    let theme: CoveThemePalette

    @State private var trendKind: CoveAccountTokenUsageTrendKind = .daily

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 8) {
                header(now: context.date)

                if let profile = usage?.accountTokenUsage {
                    let metrics = summaryMetrics(profile.summary)
                    if !metrics.isEmpty {
                        LazyVGrid(
                            columns: [
                                GridItem(.adaptive(minimum: 92), spacing: 6),
                            ],
                            alignment: .leading,
                            spacing: 6
                        ) {
                            ForEach(metrics) { metric in
                                metricCard(metric)
                            }
                        }
                    }

                    if let buckets = profile.dailyUsageBuckets,
                       !buckets.isEmpty {
                        trendSection(profile: profile, now: context.date)
                    }

                    if !profile.hasData {
                        Text("Codex supplied no profile token metrics.")
                            .coveThemeFont(theme, size: 9, weight: .medium)
                            .foregroundStyle(
                                Color(hex: theme.mutedTextHex)
                            )
                    }
                } else {
                    Label(
                        "Profile token usage unavailable",
                        systemImage: "chart.bar.xaxis"
                    )
                    .coveThemeFont(theme, size: 10, weight: .medium)
                    .foregroundStyle(
                        Color(hex: theme.foregroundHex).opacity(0.68)
                    )
                }
            }
            .padding(9)
            .background(
                RoundedRectangle(
                    cornerRadius: max(4, theme.cornerRadius * 0.5),
                    style: .continuous
                )
                .fill(Color(hex: theme.surfaceHex).opacity(0.7))
            )
        }
    }

    private func header(now: Date) -> some View {
        HStack(spacing: 8) {
            Text("Profile token usage")
                .coveThemeFont(theme, size: 11, weight: .semibold)
            Spacer()
            if let profile = usage?.accountTokenUsage {
                Text(statusLabel(profile: profile, now: now))
                    .coveThemeFont(theme, size: 8, weight: .medium)
                    .foregroundStyle(statusColor(profile: profile, now: now))
            } else {
                Text("Unavailable")
                    .coveThemeFont(theme, size: 8, weight: .medium)
                    .foregroundStyle(Color(hex: theme.mutedTextHex))
            }
        }
    }

    private func metricCard(_ metric: SummaryMetric) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metric.title)
                .coveThemeFont(theme, size: 8, weight: .medium)
                .foregroundStyle(Color(hex: theme.mutedTextHex))
            Text(metric.value)
                .coveThemeFont(theme, size: 11, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(Color(hex: theme.foregroundHex))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(hex: theme.backgroundHex).opacity(0.34))
        )
        .accessibilityElement(children: .combine)
    }

    private func trendSection(
        profile: CoveAccountTokenUsageSnapshot,
        now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Usage history", selection: $trendKind) {
                Text("Daily").tag(CoveAccountTokenUsageTrendKind.daily)
                Text("Weekly").tag(CoveAccountTokenUsageTrendKind.weekly)
                Text("Cumulative").tag(CoveAccountTokenUsageTrendKind.cumulative)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            let allPoints = profile.trendPoints(
                trendKind,
                through: now
            ) ?? []
            let visiblePoints = chartPoints(from: allPoints)
            if visiblePoints.isEmpty {
                Text("No usage history supplied for this period.")
                    .coveThemeFont(theme, size: 8, weight: .medium)
                    .foregroundStyle(Color(hex: theme.mutedTextHex))
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(trendTitle)
                    Spacer()
                    Text(formatTokens(visiblePoints.last?.tokens ?? 0))
                        .monospacedDigit()
                }
                .coveThemeFont(theme, size: 8, weight: .semibold)
                .foregroundStyle(Color(hex: theme.foregroundHex).opacity(0.72))

                trendBars(visiblePoints)
            }
        }
    }

    private func trendBars(
        _ points: [CoveAccountTokenUsageTrendPoint]
    ) -> some View {
        let maximum = max(1, points.map(\.tokens).max() ?? 0)
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(
                            point.isFuture
                                ? Color(hex: theme.borderHex).opacity(0.25)
                                : Color(hex: theme.accentHex).opacity(0.82)
                        )
                        .frame(maxWidth: .infinity)
                        .frame(
                            height: point.isFuture
                                ? 1
                                : barHeight(point.tokens, maximum: maximum)
                        )
                    if index == 0 || index == points.count - 1 {
                        Text(shortDate(point.startDate))
                            .coveThemeFont(theme, size: 7, weight: .medium)
                            .foregroundStyle(Color(hex: theme.mutedTextHex))
                            .lineLimit(1)
                    } else {
                        Text(" ")
                            .coveThemeFont(theme, size: 7)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .bottom)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(longDate(point.startDate)), \(point.tokens) tokens"
                )
            }
        }
        .frame(height: 55, alignment: .bottom)
    }

    private func summaryMetrics(
        _ summary: CoveAccountTokenUsageSummary
    ) -> [SummaryMetric] {
        var metrics: [SummaryMetric] = []
        if let value = summary.lifetimeTokens {
            metrics.append(
                .init(id: "lifetime", title: "Lifetime", value: formatTokens(value))
            )
        }
        if let value = summary.peakDailyTokens {
            metrics.append(
                .init(id: "peak", title: "Peak day", value: formatTokens(value))
            )
        }
        if let value = summary.longestRunningTurnSeconds {
            metrics.append(
                .init(id: "longest", title: "Longest task", value: formatDuration(value))
            )
        }
        if let value = summary.currentStreakDays {
            metrics.append(
                .init(id: "current-streak", title: "Current streak", value: dayCount(value))
            )
        }
        if let value = summary.longestStreakDays {
            metrics.append(
                .init(id: "longest-streak", title: "Longest streak", value: dayCount(value))
            )
        }
        return metrics
    }

    private func chartPoints(
        from points: [CoveAccountTokenUsageTrendPoint]
    ) -> [CoveAccountTokenUsageTrendPoint] {
        switch trendKind {
        case .daily:
            return Array(points.filter { !$0.isFuture }.suffix(14))
        case .weekly, .cumulative:
            return Array(points.suffix(12))
        }
    }

    private var trendTitle: String {
        switch trendKind {
        case .daily:
            "Latest day"
        case .weekly:
            "Current week"
        case .cumulative:
            "Rolling 52 weeks"
        }
    }

    private func statusLabel(
        profile: CoveAccountTokenUsageSnapshot,
        now: Date
    ) -> String {
        let age = dataAge(capturedAt: profile.capturedAt, now: now)
        if usage?.accountTokenUsageAvailability == .unavailable {
            return profile.isStale(at: now)
                ? "Refresh unavailable · stale"
                : "Refresh unavailable · \(age)"
        }
        return profile.isStale(at: now) ? "Stale · \(age)" : age
    }

    private func statusColor(
        profile: CoveAccountTokenUsageSnapshot,
        now: Date
    ) -> Color {
        if usage?.accountTokenUsageAvailability == .unavailable
            || profile.isStale(at: now) {
            return Color(hex: theme.waitingApprovalHex)
        }
        return Color(hex: theme.foregroundHex).opacity(0.62)
    }

    private func dataAge(capturedAt: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(capturedAt)))
        if seconds < 60 { return "Updated now" }
        if seconds < 3_600 { return "Updated \(seconds / 60)m ago" }
        if seconds < 86_400 { return "Updated \(seconds / 3_600)h ago" }
        return "Updated \(seconds / 86_400)d ago"
    }

    private func barHeight(_ tokens: Int64, maximum: Int64) -> CGFloat {
        max(2, 34 * CGFloat(Double(tokens) / Double(maximum)))
    }

    private func formatTokens(_ value: Int64) -> String {
        switch value {
        case 1_000_000_000...:
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", Double(value) / 1_000)
        default:
            return "\(value)"
        }
    }

    private func formatDuration(_ seconds: Int64) -> String {
        if seconds >= 3_600 {
            let roundedMinutes = (seconds / 60) + ((seconds % 60) >= 30 ? 1 : 0)
            return "\(roundedMinutes / 60)h \(roundedMinutes % 60)m"
        }
        if seconds >= 60 {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
        return "\(seconds)s"
    }

    private func dayCount(_ value: Int64) -> String {
        "\(value) \(value == 1 ? "day" : "days")"
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func longDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.wide).day())
    }

    private struct SummaryMetric: Identifiable {
        let id: String
        let title: String
        let value: String
    }
}
