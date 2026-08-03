import Foundation

public struct CoveRateLimitWindow: Codable, Equatable, Sendable {
    public var usedPercent: Int
    public var resetsAt: Date?
    public var windowDurationMinutes: Int?

    public init(usedPercent: Int, resetsAt: Date?, windowDurationMinutes: Int?) {
        self.usedPercent = min(100, max(0, usedPercent))
        self.resetsAt = resetsAt
        self.windowDurationMinutes = windowDurationMinutes.map { max(0, $0) }
    }

    public var remainingPercent: Int {
        max(0, 100 - usedPercent)
    }
}

/// A reset-credit row returned by the public Codex app-server.
///
/// These values are transient account data. Cove keeps them in memory with the
/// containing usage snapshot and never writes them through its settings or
/// session-metadata persistence layers.
public struct CoveRateLimitResetCredit: Codable, Equatable, Sendable {
    public var id: String?
    public var resetType: String?
    public var status: String?
    public var grantedAt: Date?
    public var expiresAt: Date?
    public var title: String?
    public var detail: String?

    public init(
        id: String? = nil,
        resetType: String? = nil,
        status: String? = nil,
        grantedAt: Date? = nil,
        expiresAt: Date? = nil,
        title: String? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.resetType = resetType
        self.status = status
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.title = title
        self.detail = detail
    }
}

public struct CoveTokenUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    public var reasoningOutputTokens: Int
    public var totalTokens: Int
    public var contextWindow: Int?

    public init(
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        reasoningOutputTokens: Int,
        totalTokens: Int,
        contextWindow: Int?
    ) {
        self.inputTokens = max(0, inputTokens)
        self.cachedInputTokens = max(0, cachedInputTokens)
        self.outputTokens = max(0, outputTokens)
        self.reasoningOutputTokens = max(0, reasoningOutputTokens)
        self.totalTokens = max(0, totalTokens)
        self.contextWindow = contextWindow
    }
}

/// Aggregate token-usage fields returned by the public Codex app-server
/// `account/usage/read` method. Every metric is optional because the server can
/// omit fields that are not available for the signed-in account.
public struct CoveAccountTokenUsageSummary: Codable, Equatable, Sendable {
    public var lifetimeTokens: Int64?
    public var peakDailyTokens: Int64?
    public var longestRunningTurnSeconds: Int64?
    public var currentStreakDays: Int64?
    public var longestStreakDays: Int64?

    public init(
        lifetimeTokens: Int64? = nil,
        peakDailyTokens: Int64? = nil,
        longestRunningTurnSeconds: Int64? = nil,
        currentStreakDays: Int64? = nil,
        longestStreakDays: Int64? = nil
    ) {
        self.lifetimeTokens = lifetimeTokens.map { max(0, $0) }
        self.peakDailyTokens = peakDailyTokens.map { max(0, $0) }
        self.longestRunningTurnSeconds = longestRunningTurnSeconds.map {
            max(0, $0)
        }
        self.currentStreakDays = currentStreakDays.map { max(0, $0) }
        self.longestStreakDays = longestStreakDays.map { max(0, $0) }
    }

    public var hasMetrics: Bool {
        lifetimeTokens != nil
            || peakDailyTokens != nil
            || longestRunningTurnSeconds != nil
            || currentStreakDays != nil
            || longestStreakDays != nil
    }
}

/// One server-supplied daily bucket. `startDate` intentionally remains the
/// public protocol's date string rather than being interpreted in the local
/// time zone during hydration.
public struct CoveAccountTokenUsageDailyBucket: Codable, Equatable, Sendable {
    public var startDate: String
    public var tokens: Int64

    public init(startDate: String, tokens: Int64) {
        self.startDate = startDate
        self.tokens = max(0, tokens)
    }
}

/// A transient profile-usage snapshot obtained only through the public Codex
/// app-server. Cove never reads Codex UI state or private on-disk history to
/// populate these values.
public struct CoveAccountTokenUsageSnapshot: Codable, Equatable, Sendable {
    public var summary: CoveAccountTokenUsageSummary
    public var dailyUsageBuckets: [CoveAccountTokenUsageDailyBucket]?
    public var capturedAt: Date

    public init(
        summary: CoveAccountTokenUsageSummary,
        dailyUsageBuckets: [CoveAccountTokenUsageDailyBucket]? = nil,
        capturedAt: Date
    ) {
        self.summary = summary
        self.dailyUsageBuckets = dailyUsageBuckets
        self.capturedAt = capturedAt
    }

    public var hasData: Bool {
        summary.hasMetrics || !(dailyUsageBuckets?.isEmpty ?? true)
    }

    public func isStale(
        at date: Date = Date(),
        after interval: TimeInterval = 300
    ) -> Bool {
        date.timeIntervalSince(capturedAt) > interval
    }

    /// Builds the same rolling 52-week views from the server-supplied daily
    /// buckets: Sunday-aligned daily cells, weekly sums, or running weekly
    /// totals. `nil` means the response omitted daily buckets entirely.
    public func trendPoints(
        _ kind: CoveAccountTokenUsageTrendKind,
        through referenceDate: Date = Date(),
        calendar requestedCalendar: Calendar = .current
    ) -> [CoveAccountTokenUsageTrendPoint]? {
        guard let dailyUsageBuckets else { return nil }
        // The wire format is an ISO-style Gregorian date, independent of the
        // user's display-calendar preference. Preserve only the local time
        // zone used to decide which bucket is "today".
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = requestedCalendar.timeZone
        guard let today = calendar.dateInterval(
            of: .day,
            for: referenceDate
        )?.start else {
            return []
        }
        let weekday = calendar.component(.weekday, from: today)
        guard let currentWeekStart = calendar.date(
            byAdding: .day,
            value: -(weekday - 1),
            to: today
        ), let windowStart = calendar.date(
            byAdding: .weekOfYear,
            value: -51,
            to: currentWeekStart
        ), let windowEnd = calendar.date(
            byAdding: .day,
            value: 364,
            to: windowStart
        ) else {
            return []
        }

        var tokensByDate: [Date: Int64] = [:]
        for bucket in dailyUsageBuckets {
            guard let date = Self.date(
                fromProtocolDate: bucket.startDate,
                calendar: calendar
            ), date >= windowStart, date < windowEnd, date <= today else {
                continue
            }
            tokensByDate[date] = Self.saturatingAdd(
                tokensByDate[date] ?? 0,
                bucket.tokens
            )
        }

        let daily: [CoveAccountTokenUsageTrendPoint] = (0..<364).compactMap {
            offset in
            guard let date = calendar.date(
                byAdding: .day,
                value: offset,
                to: windowStart
            ) else {
                return nil
            }
            return CoveAccountTokenUsageTrendPoint(
                startDate: date,
                tokens: tokensByDate[date] ?? 0,
                isFuture: date > today
            )
        }
        guard kind != .daily else { return daily }

        var weekly: [CoveAccountTokenUsageTrendPoint] = []
        weekly.reserveCapacity(52)
        for startIndex in stride(from: 0, to: daily.count, by: 7) {
            let week = daily[startIndex..<min(startIndex + 7, daily.count)]
            let total = week.reduce(Int64(0)) {
                Self.saturatingAdd($0, $1.tokens)
            }
            weekly.append(
                CoveAccountTokenUsageTrendPoint(
                    startDate: daily[startIndex].startDate,
                    tokens: total,
                    isFuture: false
                )
            )
        }
        guard kind != .weekly else { return weekly }

        var runningTotal: Int64 = 0
        return weekly.map { point in
            runningTotal = Self.saturatingAdd(runningTotal, point.tokens)
            return CoveAccountTokenUsageTrendPoint(
                startDate: point.startDate,
                tokens: runningTotal,
                isFuture: false
            )
        }
    }

    private static func date(
        fromProtocolDate value: String,
        calendar: Calendar
    ) -> Date? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        guard let date = calendar.date(
            from: DateComponents(year: year, month: month, day: day)
        ), calendar.component(.year, from: date) == year,
           calendar.component(.month, from: date) == month,
           calendar.component(.day, from: date) == day else {
            return nil
        }
        return calendar.dateInterval(of: .day, for: date)?.start
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }
}

public enum CoveAccountTokenUsageTrendKind: String, CaseIterable, Hashable, Sendable {
    case daily
    case weekly
    case cumulative
}

public struct CoveAccountTokenUsageTrendPoint: Equatable, Sendable {
    public var startDate: Date
    public var tokens: Int64
    public var isFuture: Bool

    public init(startDate: Date, tokens: Int64, isFuture: Bool) {
        self.startDate = startDate
        self.tokens = max(0, tokens)
        self.isFuture = isFuture
    }
}

/// Whether the latest account hydration attempt supplied profile token usage.
/// `unknown` is used by rate-limit-only notifications so they do not overwrite
/// the result of the last explicit `account/usage/read` request.
public enum CoveAccountTokenUsageAvailability: String, Codable, Equatable, Sendable {
    case unknown
    case available
    case unavailable
}

public struct CoveUsageSnapshot: Codable, Equatable, Sendable {
    public var primary: CoveRateLimitWindow?
    public var secondary: CoveRateLimitWindow?
    public var resetCreditsAvailable: Int?
    public var resetCredits: [CoveRateLimitResetCredit]?
    public var creditBalance: String?
    public var tokenUsage: CoveTokenUsage?
    public var accountTokenUsage: CoveAccountTokenUsageSnapshot?
    public var accountTokenUsageAvailability: CoveAccountTokenUsageAvailability
    public var capturedAt: Date
    public var isPartial: Bool

    public init(
        primary: CoveRateLimitWindow? = nil,
        secondary: CoveRateLimitWindow? = nil,
        resetCreditsAvailable: Int? = nil,
        resetCredits: [CoveRateLimitResetCredit]? = nil,
        creditBalance: String? = nil,
        tokenUsage: CoveTokenUsage? = nil,
        accountTokenUsage: CoveAccountTokenUsageSnapshot? = nil,
        accountTokenUsageAvailability: CoveAccountTokenUsageAvailability = .unknown,
        capturedAt: Date,
        isPartial: Bool
    ) {
        self.primary = primary
        self.secondary = secondary
        self.resetCreditsAvailable = resetCreditsAvailable
        self.resetCredits = resetCredits
        self.creditBalance = creditBalance
        self.tokenUsage = tokenUsage
        self.accountTokenUsage = accountTokenUsage
        self.accountTokenUsageAvailability = accountTokenUsageAvailability
        self.capturedAt = capturedAt
        self.isPartial = isPartial
    }

    private enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case resetCreditsAvailable
        case resetCredits
        case creditBalance
        case tokenUsage
        case accountTokenUsage
        case accountTokenUsageAvailability
        case capturedAt
        case isPartial
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            primary: try values.decodeIfPresent(
                CoveRateLimitWindow.self,
                forKey: .primary
            ),
            secondary: try values.decodeIfPresent(
                CoveRateLimitWindow.self,
                forKey: .secondary
            ),
            resetCreditsAvailable: try values.decodeIfPresent(
                Int.self,
                forKey: .resetCreditsAvailable
            ),
            resetCredits: try values.decodeIfPresent(
                [CoveRateLimitResetCredit].self,
                forKey: .resetCredits
            ),
            creditBalance: try values.decodeIfPresent(
                String.self,
                forKey: .creditBalance
            ),
            tokenUsage: try values.decodeIfPresent(
                CoveTokenUsage.self,
                forKey: .tokenUsage
            ),
            accountTokenUsage: try values.decodeIfPresent(
                CoveAccountTokenUsageSnapshot.self,
                forKey: .accountTokenUsage
            ),
            accountTokenUsageAvailability: try values.decodeIfPresent(
                CoveAccountTokenUsageAvailability.self,
                forKey: .accountTokenUsageAvailability
            ) ?? .unknown,
            capturedAt: try values.decode(Date.self, forKey: .capturedAt),
            isPartial: try values.decode(Bool.self, forKey: .isPartial)
        )
    }

    public func isStale(at date: Date = Date(), after interval: TimeInterval = 300) -> Bool {
        date.timeIntervalSince(capturedAt) > interval
    }

    public func merging(_ newer: CoveUsageSnapshot) -> CoveUsageSnapshot {
        let newerContainsAccountData = newer.primary != nil
            || newer.secondary != nil
            || newer.resetCreditsAvailable != nil
            || newer.resetCredits != nil
            || newer.creditBalance != nil
        return CoveUsageSnapshot(
            primary: newer.primary ?? primary,
            secondary: newer.secondary ?? secondary,
            resetCreditsAvailable: newer.resetCreditsAvailable ?? resetCreditsAvailable,
            resetCredits: newer.resetCredits ?? resetCredits,
            creditBalance: newer.creditBalance ?? creditBalance,
            tokenUsage: newer.tokenUsage ?? tokenUsage,
            accountTokenUsage: newer.accountTokenUsage ?? accountTokenUsage,
            accountTokenUsageAvailability: newer.accountTokenUsageAvailability == .unknown
                ? accountTokenUsageAvailability
                : newer.accountTokenUsageAvailability,
            // Token-usage notifications must not make older account rate-limit
            // windows look freshly hydrated.
            capturedAt: newerContainsAccountData ? newer.capturedAt : capturedAt,
            isPartial: newerContainsAccountData
                ? newer.isPartial
                    || (newer.primary == nil && primary == nil)
                    || (newer.secondary == nil && secondary == nil)
                : isPartial
        )
    }
}
