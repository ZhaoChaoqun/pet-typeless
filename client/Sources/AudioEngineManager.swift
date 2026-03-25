import Foundation
import AVFoundation
import os

private let logger = Logger(subsystem: "com.pettypeless.app", category: "AudioEngineManager")

/// Manages AVAudioEngine lifecycle: setup, tap installation, start/stop, and buffer-to-samples conversion.
final class AudioEngineManager {

    /// Callback invoked with 16kHz Float32 mono samples from the microphone.
    var onSamples: (([Float]) -> Void)?

    /// Callback invoked with normalized audio level (0.0–1.0).
    var onAudioLevel: ((Float) -> Void)?

    private var audioEngine: AVAudioEngine?

    // MARK: - Public API

    func start() {
        let engine = AVAudioEngine()
        self.audioEngine = engine

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        let targetSampleRate: Double = 16000
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            logger.error("无法创建目标音频格式")
            return
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            logger.error("无法创建音频转换器")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            guard let samples = self.extractSamples(buffer: buffer, converter: converter, targetFormat: targetFormat) else {
                return
            }

            // Calculate audio level
            let level = self.calculateAudioLevel(samples: samples)
            DispatchQueue.main.async {
                self.onAudioLevel?(level)
            }

            self.onSamples?(samples)
        }

        do {
            try engine.start()
            logger.info("音频引擎已启动")
        } catch {
            logger.error("音频引擎启动失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        logger.info("音频引擎已停止")
    }

    // MARK: - Private

    private func extractSamples(buffer: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat) -> [Float]? {
        let frameCount = AVAudioFrameCount(targetFormat.sampleRate * Double(buffer.frameLength) / buffer.format.sampleRate)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
            return nil
        }

        var error: NSError?
        var inputConsumed = false
        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error {
            logger.error("音频转换失败: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        guard let channelData = convertedBuffer.floatChannelData else { return nil }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(convertedBuffer.frameLength)))
        return samples
    }

    private func calculateAudioLevel(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        // Normalize to 0.0 - 1.0 range (assuming typical speech levels)
        return min(1.0, rms * 10.0)
    }
}
