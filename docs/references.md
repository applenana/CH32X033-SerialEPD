# 参考来源与复用范围

核对日期：2026-10-28。

应用图像算法来源见 [图像重建研究](image-reconstruction.md)，本块面板的多级灰度核查见 [面板灰度能力](panel-grayscale.md)。本地学习开发保留来源记录，便于继续研究。

## MoInk

- [atunverse/moink](https://github.com/atunverse/moink)：用户指定的华为 768×552 黑白黄红拆机屏参考项目。
- [src/epd_drv.c](https://github.com/atunverse/moink/blob/main/src/epd_drv.c)：A0/A1 寄存器参数、初始化次序、A0 gate 映射、A1 600 gate 刷新范围、BUSY 低有效和提前释放处理。读取时该文件 Git blob SHA 为 `1bec8edd930122456e3bb7bc341c7dd95b715d55`。
- [page/index.html](https://github.com/atunverse/moink/blob/main/page/index.html)：`packIdx` 的 180° 像素契约及四色编码。
- [src/frame.h](https://github.com/atunverse/moink/blob/main/src/frame.h)：仅用于理解原项目格式；其中一些旧尺寸说明落后于当前驱动，实际以 epd_drv.c 的 768×552 路径为准。

本工程保留必要的屏幕寄存器参数和操作顺序，重新实现无帧缓存、非阻塞状态机，不引入 ESP-IDF/FreeRTOS/Wi-Fi/Web/OTA 代码。SEP/1 不兼容 MoInk HTTP 帧协议；这里只复用硬件行为研究，不声称兼容原网页直接上传。

读取时 GitHub 没有为 MoInk 标注许可证。本工程不替上游授予任何许可，不把上游整套工程重新标注为 MIT；发布和再分发时需分别处理参考代码、WCH SDK 与本工程新增部分的许可。

## WCH

- [官方 CH32X035/X033 SDK](https://github.com/openwch/ch32x035)。原仓库已包含 Core、Peripheral、Startup、Debug 和项目模板，原版权头保留。
- [USBFS SimulateCDC 示例](https://github.com/openwch/ch32x035/tree/main/EVT/EXAM/USB/USBFS/DEVICE/SimulateCDC/User)：USBFS 端点布局、DMA、PC16/PC17 与 3.3V PHY 初始化。`usb_desc.c/h` 从官方示例导入并修改产品名；其 WCH 版权与芯片使用限制保留。`cdc.c` 重写有界收发与严格控制请求处理，未保留 UART 转发部分。
- [IWDG 示例](https://github.com/openwch/ch32x035/blob/main/EVT/EXAM/IWDG/IWDG/User/main.c)：32 分频 / reload=4000 的约 2.7 秒看门狗配置。
- [官方资料索引](https://github.com/openwch/ch32x035/blob/main/Datasheet/README_zh.md) 指向 [数据手册](https://www.wch.cn/downloads/CH32X035DS0_PDF.html)、[参考手册](https://www.wch.cn/downloads/CH32X035RM_PDF.html) 和 [QingKe V4 手册](https://www.wch.cn/downloads/QingKeV4_Processor_Manual_PDF.html)。本次网页版需 JavaScript，未取得可检索 PDF 全文，未将未读取的细节作为实测结论。

WCH 文件注明仅适用于南京沁恒微电子制造的微控制器，本工程目标 CH32X033 属于该范围。

USB VID/PID 暂沿用官方示例 `1A86:FE0C`，仅作开发联调身份，不代表本项目获得独立 USB 产品 ID 分配。产品化需采用有权使用的 VID/PID，并重新验收目标系统的驱动绑定。当前不公布虚假的固定唯一 USB 序列号（iSerialNumber=0）。
