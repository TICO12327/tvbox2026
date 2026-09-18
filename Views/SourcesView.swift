import SwiftUI

struct SourcesView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var sourceName = ""
    @State private var sourceURL = ""
    @State private var sourceFormat: SourceFormat = .auto

    var body: some View {
        NavigationStack {
            AppBackground {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        intro
                        addForm
                        if library.sources.isEmpty {
                            emptyState
                        } else {
                            Text("已添加的源").font(.title3.weight(.bold)).padding(.top, 8)
                            ForEach(library.sources) { source in
                                SourceRow(source: source)
                            }
                        }
                        if let error = library.lastError {
                            Text(error).font(.footnote).foregroundStyle(.orange)
                        }
                    }
                    .padding(18)
                }
            }
            .navigationTitle("源管理")
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("只添加你有权使用的地址", systemImage: "checkmark.shield")
                .font(.headline)
                .foregroundStyle(.cyan)
            Text("支持远程 M3U / M3U8、TXT 和通用 JSON。源内容只在本机解析和保存，不会上传到流映服务器。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var addForm: some View {
        VStack(spacing: 12) {
            TextField("源名称（可选）", text: $sourceName)
            TextField("https://example.com/source.m3u", text: $sourceURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Picker("格式", selection: $sourceFormat) {
                ForEach(SourceFormat.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            Button {
                library.addSource(name: sourceName, urlString: sourceURL, format: sourceFormat)
                if library.lastError == nil {
                    sourceName = ""
                    sourceURL = ""
                }
            } label: {
                Label("保存源", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
        }
        .padding(16)
        .background(Color.flowCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("还没有内容源")
                .font(.headline)
            Text("添加一个你有权使用的 M3U、TXT 或 JSON 地址开始。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

struct SourceRow: View {
    @EnvironmentObject private var library: LibraryStore
    let source: MediaSource
    @State private var isRefreshing = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(.cyan)
                .frame(width: 42, height: 42)
                .background(.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(source.name).font(.headline)
                Text(source.urlString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let date = source.lastUpdated { Text("更新于 \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            Button {
                Task { await library.refresh(source) }
            } label: {
                Image(systemName: library.isRefreshing ? "hourglass" : "arrow.clockwise")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .background(Color.flowCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contextMenu {
            Button(role: .destructive) { library.removeSource(source) } label: { Label("删除源", systemImage: "trash") }
        }
    }
}
