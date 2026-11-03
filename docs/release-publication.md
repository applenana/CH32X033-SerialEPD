# Ink Studio 0.4.0 / CH32X033 SerialEPD 首次开源发布

本项目自行编写的代码和文档采用 MIT License，第三方条件见 NOTICE.md。

## 下载与使用

- `serialepd.bin` / `serialepd.hex`：CH32X033F8P6 固件，SEP/1；BIN 起始地址 `0x00000000`，使用 WCH-Link 烧录。不要将此固件用于未知接线或其他芯片。
- `ink-studio-windows-x64.zip`：Windows 10/11 x64 便携程序。完整解压后运行 `ink_studio.exe`，保留 DLL 和 data 文件夹；必要时安装 VC++ x64 Redistributable。
- `ink-studio-android.apk`：Android USB OTG 版本；Release 优化但使用临时调试证书签名，仅供直接安装测试。跨构建可能需要卸载旧版后重装（先备份数据），不是商店正式签名版本。
- `serialepd.elf`、`build-info.txt` 用于调试和构建溯源；`SHA256SUMS.txt` 校验所有分发附件，项目源码由 GitHub 自动附加。

## 变更

- 图像处理在本地运行：四色预览、自由裁切与旋转、AUTO 调参、导出及可靠 USB 上传。
- 包含近期图像处理性能优化与画布适配控件改进。应用版本 `0.4.0+8`，固件协议 SEP/1。
- 新增 MIT 许可证、贡献及安全说明、固件/应用自动构建与发布流程。
- 发布前使用 Gitleaks 对完整历史、reflog 和所有本地 Git blob 扫描，未检出凭据。

## 验证与限制

固件原生测试、USB 模拟集成测试、Flutter 分析和应用/固件 FFI 集成测试，以及固件、Windows、Android 构建均为发布前检查。它们不替代实物烧录、电气时序、真实 USB 总线及 A0/A1 面板验收。

Windows 未作代码签名；Android 使用临时调试签名。请选择屏幕实际 A0/A1 批次；上传完成不等于刷屏完成。Linux/macOS/iOS/Web 未作为本版本支持平台。
