import AVKit
import SwiftUI

struct MediaDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    let item: MediaItem
    @State private var showPlayer = false

    var body: some View {
        AppBackground {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(LinearGradient(colors: [.indigo.opacity(0.8), .cyan.opacity(0.38)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(height: 220)
                        Image(systemName: item.kind == .live ? "antenna.radiowaves.left.and.right" : "play.circle.fill")
                            .font(.system(size: 62))
                            .foregroundStyle(.white.opacity(0.88))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.title).font(.system(size: 30, weight: .bold, design: .rounded))
                        Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
                        Label(item.category, systemImage: "tag")
                            .font(.caption)
                            .foregroundStyle(.cyan)
                    }
                    HStack(spacing: 12) {
                        if item.hasPlayableURL {
                            Button { showPlayer = true } label: {
                                Label("立即播放", systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.cyan)
                        } else {
                            Label("添加源后即可播放", systemImage: "link.badge.plus")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity)
                        }
                        Button { library.toggleFavorite(item) } label: {
                            Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                                .frame(width: 46, height: 46)
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("说明").font(.title3.weight(.bold))
                    Text(item.hasPlayableURL ? "播放地址来自你导入的内容源。播放遇到问题时，可以在源管理页重新刷新或检查地址。" : "这是应用内置的功能示例，不包含任何第三方内容。前往“源管理”添加你有权使用的源，即可在这里看到真实内容。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
            }
        }
        .navigationTitle("详情")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showPlayer) {
            if let urlString = item.playbackURL, let url = URL(string: urlString) {
                PlayerView(item: item, url: url)
            }
        }
    }
}

struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    let item: MediaItem
    let url: URL
    @StateObject private var playback: PlaybackController

    init(item: MediaItem, url: URL) {
        self.item = item
        self.url = url

        let enabled = UserDefaults.standard.object(forKey: "flowbox.liveTranslation.enabled") as? Bool ?? false
        let sourceLanguage = UserDefaults.standard.string(forKey: "flowbox.liveTranslation.sourceLanguage") ?? "en-US"
        let targetLanguage = UserDefaults.standard.string(forKey: "flowbox.liveTranslation.targetLanguage") ?? "简体中文"
        let apiKey = KeychainStore.shared.value(forKey: "openai.apiKey") ?? ""
        _playback = StateObject(wrappedValue: PlaybackController(
            url: url,
            isLive: item.isLive || item.kind == .live,
            translationEnabled: enabled,
            sourceLanguage: sourceLanguage,
            targetLanguageName: targetLanguage,
            apiKey: apiKey
        ))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: playback.player)
                .ignoresSafeArea()

            VStack {
                Spacer()
                if let subtitle = playback.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 20, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 22)
                        .padding(.bottom, 34)
                } else if let status = playback.translationStatus, !status.isEmpty {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.86))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(.bottom, 34)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .padding(.top, 24)
            .padding(.leading, 18)
        }
        .onAppear {
            library.markPlayed(item)
            playback.start()
        }
        .onDisappear {
            playback.stop()
        }
    }
}
