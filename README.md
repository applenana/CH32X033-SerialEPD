# CH32X033 SerialEPD

运行在 **CH32X033F8P6** 上的 USB CDC 四色墨水屏固件，针对用户提供的 3.3V 电路和华为拆机 **768×552 黑/白/黄/红**屏。第一版版本号 **0.1.0**，通信协议 **SEP/1**。

已完成固件、通信规范、Python 上位机、图片转换、测试图和自动化测试。已用 WCH RISC-V 工具链构建出 BIN/HEX/ELF；**尚未连接实物进行 USB 枚举、刷屏和电气时序验收**。参考项目的实机验证结果不等于本项目已完成实机验证。

另提供 **墨屿 · Ink Studio 0.3.2** Flutter 上位机：Windows / Android USB CDC 连接、自由裁切与旋转、6 种精选四色重建算法、预览、导出与可靠上传。详见 [软件使用与构建](app/README.md)、[算法对比](docs/image-reconstruction.md) 和 [软件验收](docs/app-validation.md)。本机直接运行 `app/build/windows/x64/runner/Release/ink_studio.exe`；Android 编译输出为 `app/build/app/outputs/apk/release/app-release.apk`。默认只编译，不打包。

## 能力与约束

- 标准 USB CDC ACM，USB FS 12 Mbps，Windows/Linux/macOS 上位机可通过串口 API 通信。115200 等 line coding 仅为兼容参数，不限制 USB 吞吐；不依赖 DTR 才能收图。
- A0、A1 两种批次显式选择；A0 使用隔行 gate 映射，A1 使用 768×552 连续写入和 768×600 刷新窗口。
- 不申请 105,984 字节帧缓存：每块最多 768 字节，包校验通过后写屏幕 RAM，全部接收且整帧 CRC32 正确后才接受刷新。
- COBS 分帧、CRC32、随机会话号、单调请求序号、精确重复请求缓存、字节偏移检查、超时取消、非阻塞刷新、USB NAK 背压和看门狗。
- 断电前的完整画面由墨水屏保持；传图中断不会主动发送刷新命令。刷新已经启动后无法回滚，异常掉电可能留下中间画面。
- v1 只提供全屏刷新；无局刷、屏幕读回、图片存储、多图轮播、固件 OTA、跨复位续传或压缩。不反复写 MCU Flash 存图。

## 硬件

| 信号 | MCU GPIO | CH32X033F8P6 管脚 |
| --- | --- | --- |
| EPD CLK | PA5 | 20 |
| EPD DIN / MOSI | PA7 | 2 |
| EPD CS | PA4 | 19 |
| EPD DC | PA0 | 14 |
| EPD RST | PA1 | 15 |
| EPD BUSY，低有效 | PA2 | 16 |
| USB D− | PC16 | 5 |
| USB D+ | PC17 | 6 |
| 调试 SWDIO / SWCLK | PC18 / PC19 | 8 / 18 |

MCU 与屏幕逻辑电源为 3.3V，SPI1 默认 Mode 0 / MSB first / **3 MHz**。详细说明见 [硬件与驱动](docs/hardware.md)，电路图片见 [原理图](docs/hardware-schematic.png)。

## 构建与烧录

在仓库根目录运行（Python 3.10+）：

```powershell
python tools/build.py
```

脚本会查找 PATH、`WCH_GCC` 和常见 MounRiver Studio 2 安装目录。也可显式指定：

```powershell
python tools/build.py --gcc "A:/MounRiverStudio/MounRiver_Studio2/resources/app/resources/win32/components/WCH/Toolchain/RISC-V Embedded GCC/bin/riscv-none-embed-gcc.exe"
```

输出位于 `build/firmware/`：`serialepd.bin`、`serialepd.hex`、`serialepd.elf`、`serialepd.map`、`build-info.txt`、`SHA256SUMS.txt`。用 WCH-Link / MounRiver 选择 CH32X033F8P6，通过 PC18/PC19 烧录；BIN 起始地址为 **0x00000000**。不要覆盖芯片出厂系统引导区或修改与本工程无关的选项字节。

原 MounRiver 工程保留，`User/` 下 C 文件需要全部参与编译；已从 IDE 源文件扫描排除 `tests/`、`tools/`、`build/`。推荐以 Python 构建脚本作为可重复构建基线。链接脚本保留模板的 62 KiB Flash / 20 KiB RAM 和 2 KiB 栈，并增加栈区重叠断言。原链接脚本为 CR 换行，已规范为 LF。

正常固件启用约 2.7 秒看门狗，所有长时间 BUSY 等待都在主循环分步运行。调试器断点调试时，可在 IDE 编译定义中加入 `SERIAL_EPD_DISABLE_WATCHDOG`；正式使用应保留看门狗。

## 上位机快速开始

```powershell
python -m pip install -r tools/requirements.txt
python tools/serialepd.py ports
python tools/serialepd.py info --port COM7
python tools/serialepd.py status --port COM7
python tools/serialepd.py pattern build/test-pattern.epd --preview build/test-pattern.png
python tools/serialepd.py send build/test-pattern.epd --port COM7 --panel a0
```

`COM7` 换成实际端口；Linux 常见 `/dev/ttyACM0`，macOS 常见 `/dev/cu.usbmodem...`。**必须依据屏幕批次选 `a0` 或 `a1`**，电路图不能判定批次，固件不自动探测或轮流尝试不同高压初始化序列。A1 示例把 `--panel a0` 改成 `--panel a1`。

转换图片后发送：

```powershell
python tools/serialepd.py convert photo.jpg build/photo.epd --preview build/photo.png --fit contain --dither
python tools/serialepd.py send build/photo.epd --port COM7 --panel a1
```

默认保留比例、白边补齐；`--fit cover` 居中裁切。`--rotate 90/180/270` 在转换前逆时针旋转；自动处理 EXIF 方向和透明背景。`--dither` 启用 Floyd–Steinberg 四色抖动，预览为量化后的实际像素。`.epd` 是无文件头的 105,984 字节裸图，不是 MoInk 的上传文件。

CLI 传图会等待初始化就绪，再逐块上传，最后发送 COMMIT，并一直查询到 `DONE`；100% 上传只表示数据写完，尚未表示刷屏完成。A1 最短保留 14 秒刷新等待，最长正常配置允许约 180 秒 BUSY 等待。

`info` / `status` 是无会话只读查询，不取消别人正在进行的上传。`send` 会打开新会话并接管尚未刷新完成的上传事务；已有刷新正在执行时不会再次刷新。`abort --port COM7` 明确取消未提交的事务；刷新期间返回 BUSY。

## 协议与开发

- [SEP/1 通信规范](docs/protocol.md)：字节布局、状态机、所有命令、错误码、超时、重试和扩展约定。
- [协议测试向量](docs/protocol-vectors.json)：可用于其他语言上位机互通。
- [硬件与驱动](docs/hardware.md)：接线、复位、A0/A1 写入差异、按钮行为。
- [验证记录与实机验收](docs/validation.md)：已验证与待验证边界、故障定位。
- [参考来源](docs/references.md)：MoInk、WCH SDK 和许可说明。
- [Ink Studio](app/README.md)：Windows / Android 应用、自由裁切、照片重建与构建。

核心文件：`User/protocol.c` 为不依赖 MCU 寄存器的协议/事务层；`User/epd.c` 为屏幕状态机；`User/board.c` 为 SPI/GPIO/毫秒时钟；`User/cdc.c` 为 USB 控制和收发；`tools/serialepd.py` 同时提供可导入的 Python 客户端和 CLI。

运行软件验证：

```powershell
python tools/test.py
python tools/build.py
git diff --check
```

测试需要本机原生 GCC（Windows 64 位 Python 配 64 位 MinGW GCC）。脚本自动识别 `C:/msys64/mingw64/bin/gcc.exe`，或设置 `HOST_CC`。原生测试直接编译生产协议和屏幕状态机，USB 测试用寄存器模型执行生产 CDC 代码；这不能替代实际 USB 总线和屏幕验证。
