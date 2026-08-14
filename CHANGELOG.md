# Changelog

本项目所有值得注意的变更都会记录在此文件中。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

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
