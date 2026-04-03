import Foundation

/// Server configuration — hardcoded for production use.
///
/// The relay server is free and requires no user configuration.
enum ServerConfig {

    /// Production WebSocket URL
    static let serverURL = URL(string: "wss://pet-typeless-server.livelymushroom-a2d89977.eastasia.azurecontainerapps.io/ws")!

    /// Production API token
    static let apiToken = "Yz8FSDZ8jkwRvt4KBjq64s1xpiXOIAC0Nxt9Vy5XlBk"

    /// Always configured
    static let isConfigured = true
}
