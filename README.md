# 空间镜 · DiskLens

本机运行的 macOS 磁盘分析与清理工具。Swift 原生引擎、AppKit 窗口和本地 WebKit 界面，MIT 开源协议。

**当前为社区预览版，发布方式为免费、本地临时签名（ad-hoc）、未苹果公证。** 不需要付费 Apple 开发者账号；不能保证在其他 Mac 上免安全提示安装。源码、安装包和 Homebrew 配置在本账号下维护。安装前请阅读下方已知限制。

## 能做什么

- 查看真实磁盘容量，按分配空间估算绘制目录面积图。
- 快速检查常用位置、分析内部 Data 数据卷，或选择一个文件夹。
- 大文件筛选、路径搜索；占用估算与逻辑大小分别标明。
- 手动执行 SHA-256 内容查重，每组至少保留一份。
- 显示系统保护、默认保护、权限不足等标记与原因。
- 审核文件、受控缓存目录及应用本体，确认后移到系统废纸篓。
- 查看本机清理记录并尝试恢复。
- 停止后在**本次 App 会话中**继续扫描。

## 先了解这些边界

“内部数据盘分析”扫描 `/System/Volumes/Data` 的可访问内容。它包含用户目录和多数应用资料，**不等于逐文件扫描所有系统卷、VM 卷、快照和其他挂载卷**。权限失败会记录，不会自动申请管理员权限或打开完整磁盘访问权限。

数据盘模式把所有已读取普通文件累计到目录，仅保存逻辑大小 1 MiB 及以上的文件明细；最多保留一百万条明细，达到后继续累计目录。快速检查和自选范围达到一百万文件上限后停止，并标明部分结果。

扫描位置只保存在内存。退出 App、切换范围，或成功清理／恢复后，需要重新扫描。扫描不是冻结的文件系统快照，期间文件可能变化。

“分配空间估算”来自文件系统块数。APFS 克隆、压缩、硬链接和快照会影响实际可释放量。`Docker.raw` 等稀疏文件的逻辑容量可能很大，不能当作实际占用。

固定保护规则仅辅助判断，无法识别所有重要文件。缓存也可能包含离线附件；普通文件仍需自行核对用途和备份。只移到废纸篓，不提供清空废纸篓或永久删除，移动后通常不会立即释放空间。

## 安装

### 下载 DMG

从 [GitHub Releases](https://github.com/xiaomiaiazhao-tech/disk-lens/releases) 下载 [DiskLens-0.5.2-universal.dmg](https://github.com/xiaomiaiazhao-tech/disk-lens/releases/download/v0.5.2/DiskLens-0.5.2-universal.dmg)，打开后把“空间镜.app”拖到“Applications”快捷方式。

首次打开的系统提示和免费版本限制见 [安装说明](docs/INSTALL.txt)。下载后请使用同一 Release 中的 SHA256SUMS 核对校验值。

### Homebrew

通过 [本项目的 Homebrew Tap](https://github.com/xiaomiaiazhao-tech/homebrew-tap) 安装：

```bash
brew install --cask xiaomiaiazhao-tech/tap/disk-lens
brew upgrade --cask disk-lens
brew uninstall --cask disk-lens
```

Homebrew 负责下载、校验和安装 App，不会绕过 macOS 安全检查。卸载仅移除 App，不清理个人文件、偏好和清理记录。无需使用 `sudo` 安装本项目，也不提供 `curl | bash` 安装脚本。

## 从源码构建

需要 macOS、Apple Command Line Tools（含 Swift/macOS SDK）或完整 Xcode，以及 Python 3.9+。UI 回归测试还需要 Node.js；运行 App 不需要 Python、Node 或联网下载依赖。

如果尚未安装 Command Line Tools，可自行运行 `xcode-select --install` 并完成系统安装流程。无需购买 Apple Developer Program 会员。

```bash
make test
make build
make dmg
make verify
```

或一条命令完成本地测试、通用 App、DMG、校验、Homebrew 草稿和源码压缩包：

```bash
make release-local
```

输出位于 `dist/`：

```text
空间镜.app
DiskLens-0.5.2-universal.dmg
DiskLens-0.5.2-source.zip
SHA256SUMS
homebrew-tap/Casks/disk-lens.rb
```

所有发布脚本只在本机工作，不创建 GitHub 仓库或 Release、不推送代码、不上传安装包、不安装或替换 `/Applications` 中的应用。可选 GitHub workflow 仅在手动触发时构建工件，不执行公开发布。

## 只读命令行检查

Homebrew 命令用于安装 GUI App；本项目暂不额外链接独立的终端命令。开发者可直接运行 App 内的只读检查入口：

```bash
"dist/空间镜.app/Contents/MacOS/DiskLens" --help
"dist/空间镜.app/Contents/MacOS/DiskLens" --inspect /path/to/folder
```

JSON 输出包含完整文件路径，请自行保管。命令行不提供删除接口。

## 项目结构

```text
Source/       Swift 引擎、原生窗口和入口
Web/          本地界面源码与 SVG 图标
Resources/    App 图标
Tests/        临时文件回归测试和界面逻辑回归
Scripts/      构建、DMG、校验、Homebrew 与源码归档
packaging/    Homebrew Cask 模板
docs/         安装、发布和扫描范围说明
licenses/     第三方许可
release.json  版本与打包配置
```

详细发布步骤见 [docs/RELEASING.md](docs/RELEASING.md)，隐私说明见 [PRIVACY.md](PRIVACY.md)。

## 验证情况

本地验证覆盖扫描累计、稀疏文件口径、查重、安全拦截、停止／继续和临时文件的废纸篓移动／恢复。测试只修改自己创建的临时文件，不把个人资料当作测试目标。生产 App 不编入测试入口。

包含 arm64 与 x86_64 两种架构。Apple 芯片 Mac 已做本地构建与验证；Intel 完成编译，尚未实机验证。尚无 Developer ID 签名、苹果公证和独立安全审计，不能据此宣称生产环境全面验证完成。

## 许可证

[MIT](LICENSE)，Copyright (c) 2026 DiskLens contributors。图标许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
