import Foundation
import os

private let logger = Logger(subsystem: "com.pettypeless.app", category: "PostProcessingPipeline")

/// Simplified post-processing pipeline for PetTypeless.
///
/// 豆包 bigmodel_async ASR 已内置 ITN（数字格式化）和标点，
/// 无需额外的后处理步骤，直接透传 ASR 结果。
final class PostProcessingPipeline {

    let processingQueue: DispatchQueue
    private let cloudRewriteService: CloudRewriteService

    init(processingQueue: DispatchQueue, cloudRewriteService: CloudRewriteService) {
        self.processingQueue = processingQueue
        self.cloudRewriteService = cloudRewriteService
    }

    /// Process raw ASR text — currently a direct passthrough since
    /// 豆包 ASR already handles ITN and punctuation.
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
