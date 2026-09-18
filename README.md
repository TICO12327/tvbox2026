# 流映 FlowBox

一个面向 iPhone / iPad 的原生 SwiftUI 媒体源管理与播放壳。它不内置节目、频道、爬虫或第三方内容源，用户只导入自己有权使用的地址。

## 当前 MVP

- 原生 SwiftUI，iOS 16+
- 首页、搜索、源管理、设置四个移动端页面
- 远程 M3U / M3U8、TXT、通用 JSON 解析
- TVBox / PeekPro 配置识别，支持 `sites`、`lives` 和常见直连 API
- `.md5` 旁车校验识别：可定位并校验对应的 `index.js`
- 通过 NodeMobile 在应用内启动用户主动添加的 CatVodSpider `index.js`，读取 `/config`、`home`、`detail` 和 `play`
- 收藏、观看历史、断点记录的本机持久化
- AVKit 播放 HTTP / HTTPS 视频地址
- 深色玻璃卡片风格，适合手机单手操作
- GitHub Actions 构建并导出自签 IPA

## 本地运行

需要 macOS、Xcode 15+ 和 XcodeGen：

```bash
brew install xcodegen
mkdir -p Vendor
curl -L "https://github.com/nodejs-mobile/nodejs-mobile/releases/download/v18.17.3/nodejs-mobile-v18.17.3-ios.zip" -o /tmp/nodejs-mobile-ios.zip
unzip -q /tmp/nodejs-mobile-ios.zip -d /tmp/nodejs-mobile-ios
cp -R "$(find /tmp/nodejs-mobile-ios -type d -name NodeMobile.framework -print -quit)" Vendor/NodeMobile.framework
xcodegen generate
open FlowBox.xcodeproj
```

在 Xcode 里选择自己的 Team 和 Bundle Identifier，然后运行到 iPhone 或模拟器。

## GitHub 自签 IPA

仓库内的 `.github/workflows/ios-ipa.yml` 会在手动触发或推送 `v*` 标签时构建 IPA。每次运行都会上传一个 `FlowBox-unsigned-ipa` 产物；它可以用于测试或后续自签。配置完整的 Apple 签名信息后，还会额外上传签名 IPA，并在 tag 构建时发布到 GitHub Release。

如需签名 IPA，在 GitHub 仓库 `Settings → Secrets and variables → Actions` 配置：

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

### TVBox / PeekPro 兼容范围

选择“TVBox / PeekPro”格式，或保持“自动识别”。FlowBox 会识别常见的 `sites`、`lives`、`parses` 配置，读取直播频道，并尝试访问使用 HTTP/HTTPS API 的站点。

带有 `jar`、`spider`、JavaScript `api` 或 `index.js` 的站点属于 NodeJS spider。对于 CatVodSpider 风格的自包含 `index.js` / `index.js.md5`，FlowBox 会在本机缓存并启动 NodeMobile，然后通过本机 HTTP 接口读取目录和播放地址。首次刷新可能需要等待几秒，源切换时需要重启应用，因为 NodeMobile 在一个 App 进程内只运行一个脚本。

远程 JavaScript 会在你的设备上执行，请只添加你信任且有权使用的源；不要把账号、密码、Cookie 或证书放进仓库。其他带 `jar` 的 TVBox 配置仍可能需要专用运行时，应用会明确提示而不会假装兼容。

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
