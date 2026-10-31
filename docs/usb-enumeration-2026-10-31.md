# 2026-10-31 USB CDC 枚举排查记录

## 已实机通过：官方 USB 驱动接入版

2026-10-31，用户烧录 `build/firmware/serialepd-wch-20261031.hex` 并重新上电后，明确反馈：**“已识别为 COM 设备”**。此前的设备描述符请求失败、代码 43 已在这次用户实测中消失。此结果只确认该 Windows 电脑上的 USB CDC 枚举，不等同于物理屏幕刷新或跨平台稳定性验收。

### 实现

- 新增 `User/ch32x035_usbfs_device.c/h`，从已实机通过的 WCH SimulateCDC V1.0.1 源文件移植，保留官方 USBFS 初始化、SETUP/IN/OUT 控制流、中断优先顺序和地址生效流程。
- `User/cdc.c` 改为有界 SEP/1 收发适配层，官方 UART2 转发替换为 EP2 接收、EP3 应答和 EP1 通知；不初始化 UART2，不占用 PA2 屏幕 BUSY 引脚。协议和屏幕状态机未修改。
- 采用官方 `PWR_VDD_SupplyVoltage()` → `USBFS_Device_Init()` 路径；恢复官方 `GPIO_IPD_Unused()` 初始化，并同步已验证示例中的 GPIO 源码（包含 CH32X033 的芯片识别修正）。供电仍为用户确认的 3.3 V。
- 保留请求字段校验、7 字节 line coding 长度校验、64 字节 OUT 上限、收包背压、重复 toggle 拒绝、发送分包/ZLP 和断连通知。休眠恢复保留端点 toggle 并重新允许收包。
- 沿用官方配置时序：SET_ADDRESS 在状态 IN 完成后生效，SET_CONFIGURATION 在 SETUP 阶段设置；适配层在旧协议状态清理前 NAK 数据 OUT。控制读取结束后的端点 0 ACK/ZLP 状态也保留官方行为。
- 空闲和未配置期间的主循环不再每轮反复屏蔽 USB 中断；只在确有共享状态操作时进入临界区。

此前模拟测试验证了自定义实现自身的预期，无法证明其外设时序与官方一致。本次通过替换整个控制路径及对齐初始化解决用户实测故障；没有通过单变量实机试验将原因唯一归结到某一行寄存器写入，不能把先前 RX_LEN 或 SETUP 修正宣称为唯一根因。

### 验证

- MounRiver WCH GCC 12.2.0，`rv32imac_zicsr / ilp32 / -Os`，`-Wall -Wextra -Werror` 编译通过；text=10512、data=44、bss=5184（含 2048 字节预留栈）。
- `python tools/test.py`：**46 项通过**。USB 模拟直接包含本次生产 WCH 驱动和 CDC 适配器。
- `tests/wch-control-trace.json`：从保留的官方驱动在本机寄存器模型上生成，39 个设备/配置/字符串描述符、地址、配置、line coding、DTR 事件逐项比较，端点 0 控制寄存器与应答数据一致。参考程序链接项目描述符，UART/PHY 为桩；这不是物理 USB 抓包。
- 新增完整路径模拟：USB 中断 → CDC → SEP/1 → EPD。A0/A1 各上传 105,984 字节，核对整帧 CRC、窗口、一次刷新及完成状态；总线复位后半帧丢弃和重新枚举通过。
- `flutter analyze --no-pub`：无问题；`flutter test --no-pub --reporter expanded --concurrency 1`：**49 项通过**。日志明确包含 A0/A1 原生 C 库集成用例，未跳过。硬件测试与软件模拟分别记录。
- HEX 每条记录校验和正确，地址从 0 开始，载荷与 10,556 字节 BIN 一致。USB DMA 缓冲区均 4 字节对齐，链接器 RAM/栈重叠检查通过。

### 通过版本

| 文件 | SHA-256 |
| --- | --- |
| `build/firmware/serialepd-wch-20261031.hex` | `5154f9492db6e7517d2931c11531f2fa27105f0f3af42e1646af7259e0907a42` |
| `build/firmware/serialepd-wch-20261031.bin` | `8808723e19d62412aa4261155512e44e2e6eacc8e2e2415223dfe33d142585bc` |
| `build/firmware/serialepd-wch-20261031.elf` | `3f3a5095c14b0cd2612b2c641ede17f0a05e02877c61d0cb886a32a0328109da` |

这些独立命名文件保留用户测试时的确切二进制。官方通过基线 `build/official-usbcdc/out/wch-simulatecdc-original.hex` 的 SHA-256 仍为 `becaff44ff34d64fcc28d55c0fc41ae6d0b1f9dd4e94fffcd9ff6b167369002e`，未覆盖。

日志：`build/setup-logs/usb-official-adapter-native.log`、`usb-official-adapter-build.log`、`usb-official-adapter-app.log`。本机 SDK、缓存、构建文件仍留在忽略的目录；没有推送 GitHub。

---

## 失败版本记录：SETUP 判断对齐（已被上方版本替代）

用户已确认官方原版 wch-simulatecdc-original.hex 正常工作，本项目固件此前仍报代码 43。官方原版是当前的实机通过基线；先前的接收长度类型修正没有证明能解决枚举问题。

进一步对照发现，官方 SimulateCDC 在 INT_ST 标识 SETUP 完成时直接解析端点 0 的请求缓冲区；项目额外要求 RX_LEN==8，不满足则 STALL。本轮删除这项额外条件，RX_LEN 只在 OUT 分支读取，其他请求字段校验和 OUT 长度边界检查保持有效。

测试用完整八字节 SETUP 缓冲区、独立变化的接收长度值验证该行为：旧代码会拒绝描述符请求，修改后通过。完整模拟枚举涵盖首次 8 字节描述符、复位、设置地址、完整设备/配置/字符串描述符和设置配置。测试注入的长度值并非从用户芯片实测取得，因此不能据此声称已经测得实机故障寄存器值或确认唯一根因。

本轮验证：原生测试 40 项通过，flutter analyze 无问题，Flutter 测试 49 项通过；完整测试日志明确包含 A0/A1 原生固件集成用例，无跳过。固件 text=8696、data=44、bss=5176。反汇编确认 SETUP 路径不再读取 RX_LEN，OUT 路径使用 16 位读取。

本轮完整功能产物：

- build/firmware/serialepd-setup-20261031.hex，SHA-256：2eda54bd950410bd9726517f0c0e3d677de00919628680b46785d48ab9066edf。
- build/firmware/serialepd-setup-20261031.bin，8740 字节，SHA-256：982fff39b144768527ad58d5d4385ededdfab28f8ca6a0760aa34eced8ff5946。
- build/firmware/serialepd-setup-20261031.elf，SHA-256：d163c76a7cd9660de857f7adac2d263f14ef2878122ecde989b0323b2fc775f8。

本轮固件实机测试失败：用户反馈“无法识别的设备”，并提供设备描述符请求失败、代码 43 截图。前轮 rx16 文件和下方记录保留供追溯，不代表本轮推荐烧录文件。日志：build/setup-logs/usb-setup-before-fix.log、usb-setup-after-fix.log、usb-setup-app-validation.log。

---
## 实机反馈与当前边界

新增实机结果：用户已确认 build/official-usbcdc/out/wch-simulatecdc-original.hex 可正常工作，而本项目固件仍发生描述符请求失败。此官方原版作为后续修复的已通过实机对照；不能继续把之前的 RX_LEN 修正当作已解决枚举故障。

供电已确认是 3.3 V。Windows 显示“未知 USB 设备（设备描述符请求失败）”，代码 43。第一次仅把 RX_LEN 读取结果转换成 uint16_t 后，用户重新烧录仍然失败。模拟测试通过不能作为实机问题已解决的证明。

当时修正实际 MMIO 访问宽度后，完整固件通过编译及软件验证；后续用户实机反馈仍失败。尚未读取故障芯片寄存器或捕获 USB 总线，不能声称已证实唯一根因。

## 官方对照及修正

本项目 Peripheral/inc/ch32x035.h 原为 WCH V1.0.2（2025/03/10），USBFSD_TypeDef.RX_LEN 定义为 volatile uint32_t。2026-10-31 下载的官方 V1.0.3（2025/10/29）已将其改为 volatile uint16_t，并补入 16 位保留区，保持后续端点地址不变。

WCH CH32X035 参考手册 V1.9 的 18.2.1.7（印刷页 219 / PDF 页 220）将 0x40023408 定义为 R16_RX_LEN，数据位为 [6:0]。

上一版 `(uint16_t)USBFSD->RX_LEN` 的反汇编仍是 `lw`，先执行 32 位外设读取再截断。本次回移官方结构修正后，最终 ELF 的 0x49A 为 `lhu a2,8(s1)`，s1 为 USBFS 基址 0x40023400，实际使用 16 位外设读取。

- 只回移 USBFSD 结构修正，不整体升级 SDK。
- cdc.c 新增寄存器访问宽度以及 RX_LEN、端点模式、DMA、控制寄存器偏移的编译期检查。旧头文件已实际触发检查失败，修正后通过。
- SETUP、控制 OUT、状态 OUT、批量 OUT 使用一次 16 位长度读取，保留无效长度拒绝。
- 测试模型区分 RX_LEN 和相邻保留半字，补充枚举、控制传输、批量收包回归。
- 3.3 V PHY、D+ 上拉及引脚初始化与官方示例核对一致。

## 验证

使用 MounRiver WCH GCC 12.2.0，rv32imac_zicsr / ilp32，-Os：

- `python tools/test.py`：39 项通过。
- `flutter analyze`：No issues found。
- `flutter test`：49 项通过。
- 单独运行 `flutter test --no-pub --reporter expanded test/firmware_integration_test.dart`：A0、A1 两项明确通过，加载已生成的原生 C 模拟库，未跳过。
- 完整固件编译通过；text=8728、data=44、bss=5176（含 2048 字节预留栈）。
- 最终机器码确认为半字读取；寄存器布局静态检查通过。

本机入口为已忽略的 build/local-dev/dev.ps1，完整日志为 build/setup-logs/usb-mmio-width-validation.log。模拟不覆盖真实外设总线访问行为、USB PHY 或 Windows 主机枚举。

## 烧录产物

完整生产固件含 SEP/1 和刷屏功能。以下独立文件名用于区分第一次失败的版本：

| 文件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| build/firmware/serialepd-rx16-20261031.bin | 8772 | 97fe4a2877878f748c078a3bc39a063858e30ff9ca908bf4d65bbc9c8fddb74b |
| build/firmware/serialepd-rx16-20261031.hex | 24707 | 151c010cb6d1f390da704d5d7aa88362c98543d6558f0f39695ea1450218fde3 |
| build/firmware/serialepd-rx16-20261031.elf | 140760 | eb904c175cfb2dcd559748fba36909949cce437c13e2413e01303f7cde76e441 |

常规 serialepd.bin/hex/elf 同步更新。BIN 从 0x00000000 烧录；HEX 自带地址。烧录后重新上电并插拔 USB，确认是否出现 COM 设备。

对照版本为 build/usb-diagnostics/wch-cdc-reference.hex，SHA-256 为 1e6b21091606a45d6c5cc23e28fd877f6be4c3ab1edf71b4fc2da4d0bd1daa0a。它使用未修改的官方 CDC 处理程序、描述符、启动和链接文件，以及本地最小入口和 UART 状态适配；固定 3.3 V，不运行屏幕、UART 转发、TIM2 或看门狗。它仅用于枚举定位，不支持刷屏。来源副本、构建脚本和产物都在已忽略的 build/ 下。

## 来源

- [WCH 官方 ch32x035.h](https://raw.githubusercontent.com/openwch/ch32x035/main/EVT/EXAM/SRC/Peripheral/inc/ch32x035.h)，SHA-256：1842a8c76c7be1596c22b032ff45cb48cf49afbf62ef0a33416aec8a3b5da1b6。
- [WCH SimulateCDC USB 处理程序](https://raw.githubusercontent.com/openwch/ch32x035/main/EVT/EXAM/USB/USBFS/DEVICE/SimulateCDC/User/ch32x035_usbfs_device.c)，SHA-256：6892e03a1309e2bfba7253cccc545aaf0502121eb1864a8675e87a7e71da5064。
- [WCH 参考手册 V1.9 的社区镜像](https://ch32-riscv-ug.github.io/CH32X035/datasheet_en/CH32X035RM.PDF)，已阅读 18.2.1.6–18.2.1.7；作者为 WCH。

开发机工具链、缓存和本地辅助脚本未加入源码变更；没有推送 GitHub。
