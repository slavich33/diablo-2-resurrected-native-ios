# 原生 Reimagined 联网客户端研究

[English](README.md)

这是面向 Apple 平台的实验性原生 Reimagined 启动器 API 客户端。目标是实现缺失的客户端组件并集成到 iOS 移植版，让 iPhone 用户将来有可能参与现有的 Reimagined 天梯。

**此模块不能启用多人游戏或天梯游玩。** 它没有接入游戏或存档路径。已使用原生 macOS 探针验证生产环境 PKCE 登录与带身份认证的 API 读取。尚未验证 iPhone 真机登录、天梯启动票据、服务器角色同步或游戏连接。

已实现：

- 原生 HTTPS 赛季列表和客户端策略读取，检查策略版本与起止时间一致性。
- PKCE 授权 URL、有边界限制的回环回调监听器、回调校验，以及公开接口规定的授权码兑换请求。
- 本机应用钥匙串会话存储、刷新/撤销请求，以及明确的原生客户端退出登录命令。
- 使用调用方固定的公钥，对清单原始字节进行 SHA-256 与 P-256/P1363 签名验证。这只是前置条件，不是完整的签名包校验。
- D2EM v3 外层封装：有边界的低字节优先字段、重复 ID 拒绝及未知必需字段拒绝。尚未实现字段载荷语义和游戏准入。
- 使用明确原生客户端 User-Agent 的只读 macOS 探针。

授权请求遵循公开启动器的随机本地回环端口回调约定。CLI 将授权 URL 写入调用方指定的文件，供浏览器打开。尚未实现游戏内 iOS 登录界面。没有附带凭据或生产信任根。测试样本仅含 .NET 10 生成的测试公钥与签名，私钥已丢弃。

## 运行

```sh
swift test --package-path dm/online
swift run --package-path dm/online reimagined-probe
# 明确的浏览器登录；请选择仓库外的私有输出路径。
swift run --package-path dm/online reimagined-probe --login-url-file /tmp/reimagined-authorize-url
swift run --package-path dm/online reimagined-probe --signed-schedule
swift run --package-path dm/online reimagined-probe --sign-out
```

库支持 iOS 16+ 和 macOS 13+。命令行探针在 macOS 运行，默认模式仅读取 `GET /ladders/schedule` 与 `GET /ladders/active`。匿名列表为空，不能证明已登录用户看到相同结果。2026-10-30，经用户授权的原生客户端登录后，两项列表也返回空；这只是当时的观测，不表示服务没有天梯。

## 待完成的集成

1. 游戏内 iOS 浏览器呈现和会话界面。原生回环/API/钥匙串组件已实现，但尚未走通 iOS 真机路径。
2. 完整的签名天梯包验证，以及与天梯运营方确认原生客户端兼容要求。
3. D2RLoader 游戏环境握手、数据包边界和游戏引擎客户端/服务器集成。公开的插件网络接口不含此实现。
4. 原生 Server Saves 行为、兼容的角色序列化、冲突处理，以及独立于离线角色的天梯存档。
5. 经授权的测试环境验证：加入、游玩、断线、重连和服务器接受的存档往返。

Windows User-Agent 不能提供这些能力。公开启动器的 HTTP PKCE 兑换请求没有 Windows 专属字段，游戏协议兼容性是另一项工作。目前移植版的 `hle_net.c` 和 `hle_account.c` 故意返回离线错误；启用任何联网路径前，还需审查游戏逻辑钩子。

## 来源与署名

此分支基于 [jhaizhou-ops/d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile)，保留其 MIT 许可证和署名。不含游戏文件、着色器缓存、存档、已签名应用、Windows 加载器二进制或凭据。

独立实现的 HTTP 字段约定参考 [Reimagined Launcher c77f983](https://github.com/D2R-Reimagined/reimagined-launcher/tree/c77f983fe40983f7d747ccc788065af9d4cd43ce)，主要包括 `ReimaginedApiHttpClient`、`LauncherAuthenticationService`、`LadderScheduleResponse` 和 `LadderBundleService`。

[D2RLoader PluginSDK](https://github.com/D2RLoader/PluginSDK) 公开 Windows x64 插件接口。[安装器 README](https://github.com/D2RLoader/Installer#readme) 明确说明加载器核心闭源。[TCP/IP 指南](https://d2rloader.net/tcp-ip.html) 说明其独立恢复的 TCP/IP 联机模式。暴雪的 [2021 年测试 FAQ](https://news.blizzard.com/en-us/article/23688836/play-diablo-ii-resurrectedtm-during-the-early-access-open-beta) 将删除原 TCP/IP 模式归因于潜在安全风险，但没有详细描述漏洞。
