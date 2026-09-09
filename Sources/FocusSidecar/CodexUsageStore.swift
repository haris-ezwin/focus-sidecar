import Foundation

@MainActor
final class CodexUsageStore: ObservableObject {
    @Published private(set) var history = CodexUsageHistory()
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    private let storageURL: URL

    init() {
        storageURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Focus Sidecar/codex-usage.json")
        if FileManager.default.fileExists(atPath: storageURL.path) {
            do {
                history = try JSONDecoder().decode(CodexUsageHistory.self, from: Data(contentsOf: storageURL))
            } catch {
                errorMessage = "Couldn’t read saved Codex usage. Tracking will restart with the next reading."
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let sample = try await Task.detached(priority: .utility) { try CodexUsageClient.read() }.value
            history.record(sample)
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: storageURL, options: .atomic)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
