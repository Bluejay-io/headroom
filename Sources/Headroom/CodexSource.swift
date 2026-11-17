import Foundation

enum CodexSource {
    static func fetch() async throws -> (windows: [LimitWindow], plan: String?) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try fetchSync() })
            }
        }
    }

    private static func fetchSync() throws -> (windows: [LimitWindow], plan: String?) {
        guard let binary = findCodex() else {
            throw SourceError("Codex CLI not found. Install it, then run \"codex login\".")
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPaths.joined(separator: ":") + ":" + (env["PATH"] ?? "")
        process.environment = env
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        defer { timeout.cancel() }

        let messages: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["clientInfo": ["name": "headroom", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read"],
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
                    let message = error["message"] as? String ?? "unknown error"
                    throw SourceError("Codex: \(message). Try \"codex login\".")
                }
                return parse(object["result"] as? [String: Any] ?? [:])
            }
        }
    }

    static func parse(_ result: [String: Any]) -> (windows: [LimitWindow], plan: String?) {
        let limits = result["rateLimits"] as? [String: Any] ?? [:]
        let windows = ["primary", "secondary"].compactMap { key -> LimitWindow? in
            guard let window = limits[key] as? [String: Any],
                  let used = (window["usedPercent"] as? NSNumber)?.doubleValue else { return nil }
            let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue
            let resets = (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return LimitWindow(id: "codex.\(key)", label: minutes.map(windowLabel) ?? key.capitalized,
                               usedPercent: used, resetsAt: resets, duration: minutes.map { TimeInterval($0 * 60) })
        }
        return (windows, (limits["planType"] as? String)?.capitalized)
    }

    private static var searchPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.volta/bin"]
    }

    private static func findCodex() -> URL? {
        for dir in searchPaths {
            let path = "\(dir)/codex"
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v codex"]
        let out = Pipe()
        shell.standardOutput = out
        shell.standardError = Pipe()
        guard (try? shell.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }
}
