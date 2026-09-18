# 流映 FlowBox

一个面向 iPhone / iPad 的原生 SwiftUI 媒体源管理与播放壳。它不内置节目、频道、爬虫或第三方内容源，用户只导入自己有权使用的地址。

## 当前 MVP

- 原生 SwiftUI，iOS 16+
- 首页、搜索、源管理、设置四个移动端页面
- 远程 M3U / M3U8、TXT、通用 JSON 解析
- 收藏、观看历史、断点记录的本机持久化
- AVKit 播放 HTTP / HTTPS 视频地址
- 深色玻璃卡片风格，适合手机单手操作
- GitHub Actions 构建并导出自签 IPA

## 本地运行

需要 macOS、Xcode 15+ 和 XcodeGen：

```bash
brew install xcodegen
xcodegen generate
open FlowBox.xcodeproj
```

在 Xcode 里选择自己的 Team 和 Bundle Identifier，然后运行到 iPhone 或模拟器。

## GitHub 自签 IPA

仓库内的 `.github/workflows/ios-ipa.yml` 会在手动触发或推送 `v*` 标签时构建 IPA。需要在 GitHub 仓库 `Settings → Secrets and variables → Actions` 配置：

| Secret | 内容 |
| --- | --- |
| `IOS_CERTIFICATE_BASE64` | `.p12` 证书的 base64 |
| `IOS_CERTIFICATE_PASSWORD` | `.p12` 密码 |
| `IOS_PROVISIONING_PROFILE_BASE64` | `.mobileprovision` 的 base64 |
| `IOS_KEYCHAIN_PASSWORD` | CI 临时钥匙串密码 |
| `IOS_TEAM_ID` | Apple Team ID |
| `IOS_PROFILE_NAME` | 描述文件名称 |
| `IOS_SIGNING_IDENTITY` | 例如 `Apple Distribution: Your Name (TEAMID)` |

生成 base64 的命令示例：

```bash
base64 -i signing.p12 | pbcopy
base64 -i profile.mobileprovision | pbcopy
```

不要把 `.p12`、私钥、描述文件、API Token 或账号会话内容提交到仓库。IPA 的安装仍受描述文件设备列表、证书有效期和 Apple 签名规则限制。

为兼容一部分仍使用 HTTP 的个人媒体源，构建配置启用了网络明文兼容选项。请优先使用 HTTPS，并只添加可信地址。

## 发布

```bash
git add .
git commit -m "Initial FlowBox iOS MVP"
git branch -M main
git remote add origin https://github.com/<你的用户名>/<你的仓库>.git
git push -u origin main
git tag v0.1.0
git push origin v0.1.0
```

之后在 GitHub Actions 中查看构建产物，带 tag 的运行会把 IPA 附加到 GitHub Release。

## 免责声明

本项目只提供本地源管理与播放能力。请仅使用拥有授权或明确有权访问的内容，并遵守当地法律法规、版权要求和内容服务条款。
