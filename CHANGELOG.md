# Changelog

本项目所有值得注意的变更都会记录在此文件中。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.0.8] - 2026-08-16

### 新增

- **Linux 移植**：新增 `linux/` 原生壳（C++ + GTK3 + WebKitGTK 4.1，系统 WebView），功能与 macOS/Windows 对齐 —— 主题（跟随系统/明亮/暗黑）、菜单多语言（跟随系统/简体中文/English，持久化到 `~/.config/deepseek-harness/settings.conf`）、全屏、编辑快捷键、外部链接走系统默认浏览器、下载另存为 + 进度条、npm 版本检查、插件市场。新增 `.github/workflows/release-linux.yml`，随 `v*` tag 发布 **x86_64 与 arm64** 双架构的便携 tarball + `.deb` 包（arm64 在 ubuntu-22.04 交叉编译，与 x64 同为 glibc 2.35 基线）。
- Linux 窗口/任务栏图标：新增 256px PNG 图标，运行时从可执行文件同目录（便携包）或 hicolor 图标主题（`.deb` 安装）加载，替代原来的通用占位图标。
- Linux 自动安装 Node.js：首次启动缺少 node/npx 时自动下载安装最新 LTS 到 `~/.local/share/deepseek-harness/nodejs`（用户级、无需 root，与 macOS/Windows 一致），带进度对话框，装完自动启动服务；仅自动安装失败时才提示手动安装（`sudo apt install nodejs npm`）。中国时区自动使用 npmmirror 镜像（node 下载与 npm registry）。
- 三个平台发布工作流合并为单个 `release.yml`：macOS DMG、Windows x64/arm64 exe+MSI、Linux x86_64/arm64 tarball+.deb，一个 `publish` job 统一附加到 Release。
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
- Windows 双架构发布：GitHub Actions（`release-windows.yml`）产出 **x64 与 arm64** 的便携 exe 与 WiX MSI 安装包（`windows/installer/DSHWebView.wxs`），推送 `v*` 标签自动附加到 Release。
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
