# 许可范围与第三方声明

本项目自行编写的代码和文档采用根目录 [MIT License](LICENSE)。维护者于 2026-11-03 确认已完成发布许可审查。已有第三方版权、许可及使用条件保持有效，不被根目录 MIT 许可证替换。

- **WCH SDK 与示例：** `Core/`、`Debug/`、`Peripheral/`、`Startup/`、`Ld/` 和 `User/` 中带 WCH 版权头的文件（包括 USB、系统初始化与异常处理代码）保留原声明。有关文件声明其软件及二进制用于南京沁恒微电子制造的微控制器。目标为 CH32X033F8P6。
- **图像重建：** [重建算法许可](app/assets/licenses/reconstruction.txt) 保留 OpenDisplay.org、Guy Sie 的 MIT 版权与来源说明，随 Flutter 应用资源分发。
- **Flutter 与原生依赖：** 各依赖遵循其自身许可；应用“关于”的开源许可页面包含 Flutter 汇集的声明。Windows libserialport 为动态链接的 LGPL 组件，应保留可替换 DLL；其源代码来源及构建包装见 [app/README.md](app/README.md)。
- **硬件研究来源：** MoInk 的屏幕寄存器及行为参考范围见 [docs/references.md](docs/references.md)。本项目的 MIT 授权不替上游或其他权利人授予任何许可。

再分发时请同时保留 LICENSE、本文件和适用的原始第三方许可声明。
