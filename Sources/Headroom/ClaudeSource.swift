import Foundation

enum ClaudeSource {
    static let cliVersion: String? = {
        guard let binary = Shell.find("claude"),
              let text = Shell.output(binary, ["--version"]),
              let version = text.split(separator: " ").first.map(String.init),
              version.range(of: "^[0-9]+(\\.[0-9]+)*$", options: .regularExpression) != nil else { return nil }
        return version
    }()

    static func fetch() async throws -> ProviderReading {
        let creds = try readCredentials()
        if let expiresAt = creds.expiresAt, expiresAt < Date() {
            throw SourceError("Claude Code login expired. Open Claude Code once to refresh it.")
        }
        var components = URLComponents(string: "https://api.anthropic.com/api/oauth/usage")!
        if cliVersion != nil {
            components.queryItems = [URLQueryItem(name: "cedar_ember", value: "1"), URLQueryItem(name: "skip_spend", value: "1")]
        }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        sign(&request, token: creds.token)
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
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ProviderReading(windows: try parse(data), plan: creds.plan, resets: parseResets(json?["cedar_ember"]))
    }

    static func claim(grantId: String, requestId: String) async throws -> ResetOutcome {
        let creds = try readCredentials()
        guard let version = cliVersion else {
            throw ClaimFailure(message: "Headroom couldn't find Claude Code, which it needs to spend a reset.", settled: true)
        }
        guard let organization = organizationId() else {
            throw ClaimFailure(message: "Couldn't find your Claude organisation. Open Claude Code once, then try again.", settled: true)
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/organizations/\(organization)/reset_rate_limits")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        sign(&request, token: creds.token, version: version)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["program": "cedar_ember", "grant_id": grantId, "request_id": requestId])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 {
            throw ClaimFailure(message: "Claude is rate limiting resets. No reset was spent. Try again soon.", settled: true)
        }
        if status == 401 || status == 403 {
            throw ClaimFailure(message: "Claude Code's login expired. Open Claude Code once, then try again.", settled: true)
        }
        guard status == 200,
              let result = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? String else {
            throw ClaimFailure(message: "Claude didn't confirm the reset (HTTP \(status)). Trying again won't spend a second one.", settled: false)
        }
        switch result {
        case "reset": return .reset
        case "not_limited": return .nothingToReset
        case "already_used": return .alreadyUsed
        case "ineligible": return .noCredit
        case "cooldown": throw ClaimFailure(message: "Claude resets are cooling down. No reset was spent. Try again later.", settled: true)
        default: throw ClaimFailure(message: "Claude couldn't confirm the reset. If you're still limited in a minute, try again. It won't spend a second one.", settled: false)
        }
    }

    private static func sign(_ request: inout URLRequest, token: String, version: String? = cliVersion) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(version.map { "claude-cli/\($0) (external, cli)" } ?? "Headroom", forHTTPHeaderField: "User-Agent")
    }

    private enum ResetKind: String, CaseIterable {
        case full, session, weekly, fable

        var title: String {
            switch self {
            case .full: return "Full reset"
            case .session: return "5-hour reset"
            case .weekly: return "Weekly reset"
            case .fable: return "Fable reset"
            }
        }

        var detail: String {
            switch self {
            case .full: return "Refills your 5-hour and weekly limits."
            case .session: return "Refills your 5-hour limit."
            case .weekly: return "Refills your weekly limit."
            case .fable: return "Refills your Fable allowance and gives back what Fable used on your weekly limit. It doesn't reset your whole week."
            }
        }

        init(grant: [String: Any]) {
            if grant["gives_back_weekly"] as? Bool == true { self = .fable; return }
            if let type = grant["type"] as? String, let kind = ResetKind(rawValue: type), kind != .fable { self = kind; return }
            let clears = grant["clears"] as? [String] ?? []
            let session = clears.contains("five_hour"), other = clears.contains { $0 != "five_hour" }
            self = session && !other ? .session : other && !session ? .weekly : .full
        }
    }

    static func parseResets(_ value: Any?, now: Date = Date()) -> [ResetOption] {
        guard let block = value as? [String: Any], block["eligible"] as? Bool == true,
              let grants = block["grants"] as? [[String: Any]] else { return [] }
        let live = grants.compactMap { grant -> (id: String, left: Int, ends: Date?, kind: ResetKind)? in
            guard let id = grant["id"] as? String, id.range(of: "^[a-z0-9_-]{1,40}$", options: .regularExpression) != nil,
                  let left = (grant["resets_left"] as? NSNumber)?.intValue, left > 0,
                  grant["paused"] as? Bool != true, grant["usable_now"] as? Bool == true else { return nil }
            let ends = parseDate(grant["ends_at"])
            if let ends, ends.timeIntervalSince(now) <= 0 { return nil }
            return (id, left, ends, ResetKind(grant: grant))
        }
        return ResetKind.allCases.compactMap { kind in
            let group = live.filter { $0.kind == kind }.sorted { ($0.ends ?? .distantFuture).timeIntervalSince1970 < ($1.ends ?? .distantFuture).timeIntervalSince1970 }
            guard let first = group.first else { return nil }
            return ResetOption(id: "claude.\(kind.rawValue)", title: kind.title, detail: kind.detail,
                               count: group.reduce(0) { $0 + $1.left }, expiresAt: first.ends, creditId: first.id)
        }
    }

    private static func organizationId() -> String? {
        let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        let home = FileManager.default.homeDirectoryForCurrentUser
        let file = env.map { URL(fileURLWithPath: $0).appendingPathComponent(".claude.json") } ?? home.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = (json["oauthAccount"] as? [String: Any])?["organizationUuid"] as? String,
              !id.isEmpty, id.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        return id
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
