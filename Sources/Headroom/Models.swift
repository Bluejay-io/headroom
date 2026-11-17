import Foundation

struct LimitWindow: Identifiable, Equatable, Codable {
    let id: String
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
    let duration: TimeInterval?

    var leftPercent: Double { max(0, min(100, 100 - usedPercent)) }

    func paceLeftPercent(now: Date = Date()) -> Double? {
        guard let resetsAt, let duration, duration > 0 else { return nil }
        let remaining = max(0, min(duration, resetsAt.timeIntervalSince(now)))
        return 100 * remaining / duration
    }

    func status(now: Date = Date()) -> LimitStatus {
        if leftPercent < 15 { return .low }
        if let pace = paceLeftPercent(now: now), leftPercent < pace - 2 { return .behind }
        return .fine
    }
}

enum LimitStatus { case fine, behind, low }

enum Provider: String, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var name: String { self == .claude ? "Claude" : "Codex" }
}

struct ProviderState {
    var windows: [LimitWindow] = []
    var plan: String?
    var error: String?
    var signedIn = false
    var retryAt: Date?
    var updatedAt: Date?
    var loading = true
    var resets: [ResetOption] = []
    var claiming: String?
    var resetNote: ResetNote?

    var resetCount: Int { resets.reduce(0) { $0 + $1.count } }

    var barWindows: [LimitWindow] {
        Array(windows.sorted { ($0.duration ?? .infinity) < ($1.duration ?? .infinity) }.prefix(2))
    }
}

struct SourceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct RateLimited: Error {
    let retryAfter: TimeInterval?
}

func windowLabel(minutes: Int) -> String {
    switch minutes {
    case 300: return "5-hour"
    case 10080: return "Weekly"
    case 40320...44640: return "Monthly"
    case let m where m % 1440 == 0: return "\(m / 1440)-day"
    case let m where m % 60 == 0: return "\(m / 60)-hour"
    default: return "\(minutes)-minute"
    }
}

struct ProviderReading {
    var windows: [LimitWindow]
    var plan: String?
    var resets: [ResetOption]
    var resetDetails = true
}

struct ResetOption: Identifiable, Equatable, Codable {
    let id: String
    var title: String
    let detail: String
    let count: Int
    var expiresAt: Date?
    let creditId: String?
}

enum ResetOutcome {
    case reset, nothingToReset, alreadyUsed, noCredit
}

struct ClaimFailure: LocalizedError {
    let message: String
    let settled: Bool
    var errorDescription: String? { message }
}

struct ResetNote: Equatable {
    let text: String
    let good: Bool
    let at: Date
}
