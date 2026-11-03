# 贡献指南

感谢你愿意改进 CH32X033 SerialEPD。提交问题或改动前，请先阅读根目录 README、`docs/protocol.md` 和适用模块的说明。

## 报告问题

请说明复现步骤、期望结果、实际结果、软件/工具链版本和相关日志。涉及设备时，请注明 CH32X033 板卡、屏幕批次（A0/A1）、USB 主机系统和接线。提交前检查日志、截图和示例文件中没有个人信息、设备标识或密钥。

## 提交改动

- 保持 SEP/1 文档、`docs/protocol-vectors.json`、固件、Python CLI 和 Flutter 应用相互一致。
- 新增协议行为时补充协议向量与相应测试；不要把模拟测试描述成实物验证。
- 固件改动运行 `python tools/test.py`；Flutter 改动在 `app` 目录运行 `flutter analyze` 和 `flutter test`。Flutter 的固件互通测试依赖先运行前述 Python 测试所构建的模拟库。
- 固件构建可运行 `python tools/build.py`，需要 WCH QingKe RISC-V 工具链。
- 使用清晰的提交说明，并在 PR 中写明改动、验证结果和未覆盖的硬件验证。

## 许可

本项目自有代码和文档采用 [MIT License](LICENSE)。除非明确说明并与维护者协商，否则向本项目提交的自有贡献按相同 MIT 许可提供。贡献者应有权提供所提交内容；第三方文件仍受其各自许可约束，并须保留来源与版权声明，详见 [NOTICE.md](NOTICE.md)。
