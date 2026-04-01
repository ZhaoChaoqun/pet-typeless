import Foundation
import os

private let logger = Logger(subsystem: "com.pettypeless.app", category: "PostProcessingPipeline")

/// Post-processing pipeline for PetTypeless.
///
/// With 豆包 bigmodel_async ASR handling ITN and punctuation server-side,
/// this pipeline is a simple pass-through. Kept as an extension point for
/// future local post-processing steps (e.g., custom term replacement).
final class PostProcessingPipeline {

    let processingQueue: DispatchQueue

    init(processingQueue: DispatchQueue) {
        self.processingQueue = processingQueue
    }

    /// Process ASR text. Currently a pass-through since 豆包 ASR
    /// handles ITN + punctuation server-side.
    func process(rawText: String, completion: @escaping (String?) -> Void) {
        processingQueue.async {
            guard !rawText.isEmpty else {
                logger.info("最终识别结果: （无）")
                completion(nil)
                return
            }

            logger.info("最终结果: \(rawText, privacy: .public)")
            completion(rawText)
        }
    }
}
