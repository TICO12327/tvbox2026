import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        NavigationStack {
            AppBackground {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        hero

                        if !library.history.isEmpty {
                            MediaSection(title: "继续播放", subtitle: "从上次离开的地方接着看", items: library.history)
                        }
                        MediaSection(title: "为你准备", subtitle: "简洁、快速、只显示你自己的源", items: library.items)
                        MediaSection(title: "我的收藏", subtitle: "把常看的内容放在这里", items: library.favorites)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 28)
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(for: MediaItem.self) { MediaDetailView(item: $0) }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("流映")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("你的移动媒体空间")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "waveform.path.ecg")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.cyan)
                .padding(12)
                .background(Color.flowCard, in: Circle())
        }
        .padding(.top, 12)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("移动端优先", systemImage: "iphone.gen3")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.cyan)
            Text("把内容源留在自己手里")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text("流映不内置任何节目或频道。添加你有权使用的源，统一管理收藏、历史和播放体验。")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
            NavigationLink(destination: SourcesView()) {
                Label("添加第一个源", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(.cyan, in: Capsule())
                    .foregroundStyle(.black)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color.cyan.opacity(0.25), Color.indigo.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.1)))
    }
}

struct MediaSection: View {
    let title: String
    let subtitle: String
    let items: [MediaItem]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title3.weight(.bold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(items) { item in
                            NavigationLink(value: item) { MediaCard(item: item) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

struct MediaCard: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [.indigo.opacity(0.9), .cyan.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 152, height: 104)
                if let urlString = item.artworkURL, let url = URL(string: urlString) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                    .frame(width: 152, height: 104)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                Image(systemName: item.kind == .live ? "dot.radiowaves.left.and.right" : "play.fill")
                    .font(.caption.weight(.bold))
                    .padding(8)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(9)
            }
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(item.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 152, alignment: .leading)
    }
}
