# 原生 Reimagined 联网客户端研究

[English](README.md)

这是面向 Apple 平台的实验性原生 Reimagined 启动器 API 客户端。目标是实现缺失的客户端组件并集成到 iOS 移植版，让 iPhone 用户将来有可能参与现有的 Reimagined 天梯。

**此模块不能启用多人游戏或天梯游玩。** iOS 外壳已纳入该模块和原生账户/赛季/地区界面；游戏网络与存档路径仍未接通。已使用原生 macOS 探针验证生产环境 PKCE 登录与带身份认证的 API 读取。尚未验证 iPhone 真机登录、天梯启动票据、服务器角色同步或游戏连接。

已实现：

- 原生 HTTPS 赛季列表和客户端策略读取，检查策略版本与起止时间一致性。
- PKCE 授权 URL、有边界限制的回环回调监听器、回调校验，以及公开接口规定的授权码兑换请求。
- 本机应用钥匙串会话存储、刷新/撤销请求，以及明确的原生客户端退出登录命令。
- 使用调用方固定的公钥，对清单原始字节进行 SHA-256 与 P-256/P1363 签名验证。这只是前置条件，不是完整的签名包校验。
- D2EM v3 外层封装：有边界的低字节优先字段、重复 ID 拒绝及未知必需字段拒绝。尚未实现字段载荷语义和游戏准入。
- 使用明确原生客户端 User-Agent 的只读 macOS 探针。

授权请求遵循公开启动器的随机本地回环端口回调约定。CLI 将授权 URL 写入调用方指定的文件，供浏览器打开。iOS 界面使用应用内 Safari 进行网站授权，并复用回环/API/钥匙串组件。尚未验证真机登录路径。没有附带凭据或生产信任根。测试样本仅含 .NET 10 生成的测试公钥与签名，私钥已丢弃。

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

## iOS 集成

`dm/ios/project.yml` 将客户端源文件编入应用。`dm/ios/Sources/dm_online.swift` 提供原生 UIKit 账户界面，包含登录、明确退出登录、赛季刷新、经过策略检查的赛季选择及服务器地区偏好。游戏传输尚未实现，因此不提供加入/游玩动作。

暂停菜单的 **更多 → Reimagined Online** 入口与诊断共用原生工具面板，保留诊断分享功能。所有新增游戏界面文字均登记在 `dm/i18n/ui_text.tsv`。

只启动账户界面可使用 `-mode online`，不会启动游戏宿主。新的暂停菜单文字需要重新生成设备覆盖层并构建完整应用后才会显示。界面可以读取可用元数据，但不会安装天梯包、取得游戏准入或修改角色存档。

本次验证：32 个库测试通过；新增 Swift 源码可编译为 ARM64 iOS；实际原生工具菜单、账户页与关闭返回已在不含游戏资源的独立 Mac Catalyst 宿主中验证。这不代表真机 iPhone 路径或完整游戏构建已经验证。

## 待完成的集成

1. 重新生成游戏覆盖层并在真机验证集成的 iOS 界面。账户界面与原生组件已经编译，但尚未走通完整真机路径。
2. 完整的签名天梯包验证，以及与天梯运营方确认原生客户端兼容要求。
3. D2RLoader 游戏环境握手、数据包边界和游戏引擎客户端/服务器集成。公开的插件网络接口不含此实现。
4. 原生 Server Saves 行为、兼容的角色序列化、冲突处理，以及独立于离线角色的天梯存档。
5. 经授权的测试环境验证：加入、游玩、断线、重连和服务器接受的存档往返。

Windows User-Agent 不能提供这些能力。公开启动器的 HTTP PKCE 兑换请求没有 Windows 专属字段，游戏协议兼容性是另一项工作。目前移植版的 `hle_net.c` 和 `hle_account.c` 故意返回离线错误；启用任何联网路径前，还需审查游戏逻辑钩子。

## 来源与署名

此分支基于 [jhaizhou-ops/d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile)，保留其 MIT 许可证和署名。不含游戏文件、着色器缓存、存档、已签名应用、Windows 加载器二进制或凭据。

独立实现的 HTTP 字段约定参考 [Reimagined Launcher c77f983](https://github.com/D2R-Reimagined/reimagined-launcher/tree/c77f983fe40983f7d747ccc788065af9d4cd43ce)，主要包括 `ReimaginedApiHttpClient`、`LauncherAuthenticationService`、`LadderScheduleResponse` 和 `LadderBundleService`。

[D2RLoader PluginSDK](https://github.com/D2RLoader/PluginSDK) 公开 Windows x64 插件接口。[安装器 README](https://github.com/D2RLoader/Installer#readme) 明确说明加载器核心闭源。[TCP/IP 指南](https://d2rloader.net/tcp-ip.html) 说明其独立恢复的 TCP/IP 联机模式。暴雪的 [2021 年测试 FAQ](https://news.blizzard.com/en-us/article/23688836/play-diablo-ii-resurrectedtm-during-the-early-access-open-beta) 将删除原 TCP/IP 模式归因于潜在安全风险，但没有详细描述漏洞。

## 原生传输与游戏会话

新增 Network.framework TCP 字节流和 `dm/ios/Sources/OnlineTransport.h` 的非阻塞 C 轮询接口。收发队列有上限，支持背压、断线、EOF 后读完剩余数据；这不是 D2RLoader 游戏包协议或准入实现。独立 C 调用方与 POSIX 对端的检查可运行 `bash dm/online/Tests/NativeTransportABI/run.sh`。

新增短期游戏令牌申请/撤销、带过期和包身份校验的赛季启动票据请求，以及按账户与赛季隔离的本地存档目录准备。目录准备不上传或移动角色，也不切换正在运行的 `DM_SAVE` 挂载。

可显式运行 `reimagined-probe --check-game-token` 检查令牌 API；成功申请后立即请求撤销。2026-10-30 已验证开发者签名的 Mac 原生探针完成 PKCE 登录、申请并撤销游戏令牌；再次使用尚未过期的令牌被服务器以 HTTP 401 拒绝。更新可执行文件并保留相同签名身份后，新进程仍可读取其会话。启动票据仅有夹具测试，尚未进行游戏准入或服务器角色写入。探针使用独立 Keychain 命名空间；反复开发应保留稳定签名身份及 `org.d2rmobile.reimagined.probe` 标识。CLI 禁止本进程的旧 Keychain 弹框，拒绝时快速失败，不删除或迁移旧受保护记录。

`tools/check_engine_input.py` 只读核对原始 Switch 3.3.94012 NSO 的模块 ID、三个解压段哈希，以及已有命令/系统消息投递调用点。它不安装钩子、不验证运行时准入。C 接口端口参数为 32 位，避免 Apple/Horizon 窄参数调用约定差异。

已独立实现 D2RL v1 控制消息、客户端到服务器的外壳和环境清单分片/重组；详见 [部分协议观察](docs/CONTROL_PROTOCOL.md)。服务器回复语义、完整 TCP 游戏流和真实游戏互操作仍未验证。

### 离线编码参考

已在 Mac 的独立离线参考环境中核对固定版本官方核心的 504 个编码/边界案例，45 个参考向量纳入 Swift 测试。详见 [局部协议与复现说明](docs/CONTROL_PROTOCOL.md)。这只验证编码组件，尚不代表天梯游戏连接成功。
