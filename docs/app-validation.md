# Ink Studio 应用验证记录

以下为 **0.3.0 历史验证**。0.3.1 依用户要求仅编译，见 [本版说明](release-0.3.1.md)，不能沿用本页作为回归通过结论。

日期：2026-10-28。目标：Windows x64、Android USB Host，SEP/1，768×552 BWYR。

## 已验证的软件层

- Flutter / Dart 静态检查无问题。
- Flutter 测试覆盖 CRC 标准向量、与固件文档相同的 COBS 编码、碎片帧、超长噪声后恢复、四像素 `0x1B` 打包顺序。
- 6 种算法均检查纯四色保持、PNG 与 2bpp 一致；检查中灰网点、透明白底、损坏文件拒绝、极端窄长图片有界裁剪。
- 蓝噪声秩表为完整排列；色域映射保持线性亮度；DBS 降低目标误差、严格保持初始四色占比，灰阶不混入红黄点。标准照片的独立尺度误差和对比图见 [算法记录](image-reconstruction.md)。
- 裁切坐标、90° / 任意角旋转、镜像、斜转白角有图像测试；真实手势测试覆盖四角裁切、框内移动、角度滑块、镜像、还原、确认和返回取消，1200×900、390×844、320×700 无布局异常。
- 完整帧传输模拟验证 DATA / COMMIT 丢应答只重试同一请求，取消不触发刷新，COMMIT 结果未知不主动 ABORT 或重复上传。
- **Dart 客户端直接 FFI 调用生产 `User/protocol.c` 和 `User/epd.c`**：A0、A1 完整 105,984 字节写入模拟 SPI，CRC 一致，故意丢 DATA / COMMIT 应答后仍只刷新一次，最终 DONE。
- 快速连续调参只发布最新图像；无效图片使旧帧失效，不能误发送。
- Flutter widget 检查 1440×1000、800×1000、390×844、320×700，无布局异常；Windows 和 Android 布局截图人工查看。
- 固件原有 35 项 Python/C 测试重新通过。硬件映射与固件未被本次应用开发改动；仅 IDE 源扫描增加排除 `app/`。
- 本轮完整 Flutter 测试 **32 项通过，0 跳过**，包含 A0 / A1 生产 C 固件 FFI 互通；`flutter analyze --no-pub` 无问题。相对前版 38 项，删除了六种算法的纯色用例和 Bayer 秩表用例，新增旧偏好迁移测试。
- Windows Release 构建成功，EXE 文件版本 `0.3.0+3`。启动后进程正常响应；本次原生窗口捕获工具两次超时（`FrameArrived timed out` / `window capture timed out`），未取得可靠的原生窗口操作观察，不将其计为已完成的视觉验收。文档截图来自 Flutter widget 渲染。
- Android `assembleRelease` 经可选镜像成功；标准构建的 Google Maven 下载曾因 TLS 握手失败，未将失败归为源码缺陷。APK `versionName=0.3.0`、`versionCode=3`，minSdk 24、targetSdk 36，包含 armeabi-v7a / arm64-v8a / x86_64；APK v2 签名验证通过，签名主体为 Android Debug（学习测试证书）。
- 发布工具检查源文件与构建的新旧顺序、ZIP CRC，生成 Windows ZIP、Android APK、SHA256SUMS 和源码提交信息。构建产物在 `build/releases/`，不提交到源码。

## 实物验收仍待完成

| 项目 | 验证方法 |
| --- | --- |
| Windows CDC 驱动 | 真机枚举 COM，连接、查询、重复插拔、端口占用恢复 |
| Android USB 权限和 CDC | 至少一台 USB Host 手机，首次授权、拒绝后重试、OTG 拔插 |
| A0 / A1 显示 | 各自批次发送四色色条、方向标记、照片；核对颜色、行映射、刷新结束 |
| 掉线与暂停 | 传输时拔线、刷新时拔线、手机切后台、手动熄屏，确认提示与重连状态 |
| 电源 | OTG 供电峰值和 LDO 压降、BUSY 实际时序、A1 停钟保持 CS |
| 图片与导出 | 两个平台系统文件选择器、不同来源图片、保存权限与导出后重新打开 |

截图、原生构建成功和模拟测试不能代替上述验收。实际颜色需要面板测量后才能进一步校准。
