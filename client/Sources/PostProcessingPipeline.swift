import Foundation
import os

private let logger = Logger(subsystem: "com.pettypeless.app", category: "PostProcessingPipeline")

/// Simplified post-processing pipeline for PetTypeless.
///
/// Since ASR and rewrite are both handled server-side, this pipeline is much simpler
/// than Nano Typeless's version. It only handles the CloudRewrite step.
final class PostProcessingPipeline {

    let processingQueue: DispatchQueue
    private let cloudRewriteService: CloudRewriteService

    init(processingQueue: DispatchQueue, cloudRewriteService: CloudRewriteService) {
        self.processingQueue = processingQueue
        self.cloudRewriteService = cloudRewriteService
    }

    /// Process raw ASR text through the cloud rewrite pipeline.
    ///
    /// Pipeline: Raw ASR text → CloudRewrite (Server-side LLM) → Final text
    ///
    /// All local processing steps (TermNorm, ITN, CSC, Punctuation) are removed
    /// because the server-side Azure ASR handles punctuation and the rewrite
    /// handles formatting.
    func process(rawText: String, completion: @escaping (String?) -> Void) {
        processingQueue.async { [weak self] in
            guard let self = self else { return }

            guard !rawText.isEmpty else {
                logger.info("最终识别结果: （无）")
                completion(nil)
                return
            }

            // Cloud rewrite via Server
            Task { [weak self] in
                guard let self = self else { return }
                let rewrittenText = await self.cloudRewriteService.rewriteOrPassthrough(rawText)
                self.processingQueue.async {
                    logger.info("最终结果: \(rewrittenText, privacy: .public)")
                    completion(rewrittenText)
                }
            }
        }
    }
}
