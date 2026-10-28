# 两个 NFC 项目的色阶与混色研究

2026-10-28，源码阅读；没有运行其程序或做实屏测试。

## kur0neko/huawei-epd-pn532

[仓库](https://gitee.com/kur0neko/huawei-epd-pn532)，读取提交 `829848067b2ff6631ad1b55455e2ae5aa6a4c652`。网页读取失败后通过 Git 获取源码，只保存于忽略的 `build/research/`。

`image_codec.py` 的调色板是黑 `(0,0,0)`、白 `(255,255,255)`、黄 `(245,205,0)`、红 `(200,0,0)`。`pack_codes()` 明确拒绝大于 3 的色码，每像素两个比特。没有第五种颜色或每色多个浓度的图像编码。

默认 Atkinson：RGB 欧氏距离选最近墨色，将每通道误差除 8，整数向零截断，分给六个邻点，每次加误差后限幅，因此只扩散约 3/4 误差。保留原项目的左下边界规则；这不是新的硬件灰阶。另提供 Pillow Floyd–Steinberg 或关闭抖动。灰度照片模式也只产生黑白两个色号。

## wiwiwei/ink-nfc-lab

[ImageCodec.java](https://github.com/wiwiwei/ink-nfc-lab/blob/main/src/dev/inknfclab/ImageCodec.java) 同样输出 105,984 字节、四个色号；预览直接从四项调色板取色。

[ImageQuantizer.java](https://github.com/wiwiwei/ink-nfc-lab/blob/main/src/dev/inknfclab/ImageQuantizer.java) 使用同一组较暗红黄调色板。经典路径以 OKLab 距离选最近颜色，再进行蛇形 Floyd–Steinberg 扩散；中性灰和部分蓝色区域转成黑白，避免在四色不擅长的色域中产生杂色。这里的扩散误差仍按 gamma 编码 RGB 计算，不能称为全程线性光扩散。

[ResearchQuantizer.java](https://github.com/wiwiwei/ink-nfc-lab/blob/main/src/dev/inknfclab/ResearchQuantizer.java) 用 smoothstep 平滑控制低彩度和冷色区域的去色程度，并给这些区域的红黄候选加入惩罚。扩散核包含 FS、Sierra Lite、Stucki；有序模式用 Bayer 阈值在两个候选墨色之间分配点。这些都是空间混色，未增加像素状态。

## 对本项目的意义

两者都没有提供“本块面板支持原生多级灰度”的证据。多彩来自四色像素的面积比例、网点位置及预处理，人眼在一定距离将黑黄看成较暗黄、红黄看成橙色、黑白看成灰色。蓝绿仍超出可准确再现的范围，不能由软件无损恢复。

值得后续比较的是较暗红黄调色板、低彩度保护以及平滑冷色压缩。上述调色板在源码中确实存在，但源码没有让我们取得本块屏的色度测量数据，不能直接标成用户面板的实测校准值。当前 DBS 已保护严格中性灰，并保持初始四色占比；本轮不增加新的算法菜单，也不声称哪条路径实屏更好。保留三种传统抖动及现有两种重建，交由用户先测试串口修复版。

NFC 项目的像素旋转、列扫描、APDU、压缩包布局属于其原厂驱动板协议，不能直接替换本项目 SEP/1 行优先数据。借鉴图像算法不需要修改已经定义好的 USB 通信格式。

## 0.3.2 已实现的借鉴

新增可调“自然映射”，借鉴 ResearchQuantizer 的低彩度 / 冷色 smoothstep 保护与候选色惩罚思路，自行实现线性亮度守恒的预处理及按源图掩码抑制扩散串色。没有移植其 Java 实现，也没有采用未经本屏测量的暗红黄调色板。设置、算法细节及取舍见 [0.3.2 说明](release-0.3.2.md)。当前只编译，由用户比较实屏观感。
