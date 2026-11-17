import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var states: [Provider: ProviderState] = [.claude: ProviderState(), .codex: ProviderState()]
    @Published private(set) var refreshing = false
    @Published var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    @Published private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    @Published var alertThreshold: Double {
        didSet { UserDefaults.standard.set(alertThreshold, forKey: "alertThreshold") }
    }

    var onChange: (() -> Void)?
    private var timer: Timer?
    private var alerted: Set<String> = []
    private var nextFetch: [Provider: Date] = [:]
    private var lastAttempt: [Provider: Date] = [:]
    private var backoff: [Provider: TimeInterval] = [:]
    private static let interval: [Provider: TimeInterval] = [.claude: 180, .codex: 60]

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["notificationsEnabled": true, "alertThreshold": 20.0])
        notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        alertThreshold = defaults.double(forKey: "alertThreshold")
    }

    var lastUpdated: Date? { states.values.compactMap(\.updatedAt).max() }

    func start() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        Task { await refreshNotificationStatus() }
    }

    func refreshIfStale() {
        Task { await refresh() }
    }

    func refresh(force: Bool = false) async {
        guard !refreshing else { return }
        let now = Date()
        let due = Provider.allCases.filter { provider in
            guard let next = nextFetch[provider], now < next else { return true }
            guard force, backoff[provider] == nil else { return false }
            guard let last = lastAttempt[provider] else { return true }
            return now.timeIntervalSince(last) >= 30
        }
        guard !due.isEmpty else { return }
        refreshing = true
        for provider in due { lastAttempt[provider] = now }
        async let claude = due.contains(.claude) ? Result { try await ClaudeSource.fetch() } : nil
        async let codex = due.contains(.codex) ? Result { try await CodexSource.fetch() } : nil
        if let result = await claude { apply(.claude, result) }
        if let result = await codex { apply(.codex, result) }
        refreshing = false
        onChange?()
    }

    private func apply(_ provider: Provider, _ result: Result<(windows: [LimitWindow], plan: String?), Error>) {
        var state = states[provider] ?? ProviderState()
        state.loading = false
        let interval = Self.interval[provider] ?? 60
        nextFetch[provider] = Date().addingTimeInterval(interval)
        switch result {
        case .failure(let limited as RateLimited):
            let wait = max(limited.retryAfter ?? 0, min((backoff[provider] ?? interval) * 2, 1800))
            backoff[provider] = wait
            nextFetch[provider] = Date().addingTimeInterval(wait)
            state.signedIn = true
            if state.windows.isEmpty {
                state.error = "Signed in. \(provider.name) is busy, so your numbers will show \(Format.reset(Date().addingTimeInterval(wait)))."
            }
        case .success(let value):
            backoff[provider] = nil
            state.signedIn = true
            state.windows = value.windows
            state.plan = value.plan
            state.error = nil
            state.updatedAt = Date()
            notify(provider, value.windows)
        case .failure(let error):
            state.signedIn = false
            state.error = error.localizedDescription
        }
        states[provider] = state
    }

    private func notify(_ provider: Provider, _ windows: [LimitWindow]) {
        for window in windows {
            let key = window.id
            if window.leftPercent < alertThreshold {
                guard !alerted.contains(key) else { continue }
                alerted.insert(key)
                post(title: "\(provider.name) \(window.label) limit is low",
                     body: "\(Int(window.leftPercent))% left. Resets \(Format.reset(window.resetsAt)).")
            } else if alerted.contains(key), window.leftPercent >= 95 {
                alerted.remove(key)
                post(title: "\(provider.name) \(window.label) has reset", body: "You're back to \(Int(window.leftPercent))%.")
            }
        }
    }

    private func post(title: String, body: String) {
        guard notificationsEnabled, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func refreshNotificationStatus() async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestNotifications() async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
        await refreshNotificationStatus()
    }

    func isConnected(_ provider: Provider) -> Bool {
        states[provider]?.signedIn ?? false
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Headroom: launch at login failed: \(error.localizedDescription)")
            }
            objectWillChange.send()
        }
    }
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

enum Format {
    static func reset(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "soon" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "now" }
        if seconds < 86400 {
            let hours = Int(seconds) / 3600, minutes = (Int(seconds) % 3600) / 60
            return hours > 0 ? "in \(hours)h \(minutes)m" : "in \(max(1, minutes))m"
        }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(seconds < 7 * 86400 ? "EEE HH:mm" : "d MMM HH:mm")
        return formatter.string(from: date)
    }

    static func exact(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Not updated yet" }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 10 { return "Updated just now" }
        if seconds < 60 { return "Updated \(seconds)s ago" }
        return "Updated \(seconds / 60)m ago"
    }
}
