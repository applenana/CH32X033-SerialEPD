# 开源与发布说明

## 许可

维护者于 2026-11-03 选择 MIT 并确认已完成许可审查。本项目自行编写的代码和文档采用根目录 [LICENSE](../LICENSE)，贡献规则见 [CONTRIBUTING.md](../CONTRIBUTING.md)。WCH SDK、示例与其他第三方组件保留原有条件，范围见 [NOTICE.md](../NOTICE.md)；根目录 MIT 不替换第三方版权或芯片使用限制。

## 自动构建与 GitHub Release

工作流在 PR、推送到 main、手动触发和 v* 标签推送时运行：

- 从 WCH 官方 board manager 索引所列地址取得 GCC 8.2.0，并验证固定 SHA-256。该编译器支持源码的 WCH-Interrupt-fast 属性；普通上游 RISC-V GCC 不能直接替代。
- 构建固件 BIN/HEX/ELF 并运行原生固件、USB 控制器及 SEP/1 集成测试。
- 使用 Flutter 3.41.9 执行分析和完整测试；先构建并检查模拟库，确保固件 FFI 集成测试实际运行。
- 构建 Windows x64 便携目录和 Android Release APK。
- 仅在 v* 标签构建且所有检查通过后创建 Release 草稿，附上固件、Windows ZIP、APK、许可、构建信息和覆盖全部附件的 SHA-256 清单。维护者确认草稿附件后发布，避免用户看到未完成的产物集合。

发布时更新 app/pubspec.yaml、版本记录和 docs/release-publication.md，让标签对应应用版本；推送审阅后的提交及版本标签。检查 Actions 全部成功后公开 Release 草稿。不要移动已发布的版本标签。

Windows 输出未代码签名；Android APK 是 Release 优化构建，但使用临时调试密钥，只供直接安装测试，不保证跨构建覆盖安装。正式商店发行需要维护者自己的稳定签名、版本及密钥备份流程。密钥不能提交到 Git。

目前仅支持 Windows x64 和 Android；Linux/macOS/iOS/Web 未作为发布平台。构建和模拟测试不替代真实 WCH-Link 烧录、USB 总线与屏幕电气/时序验收。

## Git 历史凭据扫描

2026-11-03 在基线 eef131243dcd78e11f6484df070017c0624929f9 上执行 Gitleaks **8.30.1**，扫描器从官方 Release 下载并通过官方校验清单验证 SHA-256。

1. Gitleaks git 模式加 --all --reflog --full-history、100% 脱敏：39 个历史提交，约 1.56 MB 的补丁内容，退出码 0，未检出凭据。
2. 通过 git cat-file --batch-all-objects 导出本地对象库所有 348 个唯一 blob（包含不可达对象，共 5,885,656 字节），再次用 Gitleaks 默认规则、递归解码及归档深度 2 扫描，退出码 0，未检出凭据。
3. 补查文件名、本机用户目录、Git LFS 指针与作者邮箱：未发现敏感文件名或个人目录路径，无 LFS 指针；提交作者使用 GitHub noreply 地址。12 个二进制 blob 也纳入对象扫描，但扫描器不能识别图片里的文字。

脱敏机器报告保存在忽略目录 build/gitleaks-history.json、build/gitleaks-objects.json 和 build/privacy-scan-summary.json，不作为仓库发布内容。提交许可及发布配置后会对最终历史再扫描。未检出不等于绝无秘密，后续提交仍需审查；不对未知外部副本或图片视觉内容作保证。此前检查的当前 PNG 图片未见个人元数据。

复核时执行：gitleaks git --log-opts="--all --reflog --full-history" --redact=100 .

.gitignore 排除常见本机配置、构建输出和密钥；忽略规则不等于秘密管理。发现真正凭据时应先撤销/轮换，再决定如何清理历史，不能仅删除当前文件。建议在 GitHub 启用可用的 secret scanning / push protection。

## 后续事项

- 稳定 Android 发布签名、Windows 代码签名和安装器属于后续发行工作。
- SBOM、额外平台、可复现构建和测量过的面板色彩校准尚未提供。
- 真正的 A0/A1 面板、USB 主机兼容性和电气验收应单独记录。
