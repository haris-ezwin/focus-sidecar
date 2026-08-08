import Foundation

actor SupabaseService {
    private let configuration: SupabaseConfiguration
    private let keychain = KeychainStore()
    private let urlSession: URLSession
    private var session: SupabaseSession?

    init(configuration: SupabaseConfiguration, urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.urlSession = urlSession
    }

    var signedInEmail: String? { session?.user.email }

    func restoreSession() throws -> String? {
        session = try keychain.load()
        return session?.user.email
    }

    @discardableResult
    func signIn(email: String, password: String) async throws -> String? {
        var components = URLComponents(
            url: configuration.projectURL.appendingPathComponent("auth/v1/token"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "password")]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": password
        ])

        let newSession: SupabaseSession = try await perform(request)
        try keychain.save(newSession)
        session = newSession
        return newSession.user.email
    }

    func signOut() throws {
        session = nil
        try keychain.delete()
    }

    func tasks(for date: Date, calendar: Calendar = .current) async throws -> [FocusTask] {
        let accessToken = try await validAccessToken()
        let dateString = Self.dateString(for: date, calendar: calendar)
        var components = URLComponents(
            url: configuration.projectURL.appendingPathComponent("rest/v1/\(configuration.table)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "select", value: "id,title,priority,status,due_date,start_time,end_time"),
            URLQueryItem(name: "due_date", value: "eq.\(dateString)"),
            URLQueryItem(name: "type", value: "eq.Task"),
            URLQueryItem(name: "order", value: "start_time.asc.nullslast,created_at.asc")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await perform(request)
    }

    func setCompleted(_ completed: Bool, taskID: UUID) async throws {
        let accessToken = try await validAccessToken()
        var components = URLComponents(
            url: configuration.projectURL.appendingPathComponent("rest/v1/\(configuration.table)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(taskID.uuidString.lowercased())"),
            URLQueryItem(name: "select", value: "id,status")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "status": completed ? "Done" : "Todo"
        ])

        let updatedRows: [TaskStatusUpdate] = try await perform(request)
        guard updatedRows.count == 1,
              updatedRows[0].id == taskID,
              updatedRows[0].status == (completed ? "Done" : "Todo") else {
            throw FocusSidecarError.server("The task was not updated. Refresh and try again.")
        }
    }

    func deleteTask(taskID: UUID) async throws {
        let accessToken = try await validAccessToken()
        var components = URLComponents(
            url: configuration.projectURL.appendingPathComponent("rest/v1/\(configuration.table)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(taskID.uuidString.lowercased())"),
            URLQueryItem(name: "select", value: "id")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "DELETE"
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")

        let deletedRows: [TaskIdentifier] = try await perform(request)
        guard deletedRows.count == 1, deletedRows[0].id == taskID else {
            throw FocusSidecarError.server("The task was not deleted. Refresh and try again.")
        }
    }

    private func validAccessToken() async throws -> String {
        guard var session else { throw FocusSidecarError.authenticationRequired }
        if session.needsRefresh {
            session = try await refresh(session.refreshToken)
            try keychain.save(session)
            self.session = session
        }
        return session.accessToken
    }

    private func refresh(_ refreshToken: String) async throws -> SupabaseSession {
        var components = URLComponents(
            url: configuration.projectURL.appendingPathComponent("auth/v1/token"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        return try await perform(request)
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response, data: data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw FocusSidecarError.invalidResponse
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw FocusSidecarError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let payload = try? JSONDecoder().decode(SupabaseErrorPayload.self, from: data)
            throw FocusSidecarError.server(payload?.bestMessage ?? "Request failed (\(http.statusCode)).")
        }
    }

    static func dateString(for date: Date, calendar: Calendar) -> String {
        var calendar = calendar
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }
}

private struct TaskStatusUpdate: Decodable {
    let id: UUID
    let status: String
}

private struct TaskIdentifier: Decodable {
    let id: UUID
}
