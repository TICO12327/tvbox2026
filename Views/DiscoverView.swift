import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var query = ""

    private var results: [MediaItem] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return library.items }
        return library.items.filter { item in
            item.title.localizedCaseInsensitiveContains(keyword)
                || item.subtitle.localizedCaseInsensitiveContains(keyword)
                || item.category.localizedCaseInsensitiveContains(keyword)
        }
    }

    var body: some View {
        NavigationStack {
            AppBackground {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                        ForEach(results) { item in
                            NavigationLink(value: item) { DiscoverCard(item: item) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(18)
                }
            }
            .navigationTitle("发现")
            .searchable(text: $query, prompt: "搜索标题、分类或源")
            .navigationDestination(for: MediaItem.self) { MediaDetailView(item: $0) }
        }
    }
}

struct DiscoverCard: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [.purple.opacity(0.75), .blue.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .aspectRatio(1.25, contentMode: .fit)
                Image(systemName: item.kind == .live ? "antenna.radiowaves.left.and.right" : "play.rectangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.8))
            }
            Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(item.category).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
