import Foundation

enum CodexSource {
    static func fetch(resetDetails: Bool) async throws -> ProviderReading {
        let params: [String: Any] = resetDetails ? [:] : ["excludeResetCreditDetails": true]
        do {
            return parse(try await call("account/rateLimits/read", params, timeout: 15), resetDetails: resetDetails)
        } catch let error as RPCError {
            throw SourceError("Codex: \(error.message). Try \"codex login\".")
        }
    }

    static func claim(creditId: String?, idempotencyKey: String) async throws -> ResetOutcome {
        var params: [String: Any] = ["idempotencyKey": idempotencyKey]
        if let creditId { params["creditId"] = creditId }
        let result: [String: Any]
        do {
            result = try await call("account/rateLimitResetCredit/consume", params, timeout: 25)
        } catch let error as RPCError {
            throw ClaimFailure(message: "Codex couldn't use the reset: \(error.message).", settled: true)
        } catch {
            throw ClaimFailure(message: "Codex didn't confirm the reset. Trying again won't spend a second one.", settled: false)
        }
        switch result["outcome"] as? String {
        case "reset": return .reset
        case "nothingToReset": return .nothingToReset
        case "alreadyRedeemed": return .alreadyUsed
        case "noCredit": return .noCredit
        default: throw ClaimFailure(message: "Codex gave an answer Headroom doesn't recognise. Refresh to check your limits.", settled: false)
        }
    }

    private struct RPCError: Error { let message: String }

    private static func call(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try callSync(method, params, timeout: timeout) })
            }
        }
    }

    private static func callSync(_ method: String, _ params: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        guard let binary = Shell.find("codex") else {
            throw SourceError("Codex CLI not found. Install it, then run \"codex login\".")
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Shell.searchPaths.joined(separator: ":") + ":" + (env["PATH"] ?? "")
        process.environment = env
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        let messages: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["clientInfo": ["name": "headroom", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": method, "params": params],
        ]
        for message in messages {
            var line = try JSONSerialization.data(withJSONObject: message)
            line.append(0x0A)
            stdin.fileHandleForWriting.write(line)
        }

        var buffer = Data()
        while true {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty { throw SourceError("Codex didn't answer. Is the CLI up to date?") }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      (object["id"] as? NSNumber)?.intValue == 2 else { continue }
                if let error = object["error"] as? [String: Any] {
                    throw RPCError(message: error["message"] as? String ?? "unknown error")
                }
                return object["result"] as? [String: Any] ?? [:]
            }
        }
    }

    static func parse(_ result: [String: Any], resetDetails: Bool = true) -> ProviderReading {
        let limits = result["rateLimits"] as? [String: Any] ?? [:]
        let windows = ["primary", "secondary"].compactMap { key -> LimitWindow? in
            guard let window = limits[key] as? [String: Any],
                  let used = (window["usedPercent"] as? NSNumber)?.doubleValue else { return nil }
            let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue
            let resets = (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return LimitWindow(id: "codex.\(key)", label: minutes.map(windowLabel) ?? key.capitalized,
                               usedPercent: used, resetsAt: resets, duration: minutes.map { TimeInterval($0 * 60) })
        }
        return ProviderReading(windows: windows, plan: (limits["planType"] as? String)?.capitalized,
                               resets: parseResets(result["rateLimitResetCredits"]), resetDetails: resetDetails)
    }

    static func parseResets(_ value: Any?) -> [ResetOption] {
        guard let summary = value as? [String: Any],
              let count = (summary["availableCount"] as? NSNumber)?.intValue, count > 0 else { return [] }
        let available = (summary["credits"] as? [[String: Any]] ?? []).filter { $0["status"] as? String == "available" }
        let soonest = available.min { (($0["expiresAt"] as? NSNumber)?.doubleValue ?? .infinity) < (($1["expiresAt"] as? NSNumber)?.doubleValue ?? .infinity) }
        let title = (soonest?["title"] as? String).map { $0.replacingOccurrences(of: " (Monthly)", with: "") } ?? "Full reset"
        return [ResetOption(id: "codex.reset", title: title, detail: "Refills your Codex usage limits.", count: count,
                            expiresAt: (soonest?["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                            creditId: nil)]
    }
}
