import Foundation

/// 统一的 ASR 引擎接口
///
/// 封装了不同 ASR 后端的差异，
/// 让 RecordingManager 无需关心具体引擎类型。
protocol ASREngine: AnyObject {
    /// 将新的音频采样送入引擎
    /// - Parameter samples: 16kHz monoFloat32 PCM 采样
    /// - Parameter onPartialResult: 有新的部分识别结果时回调（stableText, unfixedText）
    func processAudio(samples: [Float], onPartialResult: @escaping (String, String?) -> Void)

    /// 刷新引擎缓冲区，获取最终识别文本
    /// - Parameter completion: 返回最终文本（在 main queue 上调用）
    func flush(completion: @escaping (String) -> Void)

    /// 重置引擎状态，准备下一次识别
    func reset()

    /// 引擎是否需要外部标点处理
    var needsPunctuation: Bool { get }

    /// 引擎是否需要外部 ITN（逆文本规范化）
    var needsITN: Bool { get }
}
