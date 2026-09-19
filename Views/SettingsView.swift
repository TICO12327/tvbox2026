import SwiftUI

struct SettingsView: View {
    @AppStorage("flowbox.autoplay") private var autoplay = true
    @AppStorage("flowbox.keepAwake") private var keepAwake = true
    @AppStorage("flowbox.liveTranslation.enabled") private var liveTranslationEnabled = false
    @AppStorage("flowbox.liveTranslation.sourceLanguage") private var sourceLanguage = "en-US"
    @AppStorage("flowbox.liveTranslation.targetLanguage") private var targetLanguage = "简体中文"
    @AppStorage("flowbox.liveTranslation.chunkSeconds") private var chunkSeconds = 5.0
    @State private var openAIKey = ""
    @State private var keychainMessage: String?

    private let sourceLanguages = [
        (id: "en-US", name: "英语"),
        (id: "ja-JP", name: "日语"),
        (id: "ko-KR", name: "韩语"),
        (id: "zh-CN", name: "中文"),
        (id: "auto", name: "自动检测")
    ]

    private let targetLanguages = ["简体中文", "繁體中文", "English", "日本語", "한국어"]

    init() {
        _openAIKey = State(initialValue: KeychainStore.shared.value(forKey: "openai.apiKey") ?? "")
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
                        Toggle("显示翻译字幕", isOn: $liveTranslationEnabled)
                        Picker("直播源语言", selection: $sourceLanguage) {
                            ForEach(sourceLanguages, id: \.id) { language in
                                Text(language.name).tag(language.id)
                            }
                        }
                        Picker("翻译成", selection: $targetLanguage) {
                            ForEach(targetLanguages, id: \.self) { language in
                                Text(language).tag(language)
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("字幕延迟")
                                Spacer()
                                Text(String(format: "%.0f 秒", chunkSeconds))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $chunkSeconds, in: 3...10, step: 1)
                            Text("越小越实时，但请求次数和费用越高。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("OpenAI API") {
                        SecureField("OpenAI API Key", text: $openAIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("保存 API Key") { saveAPIKey() }
                        if let keychainMessage {
                            Text(keychainMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Text("播放器会按设定的间隔把直播音频切片发送给 OpenAI 进行转录和翻译，字幕由返回结果生成。API Key 只保存在本机钥匙串，不会写入 GitHub。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Section("隐私") {
                        Label("配置仅保存在本机", systemImage: "lock.shield")
                        Label("不内置、不分发任何节目源", systemImage: "checkmark.seal")
                        Label("音频切片会上传至你配置的语音服务", systemImage: "waveform.badge.mic")
                    }

                    Section("关于流映") {
                        HStack { Text("版本"); Spacer(); Text("0.2.0").foregroundStyle(.secondary) }
                        Link(destination: URL(string: "https://github.com/TICO12327/tvbox2026")!) {
                            Label("项目主页", systemImage: "link")
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
            try KeychainStore.shared.setValue(openAIKey, forKey: "openai.apiKey")
            keychainMessage = "已安全保存"
        } catch {
            keychainMessage = error.localizedDescription
        }
    }
}
