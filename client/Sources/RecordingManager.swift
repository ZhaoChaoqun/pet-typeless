import Foundation
import os

private let logger = Logger(subsystem: "com.pettypeless.app", category: "RecordingManager")

/// Thin coordinator that owns the FSM and delegates to focused subsystems:
/// - `AudioEngineManager` — microphone capture
/// - `ServerConnection` — WebSocket connection to Relay Server
///
/// Thread safety:
/// - All state transitions happen on `stateQueue` (serial).
/// - Audio processing runs on a Core Audio thread (via AudioEngineManager tap callback).
/// - UI callbacks are dispatched to the main queue.
class RecordingManager {
    static let shared = RecordingManager()

    private let audioEngineManager = AudioEngineManager()
    private var serverConnection: ServerConnection

    /// 所有状态变更必须且只能通过此队列
    private let stateQueue = DispatchQueue(label: "com.pettypless.state")
    private var state: RecordingState = .idle

    /// Flushing timeout — auto-recover if server never sends "final"
    private var flushTimeoutWorkItem: DispatchWorkItem?
    private static let flushTimeoutSeconds: TimeInterval = 8.0

    // MARK: - 公开回调

    var onPartialResult: ((String, String?) -> Void)?
    var onAudioLevel: ((Float) -> Void)? {
        didSet { audioEngineManager.onAudioLevel = onAudioLevel }
    }
    var onFinalResult: ((String?) -> Void)?
    var onRecordingStarted: (() -> Void)?
    var onProcessingStarted: (() -> Void)?
    var onConnectionStateChanged: ((Bool) -> Void)?

    init() {
        let url = ServerConfig.serverURL
        let token = ServerConfig.apiToken

        serverConnection = ServerConnection(serverURL: url, apiToken: token)

        setupServerCallbacks()

        // Skip auto-connect in test environment
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            logger.info("检测到单元测试环境，跳过自动连接")
            return
        }

        handleEvent(.reloadRequested)
    }

    // MARK: - Server Connection Setup

    private func setupServerCallbacks() {
        serverConnection.onPartialResult = { [weak self] text in
            self?.handleEvent(.partialResult(text: text, unfixedText: nil))
        }

        serverConnection.onFinalResult = { [weak self] text in
            self?.cancelFlushTimeout()
            self?.handleEvent(.flushComplete(rawText: text))
        }

        serverConnection.onConnectionStateChanged = { [weak self] connected in
            self?.onConnectionStateChanged?(connected)
            if connected {
                self?.handleEvent(.modelLoaded)
            }
        }
    }

    /// Reconnect with updated server configuration
    func reconnect() {
        let url = ServerConfig.serverURL
        let token = ServerConfig.apiToken
        serverConnection.updateConfig(serverURL: url, apiToken: token)
    }

    // MARK: - 公开事件入口

    func handleEvent(_ event: RecordingEvent) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            let oldState = self.state

            guard let newState = RecordingState.nextState(from: oldState, event: event) else {
                switch event {
                case .fnKeyDown, .fnKeyUp:
                    logger.debug("事件 \(event, privacy: .public) 在状态 \(oldState, privacy: .public) 下被忽略")
                default:
                    break
                }
                return
            }

            self.state = newState
            if oldState.description != newState.description {
                logger.debug("状态转换: \(oldState, privacy: .public) → \(newState, privacy: .public) [事件: \(event, privacy: .public)]")
            }
            self.handleSideEffects(from: oldState, to: newState, event: event)
        }
    }

    var isInitialized: Bool {
        serverConnection.isConnected
    }

    func reloadModel() {
        handleEvent(.reloadRequested)
    }

    // MARK: - Flushing Timeout

    private func startFlushTimeout() {
        cancelFlushTimeout()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            logger.warning("Flush timeout (\(Self.flushTimeoutSeconds)s) — auto-recovering")
            // Fire flushComplete with empty text to recover the FSM
            self.handleEvent(.flushComplete(rawText: ""))
        }
        flushTimeoutWorkItem = workItem
        stateQueue.asyncAfter(deadline: .now() + Self.flushTimeoutSeconds, execute: workItem)
    }

    private func cancelFlushTimeout() {
        flushTimeoutWorkItem?.cancel()
        flushTimeoutWorkItem = nil
    }

    // MARK: - 副作用处理

    private func handleSideEffects(from oldState: RecordingState, to newState: RecordingState, event: RecordingEvent) {
        switch (oldState, newState) {

        case (_, .initializing):
            serverConnection.connect()

        case (.ready, .recording):
            DispatchQueue.main.async { self.onRecordingStarted?() }
            startRecording()

        case (.recording, .recording):
            if case .partialResult(let text, let unfixedText) = event {
                DispatchQueue.main.async { self.onPartialResult?(text, unfixedText) }
            }

        case (.recording, .flushing):
            DispatchQueue.main.async { self.onProcessingStarted?() }
            audioEngineManager.stop()
            serverConnection.sendEndSession()
            startFlushTimeout()

        case (.flushing, .ready):
            cancelFlushTimeout()
            if case .flushComplete(let rawText) = event {
                let finalText: String? = rawText.isEmpty ? nil : rawText
                if let text = finalText {
                    logger.info("最终结果: \(text, privacy: .public)")
                } else {
                    logger.info("最终识别结果: （无）")
                }
                DispatchQueue.main.async { self.onFinalResult?(finalText) }
            }

        default:
            break
        }
    }

    // MARK: - Recording Lifecycle

    private func startRecording() {
        audioEngineManager.onSamples = { [weak self] samples in
            self?.processAudioSamples(samples)
        }
        audioEngineManager.start()

        serverConnection.sendStartSession()

        logger.info("开始云端录音")
    }

    private func processAudioSamples(_ samples: [Float]) {
        guard stateQueue.sync(execute: { state.isRecording }) else { return }

        // Convert Float32 samples to raw bytes and send to server
        let data = samples.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        serverConnection.sendAudioData(data)
    }

    // MARK: - Test Support

    #if DEBUG
    static func testable(withConnection connection: ServerConnection) -> RecordingManager {
        let manager = RecordingManager()
        manager.stateQueue.sync { manager.state = .ready }
        return manager
    }

    var testableState: RecordingState {
        get { stateQueue.sync { state } }
        set { stateQueue.sync { state = newValue } }
    }
    #endif
}
