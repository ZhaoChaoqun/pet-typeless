import Foundation
import os

private let logger = Logger(subsystem: "com.pettypeless.app", category: "ServerConnection")

/// Manages the shared WebSocket connection to the Relay Server.
///
/// RecordingManager uses this for ASR (start/end session, audio streaming).
/// Handles connection lifecycle, reconnection, and message routing.
///
/// Thread safety:
/// - `isConnected` and `reconnectAttempts` are protected by `stateLock`.
/// - WebSocket operations are dispatched on `wsQueue` (serial).
final class ServerConnection: NSObject, URLSessionWebSocketDelegate {

    // MARK: - Configuration

    private var serverURL: URL
    private var apiToken: String

    // MARK: - Connection

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let wsQueue = DispatchQueue(label: "com.pettypeless.connection", qos: .userInitiated)

    // MARK: - Thread-safe State

    private var _isConnected = false
    private var _reconnectAttempts = 0
    private let stateLock = NSLock()

    private(set) var isConnected: Bool {
        get { stateLock.withLock { _isConnected } }
        set {
            stateLock.withLock { _isConnected = newValue }
        }
    }

    private var reconnectAttempts: Int {
        get { stateLock.withLock { _reconnectAttempts } }
        set { stateLock.withLock { _reconnectAttempts = newValue } }
    }

    private static let maxReconnectAttempts = 5
    private static let reconnectBaseDelay: TimeInterval = 1.0

    // MARK: - Message Routing

    /// Callback for ASR partial results
    var onPartialResult: ((String) -> Void)?
    /// Callback for ASR final results
    var onFinalResult: ((String) -> Void)?
    /// Connection state change callback
    var onConnectionStateChanged: ((Bool) -> Void)?

    // MARK: - Init

    init(serverURL: URL, apiToken: String) {
        self.serverURL = serverURL
        self.apiToken = apiToken
        super.init()
    }

    // MARK: - Configuration Update

    func updateConfig(serverURL: URL, apiToken: String) {
        self.serverURL = serverURL
        self.apiToken = apiToken
        disconnect()
        connect()
    }

    // MARK: - Connection Management

    func connect() {
        wsQueue.async { [weak self] in
            self?._connect()
        }
    }

    private func _connect() {
        // Clean up existing connection
        webSocket?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()

        // Build URL with token
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "token", value: apiToken))
        components.queryItems = queryItems

        guard let url = components.url else {
            logger.error("Invalid server URL: \(self.serverURL.absoluteString, privacy: .public)")
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300

        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        webSocket = urlSession?.webSocketTask(with: url)
        webSocket?.resume()

        logger.info("Connecting to \(url.host() ?? "unknown", privacy: .public):\(url.port ?? 0)")
        receiveMessage()
    }

    func disconnect() {
        wsQueue.async { [weak self] in
            guard let self = self else { return }
            self.webSocket?.cancel(with: .goingAway, reason: nil)
            self.webSocket = nil
            self.urlSession?.invalidateAndCancel()
            self.urlSession = nil
            self.isConnected = false
        }
    }

    // MARK: - Sending Messages

    func sendStartSession() {
        let msg = #"{"type":"start_session"}"#
        send(text: msg)
    }

    func sendEndSession() {
        let msg = #"{"type":"end_session"}"#
        send(text: msg)
    }

    func sendAudioData(_ data: Data) {
        webSocket?.send(.data(data)) { error in
            if let error = error {
                logger.error("Failed to send audio: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func send(text: String) {
        webSocket?.send(.string(text)) { error in
            if let error = error {
                logger.error("Failed to send message: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Receiving Messages

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleTextMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleTextMessage(text)
                    }
                @unknown default:
                    break
                }
                self.receiveMessage()

            case .failure(let error):
                logger.error("WebSocket receive error: \(error.localizedDescription, privacy: .public)")
                self.handleDisconnect()
            }
        }
    }

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            logger.warning("Invalid message: \(text.prefix(100), privacy: .public)")
            return
        }

        switch type {
        case "partial":
            if let resultText = json["text"] as? String {
                onPartialResult?(resultText)
            }

        case "final":
            let resultText = json["text"] as? String ?? ""
            logger.info("Final ASR result: \(resultText.prefix(80), privacy: .public)")
            onFinalResult?(resultText)

        case "session_started":
            logger.info("ASR session started")

        case "session_ended":
            logger.info("ASR session ended")

        case "error":
            let errorMsg = json["message"] as? String ?? "Unknown error"
            logger.error("Server error: \(errorMsg, privacy: .public)")

        default:
            logger.debug("Unknown message type: \(type, privacy: .public)")
        }
    }

    // MARK: - Reconnection

    private func handleDisconnect() {
        isConnected = false

        DispatchQueue.main.async { [weak self] in
            self?.onConnectionStateChanged?(false)
        }

        let currentAttempts = reconnectAttempts
        guard currentAttempts < Self.maxReconnectAttempts else {
            logger.error("Max reconnect attempts reached (\(Self.maxReconnectAttempts))")
            return
        }

        reconnectAttempts = currentAttempts + 1
        let delay = Self.reconnectBaseDelay * pow(2.0, Double(currentAttempts))
        logger.info("Reconnecting in \(delay, privacy: .public)s (attempt \(currentAttempts + 1)/\(Self.maxReconnectAttempts))")

        wsQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?._connect()
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        logger.info("WebSocket connected")
        isConnected = true
        reconnectAttempts = 0

        DispatchQueue.main.async { [weak self] in
            self?.onConnectionStateChanged?(true)
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        logger.info("WebSocket closed: code=\(closeCode.rawValue) reason=\(reasonStr, privacy: .public)")
        handleDisconnect()
    }
}
