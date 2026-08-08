import Foundation

struct CountdownEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var eventAt: Date

    var daysUntil: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let eventDay = calendar.startOfDay(for: eventAt)
        return calendar.dateComponents([.day], from: today, to: eventDay).day ?? 0
    }

    var countdownLabel: String {
        switch daysUntil {
        case let days where days < 0:
            "Passed"
        case 0:
            "Today"
        case 1:
            "1 day"
        default:
            "\(daysUntil) days"
        }
    }

    var dateTimeLabel: String {
        eventAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

struct FocusTask: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let priority: String?
    let status: String
    let dueDate: String?
    let startTime: String?
    let endTime: String?

    enum CodingKeys: String, CodingKey {
        case id, title, priority, status
        case dueDate = "due_date"
        case startTime = "start_time"
        case endTime = "end_time"
    }

    var isDone: Bool { status == "Done" }

    var timeLabel: String? {
        guard let startTime, !startTime.isEmpty else { return nil }
        let start = Self.displayTime(startTime)
        guard let endTime, !endTime.isEmpty else { return start }
        return "\(start)–\(Self.displayTime(endTime))"
    }

    private static func displayTime(_ raw: String) -> String {
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.dateFormat = raw.split(separator: ".").first?.count == 5 ? "HH:mm" : "HH:mm:ss"

        guard let date = input.date(from: String(raw.split(separator: ".").first ?? "")) else {
            return String(raw.prefix(5))
        }

        let output = DateFormatter()
        output.locale = .current
        output.dateFormat = "h:mm a"
        return output.string(from: date).lowercased()
    }
}

struct SupabaseSession: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let expiresAt: Int?
    let user: SupabaseUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
        case user
    }

    var needsRefresh: Bool {
        guard let expiresAt else { return false }
        return Date().timeIntervalSince1970 >= Double(expiresAt - 60)
    }
}

struct SupabaseUser: Codable, Sendable {
    let id: UUID
    let email: String?
}

struct SupabaseErrorPayload: Codable {
    let message: String?
    let errorDescription: String?
    let msg: String?

    enum CodingKeys: String, CodingKey {
        case message, msg
        case errorDescription = "error_description"
    }

    var bestMessage: String { message ?? errorDescription ?? msg ?? "The request failed." }
}

enum FocusSidecarError: LocalizedError {
    case authenticationRequired
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            "Sign in to load your tasks."
        case .invalidResponse:
            "The server returned an unreadable response."
        case .server(let message):
            message
        }
    }
}
