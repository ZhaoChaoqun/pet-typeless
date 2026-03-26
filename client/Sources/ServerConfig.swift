import Foundation

/// Server configuration management.
///
/// Stores Relay Server URL and API token in UserDefaults.
enum ServerConfig {

    private static let serverURLKey = "serverURL"
    private static let apiTokenKey = "apiToken"

    /// Default server URL for local development
    static let defaultServerURL = URL(string: "ws://localhost:8000/ws")!

    /// Current server URL (from UserDefaults or default)
    static var serverURL: URL {
        get {
            if let urlString = UserDefaults.standard.string(forKey: serverURLKey),
               let url = URL(string: urlString) {
                return url
            }
            return defaultServerURL
        }
        set {
            UserDefaults.standard.set(newValue.absoluteString, forKey: serverURLKey)
        }
    }

    /// Current API token (from UserDefaults)
    static var apiToken: String {
        get {
            UserDefaults.standard.string(forKey: apiTokenKey) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: apiTokenKey)
        }
    }

    /// Whether the server is configured (has both URL and token)
    static var isConfigured: Bool {
        !apiToken.isEmpty
    }
}
