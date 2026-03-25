import Foundation
import os

private let logger = Logger(subsystem: "com.pettypeless.app", category: "CloudASREngine")

/// Cloud ASR engine that connects to the Relay Server via WebSocket.
///
/// Implements the `ASREngine` protocol — the same interface used by local engines
/// in Nano Typeless — so RecordingManager works without modification.
///
/// Communication protocol:
/// - Audio: binary frames, PCM 16kHz mono Float32 samples
/// - Control: JSON text frames
///   - Send: `{"type":"start_session"}`, `{"type":"end_session"}`
///   - Receive: `{"type":"partial","text":"..."}`, `{"type":"final","text":"..."}`
class CloudASREngine: NSObject, ASREngine, URLSessionWebSocketDelegate {

    // MARK: - ASREngine conformance

    let needsPunctuation = false  // Server-side Azure ASR provides punctuation
    let needsITN = false          // Server-side handles ITN

    // MARK: - Connection

    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private let serverURL: URL
    private let apiToken: String

    /// Serial queue for all WebSocket operations
    private let wsQueue = DispatchQueue(label: "com.pettypeless.ws", qos: .userInitiated)

    /// Current partial result callback (set during processAudio, used by message receiver)
    private var onPartialResult: ((String, String?) -> Void)?

    /// Flush completion handler — set by flush(), called when "final" message arrives
    private var flushCompletion: ((String) -> Void)?

    /// Whether a recording session is active
    private var isSessionActive = false

    /// Auto-reconnect state
    private var reconnectAttempts = 0
    private static let maxReconnectAttempts = 5
    private static let reconnectBaseDelay: TimeInterval = 1.0

    /// Connection state change callback
    var onConnectionStateChanged: ((Bool) -> Void)?

    // MARK: - Init

    init(serverURL: URL, apiToken: String) {
        self.serverURL = serverURL
        self.apiToken = apiToken
        super.init()
    }

    // MARK: - Connection Management

    func connect() {
        wsQueue.async { [weak self] in
            self?._connect()
        }
    }

    private func _connect() {
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

        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        webSocket = session?.webSocketTask(with: url)
        webSocket?.resume()

        logger.info("Connecting to server: \(url.host() ?? "unknown", privacy: .public)")
        receiveMessage()
    }

    func disconnect() {
        wsQueue.async { [weak self] in
            self?.webSocket?.cancel(with: .goingAway, reason: nil)
            self?.webSocket = nil
            self?.session?.invalidateAndCancel()
            self?.session = nil
            self?.isSessionActive = false
            logger.info("Disconnected from server")
        }
    }

    // MARK: - ASREngine Protocol

    func processAudio(samples: [Float], onPartialResult: @escaping (String, String?) -> Void) {
        self.onPartialResult = onPartialResult

        wsQueue.async { [weak self] in
            guard let self = self, let ws = self.webSocket else { return }

            // Start session if not active
            if !self.isSessionActive {
                self.isSessionActive = true
                let startMsg = #"{"type":"start_session"}"#
                ws.send(.string(startMsg)) { error in
                    if let error = error {
                        logger.error("Failed to send start_session: \(error.localizedDescription, privacy: .public)")
                    } else {
                        logger.info("Session started")
                    }
                }
            }

            // Convert Float32 samples to raw bytes and send as binary frame
            let data = samples.withUnsafeBufferPointer { buffer in
                Data(buffer: buffer)
            }

            ws.send(.data(data)) { error in
                if let error = error {
                    logger.error("Failed to send audio: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func flush(completion: @escaping (String) -> Void) {
        wsQueue.async { [weak self] in
            guard let self = self, let ws = self.webSocket else {
                DispatchQueue.main.async { completion("") }
                return
            }

            self.flushCompletion = completion
            self.isSessionActive = false

            let endMsg = #"{"type":"end_session"}"#
            ws.send(.string(endMsg)) { error in
                if let error = error {
                    logger.error("Failed to send end_session: \(error.localizedDescription, privacy: .public)")
                    let cb = self.flushCompletion
                    self.flushCompletion = nil
                    DispatchQueue.main.async { cb?("") }
                }
            }

            // Timeout: if no "final" response within 8 seconds, return empty
            DispatchQueue.global().asyncAfter(deadline: .now() + 8.0) { [weak self] in
                guard let self = self else { return }
                if let cb = self.flushCompletion {
                    logger.warning("Flush timeout — no final response from server")
                    self.flushCompletion = nil
                    DispatchQueue.main.async { cb("") }
                }
            }
        }
    }

    func reset() {
        wsQueue.async { [weak self] in
            self?.isSessionActive = false
            self?.flushCompletion = nil
            self?.onPartialResult = nil
        }
    }

    // MARK: - WebSocket Message Handling

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
                // Continue receiving
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
            logger.warning("Invalid message from server: \(text.prefix(100), privacy: .public)")
            return
        }

        switch type {
        case "partial":
            if let resultText = json["text"] as? String {
                let callback = onPartialResult
                DispatchQueue.main.async {
                    callback?(resultText, nil)
                }
            }

        case "final":
            let resultText = json["text"] as? String ?? ""
            logger.info("Final result: \(resultText.prefix(80), privacy: .public)")
            if let cb = flushCompletion {
                flushCompletion = nil
                DispatchQueue.main.async {
                    cb(resultText)
                }
            }

        case "error":
            let errorMsg = json["message"] as? String ?? "Unknown error"
            logger.error("Server error: \(errorMsg, privacy: .public)")

        default:
            logger.debug("Unknown message type: \(type, privacy: .public)")
        }
    }

    // MARK: - Reconnection

    private func handleDisconnect() {
        isSessionActive = false

        DispatchQueue.main.async { [weak self] in
            self?.onConnectionStateChanged?(false)
        }

        // Return empty result if we were flushing
        if let cb = flushCompletion {
            flushCompletion = nil
            DispatchQueue.main.async { cb("") }
        }

        // Auto-reconnect with exponential backoff
        guard reconnectAttempts < Self.maxReconnectAttempts else {
            logger.error("Max reconnect attempts reached (\(Self.maxReconnectAttempts))")
            return
        }

        reconnectAttempts += 1
        let delay = Self.reconnectBaseDelay * pow(2.0, Double(reconnectAttempts - 1))
        logger.info("Reconnecting in \(delay, privacy: .public)s (attempt \(self.reconnectAttempts)/\(Self.maxReconnectAttempts))")

        wsQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?._connect()
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        logger.info("WebSocket connected")
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
