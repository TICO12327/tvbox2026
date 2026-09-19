import AVFoundation
import SwiftUI

@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var subtitle: String?
    @Published private(set) var translationStatus: String?

    private let url: URL
    private let isLive: Bool
    private let translationEnabled: Bool
    private let translation: LiveTranslationCoordinator?
    private var startTask: Task<Void, Never>?

    init(url: URL, isLive: Bool, translationEnabled: Bool, sourceLanguage: String, apiKey: String) {
        self.url = url
        self.isLive = isLive
        self.translationEnabled = translationEnabled && isLive

        if translationEnabled && isLive {
            let coordinator = LiveTranslationCoordinator(sourceLanguage: sourceLanguage, apiKey: apiKey)
            self.translation = coordinator
        } else {
            self.translation = nil
        }
    }

    func start() {
        guard player == nil else { return }

        let playerItem = AVPlayerItem(url: url)
        let avPlayer = AVPlayer(playerItem: playerItem)
        player = avPlayer

        startTask = Task { [weak self, weak playerItem, weak avPlayer] in
            guard let self, let playerItem, let avPlayer else { return }

            if self.translationEnabled, let translation = self.translation {
                translation.onSubtitle = { [weak self] text in
                    self?.subtitle = text
                }
                translation.onStatus = { [weak self] status in
                    self?.translationStatus = status
                }
                await translation.start()
                await self.installAudioTap(on: playerItem)
            }

            guard !Task.isCancelled else { return }
            avPlayer.play()
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        translation?.stop()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        subtitle = nil
        translationStatus = nil
    }

    private func installAudioTap(on playerItem: AVPlayerItem) async {
        guard let asset = playerItem.asset as? AVURLAsset else {
            translationStatus = "当前媒体不支持实时音频采集"
            return
        }

        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let audioTrack = tracks.first else {
                translationStatus = "直播没有可用的音频轨道"
                return
            }

            let installed = FBAudioTapBridge.install(on: playerItem, audioTrack: audioTrack) { [weak self] data, sampleRate in
                Task { @MainActor [weak self] in
                    self?.translation?.appendPCM(data, sampleRate: sampleRate)
                }
            }
            if !installed {
                translationStatus = "播放器不支持实时音频采集"
            }
        } catch {
            translationStatus = "无法读取直播音频轨道：\(error.localizedDescription)"
        }
    }
}
