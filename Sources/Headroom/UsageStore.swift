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
    @Published var alertThreshold: Double {
        didSet { UserDefaults.standard.set(alertThreshold, forKey: "alertThreshold") }
    }

    var onChange: (() -> Void)?
    private var timer: Timer?
    private var alerted: Set<String> = []

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["notificationsEnabled": true, "alertThreshold": 20.0])
        notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        alertThreshold = defaults.double(forKey: "alertThreshold")
    }

    var lastUpdated: Date? { states.values.compactMap(\.updatedAt).max() }

    func start() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        }
    }

    func refreshIfStale() {
        guard let lastUpdated, Date().timeIntervalSince(lastUpdated) < 20 else {
            Task { await refresh() }
            return
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        async let claude = Result { try await ClaudeSource.fetch() }
        async let codex = Result { try await CodexSource.fetch() }
        apply(.claude, await claude)
        apply(.codex, await codex)
        refreshing = false
        onChange?()
    }

    private func apply(_ provider: Provider, _ result: Result<(windows: [LimitWindow], plan: String?), Error>) {
        var state = states[provider] ?? ProviderState()
        state.loading = false
        switch result {
        case .success(let value):
            state.windows = value.windows
            state.plan = value.plan
            state.error = nil
            state.updatedAt = Date()
            notify(provider, value.windows)
        case .failure(let error):
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
