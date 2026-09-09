import CryptoKit
import Darwin
import Foundation

enum CodexUsageError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): message }
    }
}

/// Reads quota metadata only. Does not start a Codex thread or a model turn.
enum CodexUsageClient {
    static func read() throws -> CodexUsageSample {
        let candidates = [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path
        ]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CodexUsageError.unavailable("Install the Codex CLI and sign in to track usage.")
        }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            // A wedged server must not accumulate background children on subsequent refreshes.
            let child = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(child, SIGKILL) }
            }
            try? output.fileHandleForReading.close()
        }

        func send(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value)
            data.append(0x0a)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 0, "method": "initialize", "params": [
            "clientInfo": ["name": "focus_sidecar", "title": "Focus Sidecar", "version": "0.3.0"]
        ]])
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        var buffer = Data()
        var accountKey: String?
        while ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 250)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            guard ready > 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            guard count > 0 else { break }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count < 2_000_000 else { break }
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = message["id"] as? Int else { continue }
                if message["error"] != nil {
                    throw CodexUsageError.unavailable("Codex usage is unavailable. Check your Codex sign-in and retry.")
                }
                let result = message["result"] as? [String: Any] ?? [:]
                switch id {
                case 0:
                    try send(["method": "initialized", "params": [:] as [String: String]])
                    try send(["id": 1, "method": "account/read", "params": ["refreshToken": false]])
                case 1:
                    guard let account = result["account"] as? [String: Any],
                          let email = account["email"] as? String, !email.isEmpty else {
                        throw CodexUsageError.unavailable("Sign in to the Codex CLI with your ChatGPT account.")
                    }
                    let identity = email + ":" + (account["chatgptAccountId"] as? String ?? "")
                    accountKey = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
                    try send(["id": 2, "method": "account/rateLimits/read"])
                case 2:
                    guard let accountKey else { continue }
                    return try sample(from: result, accountKey: accountKey, date: Date())
                default: continue
                }
            }
        }
        throw CodexUsageError.unavailable("Couldn’t refresh Codex usage. Open Codex and try again.")
    }

    static func sample(from result: [String: Any], accountKey: String, date: Date) throws -> CodexUsageSample {
        let buckets = result["rateLimitsByLimitId"] as? [String: [String: Any]]
        let legacy = result["rateLimits"] as? [String: Any]
        let bucket = buckets?["codex"] ?? ((legacy?["limitId"] as? String == "codex" || legacy?["limitId"] == nil) ? legacy : nil)
        let windows = [bucket?["primary"], bucket?["secondary"]].compactMap { $0 as? [String: Any] }
        guard let weekly = windows.first(where: { ($0["windowDurationMins"] as? Int) == 10_080 }),
              let used = (weekly["usedPercent"] as? NSNumber)?.doubleValue, used.isFinite, (0...100).contains(used),
              let reset = (weekly["resetsAt"] as? NSNumber)?.doubleValue, reset.isFinite else {
            throw CodexUsageError.unavailable("No weekly Codex allowance is available for this account.")
        }
        return CodexUsageSample(accountKey: accountKey, date: date, usedPercent: used, resetsAt: reset)
    }
}
