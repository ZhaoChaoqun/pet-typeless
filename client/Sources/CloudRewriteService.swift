import Foundation
import os

private let cloudRewriteLogger = Logger(subsystem: "com.pettypeless.app", category: "CloudRewriteService")

/// Cloud rewrite service that sends text to the Relay Server for LLM-based rewriting.
///
/// Instead of calling Azure OpenAI directly, this sends a WebSocket message
/// `{"type":"rewrite","text":"..."}` and waits for `{"type":"rewrite_result","text":"..."}`.
///
/// Shares the same WebSocket connection as CloudASREngine.
final class CloudRewriteService {

    /// Wall-clock timeout for the entire rewrite operation.
    private static let rewriteTimeout: Duration = .seconds(5)

    /// Reference to the WebSocket task (shared with CloudASREngine via ServerConnection)
    private weak var connection: ServerConnection?

    init(connection: ServerConnection) {
        self.connection = connection
    }

    /// Rewrite the text via Server, or return original on timeout/error.
    func rewriteOrPassthrough(_ text: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        guard let connection = connection else {
            cloudRewriteLogger.debug("Cloud rewrite skipped: no server connection")
            return text
        }

        do {
            let result = try await withThrowingTaskGroup(of: String.self) { group in
                // Race 1: the actual rewrite request
                group.addTask {
                    try await connection.sendRewriteRequest(text: text)
                }

                // Race 2: timeout deadline
                group.addTask {
                    try await Task.sleep(for: Self.rewriteTimeout)
                    throw RewriteTimeoutError()
                }

                guard let result = try await group.next() else {
                    return text
                }
                group.cancelAll()
                return result
            }

            cloudRewriteLogger.info("Cloud rewrite: \(text.prefix(80), privacy: .public) → \(result.prefix(80), privacy: .public)")
            return result
        } catch is RewriteTimeoutError {
            cloudRewriteLogger.warning("Cloud rewrite timed out (\(Self.rewriteTimeout, privacy: .public)), using original text")
            return text
        } catch is CancellationError {
            cloudRewriteLogger.debug("Cloud rewrite cancelled")
            return text
        } catch {
            cloudRewriteLogger.warning("Cloud rewrite error: \(error.localizedDescription, privacy: .public). Fallback to original text")
            return text
        }
    }
}

/// Thrown by the timeout racer to signal that the rewrite deadline has been exceeded.
private struct RewriteTimeoutError: Error {}
