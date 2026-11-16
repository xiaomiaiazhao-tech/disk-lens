# 发布维护

## 社区预览版状态

- 已准备 MIT 源码、构建脚本、DMG 与 Homebrew 模板。
- 使用免费本地临时签名，未经苹果公证。
- 源码仓库：`xiaomiaiazhao-tech/disk-lens`；安装 Tap：`xiaomiaiazhao-tech/homebrew-tap`。
- 本地构建不需要 Apple 账号；第三方首次打开时仍可能被 Gatekeeper 拦截。

## 发布前检查

1. 确定 GitHub 账号与源码仓库，例如 `xiaomiaiazhao-tech/disk-lens`。
2. 核对 MIT 署名和第三方许可证。当前署名使用通用的 `DiskLens contributors`，可在公开前换成你希望公开的署名。
3. 在 `release.json` 填入真实仓库地址。`bundle_id` 目前沿用已有版本的 `local.disklens.cleaner`，以保持偏好和历史兼容。首次公开前可确定长期稳定的 ID；公开后随意更换会改变偏好、权限与应用识别。
4. 只把源码项目加入仓库，不上传 `build/`、`dist/`、本机报告、历史、签名密钥或临时清理脚本。
5. 执行本地验证：

```bash
make release-local REPOSITORY=xiaomiaiazhao-tech/disk-lens
```

`release.json` 和生成的 Cask 应始终指向真实仓库，安装 URL、版本和校验值必须对应同一个最终安装包。

## 发布顺序

1. 建立源码仓库，推送审核过的源文件。
2. 为这次构建对应的源码建立标签，例如 `v0.5.2`。
3. 在 GitHub Releases 上传 DMG、源码包和 `SHA256SUMS`，明确写明未公证与已知限制。
4. 建立 `xiaomiaiazhao-tech/homebrew-tap`，把生成的 `Casks/disk-lens.rb` 放入其中。
5. 核对 Cask 里的版本、下载 URL 与 SHA-256 对应同一个最终 DMG，再发布 Tap。
6. 在新用户环境实测下载安装和首次启动。当前仅有本地验证，不宣称完成跨机器验证。

发布后用户可安装：

```bash
brew tap xiaomiaiazhao-tech/tap
brew install --cask xiaomiaiazhao-tech/tap/disk-lens
```

不要用不带版本的下载链接，不要用 `sha256 :no_check`，也不要在 Cask 中自动移除 quarantine 或关闭 Gatekeeper。

## Homebrew 草稿与本地检查

```bash
python3 Scripts/render_cask.py --repository xiaomiaiazhao-tech/disk-lens
ruby -c dist/homebrew-tap/Casks/disk-lens.rb
```

可用 `--url file:///absolute/path/to/the.dmg --output build/local-cask.rb` 生成仅供本机开发检查的版本。不要发布含本机绝对路径的 Cask。本地 Ruby 语法检查不是完整 Homebrew 安装或跨机器验证。

## 免费方案的限制

ad-hoc 签名只可用于验证包在签名后未被修改，不提供可验证的开发者身份，也不能代替苹果公证。DMG 和 Homebrew 是分发方式，不会绕过系统检查。部分 Mac 或组织管理策略可能拒绝运行。

将来如果要降低普通用户首次安装的阻力，可以另外申请 Developer ID 签名和苹果公证。当前脚本不依赖证书、Apple ID、私钥、密码或云服务。

## 可选 CI

`.github/workflows/build.yml` 只允许手动触发，权限为只读。它执行测试、打包并上传 CI 工件，不创建 Release、不推送 Tap。最低成本的默认方式仍是在本机执行 `make release-local`。

参考：

- [GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)
- [Homebrew Tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)
- [Apple 首次启动说明](https://support.apple.com/en-us/102445)
