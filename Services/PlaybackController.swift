import AVFoundation
import Combine
import SwiftUI

/// 负责直播播放与实时字幕的协调。
///
/// 关于音频采集时机的关键说明：
/// 旧实现在 `AVPlayerItem` 刚创建、尚未解析 manifest 时就去 `loadTracks(.audio)`，
/// 直播流此时常常返回空数组，于是整条字幕链路在最开始就断了（表现为「直播没有
/// 可用的音频轨道」）。正确做法是等 `status == .readyToPlay`，或直接监听
/// `tracks` 异步发布，确认音轨出现后再安装 tap。
@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var subtitle: String?
    @Published private(set) var translationStatus: String?
    @Published private(set) var isTranslationActive = false

    private let url: URL
    private let isLive: Bool
    private let translationEnabled: Bool
    private let sourceLanguage: String
    private let targetLanguageName: String
    private let apiKey: String

    private var translation: LiveTranslationCoordinator?
    private var playerItem: AVPlayerItem?
    private var statusObserver: NSKeyValueObservation?
    private var trackTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var tapInstalled = false

    init(
        url: URL,
        isLive: Bool,
        translationEnabled: Bool,
        sourceLanguage: String,
        targetLanguageName: String,
        apiKey: String
    ) {
        self.url = url
        self.isLive = isLive
        self.translationEnabled = translationEnabled && isLive
        self.sourceLanguage = sourceLanguage
        self.targetLanguageName = targetLanguageName
        self.apiKey = apiKey
    }

    func start() {
        guard player == nil else { return }

        let item = AVPlayerItem(url: url)
        let avPlayer = AVPlayer(playerItem: item)
        // 直播流不等待缓冲填满，尽快出画面。
        avPlayer.automaticallyWaitsToMinimizeStalling = !isLive
        playerItem = item
        player = avPlayer

        if translationEnabled {
            startTranslation(on: item)
        }

        avPlayer.play()
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        trackTask?.cancel()
        trackTask = nil
        statusObserver?.invalidate()
        statusObserver = nil

        translation?.stop()
        translation = nil

        if let playerItem {
            FBAudioTapBridge.uninstall(from: playerItem)
        }
        tapInstalled = false

        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerItem = nil
        subtitle = nil
        translationStatus = nil
        isTranslationActive = false
    }

    // MARK: - 字幕流水线

    private func startTranslation(on item: AVPlayerItem) {
        let coordinator = LiveTranslationCoordinator(
            apiKey: apiKey,
            sourceLanguage: sourceLanguage,
            targetLanguageName: targetLanguageName
        )
        coordinator.onSubtitle = { [weak self] text in
            self?.subtitle = text
        }
        coordinator.onStatus = { [weak self] status in
            self?.translationStatus = status
        }
        translation = coordinator
        coordinator.start()

        // 音轨可能在 item ready 之后才异步出现，因此两条路都走：
        // 1) 监听 status，ready 时尝试安装
        // 2) 监听 tracks 异步发布，音轨一到就安装
        observeReadiness(item)
        observeTracks(item)
    }

    private func observeReadiness(_ item: AVPlayerItem) {
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    await self.installTapIfPossible(on: item)
                case .failed:
                    let message = item.error?.localizedDescription ?? "未知错误"
                    self.translationStatus = "直播加载失败：\(message)"
                default:
                    break
                }
            }
        }
    }

    private func observeTracks(_ item: AVPlayerItem) {
        trackTask = Task { [weak self] in
            guard let self else { return }
            let asset = item.asset
            do {
                // 等到音轨真正出现（直播流会随 manifest 解析逐步出现）。
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                guard !Task.isCancelled else { return }
                if let track = tracks.first {
                    await self.installTapIfPossible(onAssetTrack: track)
                }
            } catch {
                guard !Task.isCancelled else { return }
                if self.translationStatus == nil {
                    self.translationStatus = "无法读取直播音频轨道：\(error.localizedDescription)"
                }
            }
        }
    }

    private func installTapIfPossible(on item: AVPlayerItem) async {
        guard !tapInstalled, translationEnabled else { return }
        do {
            let tracks = try await item.asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else {
                // 音轨尚未出现，等 observeTracks 的回调。
                return
            }
            await installTapIfPossible(onAssetTrack: track)
        } catch {
            if translationStatus == nil {
                translationStatus = "无法读取直播音频轨道：\(error.localizedDescription)"
            }
        }
    }

    private func installTapIfPossible(onAssetTrack track: AVAssetTrack) async {
        guard !tapInstalled, translationEnabled, let item = playerItem else { return }

        let installed = FBAudioTapBridge.install(on: item, audioTrack: track) { [weak self] samples, count, sampleRate in
            guard count > 0 else { return }
            // 拷贝到 Swift 数组再跨线程传递，回调返回后指针即失效。
            let buffer = Array(UnsafeBufferPointer(start: samples, count: Int(count)))
            Task { @MainActor [weak self] in
                self?.translation?.appendPCM(buffer, sampleRate: sampleRate)
            }
        }

        if installed {
            tapInstalled = true
            isTranslationActive = true
            translationStatus = nil
        } else {
            translationStatus = "播放器不支持实时音频采集"
        }
    }
}
