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
