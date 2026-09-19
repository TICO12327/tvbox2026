import Foundation

/// 把音频 tap 送来的 PCM 片段累积成固定时长的 16kHz 单声道 WAV。
///
/// 为什么必须转换：
/// 1. 转录接口虽然能接收 44.1kHz，但采样率越高上传体积越大、费用越高；
///    语音识别在 16kHz 已足够，这是 Whisper 的原生采样率。
/// 2. 直播音频常见 48kHz / 立体声，直接上传会让流量翻好几倍。
/// 3. 固定时长切片是「流式」的唯一可行做法：接口不是流式协议，
///    必须攒够一段才能发一次请求。
final class AudioChunker {
    /// 切片时长。4~6 秒是延迟与费用的平衡点：太短句子会被切断、
    /// 请求数暴增；太长字幕会明显滞后于画面。
    private let chunkSeconds: Double
    private let sampleRate: Double
    private let maxQueuedSeconds: Double

    private var pending: [Float] = []
    private var queuedSeconds: Double = 0
    private var lastEmitTime: Date?

    /// 达到切片长度时回调。回调发生在内部串行队列语义下，
    /// 调用方负责派发到自己的队列。
    var onChunk: ((Data) -> Void)?

    /// - Parameters:
    ///   - chunkSeconds: 每个切片的秒数。
    ///   - sampleRate: 输出采样率（固定 16000）。
    ///   - maxQueuedSeconds: 积压上限。网络慢时避免内存无限增长。
    init(chunkSeconds: Double = 5.0, sampleRate: Double = 16_000, maxQueuedSeconds: Double = 60) {
        self.chunkSeconds = chunkSeconds
        self.sampleRate = sampleRate
        self.maxQueuedSeconds = maxQueuedSeconds
    }

    /// 追加一段来自音频 tap 的 PCM。
    /// - Parameters:
    ///   - samples: 单声道 Float32 样本，取值范围 [-1, 1]。
    ///   - sourceSampleRate: 该段音频的实际采样率。
    func append(_ samples: [Float], sourceSampleRate: Double) {
        guard !samples.isEmpty, sourceSampleRate > 0 else { return }

        let resampled = Self.resample(samples, from: sourceSampleRate, to: sampleRate)
        guard !resampled.isEmpty else { return }

        pending.append(contentsOf: resampled)

        let pendingSeconds = Double(pending.count) / sampleRate
        // 积压保护：只保留最近的一段，丢弃最旧数据。
        if pendingSeconds > maxQueuedSeconds {
            let keepCount = Int(maxQueuedSeconds * sampleRate)
            if pending.count > keepCount {
                pending.removeFirst(pending.count - keepCount)
            }
        }

        if pendingSeconds >= chunkSeconds {
            flush()
        }
    }

    /// 立即产出一个切片（用于停止播放时把残余音频送出）。
    func flush() {
        guard !pending.isEmpty else { return }

        let samples = pending
        pending.removeAll(keepingCapacity: true)

        // 忽略过短的碎片：不足 0.8 秒的音频识别质量很差，
        // 而且会给接口带来大量无意义请求。
        guard Double(samples.count) / sampleRate >= 0.8 else { return }

        let wav = Self.makeWAV(samples: samples, sampleRate: sampleRate)
        lastEmitTime = Date()
        onChunk?(wav)
    }

    /// 丢弃所有未发送数据（切换频道时使用）。
    func reset() {
        pending.removeAll(keepingCapacity: false)
        queuedSeconds = 0
        lastEmitTime = nil
    }

    /// 判断当前是否处于静音间隙 —— 用于尽量在句子边界切分。
    var isIdle: Bool {
        guard let lastEmitTime else { return true }
        return Date().timeIntervalSince(lastEmitTime) > chunkSeconds
    }

    // MARK: - 重采样

    /// 线性插值重采样。语音识别对音质要求不高，线性插值足够，
    /// 且避免了引入 vDSP / AVAudioConverter 的额外复杂度。
    private static func resample(_ input: [Float], from source: Double, to target: Double) -> [Float] {
        if abs(source - target) < 1 {
            return input
        }

        let ratio = target / source
        let outputCount = Int(Double(input.count) * ratio)
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        let step = Double(input.count - 1) / Double(max(outputCount - 1, 1))

        for index in 0..<outputCount {
            let position = Double(index) * step
            let lower = Int(position)
            let upper = min(lower + 1, input.count - 1)
            let fraction = Float(position - Double(lower))
            output[index] = input[lower] * (1 - fraction) + input[upper] * fraction
        }
        return output
    }

    // MARK: - WAV 封装

    /// 生成 16-bit PCM 单声道 WAV。
    /// 接口需要可识别的容器格式，裸 PCM 会被拒绝。
    static func makeWAV(samples: [Float], sampleRate: Double) -> Data {
        let bitsPerSample = 16
        let channels = 1
        let byteRate = Int(sampleRate) * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = samples.count * bitsPerSample / 8
        let chunkSize = 36 + dataSize

        var data = Data(capacity: 44 + dataSize)

        func appendString(_ value: String) {
            data.append(contentsOf: Array(value.utf8))
        }
        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        // RIFF header
        appendString("RIFF")
        appendUInt32(UInt32(chunkSize))
        appendString("WAVE")

        // fmt chunk
        appendString("fmt ")
        appendUInt32(16)                        // PCM 子块大小
        appendUInt16(1)                         // PCM 格式
        appendUInt16(UInt16(channels))
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(byteRate))
        appendUInt16(UInt16(blockAlign))
        appendUInt16(UInt16(bitsPerSample))

        // data chunk
        appendString("data")
        appendUInt32(UInt32(dataSize))

        // 浮点 [-1,1] 转 16-bit 整数，带钳位防止溢出产生的爆音
        var pcm = [Int16](repeating: 0, count: samples.count)
        for index in 0..<samples.count {
            let clamped = max(-1.0, min(1.0, samples[index]))
            pcm[index] = Int16(clamped * 32_767.0)
        }
        pcm.withUnsafeBufferPointer { buffer in
            data.append(UnsafeBufferPointer(start: buffer.baseAddress, count: buffer.count))
        }

        return data
    }
}
