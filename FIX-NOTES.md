# 接口刷新修复与验证

基线：c68fb5e（在用户最初提供的 62a9c6e 构建之后）。

## 已修复

- Swift 启动脚本插值错误：原先生成 `const bundlePath = (pathLiteral)`，会触发未定义变量异常。
- 在加载远程脚本之前安装异常处理，阻止常规 JavaScript process.exit / process.abort 调用进入原生退出路径。
- 删除假的 WebAssembly 实现；依赖不支持能力的源应报告失败，不能假装成功。
- 启动失败后保留 Node 事件循环，并将失败阶段传回 Swift；原生 Node 返回后禁止同进程重新初始化。
- argv 增加末尾空指针空间。
- 源管理新增“查看 / 导出诊断日志”。本地日志记录下载、校验、启动、健康检查与失败阶段，不记录源 URL、请求凭证或远程异常正文。
- GitHub Actions 在打包前运行生成脚本回归测试。

## 验证范围

旧代码的 ReferenceError 已在 JavaScript VM 中复现。
执行 `node --test Tests/bootstrap.test.mjs`：6 项测试通过。测试先用 swiftc 编译真实的脚本生成器，再执行生成的 JavaScript，覆盖路径转义、同步错误、exit、abort、未捕获异常和 Promise rejection。

本机没有完整 Xcode/iOS SDK，尚未完成 iOS 编译、IPA 打包或 LiveContainer 真机测试。测试使用桌面 JavaScript VM 和模拟的 Node 接口，不等同于 NodeMobile 真机验证。
JavaScript 处理器不能捕获原生崩溃、内存耗尽或系统 watchdog；不能据此宣称 0x8BADF00D 已被消除。

## 构建和真机复测

将此源码包的文件（含隐藏的 .github 目录）合入仓库后，在 GitHub Actions 中运行 Build signed IPA，选择包含本修复的分支。使用新生成的 FlowBox-unsigned-ipa 产物导入 LiveContainer。

1. 保留原数据备份，完全退出流映后启动修复版。
2. 用原先可播放的直播源验证播放未受影响。
3. 刷新原来的 index.js.md5 源，检查是否能加载，或给出明确错误。
4. 连续刷新同一源；启动失败后不应反复初始化 Node。
5. 若失败，在源管理导出日志。若仍闪退，重开流映导出日志，并附对应时间的 .ips。

本次仅处理刷新和诊断，未修改实时翻译功能。没有向 GitHub 推送，也没有触发远程构建。
