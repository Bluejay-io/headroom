import Foundation

enum ClaudeSource {
    static func fetch() async throws -> (windows: [LimitWindow], plan: String?) {
        let creds = try readCredentials()
        if let expiresAt = creds.expiresAt, expiresAt < Date() {
            throw SourceError("Claude Code login expired. Open Claude Code once to refresh it.")
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Headroom", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw SourceError("Claude Code login expired. Open Claude Code once to refresh it.")
        }
        if status == 429 {
            let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
            throw RateLimited(retryAfter: header.flatMap(TimeInterval.init))
        }
        guard status == 200 else { throw SourceError("Claude returned HTTP \(status).") }
        return (try parse(data), creds.plan)
    }

    static func parse(_ data: Data) throws -> [LimitWindow] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError("Unexpected Claude response.")
        }
        if let limits = json["limits"] as? [[String: Any]], !limits.isEmpty {
            return limits.enumerated().compactMap { index, limit in
                guard let percent = (limit["percent"] as? NSNumber)?.doubleValue else { return nil }
                let kind = limit["kind"] as? String ?? "limit"
                let group = limit["group"] as? String
                let model = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                let label: String
                let duration: TimeInterval?
                switch (kind, group) {
                case ("session", _): label = "5-hour"; duration = 5 * 3600
                case ("weekly_all", _): label = "Weekly"; duration = 7 * 86400
                case (_, "weekly"): label = model.map { "Weekly · \($0)" } ?? "Weekly"; duration = 7 * 86400
                default: label = kind.replacingOccurrences(of: "_", with: " ").capitalized; duration = nil
                }
                return LimitWindow(id: "claude.\(kind).\(index)", label: label, usedPercent: percent,
                                   resetsAt: parseDate(limit["resets_at"]), duration: duration)
            }
        }
        let legacy: [(String, String, TimeInterval)] = [
            ("five_hour", "5-hour", 5 * 3600), ("seven_day", "Weekly", 7 * 86400),
            ("seven_day_opus", "Weekly · Opus", 7 * 86400), ("seven_day_sonnet", "Weekly · Sonnet", 7 * 86400),
        ]
        return legacy.compactMap { key, label, duration in
            guard let window = json[key] as? [String: Any],
                  let used = (window["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return LimitWindow(id: "claude.\(key)", label: label, usedPercent: used,
                               resetsAt: parseDate(window["resets_at"]), duration: duration)
        }
    }

    private struct Credentials { let token: String; let expiresAt: Date?; let plan: String? }

    private static func readCredentials() throws -> Credentials {
        var raw = runSecurity()
        if raw == nil {
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
            raw = try? Data(contentsOf: file)
        }
        guard let raw,
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            throw SourceError("Not signed in to Claude Code. Run \"claude\" and log in.")
        }
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return Credentials(token: token, expiresAt: expiresAt, plan: (oauth["subscriptionType"] as? String)?.capitalized)
    }

    private static func runSecurity() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && !data.isEmpty ? data : nil
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
