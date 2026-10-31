# 验证记录

2026-10-31 增补：[USB CDC 枚举修复与实机通过记录](usb-enumeration-2026-10-31.md)。官方 USB 驱动接入版 serialepd-wch-20261031.hex 已获用户确认“已识别为 COM 设备”。46 项原生测试、49 项应用测试通过，静态分析无问题；包含 A0/A1 原生集成与 USB 整帧模拟。物理屏幕刷新尚待验收。以下保留 2026-10-28 的历史记录，其中旧版“待测”不覆盖本次 Windows 枚举实测。

软件验收日期：2026-10-28。以下记录只覆盖当前源码的编译和模拟运行；尚未向连接的实机烧录，也没有实际屏幕刷新、USB 总线抓包或电源测量结果。

## 构建

命令：`python tools/build.py`。

工具链：MounRiver 的 xPack GNU RISC-V Embedded GCC 8.2.0；目标 `rv32imac` / `ilp32`，`-Os`，生产 C 源启用 `-Wall -Wextra -Werror`。输出 BIN、HEX、ELF、MAP 和编译信息，位置为 `build/firmware/`。

当前版本目标构建结果见 `build/firmware/build-info.txt`。链接范围为 62 KiB Flash、20 KiB RAM；栈预留 2048 字节。GNU size 的 bss 会把 `.stack` 也计入，不能把这 2 KiB 再重复累加。尚未进行实机栈水位或最坏中断嵌套测量。

本次 GCC 8.2.0 构建：text=9024、data=52、bss=5184（含 2048 字节栈）；Flash 共 9076 字节，静态变量共 3188 字节，连同预留栈共占 RAM 5236 字节。构建脚本输出 `SHA256SUMS.txt` 供复制烧录文件后校验。

## 自动化测试

命令：`python tools/test.py`。当前 **35 项通过**。

- 将生产 `User/protocol.c` 和 `User/epd.c` 编译为本机动态库，Python 真实协议客户端直接驱动该 C 库，板级层模拟 SPI/GPIO/BUSY。
- COBS 边界 0/253/254/255/792 字节、CRC32 标准向量、包拆分/粘连、半帧超时、超长、损坏 CRC、坏版本/flags/reserved。
- 3,000 个随机畸形帧及 2,000 个 CRC 合法但命令参数随机的请求；确认不意外启动刷新并可重新同步。
- A0 全部 552 行 gate 映射、A1 连续 CS、105,984 字节完整写入及最终 CRC；MoInk 网页/驱动的两次旋转与本协议普通行优先布局等价。
- 丢失 ACK 后 DATA 不重复写入，COMMIT 不重复刷新；只读查询不破坏幂等缓存；旧会话、乱序、错误 offset、行长度错误、整帧 CRC 错误均被拒绝。
- BUSY 卡死、SPI 失败、30 秒上传空闲超时、120 秒总上传期限、USB 逻辑断开、刷新中断连后新会话观察、32 位计时器回绕。
- 真实 Python Client + C 固件的端到端上传：模拟 OPEN/DATA/COMMIT 各丢一次应答、11 字节短写与 7 字节短读，最终只刷新一次。
- 生产 `User/cdc.c` 在 USB 寄存器模型下测试：设备/配置描述符多包读取、地址/配置的 status-stage 生效、非法控制请求 STALL、line coding、DTR、SerialState 通知及 DATA toggle、OUT 背压/重复 USB toggle、IN 分包/整包 ZLP、端点 halt/clear、挂起和复位。
- 图片透明度处理、2bpp 打包、测试图生成和四色预览。
- 文档中固定编码向量与客户端编码一致；GCC 16 的 `-fanalyzer` 检查协议、屏幕状态机及寄存器模型下 CDC 代码，无诊断。

寄存器模型不模拟真实 USB PHY、DMA 总线竞争、主机驱动、硬件 FIFO 长度保护或精确中断时序。模拟通过只证明受测的软件逻辑，不证明 USB 规范认证或实物可用性。

## 待实机验收

| 项目 | 目前状态 | 验收标准 |
| --- | --- | --- |
| 3.3V USB CDC 枚举 | 待测 | Windows/Linux 至少各一台，重复插拔、端口打开关闭、状态查询稳定 |
| A0 全屏图 | 待测 | 四色正确，方向正确，上下半屏交界无错行 |
| A1 全屏图 | 待测 | 分块停钟期间 CS 持续低可用，600 gate 刷新窗适合此批次 |
| BUSY 时序 | 待测 | 用逻辑分析仪确认低有效、assert/release 与实际刷新对应 |
| USB 与刷屏并行 | 待测 | 长刷新期间 INFO/STATUS 可响应，没有异常重枚举 |
| 异常中断 | 待测 | 上传未提交不主动刷新；刷新中掉电后的行为有记录 |
| 电源与温度 | 待测 | 记录峰值电流、3.3V 压降、实际环境下刷新时间 |
| 看门狗和栈 | 待测 | 人工卡住主循环可恢复；栈水位有余量 |

## 故障定位

- 没有串口：先检查 PC16/PC17、3.3V 和 SW1 未按住、USB 线包含数据线；确认系统对 `1A86:FE0C` 的绑定。不要把实际电路改成其他开发板接线来迁就示例。
- INFO 可读、BEGIN 后 ERROR/driver_error=2：检查屏幕供电、BUSY=PA2、RST=PA1、DC=PA0 和屏幕批次。
- A0 driver_error=4：刷新后没看到 BUSY 拉低，检查 SPI/CS/DC、BUSY 连接及批次；不是“刷新很快”。
- A1 保持 REFRESH：至少等待 14 秒；最长刷新 BUSY 180 秒。超时后检查电源、批次和屏幕接口。
- result=SEQUENCE：重试是否用了相同 payload，是否混入另一个写入客户端；不能跳过未知执行结果。
- last_error=TIMEOUT：READY 后 30 秒没有新的有效图像块，或 120 秒总上传期限已到；INFO/STATUS 不能用于无限保活。
- 上传 100% 但未 DONE：仍在刷新或收尾，查询 STATUS。USB 断开/复位后不要假设上次提交一定成功。

详细的首次验收顺序见 [硬件说明](hardware.md)。
