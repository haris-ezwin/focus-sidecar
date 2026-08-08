import Foundation

struct SupabaseConfiguration: Sendable {
    let projectURL: URL
    let publishableKey: String
    let table: String

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) throws -> SupabaseConfiguration {
        let urlString = value(
            environmentKey: "FOCUS_SUPABASE_URL",
            plistKey: "FocusSupabaseURL",
            environment: environment,
            bundle: bundle
        )
        let publishableKey = value(
            environmentKey: "FOCUS_SUPABASE_PUBLISHABLE_KEY",
            plistKey: "FocusSupabasePublishableKey",
            environment: environment,
            bundle: bundle
        )
        let table = value(
            environmentKey: "FOCUS_SUPABASE_TABLE",
            plistKey: "FocusSupabaseTable",
            environment: environment,
            bundle: bundle
        ) ?? "tasks"

        guard let urlString, let projectURL = URL(string: urlString), projectURL.scheme == "https" else {
            throw SupabaseConfigurationError.missingOrInvalid("FOCUS_SUPABASE_URL")
        }
        guard let publishableKey, !publishableKey.isEmpty else {
            throw SupabaseConfigurationError.missingOrInvalid("FOCUS_SUPABASE_PUBLISHABLE_KEY")
        }
        guard !publishableKey.hasPrefix("sb_secret_") else {
            throw SupabaseConfigurationError.secretKeyNotAllowed
        }

        return SupabaseConfiguration(
            projectURL: projectURL,
            publishableKey: publishableKey,
            table: table
        )
    }

    private static func value(
        environmentKey: String,
        plistKey: String,
        environment: [String: String],
        bundle: Bundle
    ) -> String? {
        if let value = environment[environmentKey], !value.isEmpty {
            return value
        }
        return bundle.object(forInfoDictionaryKey: plistKey) as? String
    }
}

enum SupabaseConfigurationError: LocalizedError {
    case missingOrInvalid(String)
    case secretKeyNotAllowed

    var errorDescription: String? {
        switch self {
        case .missingOrInvalid(let name):
            "Missing or invalid \(name). Copy .env.example to .env and add your Supabase settings."
        case .secretKeyNotAllowed:
            "A Supabase secret/service-role key cannot be embedded in this app. Use a publishable key."
        }
    }
}
