## [Unreleased]

## [1.2.0] - 2026-08-25

### 修复

- **AbortSignal polyfill 误伤插件**：polyfill 注入曾按内容特征判断 HTML，把含 `<head`/`<html` 字符串的插件 JS bundle 也注入破坏（"Failed to load plugins / loaded without registering"）。现在**只对 `content-type: text/html` 的响应注入**，且注入位置在 `<head>` 闭合标签之后，注入文档强制 `no-store` 防旧缓存
- **连接后页面挂起**：`/plugins/events`（HTTP SSE 长连接）曾被当作一次性 HTTP 请求，隧道等待完整响应直到 30s 超时；现在**流式转发**（桥接端 + 手机端均支持，LAN 直连同样生效），页面不再等待
- **隧道掉线后无恢复**：relay 隧道断线后现在**自动重连**（指数退避 2s→30s），断线时显示「正在重新连接…」，恢复后自动刷新页面

### 优化

- **连接提速**：relay 下行大资源 **gzip 压缩**（传输量约 -70%）；注入后的首页 HTML 进入手机内存缓存，二次进入秒开
- **relay 服务器自定义**：设置中可自定义 relay 服务器地址（开关开启时优先），关闭或未设置时使用默认 `https://relay.deepvisus.top`

## [1.1.9] - 2026-08-22

### 修复

- **Android 旧 WebView 上「收集」消息报错**：dsh 网页调用 `AbortSignal.any()`（Chrome 116+ 才有），旧系统 WebView 上收集/发送消息报 `AbortSignal.any is not a function`。手机端现在在页面加载前注入 polyfill（`AbortSignal.any` + `AbortSignal.timeout`）

## [1.1.8] - 2026-08-22

### 优化

- **启动屏统一深色（三端）**：dsh 网页为深色风格，启动屏固定 `#1e1e1e` 深底 + 浅色文字/日志/spinner（不再跟随系统外观），消除浅色屏一闪而过再进深色界面的割裂感；macOS spinner 强制深色外观，浅色模式下也清晰可见
- **启动日志实时显示**：启动屏底部实时显示 dsh 最新一行日志；npm 下载进度条（`\r` 刷新、无换行）按最新进度帧显示（macOS/Linux/Windows 均处理）；日志文字改为高对比色
- **Windows 启动超时修复**：超时对齐 180s，且**任何**日志输出（含 `\r` 进度）都复位倒计时——dsh 更新触发 npx 重新下载时不再被误杀
- **Android 连接提速**：
  - 点击终端卡片后 LAN 探测与中继连接**并行**发起，不在同一网络时不再串行等探测超时（探测收紧到 1s）
  - 中继建连加 8s 超时保护（此前 TCP/DNS 挂起时 app 会误判已连接，进页面白屏）
  - 页面静态资源（`/assets/*`，hash 文件名）内存 LRU 缓存，二次进入秒开
  - LAN 直连复用 HTTP keep-alive 连接
- **CI 发布流程修复**：publish 总是先删旧 release 再重建，根治删 tag 重发导致的 release 孤儿化（匿名 API 404、资产不可见）

## [1.1.7] - 2026-08-21

### 新增

- **插件管理窗口（三端：macOS / Windows / Linux）**：View 菜单「插件管理…」/ Help 菜单「插件市场…」打开原生窗口（替代浏览器跳转），三个 Tab：
  - **已安装**：直接安装的插件按**依赖树**展示，默认收起、行前 `+`/`−` 展开折叠；每行可 启用/停用/卸载；内置模板（`@deepseek-ai/dsh-base`、`@deepseek-ai/dsh-web-app`）标注「内置」且不提供操作；列表统一行高、弱分割线、按钮右对齐
  - **已启用**：`dsh.profile.bundles` 插件层按序展示，可停用
  - **插件市场**：拉取 `harness-market` 索引（155 个插件），支持本地化搜索；npm 包一键安装、GitHub 仓库直接以 git 依赖安装，另提供「打开」；已安装的条目按钮变为 启用/停用
  - **从本地安装**：选择本地插件目录（含 package.json）或 `.tgz`/`.tar.gz` 直接安装到 profile；声明 `dsh.bundle` 的自动加入启用层，其余作为普通依赖
  - 插件层变更后提供「重启 dsh web」一键生效；修复 GUI 环境 PATH 精简导致 pnpm 检测失败的安装失效问题
- **启动不再弹出浏览器网页**：`dsh web` 引擎默认会在默认浏览器打开 Web UI，三端启动命令统一加 `--no-open`（自定义 `--command` 不受影响）
- **中继服务器 certbot 证书脚本**（`mobile/relay/deploy/`）：`certbot-issue.sh` 一键申请（nginx/standalone/webroot 三种模式，幂等）、`certbot-renew.sh` + systemd timer 每日两次自动续期（续期复用私钥，不影响手机端证书固定）；nginx 反代 TLS 路线完整文档

## [1.1.6] - 2026-08-18

### 移除

- **WebRTC P2P 直连整体下线（三端 + 手机端）**：外网远程访问一律走中继隧道。删除 bridge 的 werift（含其媒体依赖 mediabunny 等，`mobile/bridge` 依赖只剩 `ws`）、手机端 flutter_webrtc（`p2p_client.dart`、「屏蔽 P2P 直连」开关、连接指示 chip、信令 `signal` 帧全部移除）、以及开发探针 `mobile/p2p_probe`。LAN 内直连代理保留（非 WebRTC）。协议文档 §9 同步改写。
- **bridge 打包瘦身（三端）**：新增 `mobile/bridge/prune.mjs`，打包时从 node_modules 剥离源码映射/TypeScript 源码/README/LICENSE 等纯开发文件；macOS `build-app.sh`、Windows/Linux CI 打包前均执行。桥依赖从 26 MB（werift 时代）降至约 0.2 MB（仅 ws），DMG 体积显著下降。

### 新增

- **启动界面实时显示服务日志（三端）**：默认启动命令加 `--verbose`（npx/npm 参数，位于包名之前，不影响 dsh web 自身参数），捞回 npx/dsh 的 stdout/stderr。启动界面最下方只显示**最后一行**日志（macOS 加载遮罩底部 / Windows 加载遮罩底部 / Linux 加载遮罩底部），且**每有新日志输出就复位启动超时倒计时**——首次启动 npx 下载依赖等「慢但在推进」的场景不再被超时杀掉。
- **手机端「屏蔽 P2P 直连」开关**：WebRTC P2P 直连的往返时延在某些网络下比中继隧道更长、影响操作响应。首页新增「屏蔽 P2P 直连」开关，远程页右上角连接指示（P2P 直连 / 中继隧道）点击也可即时切换——开启后立即断开 P2P 并退回中继隧道，设置持久化，之后连接不再发起 P2P 升级。

## [1.1.5] - 2026-08-17

### 修复

- **手机端 "Failed to load plugins"**：插件 bundle（50–430KB）超过 WebRTC DataChannel 协商的 max-message-size（werift 默认 64KB），bridge 的 `dc.send` 抛 `max-message-size exceeded` 被吞掉，手机 30s 超时返回 502 → 前端渲染 "Failed to load plugins"。修复：bridge 对 >16KB 的 `http-reply` 拆成 `http-chunk` 分片，手机端按 `id` 收齐后拼接（`mobile/bridge/bridge.mjs`、`mobile/app/lib/core/p2p_client.dart`）。
- **LAN 直连地址选错网卡**：配对二维码的 `lan=` 之前无条件优先 `192.168.*`，在有 VM 虚拟网卡（VMware/Parallels 桥接网卡）时会选中手机无法访问的地址，导致同 WiFi 下也退回中继/P2P。修复：三端统一改为优先「默认路由接口」——macOS 用 SystemConfiguration `PrimaryInterface`、Windows 用 `GetBestInterface`、Linux 用 `/proc/net/route`。

## [1.1.3] - 2026-08-17

### 修复

- **首次启动不再卡死**：`@deepseek-ai/dsh` 尚未缓存时，npx 会在 stdin 上询问 "Ok to proceed? (y)"，GUI 壳没有终端回答，服务永远起不来导致 WebView 卡死。三端默认启动命令统一加 `--yes`（macOS 另补 `npm_config_yes=true` 环境变量），npx 自动安装不再交互确认。

## [1.1.2] - 2026-08-17

### 修复

- **CI 构建全绿**：修复 Linux（libsoup3 API、静态回调、lambda 捕获、qrcodegen C 语言启用、deb control 缩进）与 Windows（winsock 头序、namespace 限定、对话框模板类型、WiX heat/ICE80）的全部编译与打包错误，macOS / Linux（x64+arm64）/ Windows（x64+arm64）以及 Android / iOS 手机端产物均构建成功。
- **iOS 产物打包**：修正 CI 中 Runner.app 的 zip 路径，iOS App 产物正常上传。

## [1.1.1] - 2026-08-17

### 新增

- **Android 前台服务**：远程会话连接期间启动前台服务（`dataSync` 类型），App 切到后台时进程优先级提升，OEM 省电策略不再杀进程——手机锁屏/切 App 时连接保持，回前台自动恢复，不再需要手动重连。

### 修复

- 手机 App 默认 widget 测试引用不存在的类导致 `flutter analyze` 报错。

## [1.1.0] - 2026-08-17

### 新增

- **手机远程连接（全平台统一）**：Windows 与 Linux 壳同步 macOS 的远程连接能力——配对二维码与设备码/PIN 现在携带局域网直连地址（`lan=`），手机在局域网内直连、外网走 WebRTC P2P、断线回退云中继；配对 PIN 稳定持久化（Windows 注册表 / Linux `~/.config/deepseek-harness/pin`）。
- **中继服务器免费部署**：新增 `mobile/relay/deploy/`——Dockerfile（多阶段、支持国内镜像源参数）、Caddy 自动 HTTPS 反代、docker-compose 一键栈、部署指南（Oracle Cloud 永久免费 VPS / Cloudflare Tunnel / 国内云试用三路线）。
- **Flutter CI**：新增 `.github/workflows/flutter.yml`，产出 Android release APK 与 iOS 未签名 `Runner.app`，随 `v*` tag 自动挂到 GitHub Release。
- **移动端**：新增 iOS 平台工程；WebView 会话恢复、LAN 直连模式统一走本地固定端口代理（会话历史跨启动/跨模式持久）；修复 bridge LAN WebSocket 转发（Node 内置 WebSocket 兼容）与插件加载竞态（自动重载）。

### 修复

- bridge：LAN 事件流（events.mux）经代理转发崩溃（`up.on is not a function`）已修复；手机端"无法获取本地会话"、插件加载失败自动重试。
- 手机 App：代理端口固定 38080，localStorage origin 稳定。

### 变更

- 桌面壳与移动端版本号统一为 1.1.0。

# Changelog

本项目所有值得注意的变更都会记录在此文件中。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.0.9] - 2026-08-16

### 新增

- Linux 自动安装 Node.js：首次启动缺少 node/npx 时自动下载安装最新 LTS 到 `~/.local/share/deepseek-harness/nodejs`（用户级、无需 root，与 macOS/Windows 一致），带进度对话框，装完自动启动服务；仅自动安装失败时才提示手动安装（`sudo apt install nodejs npm`）。中国时区自动使用 npmmirror 镜像（node 下载与 npm registry）。
- 三个平台发布工作流合并为单个 `release.yml`：macOS DMG、Windows x64/arm64 exe+MSI、Linux x86_64/arm64 tarball+.deb，一个 `publish` job 统一附加到 Release。

### 修复

- Linux 首次启动卡在加载画面：npx 首次安装 `@deepseek-ai/dsh` 时交互式询问 "Ok to proceed?" 导致挂起（现设置 `npm_config_yes=true` 并把子进程 stdin 重定向到 `/dev/null`）；启动轮询 3 分钟兜底，加载画面 30 秒后提示「首次启动正在下载依赖」。
- Linux 中国时区镜像判定：`/etc/timezone`（Debian 遗留文件）可能过期残留（实测一台 Asia/Shanghai 时区的机器上该文件为 `US/Pacific`），导致误判非中国时区、未走 npmmirror 镜像，npm 下载慢 10-20 倍。现改为以 `/etc/localtime`（符号链接、systemd/timedatectl 维护）为权威来源，`/etc/timezone` 仅作后备。
- Linux 自动安装 Node.js 完成后段错误：安装对话框销毁时 weak pointer 回调写入已释放的上下文（heap use-after-free，损坏 GLib 分配器后在下一次启动服务的 `g_child_watch_add` 处崩溃）。现于完成回调中先移除 weak pointer 再释放上下文。
- Linux 自动安装 Node.js 完成后 webview 空白：加载遮罩在失败路径被隐藏后未重新显示，现于重启服务前恢复显示。
- Linux 页面下载失效警告：新版 WebKitGTK 将 WebKitWebContext 的下载信号由 `download-start` 更名为 `download-started`，现于运行时探测兼容 2.36 基线及新版。

## [1.0.8] - 2026-08-16

### 新增

- **Linux 移植**：新增 `linux/` 原生壳（C++ + GTK3 + WebKitGTK 4.1，系统 WebView），功能与 macOS/Windows 对齐 —— 主题（跟随系统/明亮/暗黑）、菜单多语言（跟随系统/简体中文/English，持久化到 `~/.config/deepseek-harness/settings.conf`）、全屏、编辑快捷键、外部链接走系统默认浏览器、下载另存为 + 进度条、npm 版本检查、插件市场。随 `v*` tag 发布 **x86_64 与 arm64** 双架构的便携 tarball + `.deb` 包（arm64 在 ubuntu-22.04 交叉编译，与 x64 同为 glibc 2.35 基线）。
- Linux 窗口/任务栏图标：新增 256px PNG 图标，运行时从可执行文件同目录（便携包）或 hicolor 图标主题（`.deb` 安装）加载，替代原来的通用占位图标。
- 全屏模式菜单项（macOS + Windows）：macOS 视图菜单新增「进入/退出全屏」（⌃⌘F，标题随窗口状态切换）；Windows 菜单栏新增「全屏」开关（无边框铺满显示器，可勾选）。

### 修复

- 语言菜单缺少「跟随系统」选项（macOS + Windows）：手动切换语言后无法恢复跟随系统，现与主题菜单一致，提供 跟随系统 / 简体中文 / English 三项。

## [1.0.7] - 2026-08-16

### 新增

- 主题设置菜单（macOS + Windows）：明亮 / 暗黑 / 跟随系统三档，跟随系统为默认；暗黑模式下 macOS 原生外观与 `prefers-color-scheme`、Windows 标题栏与 WebView2 配色同步切换，选择持久化（macOS UserDefaults / Windows 注册表）。
- 菜单多语言支持（macOS + Windows）：中文（简体中文）与英文两种，默认跟随系统语言，可在菜单中随时切换并持久化。

## [1.0.6] - 2026-08-16

### 新增

- 菜单新增 **Plugins Market** 选项（macOS：Help 菜单；Windows：窗口菜单栏）：点击后在系统默认浏览器打开 https://tonytsangzen.github.io/harness-market/。
- 外部链接/新窗口支持（macOS + Windows）：点击 `target="_blank"`、`window.open` 或跳转到本地 dsh 服务器以外的 URL 时，自动用系统默认浏览器打开；仅本地服务器页面在 WebView 内导航。
- Windows 页面内下载支持（对齐 macOS）：注入 JS 拦截 `<a download>` 点击，绕过引擎对程序化下载（无用户手势）的拦截，改为 WinHTTP 原生下载；弹「另存为」对话框选择保存位置（默认 Downloads），底部进度条显示进度，失败弹错误对话框。
- Windows 应用图标：提交的 `AppIcon.ico` 通过 `resources.rc` 嵌入 exe，并用作窗口类图标（Explorer、任务栏、标题栏）。
- Windows 双架构发布：GitHub Actions 产出 **x64 与 arm64** 的便携 exe 与 WiX MSI 安装包（`windows/installer/DSHWebView.wxs`），推送 `v*` 标签自动附加到 Release。
- README 新增 Windows 最终用户安装说明（MSI / 便携 exe，按 CPU 架构选择）。

### 变更

- Windows 构建按目标架构选择 WebView2 静态加载库（`CMakeLists.txt`）：VS 生成器下以 `CMAKE_GENERATOR_PLATFORM`/`CMAKE_VS_PLATFORM_NAME` 判定 arm64。
- Windows 页面下载改为先弹保存对话框（原为直接保存到 Downloads 目录）。
- 新增 `.gitignore`（忽略 `dist/`、`windows/build*/`、WiX 中间产物等）。

## [1.0.1] - 2026-08-14

### 修复

- 页面内「Session ZIP」下载不触发：新增 JS 拦截 `<a download>` 点击并通过 `URLSession` 原生下载，绕开 WebKit 对程序化下载导航支持不可靠的问题。
- 下载进度不更新：改用 `URLSessionDataTask` 读取 `expectedContentLength`，未知总量时退化为不确定进度条。
- 系统已装 Node 仍走安装流程：Node/npx 检测改为探测常见安装路径并执行 `--version` 校验有效性。

## [1.0.0] - 2026-08-14

### 新增

- macOS 原生 `WKWebView` 包装壳，启动时拉起 `npx @deepseek-ai/dsh web` 并加载页面。
- 运行时按需安装：启动时检测 Node.js/npx，缺失则显示「Preparing runtime…」窗口（含进度条）自动下载并安装官方 Node `.pkg`。
- 下载镜像按当前时区优选：中国大陆时区（UTC+07:30 ~ UTC+08:30）走 npmmirror CDN，其余走 nodejs.org 官方源。
- Node/npx 有效性校验：通过执行 `--version` 确认命令可真正运行，而非仅检查文件存在。
- 常规 macOS 编辑快捷键：Cmd+C/X/V/A、Cmd+Z/Shift+Z、Cmd+Q，以及单击即可粘贴（绕过 WebKit 剪贴板权限）。
- 页面内下载支持：拦截 `<a download>` 点击，弹保存面板并用原生 URLSession 下载，底部显示进度条；兼容标准导航下载（`WKDownload`）。
- 应用图标：纯白方形背景 + 居中图标，圆角交给 macOS 系统自动蒙版（符合 Apple HIG）。
- 打包与发布：
  - `build-app.sh` 编译 Swift 二进制并组装 `.app`。
  - `scripts/create-dmg.sh` 生成带 `/Applications` 快捷方式的 DMG。
  - GitHub Actions 发布工作流（`release.yml`）：推送 `v*` 标签自动构建 DMG 并附加到 Release。
  - `scripts/setup.sh` 面向开发者的构建工具链一键安装。
  - `install.sh` 面向最终用户：下载 DMG、安装到 `/Applications` 并启动。
- 开源协议：MIT License（`LICENSE`）。

### 变更

- Bundle identifier 由 `com.deepseek.dsh-webview` 改为 `com.deepvisus.harness-desktop`。
- README 结构重写，新增安装、运行时供给、签名与公证等章节。
