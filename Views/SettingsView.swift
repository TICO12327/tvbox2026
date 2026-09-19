import SwiftUI

struct SettingsView: View {
    @AppStorage("flowbox.autoplay") private var autoplay = true
    @AppStorage("flowbox.keepAwake") private var keepAwake = true
    @AppStorage("flowbox.liveTranslation.enabled") private var liveTranslationEnabled = false
    @AppStorage("flowbox.liveTranslation.sourceLanguage") private var sourceLanguage = "en-US"
    @State private var deepSeekAPIKey = ""
    @State private var keychainMessage: String?

    private let languages = [
        (id: "en-US", name: "英语"),
        (id: "ja-JP", name: "日语"),
        (id: "ko-KR", name: "韩语"),
        (id: "zh-CN", name: "中文")
    ]

    init() {
        _deepSeekAPIKey = State(initialValue: KeychainStore.shared.value(forKey: "deepseek.apiKey") ?? "")
    }

    var body: some View {
        NavigationStack {
            AppBackground {
                List {
                    Section("播放") {
                        Toggle("自动播放下一集", isOn: $autoplay)
                        Toggle("播放时保持屏幕常亮", isOn: $keepAwake)
                    }
                    Section("直播实时翻译") {
                        Toggle("显示中文字幕", isOn: $liveTranslationEnabled)
                        Picker("直播源语言", selection: $sourceLanguage) {
                            ForEach(languages, id: \.id) { language in
                                Text(language.name).tag(language.id)
                            }
                        }
                        SecureField("DeepSeek API Key", text: $deepSeekAPIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("保存 API Key") {
                            saveAPIKey()
                        }
                        if let keychainMessage {
                            Text(keychainMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Text("播放器会先用 Apple 语音识别直播声音，再将文字发送给 DeepSeek 翻译。API Key 只保存在本机钥匙串，不会写入 GitHub。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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

    private func saveAPIKey() {
        do {
            try KeychainStore.shared.setValue(deepSeekAPIKey, forKey: "deepseek.apiKey")
            keychainMessage = "已安全保存"
        } catch {
            keychainMessage = error.localizedDescription
        }
    }
}
