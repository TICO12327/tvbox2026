import SwiftUI

struct SettingsView: View {
    @AppStorage("flowbox.autoplay") private var autoplay = true
    @AppStorage("flowbox.keepAwake") private var keepAwake = true

    var body: some View {
        NavigationStack {
            AppBackground {
                List {
                    Section("播放") {
                        Toggle("自动播放下一集", isOn: $autoplay)
                        Toggle("播放时保持屏幕常亮", isOn: $keepAwake)
                    }
                    Section("隐私") {
                        Label("配置仅保存在本机", systemImage: "lock.shield")
                        Label("不内置、不分发任何节目源", systemImage: "checkmark.seal")
                    }
                    Section("关于流映") {
                        HStack { Text("版本"); Spacer(); Text("0.1.0").foregroundStyle(.secondary) }
                        Link(destination: URL(string: "https://github.com/")!) {
                            Label("项目主页（发布后替换）", systemImage: "link")
                        }
                    }
                    Section {
                        Text("请仅使用你拥有授权或明确有权访问的媒体地址，并遵守当地法律法规与内容服务条款。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("设置")
        }
    }
}
